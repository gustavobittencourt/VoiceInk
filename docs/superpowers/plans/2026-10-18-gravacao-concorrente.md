# Gravação concorrente — plano de implementação

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** permitir iniciar uma gravação nova enquanto as anteriores ainda são transcritas ou melhoradas, com entrega FIFO, cada texto no app de origem da sua gravação.

**Architecture:** cada gravação parada vira um `RecordingJob`, que leva o próprio áudio, sessão, configuração, contexto, modo congelado e app de origem. Uma fila pura (`RecordingJobQueue`, só Foundation) roda o processamento de um item por vez. A entrega de cada item espera os anteriores e a ausência de gravação viva. O engine separa o estado da gravação viva (`liveState`) do estado exibido no painel (`recordingState`), que é derivado da gravação viva ou do item da vez.

**Tech Stack:** Swift 5, SwiftUI, AppKit, SwiftData, XCTest. O teste da lógica pura roda via `swiftc` + `xcrun xctest`, fora do host app.

**Spec:** `docs/superpowers/specs/2026-10-18-gravacao-concorrente-design.md`

## Global Constraints

- Sem dependência nova. Diff contido: não mover nem renomear arquivos existentes, porque o branch `local` é rebaseado sobre `origin/main` a cada `voiceink-update`.
- Comentários novos em PT-BR, no estilo do patch "Colar no app de origem" (`TranscriptionDelivery.swift:5-13`). Identificadores em inglês.
- Texto de UI novo em inglês com `String(localized:)`, como o resto do app.
- Com a fila vazia, o comportamento tem de ser idêntico ao de hoje: sons, painel, colagem, follow-up do assistente.
- Não substituir `/Applications/VoiceInk.app`. O `make local` grava em `~/Downloads/VoiceInk.app`, o que está liberado.
- Commits só pela skill `/commit` (staged) ou `/commits`.
- Compilação incremental por task (chamada de **BUILD** abaixo), na raiz da worktree:
  ```
  xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Release -derivedDataPath .local-build -xcconfig LocalBuild.xcconfig CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM="" CODE_SIGN_ENTITLEMENTS="$PWD/VoiceInk/VoiceInk.local.entitlements" SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) LOCAL_BUILD' -skipPackagePluginValidation -skipMacroValidation build > /tmp/vi-build.log 2>&1; echo rc=$?
  ```
  Passa com `rc=0` e `** BUILD SUCCEEDED **` em `/tmp/vi-build.log`. Também é preciso que `grep -c 'warning:.*\(RecordingJobQueue\|PasteTargetPolicy\)' /tmp/vi-build.log` dê 0.
- Teste unitário (chamado de **UNIT**): `make test-unit > /tmp/vi-unit.log 2>&1; echo rc=$?`. Passa com `rc=0`, e o resumo do `xctest` mostra o total de testes com 0 failures.

## Review Focus

1. **Atalho ou Esc durante o `await recorder.stopRecording()`.** A janela de parada é curta. O atalho tem de ser ignorado e o Esc tem de cancelar só a gravação que está parando, sem tocar na fila. A flag `isStoppingLiveRecording` cobre isso no `toggleRecord` e no `cancelRecording` (Task 3, itens 3 e 9). O cooldown de 0,5 s do atalho (`RecordingShortcutManager.swift:388-392`) já engole pressões rápidas, então o E2E não consegue provar a flag isoladamente. Ela fica para a revisão de código.
2. **Três gravações em rajada com o enhancement lento.** Ordem e destino têm de valer por item, e o item 3 não pode esperar a entrega do 1 para começar a transcrever. Coberto por `testNextJobProcessesWhileEarlierWaitsForDelivery` e `testDeliveriesFollowEnqueueOrder` (Task 1).
3. **App de origem fechado antes da entrega.** O texto vai para o clipboard com notificação, sem colar no app da frente. Coberto por `testTerminatedTargetCopiesToClipboard` e `testTargetThatNeverFocusesCopiesToClipboard` (Task 2).
4. **Esc duplo com gravação viva e fila.** Cancela só a gravação viva; a fila segue e o painel continua visível. Verificado à mão no E2E (Task 5, passo 7). A lógica fica em `RecorderUIManager.cancelRecording` (Task 4).
5. **Item que termina sem entregar** (transcrição falhou, cancelado) não pode travar os seguintes. Coberto por `testJobThatFinishesWithoutDeliveryDoesNotBlockQueue` (Task 1).
6. **Gravação nova no meio do start assíncrono** (`requestRecordPermission` → `Task` → `passesRecordingPreflight`, `VoiceInkEngine.swift:234-258`). A entrega não pode liberar nem esconder o painel nessa janela. Coberto pelo `pendingStartID` (Task 3, item 3) e pela revisão de código.

