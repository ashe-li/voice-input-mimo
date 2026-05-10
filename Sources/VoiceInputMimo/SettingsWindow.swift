import AppKit
import SwiftUI

/// Thin AppKit shell around the SwiftUI `SettingsRootView`. Phase 3 swaps the
/// 666-line hand-rolled grid form for a `NavigationSplitView` driven by
/// `@Observable SettingsViewModel`. AppDelegate's entry-point API
/// (`SettingsWindow()` + `makeKeyAndOrderFront(nil)`) is unchanged so the
/// status menu wiring (`⌘,`) keeps working.
///
/// SettingsViewModel and PromptStoreViewModel are injected as SwiftUI
/// environment values; both outlive the window so tear-down is clean.
final class SettingsWindow: NSWindow {
    private let viewModel: SettingsViewModel

    /// NSWindow initialisers always run on the main thread, so it is safe to
    /// hop into MainActor isolation here to construct the @Observable view
    /// model + SwiftUI tree. AppDelegate's `lazy var settingsWindow =
    /// SettingsWindow()` triggers this on first menu use, also on main.
    init(viewModel: SettingsViewModel? = nil) {
        let vm = viewModel ?? MainActor.assumeIsolated { SettingsViewModel() }
        self.viewModel = vm
        let root = MainActor.assumeIsolated {
            SettingsRootView()
                .environment(vm)
                .environment(PromptStoreViewModel.shared)
        }
        let host = MainActor.assumeIsolated { NSHostingController(rootView: root) }
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 580),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        self.contentViewController = host
        self.title = "VoiceInputMimo Preferences"
        self.titlebarAppearsTransparent = true
        self.toolbarStyle = .unified
        self.isReleasedWhenClosed = false
        self.setFrameAutosaveName("VoiceInputMimo.SettingsWindow")
        self.center()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWillClose),
            name: NSWindow.willCloseNotification,
            object: self
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Persist any in-flight edits when the user dismisses the window —
    /// matches the AppKit form's "Save also writes server fields" invariant
    /// so closing without explicit Save still preserves intent. The
    /// notification fires on main, so MainActor.assumeIsolated is safe.
    @objc private func handleWillClose() {
        MainActor.assumeIsolated { viewModel.save() }
    }
}
