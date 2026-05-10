import SwiftUI

/// Left column of the Prompts pane. Mode picker (refine / claudeCode) on top,
/// then a `List` of profiles with an active dot for the currently active
/// profile. Selection drives the middle column (ProfileEditor).
struct ProfileSidebar: View {
    @Environment(PromptStoreViewModel.self) private var store
    @Environment(PromptsPaneViewModel.self) private var pane

    var body: some View {
        @Bindable var pane = pane

        VStack(spacing: 0) {
            Picker("Mode", selection: $pane.selectedMode) {
                Text("Refine (zh)").tag(RefineMode.refine)
                Text("Claude Code (en)").tag(RefineMode.claudeCode)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .onChange(of: pane.selectedMode) { _, _ in pane.ensureSelection(from: store) }

            List(selection: $pane.selectedProfileID) {
                ForEach(store.profiles(for: pane.selectedMode)) { profile in
                    profileRow(profile)
                        .tag(Optional(profile.id))
                }
            }
            .listStyle(.sidebar)

            HStack(spacing: 6) {
                IconButton(systemImage: "plus", accessibilityLabel: "New profile", help: "Duplicate active") {
                    duplicateSelected()
                }
                IconButton(systemImage: "trash", accessibilityLabel: "Delete profile", help: "Delete (builtin disabled)") {
                    deleteSelected()
                }
                Spacer()
                IconButton(systemImage: "checkmark.circle", accessibilityLabel: "Set active", help: "Mark as active for this mode") {
                    activateSelected()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
    }

    @ViewBuilder
    private func profileRow(_ profile: PromptProfile) -> some View {
        let isActive = (store.activeProfileID(for: profile.mode) == profile.id)
        HStack(spacing: 6) {
            Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isActive ? .green : .secondary.opacity(0.4))
                .font(.system(size: 11))
            VStack(alignment: .leading, spacing: 1) {
                Text(profile.name).font(.callout)
                if profile.isBuiltin {
                    Text("Builtin").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Actions

    private func duplicateSelected() {
        guard let id = pane.selectedProfileID,
              let source = store.profiles(for: pane.selectedMode).first(where: { $0.id == id }) else {
            return
        }
        let copy = PromptProfile(
            id: "user-\(UUID().uuidString.prefix(8))",
            name: "\(source.name) Copy",
            mode: source.mode,
            basePrompt: source.basePrompt,
            skillIDs: source.skillIDs,
            suffix: source.suffix,
            modelOverride: source.modelOverride,
            temperature: source.temperature,
            // Drop displayLabel — the builtin's "Refining (Default Refine)"
            // form is meaningless for a renamed user copy.
            displayLabel: nil,
            slotOverrides: source.slotOverrides,
            createdAt: Date(),
            updatedAt: Date(),
            isBuiltin: false
        )
        store.saveProfile(copy)
        pane.selectProfile(copy)
    }

    private func deleteSelected() {
        guard let id = pane.selectedProfileID else { return }
        store.deleteProfile(id: id, mode: pane.selectedMode)
        pane.selectedProfileID = nil
        pane.ensureSelection(from: store)
    }

    private func activateSelected() {
        guard let id = pane.selectedProfileID else { return }
        store.setActiveProfile(id: id, mode: pane.selectedMode)
    }
}

#if DEBUG
#Preview("ProfileSidebar") {
    ProfileSidebar()
        .environment(PromptStoreViewModel())
        .environment(PromptsPaneViewModel())
        .frame(width: 240, height: 480)
}
#endif
