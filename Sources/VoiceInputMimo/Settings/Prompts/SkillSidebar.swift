import SwiftUI

/// Left column of the Skills Library mode. Lists user + builtin skills grouped
/// by `SkillCategory`. Selection drives the right column (SkillEditor).
struct SkillSidebar: View {
    @Environment(PromptStoreViewModel.self) private var store
    @Environment(PromptsPaneViewModel.self) private var pane

    var body: some View {
        @Bindable var pane = pane

        VStack(spacing: 0) {
            List(selection: $pane.selectedSkillID) {
                ForEach(SkillCategory.allCases, id: \.self) { category in
                    let inCategory = store.skills.filter { $0.category == category }
                    if !inCategory.isEmpty {
                        Section(header: Text(category.rawValue.capitalized).font(.caption)) {
                            ForEach(inCategory) { skill in
                                skillRow(skill).tag(Optional(skill.id))
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            HStack(spacing: 6) {
                IconButton(systemImage: "plus", accessibilityLabel: "New skill", help: "Create user skill") {
                    createNew()
                }
                IconButton(systemImage: "doc.on.doc", accessibilityLabel: "Duplicate", help: "Duplicate selected") {
                    duplicateSelected()
                }
                IconButton(systemImage: "trash", accessibilityLabel: "Delete skill", help: "Delete (builtin disabled)") {
                    deleteSelected()
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func skillRow(_ skill: PromptSkill) -> some View {
        HStack(spacing: 6) {
            Image(systemName: skill.isBuiltin ? "lock.fill" : "person.fill")
                .foregroundStyle(skill.isBuiltin ? Color.secondary : Color.blue)
                .font(.system(size: 11))
            VStack(alignment: .leading, spacing: 1) {
                Text(skill.name).font(.callout)
                if let desc = skill.description, !desc.isEmpty {
                    Text(desc).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }

    // MARK: - Actions

    private func createNew() {
        let skill = pane.newSkillDraft()
        store.saveSkill(skill)
    }

    private func duplicateSelected() {
        guard let id = pane.selectedSkillID,
              let source = store.skill(id: id) else { return }
        let copy = pane.makeSkillCopy(of: source)
        store.saveSkill(copy)
        pane.selectSkill(copy)
    }

    private func deleteSelected() {
        guard let id = pane.selectedSkillID else { return }
        store.deleteSkill(id: id)
        pane.selectedSkillID = nil
        pane.ensureSkillSelection(from: store)
    }
}

#if DEBUG
#Preview("SkillSidebar") {
    SkillSidebar()
        .environment(PromptStoreViewModel())
        .environment(PromptsPaneViewModel())
        .frame(width: 240, height: 480)
}
#endif
