import SwiftUI

/// Settings → Workspace → Tone Mapping. Lets the user define their own
/// `ToneRule`s on top of the hardcoded `ToneMapping.defaultRules` table.
/// User rules win on first-match (concat'd before defaults at dispatch
/// time — see `ToneMapping.effectiveRules`).
///
/// Sidebar lists user rules; right pane edits the selected rule inline
/// (bundle prefix + delegate type + delegate target).
struct ToneMappingPane: View {
    @State private var model = ToneMappingPaneViewModel()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                sidebar.frame(width: 260)
                Divider()
                contentArea.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Tone Mapping")
        .task { model.reload() }
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 12) {
            SectionHeading("Tone Mapping",
                           subtitle: "Map app bundle IDs to a mode or workflow. User rules win over the built-in table.")
            Spacer()
            if let banner = model.banner {
                Text(banner).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: Binding<Int?>(
                get: { model.selectionIndex },
                set: { model.select(index: $0) }
            )) {
                ForEach(Array(model.rules.enumerated()), id: \.offset) { idx, rule in
                    ToneMappingRow(rule: rule, workflows: model.availableWorkflows)
                        .tag(Optional(idx))
                }
            }
            .listStyle(.sidebar)

            HStack(spacing: 6) {
                Button { model.addBlank() } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("Add rule")

                Button {
                    if let i = model.selectionIndex { model.delete(at: i) }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(model.selectionIndex == nil)
                .help("Delete selected rule")
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private var contentArea: some View {
        if let i = model.selectionIndex, let rule = model.selectedRule {
            ToneRuleEditor(
                rule: rule,
                availableWorkflows: model.availableWorkflows,
                onChange: { updated in model.commit(at: i, rule: updated) }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            emptyState
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "rectangle.dashed.and.paperclip")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("Add a rule, or select one from the sidebar")
                .foregroundStyle(.secondary)
            Text("Built-in rules (Mail / Cursor / Notion / …) stay active automatically.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

// MARK: - Row

private struct ToneMappingRow: View {
    let rule: ToneRule
    let workflows: [Workflow]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(rule.bundleIDPrefix.isEmpty ? "(empty)" : rule.bundleIDPrefix)
                .font(.callout)
                .foregroundStyle(rule.bundleIDPrefix.isEmpty ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(delegateSummary)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }

    private var delegateSummary: String {
        switch rule.delegated {
        case .mode(let m): return "→ \(m.rawValue)"
        case .workflow(let id):
            let name = workflows.first(where: { $0.id == id })?.name
            return "→ workflow: \(name ?? id)"
        }
    }
}

// MARK: - Editor

private enum DelegateKind: String, CaseIterable, Identifiable {
    case mode
    case workflow
    var id: String { rawValue }
}

private struct ToneRuleEditor: View {
    let rule: ToneRule
    let availableWorkflows: [Workflow]
    let onChange: (ToneRule) -> Void

    private var currentKind: DelegateKind {
        switch rule.delegated {
        case .mode: return .mode
        case .workflow: return .workflow
        }
    }

    private var currentMode: RefineMode {
        if case .mode(let m) = rule.delegated { return m }
        return .refine
    }

    private var currentWorkflowId: String {
        if case .workflow(let id) = rule.delegated { return id }
        return availableWorkflows.first?.id ?? ""
    }

    var body: some View {
        Form {
            Section {
                TextField("Bundle ID (e.g., com.apple.mail) or prefix ending in dot", text: Binding(
                    get: { rule.bundleIDPrefix },
                    set: { v in var c = rule; c.bundleIDPrefix = v; onChange(c) }
                ))
            } header: {
                Text("Bundle ID")
            } footer: {
                Text("Exact match unless the value ends with a trailing dot (then it matches anything starting with that prefix).")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Type", selection: Binding<DelegateKind>(
                    get: { currentKind },
                    set: { kind in
                        var c = rule
                        switch kind {
                        case .mode:
                            c.delegated = .mode(currentMode)
                        case .workflow:
                            let id = currentWorkflowId
                            c.delegated = .workflow(workflowId: id)
                        }
                        onChange(c)
                    }
                )) {
                    Text("Mode").tag(DelegateKind.mode)
                    Text("Workflow").tag(DelegateKind.workflow)
                }
                .pickerStyle(.segmented)

                switch currentKind {
                case .mode:
                    Picker("Mode", selection: Binding<RefineMode>(
                        get: { currentMode },
                        set: { v in var c = rule; c.delegated = .mode(v); onChange(c) }
                    )) {
                        Text("refine").tag(RefineMode.refine)
                        Text("claudeCode").tag(RefineMode.claudeCode)
                        Text("structure").tag(RefineMode.structure)
                    }
                case .workflow:
                    workflowPicker
                }
            } header: {
                Text("Delegate")
            } footer: {
                Text("Mode dispatches a single LLM call. Workflow runs the named chain end-to-end via WorkflowExecutor.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var workflowPicker: some View {
        if availableWorkflows.isEmpty {
            Text("No workflows defined yet — create one in Settings → Workspace → Workflows first.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else {
            Picker("Workflow", selection: Binding<String>(
                get: {
                    if case .workflow(let id) = rule.delegated { return id }
                    return availableWorkflows.first?.id ?? ""
                },
                set: { id in
                    var c = rule
                    c.delegated = .workflow(workflowId: id)
                    onChange(c)
                }
            )) {
                ForEach(availableWorkflows) { wf in
                    Text(wf.name.isEmpty ? wf.id : wf.name).tag(wf.id)
                }
            }
        }
    }
}

#if DEBUG
#Preview("ToneMappingPane") {
    ToneMappingPane()
        .frame(width: 880, height: 540)
}
#endif