---

### Task 1: Fila pura `RecordingJobQueue` + runner de teste

**Files:**
- Create: `VoiceInk/Features/Recording/Workflows/RecordingJobQueue.swift` (só `import Foundation`)
- Create: `VoiceInkTests/RecordingJobQueueTests.swift`
- Create: `scripts/test-unit.sh`
- Modify: `Makefile`: alvo `test-unit` e entrada no `.PHONY`

**Interfaces:**
- Produces:
  ```swift
  @MainActor
  final class RecordingJobQueue {
      /// Corpo de um item. Chama `awaitDeliveryTurn()` imediatamente antes de entregar;
      /// `false` = item cancelado, não entregue.
      typealias Run = @MainActor (_ awaitDeliveryTurn: @escaping @MainActor () async -> Bool) async -> Void

      var onChange: (@MainActor () -> Void)?            // pendingIDs ou isDeliveryHeld mudaram
      var onIdle: (@MainActor () async -> Void)?        // pendingIDs ficou vazio
      var onDiscard: (@MainActor (UUID) async -> Void)? // item cancelado antes de começar a rodar

      private(set) var pendingIDs: [UUID]               // FIFO; inclui o item em processamento e os esperando entrega
      var pendingCount: Int { get }
      var isDeliveryHeld: Bool                          // true enquanto há gravação viva; false libera a entrega

      func enqueue(id: UUID, run: @escaping Run)
      func isCanceled(_ id: UUID) -> Bool
      func cancelAll()
  }
  ```

Semântica, que os testes fixam:
- **Processamento serial.** No máximo um item fica no estágio de processamento, ou seja, o `run` começou e ainda não chamou `awaitDeliveryTurn` nem retornou. O `run` do item seguinte começa assim que o atual chama `awaitDeliveryTurn` ou retorna.
- **Entrega.** O `awaitDeliveryTurn` do item X fica suspenso até X ser `pendingIDs.first` e `isDeliveryHeld == false`. Então devolve `true`. Se X é cancelado enquanto espera, devolve `false` na hora.
- O item sai de `pendingIDs` quando o `run` dele retorna. Quando `pendingIDs` esvazia, chama `onIdle`.
- **`cancelAll()`.** Marca todos como cancelados. Os que não começaram saem de `pendingIDs` sem rodar e disparam `onDiscard(id)`. Os que estão em `awaitDeliveryTurn` recebem `false`. O `run` em processamento continua até retornar, porque o pipeline consulta `isCanceled`. Depois de um `cancelAll`, um `enqueue` novo funciona normalmente.

- [ ] **Step 1: Escrever o runner e um teste que falha**

`scripts/test-unit.sh` (bash, `set -euo pipefail`) compila `VoiceInk/Features/Recording/Workflows/RecordingJobQueue.swift`, `VoiceInk/Features/Recording/Workflows/PasteTargetPolicy.swift` (a partir da Task 2; o script só inclui o que existir) e `VoiceInkTests/*.swift` num bundle `.xctest` em `$(mktemp -d)`, e roda `xcrun xctest`. Receita validada no spike de 18/10: `xcrun swiftc -swift-version 5 -parse-as-library -emit-library -Xlinker -bundle -o <B>.xctest/Contents/MacOS/<B> <fontes> -F $FW/Library/Frameworks -I $FW/usr/lib -L $FW/usr/lib -Xlinker -rpath -Xlinker $FW/Library/Frameworks -Xlinker -rpath -Xlinker $FW/usr/lib -framework XCTest`, com `FW=$(xcrun --sdk macosx --show-sdk-platform-path)/Developer`. Antes, criar `Contents/MacOS` e um `Info.plist` com `CFBundleExecutable`, `CFBundleIdentifier` e `CFBundlePackageType=BNDL`. O exit code do script é o do `xctest`.

O arquivo de teste começa com:
```swift
import XCTest
#if canImport(VoiceInk)
@testable import VoiceInk
#endif
```
Assim o mesmo arquivo compila no target `VoiceInkTests` do Xcode (pasta sincronizada no `project.pbxproj`) e no runner standalone.

Makefile: `test-unit:` com a receita `@./scripts/test-unit.sh`. Adicionar `test-unit` à linha `.PHONY`.

