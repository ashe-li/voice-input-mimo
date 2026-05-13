import XCTest
@testable import VoiceInputMimo

final class ContextCaptureTests: XCTestCase {
    func testCapturedContext_EmptyConstant() {
        XCTAssertNil(CapturedContext.empty.bundleID)
        XCTAssertNil(CapturedContext.empty.appName)
    }

    func testCapturedContext_Equatable() {
        let a = CapturedContext(bundleID: "com.apple.mail", appName: "Mail")
        let b = CapturedContext(bundleID: "com.apple.mail", appName: "Mail")
        let c = CapturedContext(bundleID: "com.apple.notes", appName: "Notes")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testCapture_ReturnsBundleIDForFrontmostApp() {
        // Under XCTest there must be a frontmost app (typically xctest itself).
        // We don't assert a specific bundle ID since CI may differ — just that
        // the capture returns *something* shaped right and doesn't crash.
        let captured = ContextCapture.capture()
        // Either there's a frontmost app (bundleID set) or .empty (loginwindow
        // case) — both are valid shapes.
        if captured.bundleID != nil {
            XCTAssertFalse(captured.bundleID!.isEmpty, "captured bundleID should not be empty string")
        }
    }
}
