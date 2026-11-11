import XCTest
#if canImport(VoiceInk)
@testable import VoiceInk
#endif

/// Portão assíncrono para segurar um item da fila num ponto conhecido do teste.
@MainActor
final class AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

@MainActor
final class EventLog {
    var events: [String] = []
}

@MainActor
final class RecordingJobQueueTests: XCTestCase {
    func testDeliveriesFollowEnqueueOrder() async {
        let queue = RecordingJobQueue()
        let log = EventLog()
        let gateA = AsyncGate()
        let delivered = expectation(description: "A e B entregues")
        delivered.expectedFulfillmentCount = 2

        queue.enqueue(id: UUID()) { turn in
            await gateA.wait()
            if await turn() {
                log.events.append("A")
                delivered.fulfill()
            }
        }
        queue.enqueue(id: UUID()) { turn in
            if await turn() {
                log.events.append("B")
                delivered.fulfill()
            }
        }

        gateA.open()
        await fulfillment(of: [delivered], timeout: 2)
        XCTAssertEqual(log.events, ["A", "B"])
    }

    func testNextJobProcessesWhileEarlierWaitsForDelivery() async {
        let queue = RecordingJobQueue()
        queue.isDeliveryHeld = true
        let aWaiting = expectation(description: "A chegou ao turno")
        let bStarted = expectation(description: "B começou a processar")
        let aDelivered = expectation(description: "A entregue com hold ativo")
        aDelivered.isInverted = true

        queue.enqueue(id: UUID()) { turn in
            aWaiting.fulfill()
            if await turn() { aDelivered.fulfill() }
        }
        queue.enqueue(id: UUID()) { _ in
            bStarted.fulfill()
        }

        await fulfillment(of: [aWaiting, bStarted], timeout: 2)
        await fulfillment(of: [aDelivered], timeout: 0.2)
    }

    func testDeliveryWaitsWhileHeldAndResumesWhenReleased() async {
        let queue = RecordingJobQueue()
        queue.isDeliveryHeld = true
        let log = EventLog()
        let delivered = expectation(description: "A entregue")

        queue.enqueue(id: UUID()) { turn in
            if await turn() {
                log.events.append("A")
                delivered.fulfill()
            }
        }

        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(log.events, [])

        queue.isDeliveryHeld = false
        await fulfillment(of: [delivered], timeout: 2)
        XCTAssertEqual(log.events, ["A"])
    }

    func testHeldDeliveriesReleaseInEnqueueOrder() async {
        let queue = RecordingJobQueue()
        queue.isDeliveryHeld = true
        let log = EventLog()
        let aInTurn = expectation(description: "A no turno")
        let bInTurn = expectation(description: "B no turno")
        let delivered = expectation(description: "A e B entregues")
        delivered.expectedFulfillmentCount = 2

        queue.enqueue(id: UUID()) { turn in
            aInTurn.fulfill()
            if await turn() {
                log.events.append("A")
                delivered.fulfill()
            }
        }
        queue.enqueue(id: UUID()) { turn in
            bInTurn.fulfill()
            if await turn() {
                log.events.append("B")
                delivered.fulfill()
            }
        }

        await fulfillment(of: [aInTurn, bInTurn], timeout: 2)
        XCTAssertEqual(log.events, [])

        queue.isDeliveryHeld = false
        await fulfillment(of: [delivered], timeout: 2)
        XCTAssertEqual(log.events, ["A", "B"])
    }

    func testSecondJobDoesNotStartWhileFirstIsProcessing() async {
        let queue = RecordingJobQueue()
        let log = EventLog()
        let gateA = AsyncGate()
        let bStarted = expectation(description: "B começou")

        queue.enqueue(id: UUID()) { turn in
            await gateA.wait()
            _ = await turn()
        }
        queue.enqueue(id: UUID()) { _ in
            log.events.append("B começou")
            bStarted.fulfill()
        }

        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(log.events, [])

        gateA.open()
        await fulfillment(of: [bStarted], timeout: 2)
    }