Primeiro teste, `testDeliveriesFollowEnqueueOrder`: o item A espera um gate antes de chamar o turno, e B não espera nada. As entregas, registradas num array quando o turno devolve `true`, têm de sair `[A, B]`.

- [ ] **Step 2: Rodar UNIT e ver falhar**

Esperado: falha de compilação, `cannot find 'RecordingJobQueue' in scope`, e `rc` diferente de 0.

- [ ] **Step 3: Implementar `RecordingJobQueue`**

Uma lista de entradas `{id, run, stage, continuation?}`, com `stage ∈ {waiting, processing, awaitingDelivery}`. Uma função `pump()` é chamada em cada transição: inicia o próximo `waiting` se nenhum estiver em `processing` e retoma o turno do primeiro se a entrega estiver liberada. O `run` executa num `Task { @MainActor in ... }`. As continuations são `CheckedContinuation<Bool, Never>`. Nunca retomar a mesma continuation duas vezes: remova-a da entrada antes de chamar `resume`. Não usar corrente de `Task`s: o review do PR #798 mostrou que cancelar a cauda dessa corrente não cancela os elos anteriores.

- [ ] **Step 4: Escrever os demais testes**

Cada teste controla os itens com um gate assíncrono (classe `AsyncGate` no próprio arquivo de teste: `wait() async` e `open()`) e espera os efeitos com `XCTestExpectation` + `await fulfillment(of:timeout: 2)`.

| teste | arranjo | asserção |
|---|---|---|
| `testNextJobProcessesWhileEarlierWaitsForDelivery` | `isDeliveryHeld = true`; A chama o turno; B marca "começou" | B começa antes de A ser entregue; A não entrega enquanto o hold está ativo |
| `testDeliveryWaitsWhileHeldAndResumesWhenReleased` | hold ativo; A chama o turno | nenhuma entrega em 0,2 s; com `isDeliveryHeld = false`, A entrega |
| `testJobThatFinishesWithoutDeliveryDoesNotBlockQueue` | A retorna sem chamar o turno | B entrega; `pendingIDs` termina vazio |
| `testCancelAllDiscardsWaitingAndFailsPendingTurns` | hold ativo; A no turno, B processando, C esperando | `cancelAll()` → turno de A devolve `false`, `onDiscard` só para C, `isCanceled` é `true` para A, B e C; quando B retorna, `onIdle` é chamado 1 vez |
| `testEnqueueAfterCancelAllRunsNormally` | `cancelAll` com fila vazia, depois enqueue D | D entrega |
| `testHeldDeliveriesReleaseInEnqueueOrder` | hold ativo; A e B chegam a `awaitDeliveryTurn` | nenhuma entrega; com `isDeliveryHeld = false`, entregas `[A, B]` |
| `testSecondJobDoesNotStartWhileFirstIsProcessing` | A em processamento, preso num gate antes do turno; B enfileirado | B não começa em 0,2 s; ao abrir o gate de A (A chama o turno), B começa |
| `testPendingCountTracksLifecycle` | enqueue A e B | `pendingCount` vai de 2 a 1 e a 0, com `onChange` chamado em cada transição |

- [ ] **Step 5: Rodar UNIT e ver passar**

Esperado: `rc=0`, `Executed 9 tests, with 0 failures`.

- [ ] **Step 6: Provar que o teste pega regressão**

Inverta temporariamente a condição de hold no `pump()`, para entregar mesmo com hold ativo. Rode UNIT: `testDeliveryWaitsWhileHeldAndResumesWhenReleased` tem de falhar **por asserção**, não por timeout do runner. Para isso, rode com teto externo: `timeout 120 make test-unit`. Reverta a inversão. Segundo mutante: deixe o `pump()` iniciar um item `waiting` mesmo com outro em `processing`. `testSecondJobDoesNotStartWhileFirstIsProcessing` tem de falhar por asserção. Reverta e rode UNIT de novo até `rc=0`.

- [ ] **Step 7: BUILD**

O arquivo novo entra no target do app sozinho, pela pasta sincronizada. Esperado: `rc=0`.

- [ ] **Step 8: Commit** via `/commit`, com os 4 arquivos.

---

### Task 2: Entrega por item: alvo próprio, clipboard e volta do foco

