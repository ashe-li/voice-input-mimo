import SwiftUI

/// Right column of the Skills Library mode. Edits the selected skill's draft.
/// Builtins are read-only — duplicate to get an editable copy.
struct SkillEditor: View {
    @Environment(PromptStoreViewModel.self) private var store
    @Environment(PromptsPaneViewModel.self) private var pane

    var body: some View {
        if pane.skillDraft != nil {
            editorBody
        } else {
            ContentUnavailableView(
                "No skill selected",
                systemImage: "wand.and.stars",
                description: Text("Pick a skill in the sidebar or create a new one.")
            )
        }
    }

    @ViewBuilder
    private var editorBody: some View {
        let isBuiltin = pane.skillDraft?.isBuiltin ?? false

        Form {
            Section {
                TextField("Name", text: nameBinding)
                    .disabled(isBuiltin)
                Picker("Category", selection: categoryBinding) {
                    ForEach(SkillCategory.allCases, id: \.self) { cat in
                        Text(cat.rawValue.capitalized).tag(cat)
                    }
                }
                .disabled(isBuiltin)
                TextField("Slot", text: slotBinding, prompt: Text("Optional — for v1.5 slot templates"))
                    .disabled(isBuiltin)
            } header: {
                SectionHeading(
                    pane.skillDraft?.name ?? "",
                    subtitle: isBuiltin ? "Builtin · read-only — duplicate to edit" : nil
                )
            }

            Section {
                TextEditor(text: contentBinding)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 160)
                    .disabled(isBuiltin)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(.separator, lineWidth: 0.5)
                    )
            } header: {
                Text("Content").font(.headline)
            }

            Section {
                TextField("Description", text: descriptionBinding, prompt: Text("Optional UI hint"), axis: .vertical)
                    .lineLimit(2...4)
                    .disabled(isBuiltin)
            } header: {
                Text("Description").font(.headline)
            }

            Section {
                HStack {
                    if let err = store.lastError {
                        Text(err.localizedDescription)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Spacer()
                    }
                    Button("Save") { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(isBuiltin || pane.skillDraft == nil)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Bindings

    private var nameBinding: Binding<String> {
        Binding(
            get: { pane.skillDraft?.name ?? "" },
            set: { pane.skillDraft?.name = $0 }
        )
    }

    private var categoryBinding: Binding<SkillCategory> {
        Binding(
            get: { pane.skillDraft?.category ?? .style },
            set: { pane.skillDraft?.category = $0 }
        )
    }

    private var slotBinding: Binding<String> {
        Binding(
            get: { pane.skillDraft?.slot ?? "" },
            set: { pane.skillDraft?.slot = $0.isEmpty ? nil : $0 }
        )
    }

    private var contentBinding: Binding<String> {
        Binding(
            get: { pane.skillDraft?.content ?? "" },
            set: { pane.skillDraft?.content = $0 }
        )
    }

    private var descriptionBinding: Binding<String> {
        Binding(
            get: { pane.skillDraft?.description ?? "" },
            set: { pane.skillDraft?.description = $0.isEmpty ? nil : $0 }
        )
    }

    // MARK: - Actions

    private func save() {
        guard let s = pane.skillDraft else { return }
        store.saveSkill(s)
    }
}

#if DEBUG
#Preview("SkillEditor") {
    SkillEditor()
        .environment(PromptStoreViewModel())
        .environment(PromptsPaneViewModel())
        .frame(width: 540, height: 600)
}
#endif
