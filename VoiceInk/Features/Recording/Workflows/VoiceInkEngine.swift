import AVFoundation
import AppKit
import Foundation
import SwiftData
import SwiftUI
import os

private final class RealtimeAudioChunkGate: @unchecked Sendable {
    private struct State {
        var bufferedChunks: [Data] = []
        var callback: ((Data) -> Void)?
        var isActive = false
        var droppedChunks = 0
    }

    private let maxBufferedChunks = 2_048
    private let state = OSAllocatedUnfairLock(initialState: State())

    func receive(_ data: Data) {
        let callback = state.withLock { state -> ((Data) -> Void)? in
            guard state.isActive else {
                if state.bufferedChunks.count < maxBufferedChunks {
                    state.bufferedChunks.append(data)
                } else {
                    state.droppedChunks += 1
                }
                return nil
            }
            return state.callback
        }
        callback?(data)
    }

    func activate(_ callback: @escaping (Data) -> Void) -> Int {
        let initialState = state.withLock { state -> (chunks: [Data], droppedChunks: Int) in
            state.callback = callback
            state.isActive = false
            let chunks = state.bufferedChunks
            let droppedChunks = state.droppedChunks
            state.bufferedChunks.removeAll()
            state.droppedChunks = 0
            return (chunks, droppedChunks)
        }
        var chunksToSend = initialState.chunks
        var droppedChunks = initialState.droppedChunks

        while true {
            for chunk in chunksToSend {
                callback(chunk)
            }

            let nextState = state.withLock { state -> (chunks: [Data], droppedChunks: Int, finished: Bool) in
                let droppedChunks = state.droppedChunks
                state.droppedChunks = 0
                guard !state.bufferedChunks.isEmpty else {
                    state.isActive = true
                    return ([], droppedChunks, true)
                }
                let chunks = state.bufferedChunks
                state.bufferedChunks.removeAll()
                return (chunks, droppedChunks, false)
            }
            droppedChunks += nextState.droppedChunks

            if nextState.finished {
                return droppedChunks
            }
            chunksToSend = nextState.chunks
        }
    }

    func reset() -> Int {
        state.withLock { state -> Int in
            let droppedChunks = state.droppedChunks
            state.bufferedChunks.removeAll()
            state.callback = nil
            state.isActive = false
            state.droppedChunks = 0
            return droppedChunks
        }
    }
}

@MainActor
class VoiceInkEngine: NSObject, ObservableObject {
    private enum RecordingUseCase {
        case newSession
        case assistantFollowUp

        var isAssistantFollowUp: Bool {
            self == .assistantFollowUp
        }
    }

    /// Uma gravação parada, com tudo o que ela precisa para ser transcrita,
    /// melhorada e entregue sem ler o estado da gravação viva seguinte.
    private struct RecordingJob {
        let transcription: Transcription
        let audioURL: URL
        let session: TranscriptionSession?
        let transcriptionConfiguration: TranscriptionRuntimeConfiguration?
        let contextStore: RecordingContextSnapshotStore?
        /// Seguem preenchendo o store do item; o item as cancela ao terminar.
        let contextCaptureTasks: [Task<Void, Never>]
        let useCase: RecordingUseCase
        let sendAfterPaste: Bool
        let pasteTarget: NSRunningApplication?
        /// Modo congelado na parada: a gravação seguinte troca o modo global.
        let mode: ModeConfig?
    }

    /// Modo escolhido pela palavra-gatilho, válido só para o item que a contém.
    private final class JobModeBox {
        var mode: ModeConfig?
    }

    /// Estado exibido no painel: o da gravação viva ou, sem ela, o do item da vez.
    @Published var recordingState: RecordingState = .idle {
        didSet {
            guard oldValue != recordingState else { return }
            ShortcutDiagnostics.notice("recording-state old=\(oldValue) new=\(recordingState) visible=\(recorderUIManager?.isRecorderPanelVisible ?? false) startID=\(activeRecordingStartID?.uuidString ?? "none")")
        }
    }
    @Published var shouldCancelRecording = false
    @Published var partialTranscript: String = ""
    @Published private(set) var pendingJobCount = 0
    var currentSession: TranscriptionSession?
    private var currentSessionTranscriptionConfiguration: TranscriptionRuntimeConfiguration?
    private(set) var activeRecordingStartID: UUID?
    private var activeRecordingUseCase: RecordingUseCase = .newSession
    private var activeRecordingContextStore: RecordingContextSnapshotStore?
    private var activeRecordingContextTasks: [Task<Void, Never>] = []
    private var voiceInkRefinePreparationTask: Task<Void, Never>?