**Files:**
- Create: `VoiceInk/Features/Recording/Workflows/PasteTargetPolicy.swift` (só `import Foundation`)
- Create: `VoiceInkTests/PasteTargetPolicyTests.swift`
- Modify: `VoiceInk/Features/Recording/Workflows/TranscriptionDelivery.swift` (`Request`, `paste`, `activateRecordStartTarget`)
- Modify: `VoiceInk/Features/Recording/Workflows/TranscriptionPipeline.swift` (`run`: 2 parâmetros novos; turno antes de `delivery.deliver`)
- Modify: `VoiceInk/Features/Recording/Workflows/VoiceInkEngine.swift:558` (passa os parâmetros novos com os valores de hoje)

**Interfaces:**
- Consumes: nada das outras tasks.
- Produces:
  ```swift
  enum PasteTargetPolicy {
      enum Plan: Equatable { case pasteInFrontmost, activateTarget, copyToClipboard }
      static func plan(pinningEnabled: Bool, hasTarget: Bool, targetIsTerminated: Bool, targetIsFrontmost: Bool) -> Plan
      enum AfterActivation: Equatable { case paste, copyToClipboard }
      static func afterActivation(targetBecameFrontmost: Bool) -> AfterActivation
  }
  ```
  - `TranscriptionDelivery.Request` ganha `let pasteTarget: NSRunningApplication?`.
  - `TranscriptionPipeline.run(...)` ganha, depois de `sendAfterPaste`: `pasteTarget: NSRunningApplication?` e `awaitDeliveryTurn: @escaping () async -> Bool`, os dois sem default (o único chamador é o engine).

Regras, pela spec:

| pinning | alvo | estado do alvo | resultado |
|---|---|---|---|
| desligado | qualquer | qualquer | `.pasteInFrontmost` |
| ligado | sem alvo | — | `.pasteInFrontmost` (como hoje) |
| ligado | com alvo | terminado | `.copyToClipboard` |
| ligado | com alvo | já está na frente | `.pasteInFrontmost` |
| ligado | com alvo | outro caso | `.activateTarget` |

Depois de `.activateTarget`: se o alvo ficou na frente em até 0,6 s, `.paste`; se não, `.copyToClipboard`.

- [ ] **Step 1: Testes da política** em `PasteTargetPolicyTests.swift`. Uma linha da tabela por teste: `testPinningDisabledPastesInFrontmost`, `testNoTargetPastesInFrontmost`, `testTerminatedTargetCopiesToClipboard`, `testFrontmostTargetPastesDirectly`, `testBackgroundTargetIsActivated`, `testTargetThatNeverFocusesCopiesToClipboard` (`afterActivation(false) == .copyToClipboard`) e `testFocusedTargetPastes`.
- [ ] **Step 2: UNIT falha** com `cannot find 'PasteTargetPolicy'`.
- [ ] **Step 3: Implementar `PasteTargetPolicy`.**
- [ ] **Step 4: UNIT passa:** `Executed 16 tests, with 0 failures`.
- [ ] **Step 5: Ligar a política na entrega**
  - `activateRecordStartTarget(_ target: NSRunningApplication?) async -> PasteTargetResult`, onde `enum PasteTargetResult { case paste(restoreFocusTo: NSRunningApplication?), copyToClipboard }`. Ela lê `PasteTargetPinning.isEnabled`, aplica `PasteTargetPolicy` e mantém o polling atual de 0,6 s. `restoreFocusTo` é o `frontmostApplication` de antes do `activate()`, e só vem preenchido quando houve ativação.
  - `paste(...)` recebe o `pasteTarget` do `Request`.
  - `.copyToClipboard`: `ClipboardManager.copyToClipboard(pastedText)`, depois `NotificationManager.shared.showNotification(title: String(localized: "Original app is no longer available. Text copied to clipboard."), type: .warning, duration: 5.0)`. Não colar.
  - `.paste(restoreFocusTo:)`: cola como hoje, mas `paste(...)` só **retorna** depois de `await pasteTask.value`, do send key (se houver) e da volta do foco. O `Task { @MainActor in ... }` solto de hoje (`TranscriptionDelivery.swift:188-198`) vira código sequencial. Motivo: o Cmd+V sai ≥ 0,20 s depois de `startPasteAtCursor` (`CursorPaster.prePasteDelay`). Se a entrega retornasse antes, o item seguinte ganharia o turno e ativaria o app dele nessa janela, e o texto de A cairia no app de B. A volta do foco reativa `restoreFocusTo` com `activate()`, desde que ele exista, não tenha terminado e seja diferente do alvo.
  - Remover a leitura de `ActiveWindowService.shared.currentApplication` da entrega.
