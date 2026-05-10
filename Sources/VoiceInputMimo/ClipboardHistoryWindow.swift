import AppKit
import SwiftUI

/// Thin NSWindow shell that hosts `ClipboardHistoryView`. The earlier
/// version injected an `NSVisualEffectView` as a subview of the host
/// controller's view, which silently blocked SwiftUI's `NavigationSplitView`
/// from laying out — the window opened with toolbar visible but body empty.
/// SwiftUI now owns its own background; the NSWindow stays minimal.
final class ClipboardHistoryWindow: NSWindow {
    init() {
        let root = MainActor.assumeIsolated {
            ClipboardHistoryView()
                .frame(minWidth: 720, idealWidth: 880, minHeight: 420, idealHeight: 560)
        }
        let host = MainActor.assumeIsolated { NSHostingController(rootView: root) }

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 560),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        self.title = "Clipboard History"
        self.isReleasedWhenClosed = false
        self.minSize = NSSize(width: 720, height: 420)
        self.contentViewController = host
        self.center()
    }
}