    // Gravação viva (só .idle, .starting e .recording) separada da fila.
    private var liveState: RecordingState = .idle
    private var isStoppingLiveRecording = false
    private var liveRecordStartPasteTarget: NSRunningApplication?

    private let jobQueue = RecordingJobQueue()
    private var jobsByID: [UUID: RecordingJob] = [:]
    private var jobDisplayStates: [UUID: RecordingState] = [:]
    /// Itens de assistente ou saída `.respond`: usam o painel e o `assistantSession`,
    /// que são únicos, então bloqueiam novas gravações como antes.
    private var blockingJobIDs = Set<UUID>()

    var isLiveRecording: Bool {
        liveState == .starting || liveState == .recording || isStoppingLiveRecording
    }

    var isProcessingWithoutLiveRecording: Bool {
        !isLiveRecording && pendingJobCount > 0
    }

    var canHandleRecordingShortcut: Bool {
        isLiveRecording || (blockingJobIDs.isEmpty && recordingState != .busy)
    }

    let recorder = Recorder()
    var recordedFile: URL? = nil
    let recordingsDirectory: URL

    // Injected managers
    let whisperModelManager: WhisperModelManager
    let transcriptionModelManager: TranscriptionModelManager
    weak var recorderUIManager: RecorderPanelPresenting?

    let modelContext: ModelContext
    internal let serviceRegistry: TranscriptionServiceRegistry
    let enhancementService: AIEnhancementService?
    let assistantSession = AssistantSession()
    let assistantChat: AssistantChatService?
    private let pipeline: TranscriptionPipeline

