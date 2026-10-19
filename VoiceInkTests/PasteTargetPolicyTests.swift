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
