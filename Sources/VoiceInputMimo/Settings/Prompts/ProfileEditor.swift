import SwiftUI

/// Middle column of the Prompts pane. Form-style editor for the selected
/// profile's draft. Builtins are read-only (form fields disabled), users can
/// duplicate first via the sidebar's `+` button to get an editable copy.
struct ProfileEditor: View {
    @Environment(PromptStoreViewModel.self) private var store
    @Environment(PromptsPaneViewModel.self) private var pane

    var body: some View {
        @Bindable var pane = pane

        if let _ = pane.draft {
            editorBody(pane: pane)
        } else {
            ContentUnavailableView(
                "No profile selected",
                systemImage: "doc.text",
                description: Text("Pick a profile in the sidebar or duplicate one to edit.")
            )
        }
    }

    @ViewBuilder
    private func editorBody(pane: PromptsPaneViewModel) -> some View {
        @Bindable var pane = pane
        let isBuiltin = pane.draft?.isBuiltin ?? false

        Form {
            if isBuiltin {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "lock.fill")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("This is a builtin profile and can't be edited directly.")
                                .font(.callout)
                            Text("Duplicate it to get an editable copy with the same prompt and skills.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            duplicateBuiltin()
                        } label: {
                            Label("Duplicate to Edit", systemImage: "plus.square.on.square")
                        }
                        .controlSize(.regular)
                        .keyboardShortcut("d", modifiers: [.command])
                    }
                    .padding(.vertical, 6)
                }
            }

            Section {
                TextField("Name", text: nameBinding(pane: pane))
                    .disabled(isBuiltin)
                TextField("Display Label", text: displayLabelBinding(pane: pane), prompt: Text("Optional"))
                    .disabled(isBuiltin)
            } header: {
                SectionHeading(
                    pane.draft?.name ?? "",
                    subtitle: isBuiltin ? "Builtin · read-only" : nil
                )
            }

            Section {
                TextEditor(text: basePromptBinding(pane: pane))
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 140)
                    .disabled(isBuiltin)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(.separator, lineWidth: 0.5)
                    )
            } header: {
                Text("Base Prompt").font(.headline)
            }

            Section {
                if let draft = pane.draft {
                    skillList(draft: draft, isBuiltin: isBuiltin)
                }
            } header: {
                HStack {
                    Text("Skills (\(pane.draft?.skillIDs.count ?? 0))").font(.headline)
                    Spacer()
                }
            }

            if pane.draft?.mode == .claudeCode {
                Section {
                    TextEditor(text: suffixBinding(pane: pane))
                        .font(.system(size: 11, design: .monospaced))
                        .frame(minHeight: 70)
                        .disabled(isBuiltin)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(.separator, lineWidth: 0.5)
                        )
                } header: {
                    Text("Reply Suffix").font(.headline)
                }
            }

            Section {
                HStack {
                    if let err = store.lastError {
                        Text("\(err.localizedDescription)")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Spacer()
                    }
                    Button("Save") { saveDraft() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(isBuiltin || pane.draft == nil)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func skillList(draft: PromptProfile, isBuiltin: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Linked skills first (in profile-defined order, drag to reorder)
            if !draft.skillIDs.isEmpty {
                Text("Linked").font(.caption).foregroundStyle(.secondary)
                List {
                    ForEach(draft.skillIDs, id: \.self) { skillID in
                        skillRow(skillID: skillID, linked: true, draft: draft, isBuiltin: isBuiltin)
                    }
                    .onMove { src, dst in pane.moveSkill(from: src, to: dst) }
                }
                .frame(minHeight: 40, maxHeight: 220)
                .listStyle(.bordered)
                .disabled(isBuiltin)
            }

            // Catalog (skills not yet linked)
            let unlinked = store.skills.filter { !draft.skillIDs.contains($0.id) }
            if !unlinked.isEmpty {
                Text("Available").font(.caption).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180))], spacing: 6) {
                    ForEach(unlinked) { skill in
                        skillChip(skill, linked: false, isBuiltin: isBuiltin)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func skillRow(skillID: String, linked: Bool, draft: PromptProfile, isBuiltin: Bool) -> some View {
        if let skill = store.skill(id: skillID) {
            skillChip(skill, linked: linked, isBuiltin: isBuiltin)
        } else {
            Text("Unknown skill: \(skillID)").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func skillChip(_ skill: PromptSkill, linked: Bool, isBuiltin: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: linked ? "checkmark.circle.fill" : "plus.circle")
                .foregroundStyle(linked ? .green : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(skill.name).font(.callout)
                Text(skill.category.rawValue).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isBuiltin else { return }
            pane.toggleSkill(skill.id)
        }
    }

    // MARK: - Bindings

    private func nameBinding(pane: PromptsPaneViewModel) -> Binding<String> {
        Binding(
            get: { pane.draft?.name ?? "" },
            set: { pane.draft?.name = $0; pane.draft?.updatedAt = Date() }
        )
    }

    private func displayLabelBinding(pane: PromptsPaneViewModel) -> Binding<String> {
        Binding(
            get: { pane.draft?.displayLabel ?? "" },
            set: { pane.draft?.displayLabel = $0.isEmpty ? nil : $0; pane.draft?.updatedAt = Date() }
        )
    }

    private func basePromptBinding(pane: PromptsPaneViewModel) -> Binding<String> {
        Binding(
            get: { pane.draft?.basePrompt ?? "" },
            set: { pane.draft?.basePrompt = $0; pane.draft?.updatedAt = Date() }
        )
    }

    private func suffixBinding(pane: PromptsPaneViewModel) -> Binding<String> {
        Binding(
            get: { pane.draft?.suffix ?? "" },
            set: { pane.draft?.suffix = $0.isEmpty ? nil : $0; pane.draft?.updatedAt = Date() }
        )
    }

    // MARK: - Actions

    private func saveDraft() {
        guard let d = pane.draft else { return }
        store.saveProfile(d)
    }

    private func duplicateBuiltin() {
        guard let source = pane.draft else { return }
        let copy = PromptProfile(
            id: "user-\(UUID().uuidString.prefix(8))",
            name: "\(source.name) Copy",
            mode: source.mode,
            basePrompt: source.basePrompt,
            skillIDs: source.skillIDs,
            suffix: source.suffix,
            modelOverride: source.modelOverride,
            temperature: source.temperature,
            displayLabel: nil,
            slotOverrides: source.slotOverrides,
            createdAt: Date(),
            updatedAt: Date(),
            isBuiltin: false
        )
        store.saveProfile(copy)
        pane.selectProfile(copy)
    }
}

#if DEBUG
#Preview("ProfileEditor") {
    ProfileEditor()
        .environment(PromptStoreViewModel())
        .environment(PromptsPaneViewModel())
        .frame(width: 540, height: 600)
}
#endif
