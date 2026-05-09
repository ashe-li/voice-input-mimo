import AppKit
import SwiftUI

/// Generic NSWindow shell that hosts a SwiftUI root view.
///
/// Phase 2 introduces this as the bridge for the SwiftUI Hybrid architecture:
/// Phase 3+ window classes (SettingsWindow, ClipboardHistoryWindow,
/// ModelMemoryWindow) become thin AppKit shells whose `contentViewController`
/// is an `NSHostingController` rendering a SwiftUI tree. The shell preserves
/// the existing `openSettings()` style entry-point API, so AppDelegate menu
/// wiring stays unchanged.
///
/// Default style mask (titled / closable / resizable / fullSizeContentView)
/// matches the existing settings window. Callers can override per-window via
/// the styleMask parameter.
final class HostingWindow<Content: View>: NSWindow {
    init(
        contentSize: NSSize,
        styleMask: NSWindow.StyleMask = [.titled, .closable, .resizable, .fullSizeContentView],
        title: String,
        @ViewBuilder rootView: () -> Content
    ) {
        let host = NSHostingController(rootView: rootView())
        super.init(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        self.contentViewController = host
        self.title = title
        self.titlebarAppearsTransparent = true
        self.isReleasedWhenClosed = false
        self.center()
    }
}

#if DEBUG
@MainActor
private struct HostingWindowPreviewBody: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("HostingWindow preview").font(.headline)
            Text("Phase 2 SwiftUI Hybrid window shell.")
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(minWidth: 320, minHeight: 160)
    }
}

#Preview("HostingWindow content") {
    HostingWindowPreviewBody()
}
#endif
