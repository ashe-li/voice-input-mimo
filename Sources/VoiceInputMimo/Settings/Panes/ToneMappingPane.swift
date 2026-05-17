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
        .navigationTitle("對應規則")
        .task { model.reload() }
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 12) {
            SectionHeading("對應規則",
                           subtitle: "把 app 的 bundle ID 對應到一個模式或工作流程。使用者規則優先於內建表。")
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
                .help("新增規則")

                Button {
                    if let i = model.selectionIndex { model.delete(at: i) }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(model.selectionIndex == nil)
                .help("刪除選取的規則")
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
            Text("新增規則，或從側欄選一條")
                .foregroundStyle(.secondary)
            Text("內建規則（Mail / Cursor / Notion / …）會自動生效。")
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
            Text(rule.bundleIDPrefix.isEmpty ? "（未填）" : rule.bundleIDPrefix)
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
            return "→ 工作流程：\(name ?? id)"
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
                TextField("Bundle ID（例如 com.apple.mail）或以「.」結尾的前綴", text: Binding(
                    get: { rule.bundleIDPrefix },
                    set: { v in var c = rule; c.bundleIDPrefix = v; onChange(c) }
                ))
            } header: {
                Text("Bundle ID")
            } footer: {
                Text("預設為精確比對；若值以「.」結尾，則改為前綴比對（匹配以此開頭的任何 bundle）。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("類型", selection: Binding<DelegateKind>(
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
                    Text("模式").tag(DelegateKind.mode)
                    Text("工作流程").tag(DelegateKind.workflow)
                }
                .pickerStyle(.segmented)

                switch currentKind {
                case .mode:
                    Picker("模式", selection: Binding<RefineMode>(
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
                Text("委派目標")
            } footer: {
                Text("「模式」會發送單一 LLM call；「工作流程」會透過 WorkflowExecutor 端到端執行指定的鏈。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var workflowPicker: some View {
        if availableWorkflows.isEmpty {
            Text("尚未定義工作流程 — 請先到「設定 → 工作區 → 工作流程」新增一個。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else {
            Picker("工作流程", selection: Binding<String>(
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
