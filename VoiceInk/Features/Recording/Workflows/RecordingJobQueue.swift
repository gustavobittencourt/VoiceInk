import Foundation

/// Fila das gravações já paradas que ainda estão sendo transcritas, melhoradas
/// ou entregues, para o usuário poder gravar de novo sem esperar.
///
/// Dois estágios, cada um serial:
/// - processamento: um item por vez. O WhisperContext local é compartilhado e
///   `setLanguage`/`setPrompt`/`fullTranscribe` intercalariam entre itens.
/// - entrega: na ordem de entrada (FIFO) e só sem gravação viva
///   (`isDeliveryHeld`), para nenhuma janela pular na frente durante a fala.
///
/// O item sinaliza o fim do processamento chamando `awaitDeliveryTurn`, e a
/// partir daí o próximo item já pode processar enquanto ele espera a vez de
/// entregar. O item só sai da fila quando o `run` dele retorna.
@MainActor
final class RecordingJobQueue {
    /// Corpo de um item. Chama `awaitDeliveryTurn()` imediatamente antes de
    /// entregar; `false` = item cancelado, não entregue.
    typealias Run = @MainActor (_ awaitDeliveryTurn: @escaping @MainActor () async -> Bool) async -> Void

    private enum Stage {
        case waiting
        case processing
        case awaitingDelivery
    }

    private final class Entry {
        let id: UUID
        let run: Run
        var stage: Stage = .waiting
        var turnContinuation: CheckedContinuation<Bool, Never>?

        init(id: UUID, run: @escaping Run) {
            self.id = id
            self.run = run
        }
    }

    var onChange: (@MainActor () -> Void)?
    var onIdle: (@MainActor () async -> Void)?
    var onDiscard: (@MainActor (UUID) async -> Void)?

    private var entries: [Entry] = []
    private var canceledIDs = Set<UUID>()

    var pendingIDs: [UUID] { entries.map(\.id) }
    var pendingCount: Int { entries.count }

    var isDeliveryHeld = false {
        didSet {
            guard oldValue != isDeliveryHeld else { return }
            pump()
            onChange?()
        }
    }

    func enqueue(id: UUID, run: @escaping Run) {
        entries.append(Entry(id: id, run: run))
        onChange?()
        pump()
    }

    func isCanceled(_ id: UUID) -> Bool {
        canceledIDs.contains(id)
    }

    func cancelAll() {
        guard !entries.isEmpty else { return }

        entries.forEach { canceledIDs.insert($0.id) }
        let discardedIDs = entries.filter { $0.stage == .waiting }.map(\.id)
        entries.removeAll { $0.stage == .waiting }

        // Quem espera a vez de entregar recebe `false` na hora; quem ainda
        // processa termina sozinho, porque o pipeline consulta `isCanceled`.
        for entry in entries {
            guard let continuation = entry.turnContinuation else { continue }
            entry.turnContinuation = nil
            continuation.resume(returning: false)
        }
        onChange?()

        let drained = entries.isEmpty
        Task { @MainActor in
            for id in discardedIDs {
                await self.onDiscard?(id)
                self.canceledIDs.remove(id)
            }
            if drained, self.entries.isEmpty {
                await self.onIdle?()
            }
        }
    }

    // MARK: - Private

    private func pump() {
        if !entries.contains(where: { $0.stage == .processing }),
            let next = entries.first(where: { $0.stage == .waiting })
        {
            next.stage = .processing
            start(next)
        }

        if !isDeliveryHeld, let head = entries.first, let continuation = head.turnContinuation {
            head.turnContinuation = nil
            continuation.resume(returning: !canceledIDs.contains(head.id))
        }
    }

    private func start(_ entry: Entry) {
        Task { @MainActor in
            await entry.run { [weak self] in
                await self?.awaitDeliveryTurn(for: entry) ?? false
            }
            await self.finish(entry)
        }
    }

    private func awaitDeliveryTurn(for entry: Entry) async -> Bool {
        entry.stage = .awaitingDelivery
        pump()

        if canceledIDs.contains(entry.id) { return false }
        if !isDeliveryHeld, entries.first === entry { return true }

        return await withCheckedContinuation { entry.turnContinuation = $0 }
    }

    private func finish(_ entry: Entry) async {
        entries.removeAll { $0 === entry }
        canceledIDs.remove(entry.id)
        onChange?()
        pump()

        if entries.isEmpty {
            await onIdle?()
        }
    }
}
