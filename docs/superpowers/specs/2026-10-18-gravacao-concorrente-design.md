# Gravação concorrente — design

Data: 18/10/2026. Fork gustavobittencourt/VoiceInk, branch `local`. Worktree `.worktrees/gravacao-concorrente`.

## Intenção

Pedido do user: "permitir que uma nova gravação seja iniciada enquanto a anterior é transcrita ou melhorada. Isso vai acelerar bastante meu fluxo de trabalho."

Hoje o atalho de gravação é ignorado enquanto a gravação anterior está em `.transcribing` ou `.enhancing`. O user dita em rajadas, e o enhancement roda num shim MLX local (`localhost:11435`, provedor Ollama) que leva segundos por item e serializa as gerações. Esperar cada item terminar quebra o fluxo. O que conta como sucesso: apertar o atalho logo depois de parar uma gravação, começar a próxima na hora, e os textos chegarem completos, na ordem e cada um no app onde foi ditado.

## Objetivos

1. O atalho de gravação inicia uma gravação nova sempre que não houver gravação viva (`.starting`/`.recording`), mesmo com itens anteriores em processamento. Vale para os quatro modos de atalho (toggle, push-to-talk, hybrid, double-tap) e para o atalho de modo específico (`modeId`).
2. Cada gravação parada vira um **item** de uma fila. A fila processa um item por vez (transcrição → enhancement → entrega) em FIFO.
3. Cada item é colado no app que estava em foco quando **a sua** gravação começou.
4. O painel de gravação mostra um contador com os itens pendentes.

## Decisões do user (18/10/2026, por AskUserQuestion)

| tema | decisão |
|---|---|
| Ordem | **FIFO estrito.** Cola na ordem em que gravou; um item pronto espera os anteriores. |
| Indicador | **Contador no painel.** O painel continua igual e ganha um selo com o número de itens pendentes. Fica visível até a fila esvaziar. Sem cancelamento por item. |
| Falha | **Cola o texto cru, mas avisa que a melhoria falhou.** Se a transcrição falhar, avisa e segue a fila. |
| Foco | **Segura até parar a atual.** Nada é colado enquanto há gravação viva. Ao parar, os itens prontos são colados em ordem, cada um no seu app. |
| Limite | **Sem limite** de itens na fila. |
| Esc duplo sem gravação viva | **Cancela a fila toda.** Descarta os itens pendentes sem colar; o áudio e o registro ficam no histórico marcados como cancelados. |
| App de origem indisponível | **Clipboard + aviso.** Se o app do item foi fechado ou não volta para a frente em 0,6 s, o texto não é colado em app nenhum: vai para o clipboard e aparece uma notificação. |
| Foco depois de colar | **Volta para o app em que o user estava.** Depois de colar num app diferente do que está na frente, devolve o foco ao app que estava na frente antes da colagem. |
| Teste final | **Eu (agente), com atalho sintético** (`osascript`) e áudio de `say` pelos alto-falantes, em dois apps (TextEdit e Notes). O user aceitou fechar o VoiceInk instalado por ~10 min para isso. Se o atalho sintético não for captado, chamo o user. |

Configuração do user, medida em `defaults read com.prakashjoshipax.VoiceInk` em 18/10/2026:
- Transcrição: Whisper local `ggml-large-v3-turbo-q5_0`, sem streaming.
- Enhancement ligado, provedor Ollama (shim MLX), modelo `gemma-e2b-gustavo:01.08.2026`.
- Atalho principal em modo `hybrid`, painel `mini`.
- Um só modo (`Dictation`), com `outputMode = paste`.

## Decisões minhas (agente), para o user conferir

