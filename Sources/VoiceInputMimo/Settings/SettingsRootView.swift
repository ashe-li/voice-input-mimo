import SwiftUI

/// Top-level Settings UI — `NavigationSplitView` with a sidebar of 7 panes
/// (5 active + 2 placeholders) and a per-pane detail view. Hosted via
/// `NSHostingController` inside the AppKit `SettingsWindow` shell.
///
/// Inject via `SettingsRootView().environment(viewModel)` on the hosting
/// controller's root.
struct SettingsRootView: View {
    @Environment(SettingsViewModel.self) private var vm

    var body: some View {
        @Bindable var vm = vm

        NavigationSplitView {
            List(selection: $vm.selectedPane) {
                SidebarSection(title: "一般") {
                    sidebarRow(.general)
                    sidebarRow(.shortcuts)
                }
                SidebarSection(title: "語音") {
                    sidebarRow(.speech)
                    sidebarRow(.asrServer)
                }
                SidebarSection(title: "工作區") {
                    sidebarRow(.prompts)
                    sidebarRow(.glossary)
                    sidebarRow(.workflows)
                    sidebarRow(.toneMapping)
                    sidebarRow(.history)
                }
                SidebarSection(title: "資訊") {
                    sidebarRow(.about)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            paneView(for: vm.selectedPane)
        }
        .frame(minWidth: 800, minHeight: 540)
    }

    @ViewBuilder
    private func sidebarRow(_ pane: SettingsPane) -> some View {
        Label(pane.title, systemImage: pane.systemImage)
            .tag(pane)
    }

    @ViewBuilder
    private func paneView(for pane: SettingsPane) -> some View {
        switch pane {
        case .general:   GeneralPane()
        case .shortcuts: ShortcutsPane()
        case .speech:    SpeechPane()
        case .asrServer: ASRServerPane()
        case .prompts:     PromptsPane()
        case .glossary:    GlossaryPane()
        case .workflows:   WorkflowsPane()
        case .toneMapping: ToneMappingPane()
        case .history:     HistoryPane()
        case .about:     AboutPane()
        }
    }
}

#if DEBUG
#Preview("SettingsRootView") {
    SettingsRootView()
        .environment(SettingsViewModel())
        .frame(width: 880, height: 580)
}
#endif
