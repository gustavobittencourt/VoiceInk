import Foundation

/// Decide onde colar o texto de uma gravação. Com várias gravações na fila, o
/// app da frente na hora da entrega tende a ser o de outra gravação: se o app
/// de origem sumiu, o texto vai para o clipboard em vez de cair no app errado.
enum PasteTargetPolicy {
    enum Plan: Equatable {
        case pasteInFrontmost
        case activateTarget
        case copyToClipboard
    }

    enum AfterActivation: Equatable {
        case paste
        case copyToClipboard
    }

    static func plan(
        pinningEnabled: Bool,
        hasTarget: Bool,
        targetIsTerminated: Bool,
        targetIsFrontmost: Bool
    ) -> Plan {
        guard pinningEnabled, hasTarget else { return .pasteInFrontmost }
        if targetIsTerminated { return .copyToClipboard }
        return targetIsFrontmost ? .pasteInFrontmost : .activateTarget
    }

    static func afterActivation(targetBecameFrontmost: Bool) -> AfterActivation {
        targetBecameFrontmost ? .paste : .copyToClipboard
    }

    /// App de origem de uma gravação que começa agora. Uma entrega em curso
    /// pode ter ativado o app de outra gravação só para colar: o app do
    /// usuário é o que estava na frente antes dessa ativação.
    static func recordStartTarget<App>(frontmost: App?, focusBorrowedFrom: App?) -> App? {
        focusBorrowedFrom ?? frontmost
    }
}

/// Espera com prazo por uma troca de foco. `activate()` só pede o foco: se a
/// próxima entrega da fila ler o app da frente antes da troca terminar, o
/// Cmd+V dela cai no app errado.
enum FocusWait {
    @MainActor
    static func until(
        timeout: TimeInterval,
        pollInterval: TimeInterval = 0.03,
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if condition() { return true }
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
    }
}