1. **Assistente e `.respond` ficam com o comportamento de hoje.** O user não usa esses fluxos (o único modo dele é `paste`). Enquanto houver na fila um item de follow-up do assistente ou de saída `.respond`, o atalho volta a ser ignorado, como hoje, até esse item terminar. Isso evita reescrever o `assistantSession`, que é único.
2. **Streaming fora do escopo da v1.** O user transcreve com Whisper local sem streaming. Para o streaming, o requisito é só não quebrar o caso de uma gravação por vez.
3. **Som de fim:** continua um por item entregue, como hoje.
4. **Gravação iniciada no meio de uma sequência de colagens:** as colagens que faltam esperam a próxima parada, coerente com "segura até parar". Resta uma janela curta de corrida: se uma colagem acabou de trazer outro app para a frente, a gravação nova pode capturar esse app como origem. Aceito como risco conhecido.
5. **`PasteTargetPinning` desligado** (opção do user, default ligado): a fila cola no app da frente, sem reativar origem e sem clipboard. A opção desligada é uma escolha explícita do user.
6. **Base técnica:** reescrever sobre o código atual usando o PR #798 só como referência. O branch daquele PR está 345 commits atrás e metade dos arquivos mudou de lugar.
7. **A palavra-gatilho não persiste mais o modo global.** Hoje ela chama `ModeManager.shared.setActiveConfiguration`, e o modo fica ativo até o próximo início de gravação redefini-lo (`ActiveWindowService.swift:46-52`, só quando existe config por app ou default). Com a fila, o modo ativado pela palavra-gatilho vale só para o item que a contém, para não contaminar a gravação viva. Com o único modo do user (`Dictation`), a diferença não aparece.
8. **Transcrição de um item em paralelo com o enhancement do anterior:** fica para uma v2 (`.work-state/tech-debt.md`). Na v1 o item seguinte começa a transcrever quando o anterior chega ao turno de entrega, ou seja, depois do enhancement dele.

O comportamento de falha do enhancement já existe: `TranscriptionPipeline.swift:206-221` mantém `finalText` igual ao texto cru e mostra notificação `.warning`. O que precisa ser garantido é que a fila siga depois disso.

## Não-objetivos