- [ ] **Step 6: Turno de entrega no pipeline.** Em `TranscriptionPipeline.run`, logo antes do `if shouldCancel()` que precede `delivery.deliver` (`TranscriptionPipeline.swift:272`): `guard await awaitDeliveryTurn() else { await finishCanceledTranscription(); return }`. Passar `pasteTarget` para o `Request`.
- [ ] **Step 7: Engine provisório** (`VoiceInkEngine.swift:558`): `pasteTarget: ActiveWindowService.shared.currentApplication, awaitDeliveryTurn: { true }`. A Task 3 troca esses valores.
- [ ] **Step 8: BUILD e UNIT** passam.
- [ ] **Step 9: Commit** via `/commit`.

---

### Task 3: Engine com fila de itens

**Files:**
- Modify: `VoiceInk/Features/Recording/Workflows/VoiceInkEngine.swift` (propriedades `:95-110`, `toggleRecord` `:178-436`, `runPipeline` `:536-654`, cancelamento `:667-729`, limpeza `:838-880`)

**Interfaces:**
- Consumes: `RecordingJobQueue` (Task 1); `pipeline.run(..., pasteTarget:, awaitDeliveryTurn:)` (Task 2).
- Produces (usados pela Task 4):
  ```swift
  @Published private(set) var pendingJobCount: Int          // espelha jobQueue.pendingCount
  var isLiveRecording: Bool { get }                         // liveState ∈ {.starting, .recording} || isStoppingLiveRecording || pendingStartID != nil
  var isProcessingWithoutLiveRecording: Bool { get }        // !isLiveRecording && pendingJobCount > 0
  var canHandleRecordingShortcut: Bool { get }              // isLiveRecording || (blockingJobIDs.isEmpty && recordingState != .busy)
  func cancelRecording() async                              // nova semântica, abaixo
  ```

Mudanças:

1. **Estado.** Criar `private var liveState: RecordingState = .idle` (só `.idle`, `.starting` e `.recording`) e `private var isStoppingLiveRecording = false`. Toda escrita atual de `recordingState` no caminho da gravação viva passa por `setLiveState(_:)`, que chama `refreshRecordingState()`. Essa função calcula:
   - `recordingState = isStoppingLiveRecording ? .transcribing : (liveState != .idle ? liveState : (jobQueue.pendingIDs.first.map { jobDisplayStates[$0] ?? .transcribing } ?? .idle))`;
   - `jobQueue.isDeliveryHeld = isLiveRecording`;
   - `pendingJobCount = jobQueue.pendingCount`.

   `jobDisplayStates: [UUID: RecordingState]` só guarda `.transcribing`/`.enhancing`. Um `onStateChange` com outro valor remove a entrada. Isso evita que o painel mostre `.idle` com fila pendente, o que faria `toggleRecorderPanel` dispensar o painel.

2. **`RecordingJob`** (struct privada no arquivo) com os campos `transcription`, `audioURL`, `session: TranscriptionSession?`, `transcriptionConfiguration: TranscriptionRuntimeConfiguration`, `contextStore`, `useCase: RecordingUseCase`, `sendAfterPaste`, `pasteTarget: NSRunningApplication?` e `mode: ModeConfig?`.

3. **Início da gravação.**
   - Logo depois de `beginApplyingConfiguration` (`:244`), guardar `liveRecordStartPasteTarget = ActiveWindowService.shared.currentApplication`. A atribuição dentro dela é síncrona.
   - Guardar sempre a `transcriptionConfiguration` resolvida em `:302-305` em `liveTranscriptionConfiguration`. Hoje ela só é guardada com streaming.
   - Remover `activePipelineTranscriptionID = nil` (`:225`).
   - No topo de `toggleRecord`: `if isStoppingLiveRecording { return }`.
   - **Start pendente síncrono.** No topo do ramo de start, antes de `requestRecordPermission` (`:234`), fazer `pendingStartID = UUID()` e chamar refresh. `isLiveRecording` passa a incluir `pendingStartID != nil`, então a entrega fica segura e o `onDismiss` não esconde o painel durante o hop assíncrono até `.starting`. Zerar `pendingStartID` quando `setLiveState(.starting)` acontecer e em **toda** saída antecipada: permissão negada, `passesRecordingPreflight` falso, guard de `:262` e catch de `:403`. Um `defer` dentro do `Task` cobre todos esses casos.