    func testJobThatFinishesWithoutDeliveryDoesNotBlockQueue() async {
        let queue = RecordingJobQueue()
        let bDelivered = expectation(description: "B entregue")
        let idle = expectation(description: "fila vazia")
        queue.onIdle = { idle.fulfill() }

        queue.enqueue(id: UUID()) { _ in }
        queue.enqueue(id: UUID()) { turn in
            if await turn() { bDelivered.fulfill() }
        }

        await fulfillment(of: [bDelivered, idle], timeout: 2)
        XCTAssertTrue(queue.pendingIDs.isEmpty)
    }

    /// Ordem do Esc duplo (`cancelEverything`): a fila é cancelada antes de a gravação
    /// viva sair, e a retenção que cai depois não pode colar o item pronto.
    func testHeldJobCanceledBeforeReleaseIsNotDelivered() async {
        let queue = RecordingJobQueue()
        queue.isDeliveryHeld = true
        let log = EventLog()
        let aInTurn = expectation(description: "A no turno")
        let aAnswered = expectation(description: "turno de A respondeu")

        queue.enqueue(id: UUID()) { turn in
            aInTurn.fulfill()
            log.events.append("turno de A: \(await turn())")
            aAnswered.fulfill()
        }

        await fulfillment(of: [aInTurn], timeout: 2)
        queue.cancelAll()
        queue.isDeliveryHeld = false
        await fulfillment(of: [aAnswered], timeout: 2)
        XCTAssertEqual(log.events, ["turno de A: false"])
    }

    func testCancelAllDiscardsWaitingAndFailsPendingTurns() async {
        let queue = RecordingJobQueue()
        queue.isDeliveryHeld = true
        let log = EventLog()
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let gateB = AsyncGate()
        let aInTurn = expectation(description: "A no turno")
        let aAnswered = expectation(description: "turno de A respondeu")
        let bStarted = expectation(description: "B processando")
        let cDiscarded = expectation(description: "C descartado")
        let idle = expectation(description: "fila vazia")
        var discardedIDs: [UUID] = []
        var idleCount = 0
        queue.onDiscard = { id in
            discardedIDs.append(id)
            cDiscarded.fulfill()
        }
        queue.onIdle = {
            idleCount += 1
            idle.fulfill()
        }

        queue.enqueue(id: a) { turn in
            aInTurn.fulfill()
            let delivered = await turn()
            log.events.append("turno de A: \(delivered)")
            aAnswered.fulfill()
        }
        queue.enqueue(id: b) { _ in
            bStarted.fulfill()
            await gateB.wait()
        }
        queue.enqueue(id: c) { _ in
            log.events.append("C rodou")
        }

        await fulfillment(of: [aInTurn, bStarted], timeout: 2)
        queue.cancelAll()
        XCTAssertTrue(queue.isCanceled(a))
        XCTAssertTrue(queue.isCanceled(b))
        XCTAssertTrue(queue.isCanceled(c))

        await fulfillment(of: [aAnswered, cDiscarded], timeout: 2)
        XCTAssertEqual(log.events, ["turno de A: false"])
        XCTAssertEqual(discardedIDs, [c])

        gateB.open()
        await fulfillment(of: [idle], timeout: 2)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(idleCount, 1)
        XCTAssertFalse(log.events.contains("C rodou"))
    }

    func testEnqueueAfterCancelAllRunsNormally() async {
        let queue = RecordingJobQueue()
        let delivered = expectation(description: "D entregue")
        queue.cancelAll()

        queue.enqueue(id: UUID()) { turn in
            if await turn() { delivered.fulfill() }
        }

        await fulfillment(of: [delivered], timeout: 2)
    }

    func testPendingCountTracksLifecycle() async {
        let queue = RecordingJobQueue()
        var counts: [Int] = []
        let idle = expectation(description: "fila vazia")
        queue.onChange = { counts.append(queue.pendingCount) }
        queue.onIdle = { idle.fulfill() }

        queue.enqueue(id: UUID()) { _ in }
        queue.enqueue(id: UUID()) { _ in }

        await fulfillment(of: [idle], timeout: 2)
        XCTAssertEqual(counts, [1, 2, 1, 0])
    }
}
