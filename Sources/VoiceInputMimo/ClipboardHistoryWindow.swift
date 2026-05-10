import AppKit
import SwiftUI

/// Phase 5 — thin NSWindow shell that hosts `ClipboardHistoryView`. Replaces
/// the 322-line hand-rolled NSPanel + NSTableView. Public entry point
/// `openClipboardHistory()` (status menu, ⌘⌥H) is unchanged.
final class ClipboardHistoryWindow: NSWindow {
    init() {
        let root = MainActor.assumeIsolated { ClipboardHistoryView() }
        let host = MainActor.assumeIsolated { NSHostingController(rootView: root) }

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 560),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        self.title = "Clipboard History"
        self.titlebarAppearsTransparent = true
        self.titleVisibility = .visible
        self.isReleasedWhenClosed = false
        self.minSize = NSSize(width: 720, height: 420)
        self.contentViewController = host
        self.center()

        if let cv = self.contentView {
            cv.wantsLayer = true
            let visualEffect = NSVisualEffectView(frame: cv.bounds)
            visualEffect.autoresizingMask = [.width, .height]
            visualEffect.material = .windowBackground
            visualEffect.blendingMode = .behindWindow
            visualEffect.state = .active
            cv.addSubview(visualEffect, positioned: .below, relativeTo: nil)
        }
    }
}
