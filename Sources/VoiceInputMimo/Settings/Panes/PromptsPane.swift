import SwiftUI

/// Phase 4 Prompts pane — 3-column editor (HSplitView) for browsing,
/// editing, and live-testing prompt profiles. Uses the Phase 2
/// PromptStoreViewModel singleton plus a pane-local @Observable
/// PromptsPaneViewModel for transient draft / test state.
struct PromptsPane: View {
    @Environment(PromptStoreViewModel.self) private var store
    @State private var pane = PromptsPaneViewModel()

    var body: some View {
        HSplitView {
            ProfileSidebar()
                .frame(minWidth: 220, idealWidth: 240, maxWidth: 320)

            ProfileEditor()
                .frame(minWidth: 360, idealWidth: 460)

            PromptTestPanel()
                .frame(minWidth: 320, idealWidth: 380)
        }
        .environment(pane)
        .navigationTitle("Prompts")
        .task {
            await store.reload()
            pane.ensureSelection(from: store)
        }
    }
}

#if DEBUG
#Preview("PromptsPane") {
    PromptsPane()
        .environment(PromptStoreViewModel())
        .frame(width: 1080, height: 600)
}
#endif
