import XCTest
#if canImport(VoiceInk)
@testable import VoiceInk
#endif

final class PasteTargetPolicyTests: XCTestCase {
    func testPinningDisabledPastesInFrontmost() {
        XCTAssertEqual(
            PasteTargetPolicy.plan(
                pinningEnabled: false, hasTarget: true, targetIsTerminated: true, targetIsFrontmost: false),
            .pasteInFrontmost
        )
    }

    func testNoTargetPastesInFrontmost() {
        XCTAssertEqual(
            PasteTargetPolicy.plan(
                pinningEnabled: true, hasTarget: false, targetIsTerminated: false, targetIsFrontmost: false),
            .pasteInFrontmost
        )
    }

    func testTerminatedTargetCopiesToClipboard() {
        XCTAssertEqual(
            PasteTargetPolicy.plan(
                pinningEnabled: true, hasTarget: true, targetIsTerminated: true, targetIsFrontmost: false),
            .copyToClipboard
        )
    }

    func testFrontmostTargetPastesDirectly() {
        XCTAssertEqual(
            PasteTargetPolicy.plan(
                pinningEnabled: true, hasTarget: true, targetIsTerminated: false, targetIsFrontmost: true),
            .pasteInFrontmost
        )
    }

    func testBackgroundTargetIsActivated() {
        XCTAssertEqual(
            PasteTargetPolicy.plan(
                pinningEnabled: true, hasTarget: true, targetIsTerminated: false, targetIsFrontmost: false),
            .activateTarget
        )
    }

    func testTargetThatNeverFocusesCopiesToClipboard() {
        XCTAssertEqual(PasteTargetPolicy.afterActivation(targetBecameFrontmost: false), .copyToClipboard)
    }

    func testFocusedTargetPastes() {
        XCTAssertEqual(PasteTargetPolicy.afterActivation(targetBecameFrontmost: true), .paste)
    }
}

@MainActor
final class FocusWaitTests: XCTestCase {
    func testWaitsUntilConditionHolds() async {
        var polls = 0
        let becameTrue = await FocusWait.until(timeout: 1, pollInterval: 0.01) {
            polls += 1
            return polls >= 3
        }
        XCTAssertTrue(becameTrue)
        XCTAssertEqual(polls, 3)
    }

    func testGivesUpAfterTimeout() async {
        let start = Date()
        let becameTrue = await FocusWait.until(timeout: 0.1, pollInterval: 0.01) { false }
        XCTAssertFalse(becameTrue)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.1)
    }
}
