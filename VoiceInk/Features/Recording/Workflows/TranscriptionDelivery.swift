import AppKit
import Foundation
import os

/// Entrega a transcrição no app que estava em foco quando a gravação começou,
/// em vez de onde o usuário estiver quando a transcrição fica pronta.
enum PasteTargetPinning {
    static let userDefaultsKey = "PinPasteTargetToRecordStart"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: userDefaultsKey) as? Bool ?? true
    }
}

@MainActor
final class TranscriptionDelivery {
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "TranscriptionDelivery")

    /// App que estava na frente quando a entrega ativou o app de origem para
    /// colar; nil fora dessa janela. Uma gravação que começa nela lê o app
    /// da entrega como frontmost.
    private(set) var focusBorrowedFrom: NSRunningApplication?

    struct Request {
        let transcription: Transcription
        let text: String?
        let output: OutputRuntimeConfiguration
        let responseConfig: EnhancementRuntimeConfiguration?
        let responseError: String?
        let isAssistantFollowUp: Bool
        let sendAfterPaste: Bool
        /// App em foco quando ESTA gravação começou. Viaja com o item porque,
        /// com gravações concorrentes, o singleton do ActiveWindowService já
        /// aponta para a gravação seguinte.
        let pasteTarget: NSRunningApplication?
    }

    private enum PasteTargetResult {
        case paste(restoreFocusTo: NSRunningApplication?)
        case copyToClipboard
    }

    struct Actions {
        let setState: (RecordingState) -> Void
        let dismiss: () async -> Void
        let sendFollowUp: (String, Transcription) async -> Void
        let showResponse: (String, String?) async -> Void
        let failResponse: (String) async -> Void
    }

    func deliver(_ request: Request, actions: Actions) async {
        guard request.transcription.transcriptionStatus == TranscriptionStatus.completed.rawValue else {
            await actions.dismiss()
            return
        }

        if request.isAssistantFollowUp {
            await deliverFollowUp(request, actions: actions)
            return
        }

        if request.output.outputMode == .respond,
            request.responseConfig != nil || request.responseError != nil
        {
            await deliverResponse(request, actions: actions)
            return
        }

        if request.output.outputMode == .customCommand {
            await deliverCustomCommand(request, actions: actions)
            return
        }

        if let text = request.text {
            let sendKey = request.sendAfterPaste ? FinishAndSendSettings.selectedKey : request.output.autoSendKey
            await paste(text, sendKey: sendKey, target: request.pasteTarget, actions: actions)
        } else {
            await actions.dismiss()
        }
    }

    private func deliverFollowUp(_ item: Request, actions: Actions) async {
        SoundManager.shared.playStopSound()

        guard let text = item.text?.trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
        else {
            return
        }

        actions.setState(.enhancing)
        await actions.sendFollowUp(text, item.transcription)
    }

    private func deliverResponse(_ item: Request, actions: Actions) async {
        SoundManager.shared.playStopSound()

        if let responseError = item.responseError {
            await actions.failResponse("Enhancement failed: \(responseError)")
        } else if let text = item.text,
            item.responseConfig != nil
        {
            await actions.showResponse(text, item.transcription.aiRequestSystemMessage)
        } else {
            await actions.failResponse("No response was generated.")
        }
    }

    private func deliverCustomCommand(_ item: Request, actions: Actions) async {
        guard let text = item.text else {
            notifyCustomCommandFailure(CustomCommandDeliveryError.noTextToDeliver)
            SoundManager.shared.playStopSound()
            await actions.dismiss()
            return
        }

        guard let customCommand = item.output.customCommand,
            let command = customCommand.trimmedCommand
        else {
            notifyCustomCommandFailure(CustomCommandDeliveryError.commandNotConfigured)
            SoundManager.shared.playStopSound()
            await actions.dismiss()
            return
        }

        let commandText = deliverableText(from: text)
        let finishAndSendKey: FinishAndSendKey = item.sendAfterPaste ? FinishAndSendSettings.selectedKey : .none
        SoundManager.shared.playStopSound()
        await actions.dismiss()

        Task {
            await runCustomCommand(command: command, commandText: commandText, finishAndSendKey: finishAndSendKey)
        }
    }

    private func runCustomCommand(command: String, commandText: String, finishAndSendKey: FinishAndSendKey) async {
        let startTime = Date()
        logger.notice("Custom command started")

        do {
            let result = try await CustomCommandDeliveryRunner.run(
                command: command,
                timeout: 10,
                context: CustomCommandDeliveryContext(transcript: commandText)
            )

            let duration = Date().timeIntervalSince(startTime)
            let stdoutBytes = result.stdout.utf8.count
            let stderrBytes = result.stderr.utf8.count

            if !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                logger.notice(
                    "Custom command stdout bytes=\(stdoutBytes, privacy: .public): \(result.stdout, privacy: .public)")
            }

            if !result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                logger.notice(
                    "Custom command succeeded with stderr duration=\(Self.formattedDuration(duration), privacy: .public)s stdoutBytes=\(stdoutBytes, privacy: .public) stderrBytes=\(stderrBytes, privacy: .public): \(result.stderr, privacy: .public)"
                )
            } else {
                logger.notice(
                    "Custom command succeeded duration=\(Self.formattedDuration(duration), privacy: .public)s stdoutBytes=\(stdoutBytes, privacy: .public) stderrBytes=\(stderrBytes, privacy: .public)"
                )
            }

            if finishAndSendKey.isEnabled {
                // Let the target app finish pasting before sending.
                try await Task.sleep(nanoseconds: 150_000_000)
                CursorPaster.performSendKey(finishAndSendKey)
            }
        } catch {
            notifyCustomCommandFailure(error, duration: Date().timeIntervalSince(startTime))
        }
    }

    private func notifyCustomCommandFailure(_ error: Error, duration: TimeInterval? = nil) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        if let duration {
            logger.error(
                "Custom command failed duration=\(Self.formattedDuration(duration), privacy: .public)s: \(message, privacy: .public)"
            )
        } else {
            logger.error("Custom command failed: \(message, privacy: .public)")
        }
    }

    private static func formattedDuration(_ duration: TimeInterval) -> String {
        String(format: "%.3f", duration)
    }

    private func paste(
        _ text: String, sendKey: FinishAndSendKey, target: NSRunningApplication?, actions: Actions
    ) async {
        let textToPaste = deliverableText(from: text)
        let appendSpace = UserDefaults.standard.bool(forKey: "AppendTrailingSpace")
        let pastedText = textToPaste + (appendSpace ? " " : "")
        actions.setState(.idle)
        SoundManager.shared.playStopSound()
        await actions.dismiss()
        defer { focusBorrowedFrom = nil }

        guard case .paste(let restoreFocusTo) = await activateRecordStartTarget(target) else {
            _ = ClipboardManager.copyToClipboard(pastedText)
            NotificationManager.shared.showNotification(
                title: String(localized: "Original app is no longer available. Text copied to clipboard."),
                type: .warning,
                duration: 5.0
            )
            return
        }

        // Só retorna depois do Cmd+V: ele sai ≥ prePasteDelay depois do start,
        // e a próxima gravação da fila ativaria o app dela nessa janela.
        let pasteOutcome = await CursorPaster.startPasteAtCursor(pastedText, sendKey: sendKey).value

        if sendKey.isEnabled && pasteOutcome.result.didPostPasteCommand {
            try? await Task.sleep(nanoseconds: 150_000_000)
            if let generation = pasteOutcome.autoLearnGeneration {
                await AutoLearnService.shared.cancelForAutoSend(generation: generation)
            }
            CursorPaster.performSendKey(sendKey)
        }

        if let restoreFocusTo, !restoreFocusTo.isTerminated,
            restoreFocusTo.processIdentifier != target?.processIdentifier
        {
            _ = restoreFocusTo.activate()
            _ = await FocusWait.until(timeout: 0.6) {
                NSWorkspace.shared.frontmostApplication?.processIdentifier == restoreFocusTo.processIdentifier
            }
        }
    }

    /// Reativa o app capturado no início da gravação e espera ele voltar a ser
    /// frontmost. É obrigatório esperar: `CursorPaster` posta o Cmd+V em
    /// `.cghidEventTap`, que entrega ao frontmost do instante do evento — não
    /// existe destino no evento, nem pid nem janela.
    /// Devolve `restoreFocusTo` = app que estava na frente antes da ativação,
    /// para a entrega devolver o foco depois de colar.
    private func activateRecordStartTarget(_ target: NSRunningApplication?) async -> PasteTargetResult {
        let frontmost = NSWorkspace.shared.frontmostApplication
        let plan = PasteTargetPolicy.plan(
            pinningEnabled: PasteTargetPinning.isEnabled,
            hasTarget: target != nil,
            targetIsTerminated: target?.isTerminated ?? false,
            targetIsFrontmost: target?.processIdentifier == frontmost?.processIdentifier
        )
        switch plan {
        case .pasteInFrontmost:
            return .paste(restoreFocusTo: nil)
        case .copyToClipboard:
            logger.notice("Paste target is no longer running; copying to clipboard")
            return .copyToClipboard
        case .activateTarget:
            break
        }
        guard let target else { return .paste(restoreFocusTo: nil) }

        // Nada de `activateIgnoringOtherApps`: o compilador avisa que no macOS 14+
        // a opção "will have no effect" — usá-la daria a falsa impressão de forçar
        // o foco. `activate()` é o caminho atual, sujeito à ativação cooperativa.
        focusBorrowedFrom = frontmost
        _ = target.activate()

        // Polling em vez de sleep fixo: troca de Space e app em fullscreen levam
        // mais do que qualquer constante que a gente chutasse aqui.
        let targetBecameFrontmost = await FocusWait.until(timeout: 0.6) {
            NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier
        }
        switch PasteTargetPolicy.afterActivation(targetBecameFrontmost: targetBecameFrontmost) {
        case .paste:
            return .paste(restoreFocusTo: frontmost)
        case .copyToClipboard:
            logger.notice("Paste target did not regain focus in time; copying to clipboard")
            return .copyToClipboard
        }
    }

    private func deliverableText(from text: String) -> String {
        var textToDeliver = text
        if let restrictionMessage = LicenseViewModel.shared.usageRestrictionMessage {
            textToDeliver = """
                \(restrictionMessage)
                \n\(textToDeliver)
                """
        }

        return textToDeliver
    }
}
