import AppKit
import Foundation

/// Snapshot of the frontmost application context used by `.contextAware` mode
/// to decide which underlying mode (refine / claudeCode / structure) to use.
///
/// v1 captures only `bundleID` (cheap, no AX permission required). Future
/// expansions can layer in AX-driven fields (window title, selected text) and
/// clipboard tails behind feature flags / permission prompts without changing
/// callers — they read whichever fields are non-nil.
struct CapturedContext: Equatable, Sendable {
    let bundleID: String?
    let appName: String?

    static let empty = CapturedContext(bundleID: nil, appName: nil)
}

/// Pure functions for capturing the current macOS app context. The capture is
/// synchronous and main-thread-safe (NSWorkspace is documented as such), so
/// `LLMRefiner.refine` can call it inline on whatever queue is current.
enum ContextCapture {
    /// Capture the frontmost application bundle ID + display name.
    ///
    /// Returns `.empty` if no app is frontmost (e.g. Loginwindow, no UI session).
    /// The caller is expected to fall back to a sensible default mode in that
    /// case rather than treating absence as an error.
    static func capture() -> CapturedContext {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return .empty
        }
        return CapturedContext(
            bundleID: app.bundleIdentifier,
            appName: app.localizedName
        )
    }
}
