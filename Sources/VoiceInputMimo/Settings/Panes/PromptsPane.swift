import SwiftUI

/// Phase 3 placeholder. Phase 4 fills this with the three-column
/// `NavigationSplitView` (ProfileSidebar / ProfileEditor / PromptTestPanel)
/// + Skills Library tab. Showing a placeholder now means the sidebar entry
/// is wired and discoverable; users see what's coming without partial UI.
struct PromptsPane: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "text.append")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            SectionHeading("Prompts", subtitle: "Profile editor + Skills library — Phase 4")
            Text("Voice-input prompts will be customizable here. Build, share, and switch profiles for different speech acts (refine / claudeCode) without touching code.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .navigationTitle("Prompts")
    }
}

#if DEBUG
#Preview("PromptsPane") {
    PromptsPane()
        .frame(width: 640, height: 480)
}
#endif