4. **Parada** (ramo `.recording`).
   - Na ordem: `isStoppingLiveRecording = true`, `setLiveState(.idle)`, `await recorder.stopRecording()`, `isStoppingLiveRecording = false`.
   - Congelar `mode = ModeManager.shared.currentEffectiveConfiguration`.
   - Criar o `Transcription` pendente como hoje e montar o `RecordingJob` com o que hoje fica nas propriedades vivas.
   - Desligar o engine desses objetos: zerar `currentSession`, `liveTranscriptionConfiguration`, `recordedFile`, `liveRecordStartPasteTarget`, `activeRecordingContextStore` e `activeRecordingContextTasks`. As tasks de contexto **não** são canceladas, porque continuam preenchendo o store do item.
   - Chamar `enqueue(job)` e retornar **sem esperar o pipeline**.
   - Caminhos de cancelamento e de "sem arquivo": como hoje, trocando `cleanupResources()` por `cleanupResourcesIfIdle()`.

5. **`enqueue(_ job:)`.** Se `job.useCase.isAssistantFollowUp` ou `ModeRuntimeResolver.outputConfiguration(mode: job.mode).outputMode == .respond`, inserir `job.transcription.id` em `blockingJobIDs` (decisão 1 da spec). Depois `jobQueue.enqueue(id:) { turn in await self.runJob(job, awaitDeliveryTurn: turn) }` e `refreshRecordingState()`.

6. **`runJob`** substitui `runPipeline`. Não lê nenhuma propriedade viva do engine.
   - `transcriptionConfiguration: job.transcriptionConfiguration`.
   - Formatação, enhancement e saída usam `ModeRuntimeResolver.…(mode: box.mode ?? job.mode, …)`.
   - `box` é uma `final class` local com `var mode: ModeConfig?`, preenchida pelo `triggerWordModeSelection`. Essa closure usa `ModeManager.shared.getConfigurationForTriggerWord(text)` e **não** chama mais `setActiveConfiguration`: o modo global pertence à gravação viva.
   - `shouldCancel: { jobQueue.isCanceled(id) }`, `onCancel: { job.session?.cancel() }`, `pasteTarget: job.pasteTarget`, `awaitDeliveryTurn: turn`.
   - `onStateChange` atualiza `jobDisplayStates[id]` e chama refresh.
   - `onDismiss: { guard !isLiveRecording, jobQueue.pendingCount <= 1 else { return }; await recorderUIManager?.dismissRecorderPanel() }`.
   - Os hooks do assistente trocam o guard por `activePipelineTranscriptionID == id` por `!jobQueue.isCanceled(id)`.
   - No fim: remover `id` de `jobDisplayStates` e de `blockingJobIDs`, e chamar refresh.
   - Apagar o que fica órfão: `activePipelineTranscriptionID`, `canceledPipelineTranscriptionIDs`, `activePipelineUseCase`, `cancelPipelineSession`, `selectTriggerWordModeIfNeeded` (se não houver outro uso) e o bloco final de `runPipeline` (`:635-653`).

7. **Fila → engine**, no `init`:
   - `jobQueue.onChange = { refreshRecordingState() }`.
   - `jobQueue.onIdle = { await cleanupResourcesIfIdle() }`.
   - `jobQueue.onDiscard = { id in` marcar o `Transcription` daquele item como `.canceled`, com `text = Transcription.canceledTranscriptionText`, e salvar `}`. Para isso, guardar `jobsByID: [UUID: RecordingJob]` até o item sair da fila.
   - Quando o refresh notar que `isLiveRecording` passou de `true` para `false` com a fila vazia, não é preciso nada além do que os caminhos de parada e cancelamento já fazem.

8. **Limpeza.** `cleanupResourcesIfIdle()`: `guard !isLiveRecording, jobQueue.pendingCount == 0 else { return }; await cleanupResources()`. Todas as chamadas internas de `cleanupResources()` passam a usar esta, menos `resetRecordingSession`, que antes chama `jobQueue.cancelAll()`.

9. **`cancelRecording()`.**
   - `if isStoppingLiveRecording`: só `shouldCancelRecording = true` e retornar. O ramo de parada já lê a flag (`:193`) e descarta a gravação.
   - `if liveState == .starting || liveState == .recording || pendingStartID != nil`: o caminho atual de `.starting/.recording`.
   - `else if jobQueue.pendingCount > 0`: `jobQueue.cancelAll()`, `partialTranscript = ""` e refresh.
   - `else`: o caminho atual de `.idle/.busy`.
   - `requestRecordingCancellation` perde o ramo `.transcribing/.enhancing`.

