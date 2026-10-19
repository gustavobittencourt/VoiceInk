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
}