- Paralelizar transcrições ou enhancements. O shim MLX já é serial, e o `WhisperContext` local é compartilhado: `setLanguage`/`setPrompt`/`fullTranscribe` intercalariam entre itens. A fila serial é requisito de correção.
- Cancelar um item específico da fila (descartado na decisão do indicador).
- Pilha de cartões por item (é o que faz o PR upstream #798; descartado).
- Mudar o pipeline de transcrição ou o enhancement em si.

## Antiobjetivos (falha mesmo se "funcionar")

- O texto de uma gravação colado no app de outra.
- O enhancement de um item usar o prompt ou modo que outra gravação aplicou depois (o Power Mode troca o modo global por app no início de cada gravação).
- Um item sumir sem aviso: nem colado, nem cancelado, nem marcado como falha no histórico.
- Uma janela pular para a frente enquanto o user está ditando.
- O modelo local ser descarregado (`cleanupResources`) enquanto ainda há item na fila ou gravação viva.
- Regressão no caso de uma gravação só: com a fila vazia, o comportamento tem de ser idêntico ao de hoje (sons, painel, colagem, follow-up do assistente).

## Estado atual (fatos, com arquivo:linha)

- O bloqueio está em `RecordingShortcutManager.swift:74-76` (`canHandleShortcutAction` rejeita `.transcribing`/`.enhancing`/`.busy`) e é aplicado em cada modo (`:383, :410, :416, :422, :449, :456, :463`).
- Push-to-talk e toggle só chamam `toggleRecorderPanel` no key-down quando o painel está **invisível** (`:414-425`). Como o painel fica visível durante o processamento, mesmo sem o guard o key-down não iniciaria gravação.
- `RecorderUIManager.toggleRecorderPanel` (`RecorderUIManager.swift:222-249`), com o painel visível, chama `cancelRecording()` em `.transcribing`/`.enhancing`.
- `VoiceInkEngine.toggleRecord` (`VoiceInkEngine.swift:178`) espera `runPipeline` inline no ramo de parada (`:204`). Uma segunda chamada concorreria por reentrância do MainActor, mas o engine é mono-sessão: `recordedFile`, `currentSession`, `currentSessionTranscriptionConfiguration`, `activePipelineTranscriptionID`, `shouldCancelRecording`, `activePipelineUseCase` e `activeRecordingContextStore` são propriedades únicas (`:95-110`). O início de uma gravação nova zera `activePipelineTranscriptionID` (`:225`), o que faz o pipeline anterior perder `onStateChange`/`onDismiss` e pular a limpeza (`:639-653`).
- O fim de cada `runPipeline` chama `cleanupResources()` (`:640`), que descarrega o Whisper local, FluidAudio e TranscribeCpp, limpa os contextos capturados do `AIEnhancementService` e descarrega o modelo preparado do VoiceInkRefine (`:862-879`).
- App de origem: `ActiveWindowService.beginApplyingConfiguration` grava `NSWorkspace.shared.frontmostApplication` no singleton `currentApplication` (`ActiveWindowService.swift:26-44`). `TranscriptionDelivery.activateRecordStartTarget` lê esse singleton (`TranscriptionDelivery.swift:205-227`). Uma gravação nova sobrescreve o alvo da anterior.
- Modo: o pipeline lê `ModeManager.shared.currentEffectiveConfiguration` no meio da execução, para formatação, enhancement e saída (`VoiceInkEngine.swift:562-588`). A palavra-gatilho troca o modo global em `selectTriggerWordModeIfNeeded` (`:656-663`).
- Entrega: `paste` faz `setState(.idle)`, toca o som de fim, chama `dismiss()`, reativa o app de origem e cola (`TranscriptionDelivery.swift:177-199`). O `CursorPaster` já serializa colagens numa fila estática.
- Arquivo de áudio: `<UUID>.wav` por gravação (`VoiceInkEngine.swift:251`). Não há colisão.
- O contexto do enhancement (clipboard, texto selecionado, OCR) é capturado no início da gravação, num `RecordingContextSnapshotStore` novo por gravação (`:520-526`). O pipeline já o recebe por parâmetro.

## Como vai funcionar (decidido nesta conversa)

### Item da fila

Cada gravação, ao parar, vira um item que carrega tudo o que hoje vive em propriedades únicas do engine:

- o `Transcription` (SwiftData) pendente e a URL do áudio;
- a `TranscriptionSession` de streaming, se houver, e a `TranscriptionRuntimeConfiguration` resolvida no início da gravação;
- o `RecordingContextSnapshotStore` daquela gravação;
- o `RecordingUseCase` (nova sessão ou follow-up do assistente) e o `sendAfterPaste`;
- o **app de origem** (`NSRunningApplication` capturado no início da gravação);
- a **configuração de modo** daquela gravação (ver abaixo);
- o estado de cancelamento do item.

### Fila

- Serial e FIFO, no MainActor. Processa um item por vez: `pipeline.run` → entrega.
- A **entrega** (colar, comando customizado, resposta) de um item espera duas condições: todos os itens anteriores entregues, e nenhuma gravação viva. Ao parar a gravação viva, a fila retoma a entrega.
- A transcrição e o enhancement do item da vez **não** esperam a gravação parar. Só a entrega espera.
- Item que falhou na transcrição: segue o caminho atual (registro `.failed` no histórico, notificação quando já existe hoje). Nada é colado, e a fila passa para o próximo.
- Esc duplo sem gravação viva: cancela todos os itens. O item em processamento é marcado como cancelado (o pipeline já verifica `shouldCancel` entre etapas). Os que ainda não começaram são marcados como cancelados no histórico sem rodar o pipeline. O painel some.
- `cleanupResources()` e `finishRecorderSession()` só rodam quando a fila esvazia **e** não há gravação viva.

### Estado exposto e atalho

- `toggleRecord` decide entre parar e iniciar **só pela gravação viva**: com gravação viva, para; sem ela, inicia. Itens em processamento não entram na decisão.
- O guard do atalho deixa de bloquear `.transcribing`/`.enhancing`. Em cada modo, o key-down/key-up passa a olhar a gravação viva, e não a visibilidade do painel, para decidir se inicia ou para. Exemplo: no push-to-talk, o key-down inicia a gravação mesmo com o painel visível mostrando processamento, e o key-up só para se houver gravação viva iniciada por aquele press.
- Com o painel visível e sem gravação viva, `toggleRecorderPanel` inicia uma gravação nova em vez de cancelar o processamento.
- O painel mostra: com gravação viva, o estado de gravação como hoje; sem gravação viva e com fila, o estado do item da vez (`.transcribing`/`.enhancing`) como hoje; sem nada, some como hoje.
- **Contador:** um selo no painel (Mini e Notch) com o número de itens pendentes (em processamento ou esperando entrega).

### Painel e Esc

- O painel só some quando a fila esvazia e não há gravação viva, ou por cancelamento.
- Esc duplo **com** gravação viva: cancela a gravação viva **e a fila toda**, sem colar nada, e o painel some (decisão do user em 11/11/2026). A regra anterior, que cancelava só a gravação viva, colava o item pronto 0,25 s depois do Esc: ele estava retido só pela gravação viva, e não dava tempo de um segundo Esc duplo.
- Esc duplo **sem** gravação viva: cancela a fila toda (decisão do user).

### App de origem por item

- O app capturado no início de cada gravação vai junto com o item até a entrega. `TranscriptionDelivery` reativa o app do item, e não o do singleton.
- Com "segura até parar", a entrega nunca acontece durante uma gravação. Ao parar, os itens prontos colam em sequência, cada um no seu app.
- Depois de colar num app que não era o da frente, o foco volta ao app que estava na frente antes da colagem.
- Se o app do item foi fechado ou não volta para a frente em 0,6 s, o texto vai para o clipboard e aparece uma notificação. Não se cola no app da frente.
- Isso só vale com `PasteTargetPinning` ligado. Com a opção desligada, a colagem vai para o app da frente, como hoje.

### Modo por item

- A configuração de modo (Power Mode por app/URL ou o `modeId` do atalho) que vale para um item é a que estava ativa para aquela gravação, nunca a que outra gravação aplicou depois.
- A palavra-gatilho continua funcionando: se a transcrição do item ativar um modo por palavra-gatilho, aquele modo vale para o enhancement e a saída **daquele item**.

## Restrições

- Swift/SwiftUI, macOS, sem dependência nova.
- A mudança vai para o branch `local` do fork, que é rebaseado sobre `origin/main` a cada `voiceink-update`. Isso pede diff contido, sem reorganizar arquivos, para conflitar pouco com o upstream.
- O fluxo de follow-up do assistente e o modo de saída `.respond` usam o painel para mostrar a resposta e o `assistantSession`, que é único.
- Build e teste com `make local` nesta worktree. O `/Applications/VoiceInk.app` não pode ser substituído sem o OK do user, porque outra sessão o usa.
- O target `VoiceInkTests` está declarado no `project.pbxproj` (`PBXFileSystemSynchronizedRootGroup`, `path = VoiceInkTests`), mas a pasta não existe em disco. O Makefile não tem alvo de teste.

## Deixado para o builder

- A forma da fila e do item: tipo novo, onde mora, e como o engine expõe o estado ao painel. Recomendação: lógica da fila isolada do engine, para teste unitário sem áudio nem SwiftData. Referência: `RecordingSession` e a fila encadeada do PR #798 (`refs/pr/798`). Cuidado com o achado do review automático daquele PR: cancelar só a cauda de uma corrente de `Task`s não cancela os elos anteriores.
- Como congelar a configuração de modo por item usando a API do `ModeRuntimeResolver`/`ModeManager`.
- O visual do selo do contador, dentro do estilo atual do Mini e do Notch.
- Se o teste unitário roda via `xcodebuild test` no target `VoiceInkTests`, ou se precisa de outro arranjo. Verificar isso cedo.
