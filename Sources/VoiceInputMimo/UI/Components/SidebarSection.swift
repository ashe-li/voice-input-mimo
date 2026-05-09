import SwiftUI

/// Labeled grouping for `NavigationSplitView` sidebar lists. Phase 3 use:
/// settings sidebar with sections like "General", "Prompts", "Diagnostics".
///
/// Wraps SwiftUI `Section` with consistent header typography so every sidebar
/// surface in the app shares the same rhythm.
struct SidebarSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        Section {
            content()
        } header: {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(nil)
        }
    }
}

#if DEBUG
#Preview("SidebarSection — within List") {
    List {
        SidebarSection(title: "General") {
            Label("Shortcuts", systemImage: "command")
            Label("Speech Recognition", systemImage: "waveform")
        }
        SidebarSection(title: "Prompts") {
            Label("Profiles", systemImage: "doc.text")
            Label("Skills", systemImage: "wand.and.stars")
        }
    }
    .listStyle(.sidebar)
    .frame(width: 200, height: 280)
}
#endif