- [ ] **Step 1: Implementar os itens 1 a 9.** Não há teste unitário possível aqui (áudio, SwiftData, AppKit). A cobertura vem da fila (Task 1) e do E2E (Task 5).
- [ ] **Step 2: BUILD** passa.
- [ ] **Step 3: Varredura de órfãos.** O comando `grep -n 'activePipelineTranscriptionID\|canceledPipelineTranscriptionIDs\|activePipelineUseCase\|recordingState = ' VoiceInk/Features/Recording/Workflows/VoiceInkEngine.swift` tem de devolver só a atribuição dentro de `refreshRecordingState`. As leituras de `recordingState == .recording` em `:290`, `:332`, `:790` e `:819` continuam corretas porque o estado derivado só vale `.recording` com gravação viva. Anotar isso no report.
- [ ] **Step 4: Regressão de uma gravação, sem microfone.** Abra o build com `open -a "$PWD/.local-build/Build/Products/Release/VoiceInk.app" <wav>` e acione Start na aba Transcribe Audio. Isso **não** passa pelo engine de gravação. Serve só para provar que o app abre e que o pipeline de arquivo não quebrou. Só rode com o app instalado fechado e com o OK da Task 5. Se ainda não houver OK, adie para a Task 5.
- [ ] **Step 5: Commit** via `/commit`.

---

### Task 4: Atalho, painel, Esc e contador

**Files:**
- Modify: `VoiceInk/Features/Shortcuts/Coordination/RecordingShortcutManager.swift` (`:74-76`, `:99-110`, handler `:373-470`)
- Modify: `VoiceInk/Features/Recording/Presentation/RecorderUIManager.swift` (`toggleRecorderPanel` `:222-249`, `cancelRecording` `:281-285`)
- Modify: `VoiceInk/Features/Recording/State/RecorderStateProvider.swift` (`var pendingJobCount: Int { get }`)
- Modify: `VoiceInk/Features/Recording/Components/RecorderComponents.swift` (novo `RecorderPendingBadge`)
- Modify: `VoiceInk/Features/Recording/Views/MiniRecorderView.swift` (`controlBar`) e `VoiceInk/Features/Recording/Views/NotchRecorderView.swift` (`mainRow`)

**Interfaces:**
- Consumes (Task 3): `isLiveRecording`, `isProcessingWithoutLiveRecording`, `canHandleRecordingShortcut`, `pendingJobCount` e a nova semântica de `cancelRecording()`.
- Produces: `struct RecorderPendingBadge: View { let count: Int }`.

Mudanças:

1. **Guard.** Apagar `canHandleShortcutAction(for:)` e injetar `canHandleShortcutAction: { engine.canHandleRecordingShortcut }`. O `RecordingShortcutModeHandler` ganha a closure `isProcessingWithoutLiveRecording: () -> Bool`, ligada a `engine.isProcessingWithoutLiveRecording`.

2. **Handler.**
   - Key-down de toggle, hybrid e pushToTalk: trocar `if !isRecorderVisible()` por `if !isRecorderVisible() || isProcessingWithoutLiveRecording()`.
   - Key-up do pushToTalk: trocar `if isRecorderVisible()` por `if isRecorderVisible() && !isProcessingWithoutLiveRecording()`.
   - Hybrid key-up e doubleTap ficam como estão. Os dois já checam `.recording` ou passam por `toggleRecorderPanel`.

3. **`toggleRecorderPanel`** com o painel visível. O caso `.starting` continua chamando `cancelRecording()`. Os casos `.transcribing` e `.enhancing` passam a ser: `guard engine.canHandleRecordingShortcut else { return }`, depois `SoundManager.shared.playStartSound()` e `await engine.toggleRecord(modeId: modeId)`.

4. **`cancelRecording`:**
   ```
   let wasLive = engine.isLiveRecording
   await engine.cancelRecording()
   if wasLive && engine.pendingJobCount > 0 { return }   // fila segue, painel fica
   await dismissRecorderPanel()
   ```
   `handleDismissRecorderPanelNotification` continua chamando `cancelRecording()` e herda essa semântica.

5. **Contador.**
   - `RecorderPendingBadge` mostra `count` num selo pequeno (cápsula, fonte monoespaçada ~10pt, branco sobre `white.opacity(0.2)`). Fica oculto com `count == 0`. Tem `accessibilityLabel(String(localized: "\(count) pending"))`.
   - No Mini, entra no `controlBar`, entre `RecorderStatusDisplay` e `RecorderModeButton`.
   - No Notch, entra no `HStack` direito do `mainRow`, antes de `RecorderStatusDisplay`.
   - O selo aparece quando `pendingJobCount >= 1` com gravação viva (`recordingState` igual a `.starting` ou `.recording`), ou quando `pendingJobCount >= 2` sem gravação viva. Com uma gravação só, o painel fica idêntico ao de hoje.