    let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "VoiceInkEngine")

    init(
        modelContext: ModelContext,
        whisperModelManager: WhisperModelManager,
        transcriptionModelManager: TranscriptionModelManager,
        enhancementService: AIEnhancementService? = nil
    ) {
        self.modelContext = modelContext
        self.whisperModelManager = whisperModelManager
        self.transcriptionModelManager = transcriptionModelManager
        self.enhancementService = enhancementService
        if let aiService = enhancementService?.getAIService() {
            self.assistantChat = AssistantChatService(
                modelContext: modelContext,
                aiService: aiService
            )
        } else {
            self.assistantChat = nil
        }

        let appSupportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.prakashjoshipax.VoiceInk")
        self.recordingsDirectory = appSupportDirectory.appendingPathComponent("Recordings")

        self.serviceRegistry = TranscriptionServiceRegistry(
            modelProvider: whisperModelManager,
            modelsDirectory: whisperModelManager.modelsDirectory,
            modelContext: modelContext
        )
        self.pipeline = TranscriptionPipeline(
            modelContext: modelContext,
            serviceRegistry: serviceRegistry,
            enhancementService: enhancementService
        )

        super.init()

        jobQueue.onChange = { [weak self] in self?.refreshRecordingState() }
        jobQueue.onIdle = { [weak self] in await self?.cleanupResourcesIfIdle() }
        jobQueue.onDiscard = { [weak self] id in self?.discardJob(id) }

        setupNotifications()
        createRecordingsDirectoryIfNeeded()
    }

    private func createRecordingsDirectoryIfNeeded() {
        do {
            try FileManager.default.createDirectory(
                at: recordingsDirectory, withIntermediateDirectories: true, attributes: nil)
        } catch {
            logger.error("❌ Error creating recordings directory: \(error, privacy: .public)")
        }
    }

    // MARK: - Toggle Record

    func toggleRecord(modeId: UUID? = nil, isAssistantFollowUp: Bool = false, sendAfterPaste: Bool = false) async {
        if isStoppingLiveRecording {
            return
        }

        if liveState == .starting {
            await cancelRecording()
            return
        }

        if liveState == .recording {
            // Stopping the hardware suspends. Keep all inputs tied to this recording
            // before cancellation or a new recording can replace the shared state.
            let audioURL = recordedFile
            let contextStore = activeRecordingContextStore
            let contextCaptureTasks = activeRecordingContextTasks
            let session = currentSession
            let transcriptionConfiguration = currentSessionTranscriptionConfiguration
                ?? ModeRuntimeResolver.transcriptionConfiguration(transcriptionModelManager: transcriptionModelManager)
            let transcription = audioURL.map {
                makeRecordingTranscription(for: $0, text: "", duration: 0, transcriptionStatus: .pending)
            }
            let useCase = activeRecordingUseCase
            // Modo e app de origem congelados na parada: a gravação seguinte troca os dois.
            let mode = ModeManager.shared.currentEffectiveConfiguration
            let pasteTarget = liveRecordStartPasteTarget
            activeRecordingUseCase = .newSession
            activeRecordingStartID = nil
            partialTranscript = ""
            isStoppingLiveRecording = true
            setLiveState(.idle)
            await recorder.stopRecording()
            isStoppingLiveRecording = false

            guard recordedFile == audioURL else {
                contextStore?.vocabularyPreparation.finish()
                contextCaptureTasks.forEach { $0.cancel() }
                session?.cancel()
                if let transcription {
                    await saveCanceledRecording(transcription)
                }
                refreshRecordingState()
                return
            }

            if let audioURL, let transcription {
                if !shouldCancelRecording {
                    modelContext.insert(transcription)
                    try? modelContext.save()
                    NotificationCenter.default.post(name: .transcriptionCreated, object: transcription)

                    // Não espera o pipeline: a gravação vira item da fila e o
                    // atalho fica livre para a próxima.
                    let job = RecordingJob(
                        transcription: transcription,
                        audioURL: audioURL,
                        session: session,
                        transcriptionConfiguration: transcriptionConfiguration,
                        contextStore: contextStore,
                        contextCaptureTasks: contextCaptureTasks,
                        useCase: useCase,
                        sendAfterPaste: sendAfterPaste,
                        pasteTarget: pasteTarget,
                        mode: mode
                    )
                    currentSession = nil
                    currentSessionTranscriptionConfiguration = nil
                    self.recordedFile = nil
                    liveRecordStartPasteTarget = nil
                    // O item leva store e tasks; o estado vivo fica limpo para a próxima.
                    activeRecordingContextStore = nil
                    activeRecordingContextTasks = []
                    enqueue(job)
                } else {
                    await finishActiveRecorderCancellation()
                }
            } else {
                cancelCurrentSession()
                if !shouldCancelRecording {
                    logger.error("❌ No recorded file found after stopping recording")
                }
                refreshRecordingState()
                await cleanupResourcesIfIdle()
            }
        } else {
            let canContinueAssistantSession = isAssistantFollowUp && assistantSession.canSendFollowUp
            let recordingUseCase: RecordingUseCase = canContinueAssistantSession ? .assistantFollowUp : .newSession

            shouldCancelRecording = false
            partialTranscript = ""
            activeRecordingUseCase = recordingUseCase
            clearActiveRecordingContext()

            if !recordingUseCase.isAssistantFollowUp {
                assistantSession.reset()
            }

            let startID = UUID()
            let permanentURL = recordingsDirectory.appendingPathComponent("\(UUID().uuidString).wav")
            recordedFile = permanentURL
            activeRecordingStartID = startID
            // `.starting` já no toque: a fila não cola nem esconde o painel
            // durante a permissão e o preflight.
            setLiveState(.starting)

            requestRecordPermission { [self] granted in
                if granted {
                    Task { @MainActor [self] in
                        guard self.activeRecordingStartID == startID, !self.shouldCancelRecording else { return }
                        guard await self.passesRecordingPreflight(),
                            self.activeRecordingStartID == startID,
                            !self.shouldCancelRecording
                        else {
                            return
                        }
                        guard self.recorderUIManager?.isRecorderPanelVisible ?? false else {
                            await self.cancelRecording()
                            return
                        }
                        // Lido direto, no mesmo instante do ActiveWindowService: o
                        // singleton não é atualizado quando o app não tem bundle id.
                        self.liveRecordStartPasteTarget = PasteTargetPolicy.recordStartTarget(
                            frontmost: NSWorkspace.shared.frontmostApplication,
                            focusBorrowedFrom: self.pipeline.focusBorrowedByDelivery
                        )
                        let activeModeTask = ActiveWindowService.shared.beginApplyingConfiguration(modeId: modeId) {
                            [weak self] in
                            guard let self else { return false }
                            return self.activeRecordingStartID == startID && !self.shouldCancelRecording
                        }

                        do {
                            let realtimeAudioGate = RealtimeAudioChunkGate()
                            self.recorder.onAudioChunk = realtimeAudioGate.receive

                            try await self.recorder.startRecording(toOutputFile: permanentURL)

                            guard self.activeRecordingStartID == startID,
                                self.recorderUIManager?.isRecorderPanelVisible ?? false,
                                !self.shouldCancelRecording
                            else {
                                ShortcutDiagnostics.notice("recording-start result=aborted startID=\(startID) currentStart=\(self.activeRecordingStartID == startID) visible=\(self.recorderUIManager?.isRecorderPanelVisible ?? false) cancelled=\(self.shouldCancelRecording)")
                                activeModeTask.cancel()
                                let shouldKeepRecordingFile = self.shouldCancelRecording
                                if self.activeRecordingStartID == startID {
                                    await self.recorder.stopRecording()
                                    if !shouldKeepRecordingFile {
                                        self.recordedFile = nil
                                    }
                                    self.setLiveState(.idle)
                                    self.activeRecordingStartID = nil
                                }
                                return
                            }

                            self.setLiveState(.recording)
                            // Preserve the clipboard before awaiting mode resolution
                            // or any later selected-text Copy operation.
                            let clipboardText = SelectedTextService.captureClipboardText()

                            // Only retire the previous paste session once recording
                            // has actually started. Preflight/permission failures
                            // must leave it available for Auto Learn capture.
                            if AutoLearnSettings.isEnabled {
                                await AutoLearnService.shared.recordingDidStart()
                            }

                            await activeModeTask.value

                            guard self.recordingState == .recording,
                                self.activeRecordingStartID == startID,
                                !self.shouldCancelRecording
                            else {
                                return
                            }

                            let modelResolution = ModeRuntimeResolver.transcriptionModelResolution(
                                transcriptionModelManager: self.transcriptionModelManager
                            )
                            guard
                                let transcriptionConfiguration = ModeRuntimeResolver.transcriptionConfiguration(
                                    from: modelResolution
                                )
                            else {
                                let failure = self.recordingModelFailure(for: modelResolution)
                                NotificationManager.shared.showNotification(
                                    title: failure.title,
                                    type: .error,
                                    duration: 7.0,
                                    actionButton: (failure.actionLabel, failure.action)
                                )
                                await self.recorder.stopRecording()
                                try? FileManager.default.removeItem(at: permanentURL)
                                self.recordedFile = nil
                                self.setLiveState(.idle)
                                self.activeRecordingStartID = nil
                                self.clearActiveRecordingContext()
                                await self.cleanupResourcesIfIdle()
                                await self.recorderUIManager?.dismissRecorderPanel()
                                return
                            }

                            self.startRecordingContextCapture(
                                language: transcriptionConfiguration.language,
                                clipboardText: clipboardText
                            )

                            if self.serviceRegistry.shouldUseRealtimeTranscription(for: transcriptionConfiguration),
                                let contextStore = self.activeRecordingContextStore
                            {
                                let session = self.serviceRegistry.createSession(
                                    for: transcriptionConfiguration,
                                    onPartialTranscript: { [weak self] partial in
                                        Task { @MainActor in
                                            guard let self,
                                                self.activeRecordingStartID == startID,
                                                self.recordingState == .recording
                                            else {
                                                return
                                            }
                                            self.partialTranscript = partial
                                        }
                                    }
                                )
                                self.currentSession = session
                                self.currentSessionTranscriptionConfiguration = transcriptionConfiguration
                                let realCallback = try await session.prepare(
                                    configuration: transcriptionConfiguration,
                                    vocabulary: contextStore.vocabularyPreparation.current
                                )

                                if let realCallback {
                                    let droppedStartupChunks = realtimeAudioGate.activate(realCallback)
                                    if droppedStartupChunks > 0 {
                                        self.logger.warning(
                                            "Realtime startup audio gate dropped \(droppedStartupChunks, privacy: .public) chunks before streaming became active"
                                        )
                                    }
                                } else {
                                    _ = realtimeAudioGate.reset()
                                    self.recorder.onAudioChunk = nil
                                }
                            } else {
                                self.currentSession = nil
                                self.currentSessionTranscriptionConfiguration = nil
                                self.recorder.onAudioChunk = nil
                                _ = realtimeAudioGate.reset()
                            }

                            self.scheduleVoiceInkRefinePreparation(for: startID)

                            Task { @MainActor [weak self] in
                                guard let self else { return }

                                let currentModel = ModeRuntimeResolver.transcriptionConfiguration(
                                    transcriptionModelManager: self.transcriptionModelManager
                                )?.model

                                if let model = currentModel,
                                    model.provider == .whisper
                                {
                                    if let localWhisperModel = self.whisperModelManager.availableModels.first(where: {
                                        $0.name == model.name
                                    }),
                                        self.whisperModelManager.whisperContext == nil
                                    {
                                        do {
                                            try await self.whisperModelManager.loadModel(localWhisperModel)
                                        } catch {
                                            self.logger.error("❌ Model loading failed: \(error, privacy: .public)")
                                        }
                                    }
                                } else if let fluidAudioModel = currentModel as? FluidAudioModel {
                                    // Unified streaming does not need the offline encoder.
                                    if transcriptionConfiguration.isRealtimeEnabled,
                                        FluidAudioModelManager.isParakeetUnifiedModel(named: fluidAudioModel.name)
                                    {
                                        return
                                    }
                                    try? await self.serviceRegistry.fluidAudioTranscriptionService.loadModel(
                                        for: fluidAudioModel)
                                } else if let transcribeCppModel = currentModel as? TranscribeCppModel {
                                    try? await self.serviceRegistry.transcribeCppTranscriptionService.loadModel(
                                        for: transcribeCppModel)
                                }

                            }

                        } catch {
                            activeModeTask.cancel()
                            self.logger.error("Recording failed to start: \(error, privacy: .public)")
                            let audioFailure = self.recordingAudioFailure(for: error)
                            if audioFailure == nil {
                                await self.recorder.stopRecording()
                            }
                            self.cancelCurrentSession()
                            if let recordedFile = self.recordedFile {
                                try? FileManager.default.removeItem(at: recordedFile)
                            }
                            self.setLiveState(.idle)
                            self.recordedFile = nil
                            self.activeRecordingStartID = nil
                            self.clearActiveRecordingContext()
                            await self.cleanupResourcesIfIdle()
                            if let failure = audioFailure {
                                NotificationManager.shared.showNotification(
                                    title: failure.title,
                                    type: .error,
                                    duration: 7.0,
                                    actionButton: (failure.actionLabel, failure.action)
                                )
                            } else {
                                NotificationManager.shared.showNotification(
                                    title: String(localized: "Recording failed to start"), type: .error)
                            }
                            await self.recorderUIManager?.dismissRecorderPanel()
                        }
                    }
                } else {
                    if activeRecordingStartID == startID {
                        activeRecordingStartID = nil
                        recordedFile = nil
                        setLiveState(.idle)
                    }
                    logger.error("Recording permission denied")
                }
            }
        }
    }

    private func requestRecordPermission(response: @escaping (Bool) -> Void) {
        response(true)
    }

    @MainActor
    private func recordingModelFailure(
        for resolution: ModeTranscriptionModelResolution
    ) -> (title: String, actionLabel: String, action: () -> Void) {
        switch resolution {
        case .noMode:
            return (
                String(localized: "No mode configured"),
                String(localized: "Manage Modes"),
                ModeSetupNavigator.openModesSettings
            )
        case .noSelection(let mode):
            return (
                String(
                    format: String(localized: "No transcription model is selected for the '%@' mode"),
                    mode.name
                ),
                String(localized: "Manage Modes"),
                ModeSetupNavigator.openModesSettings
            )
        case .modelNotFound(let mode):
            return (
                String(
                    format: String(localized: "The transcription model selected for the '%@' mode is unavailable"),
                    mode.name
                ),
                String(localized: "Manage Modes"),
                ModeSetupNavigator.openModesSettings
            )
        case .unavailable(let mode, let model), .available(let mode, let model):
            return (
                String(
                    format: String(localized: "'%@' is not available for the %@ mode"),
                    model.displayName,
                    mode.name
                ),
                String(localized: "Manage AI Models"),
                ModeSetupNavigator.openModelsSettings
            )
        }
    }

    /// Checks requirements that do not depend on asynchronous app and URL mode resolution.
    @MainActor
    private func passesRecordingPreflight() async -> Bool {
        if !ModeManager.shared.hasEnabledConfiguration {
            await failRecordingPreflight(
                title: String(localized: "No mode configured"),
                actionLabel: String(localized: "Manage Modes"),
                action: ModeSetupNavigator.openModesSettings
            )
            return false
        }

        return true
    }

    @MainActor
    private func failRecordingPreflight(
        title: String,
        actionLabel: String,
        action: @escaping () -> Void
    ) async {
        logger.error("❌ Recording preflight failed: \(title, privacy: .public)")
        activeRecordingStartID = nil
        recordedFile = nil
        setLiveState(.idle)
        NotificationManager.shared.showNotification(
            title: title,
            type: .error,
            duration: 7.0,
            actionButton: (actionLabel, action)
        )
        await recorderUIManager?.dismissRecorderPanel()
    }

    // MARK: - Recording Context

    private func startRecordingContextCapture(language: String, clipboardText: String?) {
        clearActiveRecordingContext()

        let store = RecordingContextSnapshotStore(
            savedVocabulary: CustomVocabularyService.shared.loadSavedVocabulary(from: modelContext)
        )
        store.updateClipboardText(clipboardText)
        activeRecordingContextStore = store
        activeRecordingContextTasks = RecordingContextCaptureService.startCapture(
            into: store,
            language: language
        )
    }

    private func clearActiveRecordingContext() {
        activeRecordingContextStore?.vocabularyPreparation.finish()
        activeRecordingContextTasks.forEach { $0.cancel() }
        activeRecordingContextTasks.removeAll()
        activeRecordingContextStore = nil
    }

    // MARK: - Recording Queue

    private func setLiveState(_ state: RecordingState) {
        liveState = state
        refreshRecordingState()
    }

    private func refreshRecordingState() {
        let displayedState: RecordingState
        if isStoppingLiveRecording {
            displayedState = .transcribing
        } else if liveState != .idle {
            displayedState = liveState
        } else if let headID = jobQueue.pendingIDs.first {
            displayedState = jobDisplayStates[headID] ?? .transcribing
        } else {
            displayedState = .idle
        }

        if recordingState != displayedState {
            recordingState = displayedState
        }
        jobQueue.isDeliveryHeld = isLiveRecording
        if pendingJobCount != jobQueue.pendingCount {
            pendingJobCount = jobQueue.pendingCount
        }
    }

    /// Só guarda transcribing/enhancing: com fila pendente, o painel nunca pode
    /// mostrar `.idle`, senão `toggleRecorderPanel` o dispensaria.
    private func setJobDisplayState(_ state: RecordingState, for transcriptionID: UUID) {
        if state == .transcribing || state == .enhancing {
            jobDisplayStates[transcriptionID] = state
        } else {
            jobDisplayStates[transcriptionID] = nil
        }
        refreshRecordingState()
    }

    private func enqueue(_ job: RecordingJob) {
        let transcriptionID = job.transcription.id
        jobsByID[transcriptionID] = job
        if job.useCase.isAssistantFollowUp
            || ModeRuntimeResolver.outputConfiguration(mode: job.mode).outputMode == .respond
        {
            blockingJobIDs.insert(transcriptionID)
        }

        jobQueue.enqueue(id: transcriptionID) { [weak self] awaitDeliveryTurn in
            await self?.runJob(job, awaitDeliveryTurn: awaitDeliveryTurn)
        }
        refreshRecordingState()
    }

    /// Item cancelado antes de começar a rodar: fica no histórico como cancelado.
    private func discardJob(_ transcriptionID: UUID) {
        guard let job = jobsByID.removeValue(forKey: transcriptionID) else { return }
        job.session?.cancel()
        job.transcription.text = Transcription.canceledTranscriptionText
        job.transcription.transcriptionStatus = TranscriptionStatus.canceled.rawValue
        do {
            try modelContext.save()
        } catch {
            logger.error("Failed to save discarded recording: \(error, privacy: .public)")
        }
        blockingJobIDs.remove(transcriptionID)
        jobDisplayStates[transcriptionID] = nil
        refreshRecordingState()
    }

    // MARK: - Pipeline Dispatch

    private func runJob(
        _ job: RecordingJob,
        awaitDeliveryTurn: @escaping @MainActor () async -> Bool
    ) async {
        let transcription = job.transcription
        let transcriptionID = transcription.id
        defer {
            job.contextCaptureTasks.forEach { $0.cancel() }
            jobsByID[transcriptionID] = nil
            jobDisplayStates[transcriptionID] = nil
            blockingJobIDs.remove(transcriptionID)
            refreshRecordingState()
        }

        // Resolvida na parada, com o modo daquele instante.
        guard let transcriptionConfiguration = job.transcriptionConfiguration else {
            job.contextStore?.vocabularyPreparation.finish()
            transcription.text = String(localized: "Transcription Failed: No model selected")
            transcription.transcriptionStatus = TranscriptionStatus.failed.rawValue
            try? modelContext.save()
            return
        }

        let triggeredMode = JobModeBox()
        let vocabularyPreparation = job.contextStore?.vocabularyPreparation ?? RecordingVocabularyPreparation(
            savedVocabulary: CustomVocabularyService.shared.loadSavedVocabulary(from: modelContext)
        )

        await pipeline.run(
            transcription: transcription,
            audioURL: job.audioURL,
            transcriptionConfiguration: transcriptionConfiguration,
            formattingConfiguration: {
                ModeRuntimeResolver.transcriptionFormattingConfiguration(mode: triggeredMode.mode ?? job.mode)
            },
            session: job.session,
            triggerWordModeSelection: { text in
                guard let (mode, processedText) = ModeManager.shared.getConfigurationForTriggerWord(text) else {
                    return nil
                }
                triggeredMode.mode = mode
                return processedText
            },
            enhancementConfiguration: { [weak self] in
                guard let self,
                    let enhancementService = self.enhancementService,
                    let aiService = enhancementService.getAIService()
                else {
                    return nil
                }
                return ModeRuntimeResolver.currentEnhancementConfiguration(
                    mode: triggeredMode.mode ?? job.mode,
                    enhancementService: enhancementService,
                    aiService: aiService
                )
            },
            vocabularyPreparation: vocabularyPreparation,
            recordingContextSnapshot: {
                job.contextStore?.snapshot
            },
            cancelContextCapture: {
                job.contextCaptureTasks.forEach { $0.cancel() }
            },
            outputConfiguration: {
                ModeRuntimeResolver.outputConfiguration(mode: triggeredMode.mode ?? job.mode)
            },
            sendAfterPaste: job.sendAfterPaste,
            pasteTarget: job.pasteTarget,
            awaitDeliveryTurn: awaitDeliveryTurn,
            onStateChange: { [weak self] state in
                self?.setJobDisplayState(state, for: transcriptionID)
            },
            shouldCancel: { [weak self] in
                self?.jobQueue.isCanceled(transcriptionID) ?? false
            },
            onCancel: {
                job.session?.cancel()
            },
            onDismiss: { [weak self] in
                // O painel fica enquanto houver gravação viva ou outro item na fila.
                guard let self, !self.isLiveRecording, self.jobQueue.pendingCount <= 1 else { return }
                await self.recorderUIManager?.dismissRecorderPanel()
            },
            assistant: TranscriptionPipeline.AssistantHooks(
                isFollowUp: job.useCase.isAssistantFollowUp,
                sendFollowUp: { [weak self] text, transcription in
                    guard let self, !self.jobQueue.isCanceled(transcriptionID) else { return }
                    await self.sendAssistantFollowUp(text, transcription: transcription)
                },
                startResponse: { [weak self] transcript, configuration in
                    guard let self, !self.jobQueue.isCanceled(transcriptionID) else { return }
                    self.assistantSession.beginInitialResponse(
                        transcript: transcript,
                        provider: configuration.provider,
                        modelName: configuration.modelName ?? configuration.provider?.defaultModel,
                        modeName: configuration.mode?.name,
                        modeEmoji: configuration.mode?.icon.value,
                        promptName: configuration.prompt?.title
                    )
                },
                showResponse: { [weak self] response, systemPrompt in
                    guard let self, !self.jobQueue.isCanceled(transcriptionID) else { return }
                    await self.completeAssistantResponse(response, systemPrompt: systemPrompt)
                },
                failResponse: { [weak self] message in
                    guard let self, !self.jobQueue.isCanceled(transcriptionID) else { return }
                    self.assistantSession.fail(message)
                }
            )
        )
    }

    // MARK: - Cancellation

    /// Com gravação viva, cancela só ela. Sem gravação viva, cancela a fila toda.
    func cancelRecording() async {
        if isStoppingLiveRecording {
            // O ramo de parada do toggleRecord lê a flag e descarta a gravação.
            shouldCancelRecording = true
            return
        }

        let shouldFinishSessionImmediately: Bool
        if liveState == .starting || liveState == .recording {
            requestRecordingCancellation()
            await finishActiveRecorderCancellation()
            shouldFinishSessionImmediately = false
        } else if jobQueue.pendingCount > 0 {
            jobQueue.cancelAll()
            partialTranscript = ""
            refreshRecordingState()
            shouldFinishSessionImmediately = false
        } else {
            partialTranscript = ""
            shouldCancelRecording = false
            setLiveState(.idle)
            shouldFinishSessionImmediately = true
        }

        if shouldFinishSessionImmediately {
            await finishRecorderSession()
        }
    }

    func resetRecordingSession() async {
        cancelCurrentSession()
        activeRecordingStartID = nil
        jobQueue.cancelAll()
        shouldCancelRecording = false
        partialTranscript = ""
        assistantSession.reset()
        activeRecordingUseCase = .newSession
        clearActiveRecordingContext()
        await recorder.stopRecording()
        recordedFile = nil
        isStoppingLiveRecording = false
        setLiveState(.idle)
        await cleanupResources()
    }

    private func requestRecordingCancellation() {
        shouldCancelRecording = true
        cancelCurrentSession()
    }

    private func finishActiveRecorderCancellation() async {
        activeRecordingStartID = nil
        clearActiveRecordingContext()
        await recorder.stopRecording()
        await saveCanceledRecording()
        recordedFile = nil
        partialTranscript = ""
        setLiveState(.idle)
        await cleanupResourcesIfIdle()
    }

    private func saveCanceledRecording() async {
        guard let recordedFile else { return }

        let transcription = makeRecordingTranscription(
            for: recordedFile,
            text: Transcription.canceledTranscriptionText,
            duration: 0,
            transcriptionStatus: .canceled
        )
        await saveCanceledRecording(transcription)
    }

    private func saveCanceledRecording(_ transcription: Transcription) async {
        guard let audioFileURL = transcription.audioFileURL,
            let audioURL = URL(string: audioFileURL),
            FileManager.default.fileExists(atPath: audioURL.path)
        else { return }

        let duration = await AudioFileMetadata.duration(for: audioURL)
        transcription.markAsCanceledTranscription(duration: duration)

        modelContext.insert(transcription)

        do {
            try modelContext.save()
            NotificationCenter.default.post(name: .transcriptionCreated, object: transcription)
        } catch {
            logger.error("Failed to save canceled recording: \(error, privacy: .public)")
        }
    }

    private func makeRecordingTranscription(
        for audioURL: URL,
        text: String,
        duration: TimeInterval,
        transcriptionStatus: TranscriptionStatus
    ) -> Transcription {
        let modeMetadata = currentModeMetadata()

        return Transcription(
            text: text,
            duration: duration,
            audioFileURL: audioURL.absoluteString,
            transcriptionModelName: ModeRuntimeResolver.transcriptionConfiguration(
                transcriptionModelManager: transcriptionModelManager
            )?.model.displayName,
            modeName: modeMetadata.name,
            modeEmoji: modeMetadata.emoji,
            transcriptionStatus: transcriptionStatus
        )
    }

    private func currentModeMetadata() -> (name: String?, emoji: String?) {
        guard let mode = ModeManager.shared.currentEffectiveConfiguration,
            mode.isEnabled
        else {
            return (nil, nil)
        }

        return (mode.name, mode.icon.value)
    }

    private func scheduleVoiceInkRefinePreparation(for recordingStartID: UUID) {
        voiceInkRefinePreparationTask?.cancel()

        voiceInkRefinePreparationTask = Task { @MainActor [weak self] in
            guard let self,
                self.recordingState == .recording,
                self.activeRecordingStartID == recordingStartID,
                !self.shouldCancelRecording,
                let enhancementService = self.enhancementService,
                let aiService = enhancementService.getAIService()
            else {
                return
            }

            let initialConfiguration = ModeRuntimeResolver.currentEnhancementConfiguration(
                enhancementService: enhancementService,
                aiService: aiService
            )
            guard initialConfiguration.isEnabled,
                initialConfiguration.provider == .voiceInkRefine
            else {
                return
            }

            // Preserve an already-warm XPC model immediately, while retaining the
            // debounce below before any new model preparation begins.
            await aiService.voiceInkRefineService.keepPreparedModelWarmForRecording()

            do {
                try await Task.sleep(for: .milliseconds(450))
            } catch {
                return
            }

            guard self.recordingState == .recording,
                self.activeRecordingStartID == recordingStartID,
                !self.shouldCancelRecording
            else {
                return
            }

            let configuration = ModeRuntimeResolver.currentEnhancementConfiguration(
                enhancementService: enhancementService,
                aiService: aiService
            )
            guard configuration.isEnabled, configuration.provider == .voiceInkRefine else {
                return
            }

            await aiService.voiceInkRefineService.prepareForRecording()
        }
    }

    // MARK: - Resource Cleanup

    private func cancelCurrentSession() {
        currentSession?.cancel()
        currentSession = nil
        currentSessionTranscriptionConfiguration = nil
    }

    private func finishRecorderSession() async {
        let preparationTask = voiceInkRefinePreparationTask
        voiceInkRefinePreparationTask = nil
        preparationTask?.cancel()
        enhancementService?.clearCapturedContexts()

        await preparationTask?.value
        await enhancementService?
            .getAIService()?
            .voiceInkRefineService
            .unloadPreparedModelIfNeeded()
    }

    /// Descarrega modelos só sem gravação viva e com a fila vazia.
    private func cleanupResourcesIfIdle() async {
        guard !isLiveRecording, jobQueue.pendingCount == 0 else { return }
        await cleanupResources()
    }

    func cleanupResources() async {
        logger.notice("cleanupResources: releasing model resources")
        activeRecordingStartID = nil
        activeRecordingUseCase = .newSession
        await finishRecorderSession()
        await whisperModelManager.cleanupResources()
        await serviceRegistry.cleanup()
        logger.notice("cleanupResources: completed")
    }

    // MARK: - Notification Handling

    func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePromptChange),
            name: .promptDidChange,
            object: nil
        )
    }

    @objc func handlePromptChange() {
        Task {
            let currentPrompt =
                UserDefaults.standard.string(forKey: "TranscriptionPrompt")
                ?? whisperModelManager.whisperPrompt.transcriptionPrompt
            if let context = whisperModelManager.whisperContext {
                await context.setPrompt(currentPrompt)
            }
        }
    }
}

enum AudioFileMetadata {
    static func duration(for url: URL) async -> TimeInterval {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return 0 }
        let seconds = CMTimeGetSeconds(duration)
        return seconds.isFinite ? seconds : 0
    }
}
