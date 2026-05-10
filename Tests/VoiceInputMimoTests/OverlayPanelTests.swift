import XCTest
import AppKit
@testable import VoiceInputMimo

/// Asserts overlay state transitions without relying on a visible window —
/// validates the data-layer effects of `transition(to:)` (which label is
/// populated/visible, what dismiss delay was scheduled, hover-cancel logic).
/// Pixel-level rendering (cards width, vibrancy, animation) is out of scope
/// here and only reachable via the preview-screenshot E2E flow.
@MainActor
final class OverlayPanelTests: XCTestCase {

    /// `bothReady` with translating=true and differing zh/en: dual-row mode,
    /// 1.8 s dismiss delay (longer because user has more to read).
    func testBothReadyTranslatingDualLine() {
        let panel = OverlayPanel()
        panel.transition(to: .bothReady(
            zh: "幫我看一下我的 backtest",
            en: "Help me check my backtest",
            translating: true
        ))

        XCTAssertFalse(panel.debug_zhHidden, "ZH row should be visible in translation mode")
        XCTAssertEqual(panel.debug_zhText, "幫我看一下我的 backtest")
        XCTAssertEqual(panel.debug_enText, "Help me check my backtest")
        XCTAssertEqual(panel.debug_lastDismissDelay, 1.8, accuracy: 0.01)
    }

    /// `bothReady` with translating=false (ASR-only / refine path with same
    /// text): single-row mode, 0.7 s dismiss. ZH row hidden so the same
    /// text isn't duplicated visually.
    func testBothReadyNonTranslatingSingleLine() {
        let panel = OverlayPanel()
        panel.transition(to: .bothReady(
            zh: "再測試一下",
            en: "再測試一下",
            translating: false
        ))

        XCTAssertTrue(panel.debug_zhHidden, "ZH row should be hidden in single-line mode")
        XCTAssertEqual(panel.debug_enText, "Ready: 再測試一下")
        XCTAssertEqual(panel.debug_lastDismissDelay, 0.7, accuracy: 0.01)
    }

    /// `bothReady` with translating=true but zh==en: collapse to single line
    /// (no point duplicating identical text). Defensive — shouldn't happen
    /// from production code, but the overlay shouldn't render two identical
    /// rows if it does.
    func testBothReadyTranslatingButEqualCollapsesToSingle() {
        let panel = OverlayPanel()
        panel.transition(to: .bothReady(
            zh: "Hello world",
            en: "Hello world",
            translating: true
        ))

        XCTAssertTrue(panel.debug_zhHidden)
        XCTAssertEqual(panel.debug_lastDismissDelay, 0.7, accuracy: 0.01)
    }

    /// Hover cancels the pending auto-dismiss work. Critical UX: user hovers
    /// to read the EN translation, overlay must NOT vanish underneath them.
    func testMouseEnteredCancelsPendingDismiss() {
        let panel = OverlayPanel()
        panel.transition(to: .bothReady(
            zh: "測試",
            en: "test",
            translating: true
        ))
        XCTAssertTrue(panel.debug_hasPendingDismiss, "dismiss should be scheduled")

        panel.debug_simulateMouseEntered()

        XCTAssertFalse(panel.debug_hasPendingDismiss, "hover must cancel the timer")
        XCTAssertTrue(panel.debug_isHovering)
    }

    /// MouseExited re-arms the dismiss with the SAME delay that was
    /// originally requested. The overlay must not "reset" to a different
    /// duration when the cursor leaves.
    func testMouseExitedReSchedulesWithSameDelay() {
        let panel = OverlayPanel()
        panel.transition(to: .bothReady(
            zh: "測試",
            en: "test",
            translating: true
        ))
        let originalDelay = panel.debug_lastDismissDelay

        panel.debug_simulateMouseEntered()
        XCTAssertFalse(panel.debug_hasPendingDismiss)

        panel.debug_simulateMouseExited()

        XCTAssertTrue(panel.debug_hasPendingDismiss, "exiting hover must re-arm dismiss")
        XCTAssertFalse(panel.debug_isHovering)
        XCTAssertEqual(panel.debug_lastDismissDelay, originalDelay, accuracy: 0.01)
    }

    /// Active phases (recording/transcribing/refining) don't auto-dismiss,
    /// so hover behaviour is irrelevant — but mouseExited must NOT spuriously
    /// schedule a dismiss when no auto-dismiss was ever requested.
    func testMouseExitedDuringRecordingDoesNotScheduleDismiss() {
        let panel = OverlayPanel()
        panel.transition(to: .recording(elapsed: 1.0))
        XCTAssertFalse(panel.debug_hasPendingDismiss)

        panel.debug_simulateMouseEntered()
        panel.debug_simulateMouseExited()

        XCTAssertFalse(panel.debug_hasPendingDismiss,
            "active phases (recording) must never spuriously arm a dismiss timer")
    }

    /// Transitioning from recording → bothReady arms the dismiss. Then a new
    /// transition (e.g. an .error) cancels the prior dismiss and arms a new
    /// one — the prior pending work must NOT fire stale.
    func testStateChangeCancelsPriorDismiss() {
        let panel = OverlayPanel()
        panel.transition(to: .bothReady(zh: "a", en: "b", translating: true))
        let firstDelay = panel.debug_lastDismissDelay

        panel.transition(to: .error("boom"))

        XCTAssertEqual(panel.debug_lastDismissDelay, 1.4, accuracy: 0.01,
            "error phase must overwrite the previous delay")
        XCTAssertNotEqual(firstDelay, 1.4, "sanity check different delays")
    }

    /// Refining phase carries through the profileLabel suffix (translation
    /// mode shows "Converting to English (Imported ClaudeCode)").
    func testRefiningPhaseShowsProfileLabel() {
        let panel = OverlayPanel()
        panel.transition(to: .refining(
            zh: "x",
            elapsed: 1.5,
            translating: true,
            profileLabel: "Imported ClaudeCode"
        ))

        XCTAssertTrue(panel.debug_zhHidden)
        XCTAssertTrue(panel.debug_enText.contains("Converting to English"))
        XCTAssertTrue(panel.debug_enText.contains("Imported ClaudeCode"))
    }
}
