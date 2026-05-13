import SwiftUI

/// Left column of the Prompts pane. Single sectioned `List` with one section
/// per `RefineMode` (refine / claudeCode / structure). Tapping a profile in
/// any section auto-selects that mode + profile, driving the middle column
/// (ProfileEditor).
///
/// The Structure section gets an "Auto-routed" badge in its header and each
/// profile row shows the keywords that trigger it via `StructureRouter`,
/// since structure-mode profiles aren't picked manually — the router decides
/// per-input. The fallback profile is tagged `[fallback]` so users know
/// which profile runs when no keywords match.
struct ProfileSidebar: View {
    @Environment(PromptStoreViewModel.self) private var store
    @Environment(PromptsPaneViewModel.self) private var pane

    var body: some View {
        @Bindable var pane = pane

        VStack(spacing: 0) {
            List(selection: $pane.selectedProfileID) {
                modeSection(.refine)
                modeSection(.claudeCode)
                modeSection(.structure)
            }
            .listStyle(.sidebar)
            .onChange(of: pane.selectedProfileID) { _, newID in
                syncModeToSelection(newID: newID)
            }

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
    }

    // MARK: - Mode section

    @ViewBuilder
    private func modeSection(_ mode: RefineMode) -> some View {
        Section {
            ForEach(store.profiles(for: mode)) { profile in
                profileRow(profile)
                    .tag(Optional(profile.id))
            }
        } header: {
            ModeSectionHeader(mode: mode)
        }
    }

    @ViewBuilder
    private func profileRow(_ profile: PromptProfile) -> some View {
        let isActive = (store.activeProfileID(for: profile.mode) == profile.id)
        let isFallback = (profile.mode == .structure
                          && profile.id == StructureRouter.defaultFallbackProfileID)

        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isActive ? .green : .secondary.opacity(0.4))
                    .font(.system(size: 11))
                Text(profile.name).font(.callout)
                if isFallback {
                    Text("fallback")
                        .font(.caption2)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.secondary.opacity(0.15), in: Capsule())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            if profile.isBuiltin {
                Text("Builtin").font(.caption2).foregroundStyle(.secondary)
                    .padding(.leading, 17)
            }

            if let kw = triggerKeywords(for: profile), !kw.isEmpty {
                Text("觸發：\(kw)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.leading, 17)
            }
        }
        .padding(.vertical, 2)
    }

    /// Returns a comma-joined preview of the keywords that route to this
    /// profile, or nil if not a structure-mode rule-bound profile.
    private func triggerKeywords(for profile: PromptProfile) -> String? {
        guard profile.mode == .structure else { return nil }
        guard let rule = StructureRouter.defaultRules.first(where: { $0.profileID == profile.id })
        else { return nil }
        // Show first 4 keywords; trailing ellipsis if more exist.
        let preview = rule.keywords.prefix(4).joined(separator: "、")
        return rule.keywords.count > 4 ? "\(preview)…" : preview
    }

    /// Keep `selectedMode` in sync with the section the selected profile
    /// belongs to, so ProfileEditor and PromptTestPanel observe the right
    /// mode without us having to plumb it through every callsite.
    private func syncModeToSelection(newID: String?) {
        guard let id = newID else { return }
        for mode in [RefineMode.refine, .claudeCode, .structure] {
            if store.profiles(for: mode).contains(where: { $0.id == id }) {
                if pane.selectedMode != mode {
                    pane.selectedMode = mode
                }
                if let p = store.profiles(for: mode).first(where: { $0.id == id }) {
                    pane.draft = p
                }
                return
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

/// Sidebar section header for one `RefineMode`. Localized title + a small
/// "Auto-routed" badge for `.structure` so users can see at a glance that
/// those profiles aren't picked manually.
private struct ModeSectionHeader: View {
    let mode: RefineMode

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            if mode == .structure {
                Text("Auto-routed")
                    .font(.system(size: 9, weight: .medium))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.tint.opacity(0.15), in: Capsule())
                    .foregroundStyle(.tint)
            }
            Spacer(minLength: 0)
        }
    }

    private var title: String {
        switch mode {
        case .refine: return "Refine · 中文修正"
        case .claudeCode: return "Claude Code · 英文翻譯"
        case .structure: return "Structure · 複合情境"
        case .contextAware: return "Auto · 自動辨識"
        }
    }
}

#if DEBUG
#Preview("ProfileSidebar") {
    ProfileSidebar()
        .environment(PromptStoreViewModel())
        .environment(PromptsPaneViewModel())
        .frame(width: 240, height: 600)
}
#endif