- [ ] **Step 1: Implementar os itens 1 a 5.**
- [ ] **Step 2: BUILD** passa.
- [ ] **Step 3: Conferir os casos do handler.** Para cada modo (toggle, hybrid, pushToTalk, doubleTap), escreva no report da task o caminho de chamadas para dois cenários: (a) fila vazia, que tem de ser idêntico ao de hoje; (b) fila com 1 item e sem gravação viva, que tem de iniciar uma gravação na primeira pressão. O revisor confere esse texto contra o código.
- [ ] **Step 4: Commit** via `/commit`.

---

### Task 5: Build final e E2E (coordenador, não subagente)

**Files:** nenhum código. Evidência em `.work-state/debug/e2e-gravacao-concorrente/` (scripts e logs).

- [ ] **Step 1: UNIT** passa, com o total de testes igual ao das Tasks 1 e 2.
- [ ] **Step 2: `make local > /tmp/vi-local.log 2>&1; echo rc=$?`** dá `rc=0`, e o log mostra `Signed by: VoiceInk Local Signing` e `Build complete!`.
- [ ] **Step 3: Avisar o user e fechar o app instalado.** O user já deu o OK para fechar por cerca de 10 minutos; o aviso vai na conversa. Depois: `osascript -e 'quit app "VoiceInk"'`, conferir com `pgrep -fl VoiceInk` e abrir `~/Downloads/VoiceInk.app`.
- [ ] **Step 4: Preparar.** Abrir TextEdit (documento novo) e Notes (nota nova). O atalho é F18 (`keyCode 79`, sem modificador) em modo `hybrid`, então um toque curto inicia e outro para. O áudio vem de `say -v Luciana "<frase>"` pelos alto-falantes. `isSystemMuteEnabled` não está definido, o default é `false`, e o `say` não é silenciado.
- [ ] **Step 5a: Regressão com fila vazia.** Uma gravação só, no TextEdit (F18, `say`, F18). Esperado: igual a hoje. O painel mostra transcribing e depois enhancing, sem selo. O texto é colado no TextEdit, o painel some e toca o som de fim.
- [ ] **Step 5: Cenário principal**, num script `osascript` + `say`:
  1. Foco no TextEdit, F18, `say` frase A, F18. O item A entra em transcribing.
  2. Imediatamente, foco no Notes, F18 (tem de iniciar gravação com o painel mostrando o contador 1), `say` frase B, F18.
  3. Esperar até 90 s.

  Critérios: A aparece no TextEdit e B no Notes, A colado antes de B. Critério temporal do "segura até parar": no `log show --predicate 'subsystem == "com.prakashjoshipax.voiceink"' --last 5m`, a linha de colagem de A (`Paste id=… app=`, emitida em `CursorPaster.swift`) tem timestamp **depois** do F18 que parou B, registrado pelo script. O histórico tem 2 registros `completed` com `enhancedText`. Fazer screenshot do painel durante o passo 2, para mostrar o contador.
- [ ] **Step 6: Pressão dupla.** F18 duas vezes com 50 ms de intervalo logo depois de uma gravação. Esperado: no máximo uma gravação nova, sem erro. Isso prova o caminho de ponta a ponta, mas não a flag `isStoppingLiveRecording`, porque o cooldown de 0,5 s engole a segunda pressão.
- [ ] **Step 7: Esc duplo.** Com o item A processando e a gravação C viva, Esc duplo. Esperado: C cancelada, A colado depois e o painel visível até A terminar. Em seguida, outra fila com Esc duplo sem gravação viva: nada é colado, os registros ficam `canceled` e o painel some.
- [ ] **Step 8: Leitura do histórico, só leitura.** Rodar `sqlite3 -readonly` no store SwiftData do app. O caminho vem de `find ~/Library/Application\ Support/com.prakashjoshipax.VoiceInk -name '*.store'`. Consultar `ZTRANSCRIPTION` pelos campos de status, texto e data dos registros desta sessão.
- [ ] **Step 9: Restaurar.** Fechar `~/Downloads/VoiceInk.app`, reabrir `/Applications/VoiceInk.app` e avisar o user.
- [ ] **Step 10: Se o F18 sintético não for captado** (nenhum painel aparece em 3 s): parar, registrar no ledger e chamar o user, seguindo a DoD.
