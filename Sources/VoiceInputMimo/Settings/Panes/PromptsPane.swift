import SwiftUI

/// Phase 4 Prompts pane — top-level mode switcher (Profiles / Skills) over
/// two layouts. Profiles uses a 3-column HSplitView for browsing, editing,
/// and live-testing; Skills mode uses a 2-column HSplitView for the library.
/// Phase 4B adds Import / Export toolbar buttons next to the mode picker.
struct PromptsPane: View {
    @Environment(PromptStoreViewModel.self) private var store
    @State private var pane = PromptsPaneViewModel()
    @State private var importBanner: String?

    var body: some View {
        @Bindable var pane = pane

        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("View", selection: $pane.paneMode) {
                    Text("Profiles").tag(PromptsPaneMode.profiles)
                    Text("Skills").tag(PromptsPaneMode.skills)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 240)

                Spacer()

                Button("Import…") { runImport() }
                Button("Export…") { runExport() }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if let banner = importBanner {
                Text(banner)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            switch pane.paneMode {
            case .profiles:
                profilesLayout
            case .skills:
                skillsLayout
            }
        }
        .environment(pane)
        .navigationTitle("Prompts")
        .task {
            await store.reload()
            pane.ensureSelection(from: store)
            pane.ensureSkillSelection(from: store)
        }
    }

    @ViewBuilder
    private var profilesLayout: some View {
        HSplitView {
            ProfileSidebar()
                .frame(minWidth: 220, idealWidth: 240, maxWidth: 320)

            ProfileEditor()
                .frame(minWidth: 360, idealWidth: 460)

            PromptTestPanel()
                .frame(minWidth: 320, idealWidth: 380)
        }
    }

    @ViewBuilder
    private var skillsLayout: some View {
        HSplitView {
            SkillSidebar()
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 340)

            SkillEditor()
                .frame(minWidth: 380, idealWidth: 540)
        }
    }

    // MARK: - Import / Export

    private func runExport() {
        let bundle = store.exportSnapshot()
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        do {
            if let url = try PromptImportExportAdapter.exportBundle(
                bundle,
                suggestedName: "prompts-\(timestamp).json"
            ) {
                importBanner = "Exported \(bundle.profiles.count) profiles and \(bundle.skills.count) skills to \(url.lastPathComponent)"
            }
        } catch {
            importBanner = "Export failed: \(error.localizedDescription)"
        }
    }

    private func runImport() {
        do {
            guard let bundle = try PromptImportExportAdapter.importBundle() else { return }
            let existingProfiles = store.profiles(for: .refine) + store.profiles(for: .claudeCode)
            let plan = PromptImportPlanner.plan(
                incoming: bundle,
                existingProfiles: existingProfiles,
                existingSkills: store.skills,
                strategy: .rename
            )
            Task {
                await store.applyImport(profiles: plan.profiles, skills: plan.skills)
                let r = plan.result
                importBanner = "Imported — profiles: +\(r.profilesAdded) renamed:\(r.profilesRenamed) skipped:\(r.profilesSkipped); skills: +\(r.skillsAdded) renamed:\(r.skillsRenamed) skipped:\(r.skillsSkipped)"
                pane.ensureSelection(from: store)
                pane.ensureSkillSelection(from: store)
            }
        } catch {
            importBanner = "Import failed: \(error.localizedDescription)"
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
