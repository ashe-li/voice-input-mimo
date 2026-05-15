import SwiftUI

/// Settings → Workspace → Workflows. Second consumer of `WorkspacePane`
/// (after Glossary). Sidebar lists workflow chains; the right pane edits
/// the selected chain inline (name, steps, output policy, hotkey); the
/// bottom strip is a "try it" preview that runs the chain against a
/// sample input and shows step-by-step output.
///
/// Custom-built layout (no `WorkspacePane`) because the editor needs
/// multi-line step rows with reorderable picker controls — denser than the
/// generic single-row WorkspacePane assumes.
struct WorkflowsPane: View {
    @State private var model = WorkflowsPaneViewModel()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                sidebar
                    .frame(width: 240)
                Divider()
                contentArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("工作流程")
        .task { model.reload() }
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 12) {
            SectionHeading("工作流程",
                           subtitle: "把多個 LLM 步驟串成一條 pipeline")
            Spacer()
            if let banner = model.banner {
                Text(banner)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: Binding(
                get: { model.selection },
                set: { model.select($0) }
            )) {
                ForEach(model.workflows) { wf in
                    WorkflowRow(workflow: wf).tag(Optional(wf.id))
                }
            }
            .listStyle(.sidebar)

            HStack(spacing: 6) {
                Button { model.addBlank() } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("新增工作流程")

                Button {
                    if let id = model.selection { model.delete(id: id) }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(model.selection == nil)
                .help("刪除選取的工作流程")
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private var contentArea: some View {
        VStack(spacing: 0) {
            if let wf = model.selectedWorkflow {
                WorkflowEditor(
                    workflow: wf,
                    onChange: { model.commit($0) },
                    onAddStep: { model.addStep(toWorkflowId: wf.id) },
                    onRemoveStep: { model.removeStep(at: $0, fromWorkflowId: wf.id) },
                    onMoveSteps: { from, to in
                        model.moveSteps(in: wf.id, from: from, to: to)
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                WorkflowPreview(
                    input: Binding(
                        get: { model.previewInput },
                        set: { model.setPreviewInput($0) }
                    ),
                    result: model.previewResult,
                    isRunning: model.isRunningPreview,
                    onRun: { model.runPreview() }
                )
                .frame(height: 200)
            } else {
                emptyState
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("選擇一個工作流程，或按 + 建立新的")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Row

private struct WorkflowRow: View {
    let workflow: Workflow

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(workflow.name.isEmpty ? "（未命名）" : workflow.name)
                .font(.callout)
                .foregroundStyle(workflow.name.isEmpty ? .secondary : .primary)
            Text(stepSummary)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }

    private var stepSummary: String {
        if workflow.steps.isEmpty { return "0 步驟" }
        let names = workflow.steps.map { $0.mode.rawValue }
        return names.joined(separator: " → ")
    }
}

// MARK: - Editor

/// Inline editor for a single Workflow. Owns nothing — pure input/output
/// over the workflow value and four callbacks. The pane mediates between
/// this view and the view model.
struct WorkflowEditor: View {
    let workflow: Workflow
    let onChange: (Workflow) -> Void
    let onAddStep: () -> Void
    let onRemoveStep: (Int) -> Void
    let onMoveSteps: (IndexSet, Int) -> Void

    var body: some View {
        Form {
            Section("名稱") {
                TextField("工作流程名稱", text: Binding(
                    get: { workflow.name },
                    set: { v in var c = workflow; c.name = v; onChange(c) }
                ))
            }

            Section {
                List {
                    ForEach(Array(workflow.steps.enumerated()), id: \.element.id) { idx, step in
                        WorkflowStepRow(
                            step: step,
                            stepNumber: idx + 1,
                            onChange: { updated in
                                var c = workflow
                                c.steps[idx] = updated
                                onChange(c)
                            },
                            onRemove: { onRemoveStep(idx) }
                        )
                    }
                    .onMove { source, dest in onMoveSteps(source, dest) }
                }
                .frame(minHeight: 140)

                Button {
                    onAddStep()
                } label: {
                    Label("新增步驟", systemImage: "plus")
                }
            } header: {
                Text("步驟（由上往下執行）")
            } footer: {
                Text("每個步驟的輸出會餵給下一個步驟。可拖曳重新排序。任一步驟失敗就停止鏈，回退到上一步輸出。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section("輸出策略") {
                Picker("回傳", selection: Binding(
                    get: { workflow.outputPolicy },
                    set: { v in var c = workflow; c.outputPolicy = v; onChange(c) }
                )) {
                    Text("僅最後一步").tag(WorkflowOutputPolicy.final)
                    Text("所有步驟輸出").tag(WorkflowOutputPolicy.verbose)
                }
                .pickerStyle(.segmented)
            }

            Section {
                TextField("例如：cmd+shift+1", text: Binding(
                    get: { workflow.hotkey ?? "" },
                    set: { v in
                        var c = workflow
                        let trimmed = v.trimmingCharacters(in: .whitespaces)
                        c.hotkey = trimmed.isEmpty ? nil : trimmed
                        onChange(c)
                    }
                ))
            } header: {
                Text("快捷鍵（選填）")
            } footer: {
                Text("v1：值會儲存但尚未全域綁定 — 請用上方的「執行」按鈕，或透過 Mode 4 dispatch（PR #15 之後）觸發此鏈。自由格式全域快捷鍵綁定為後續工作。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct WorkflowStepRow: View {
    let step: WorkflowStep
    let stepNumber: Int
    let onChange: (WorkflowStep) -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("\(stepNumber).")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)

            Picker("", selection: Binding(
                get: { step.mode },
                set: { v in var c = step; c.mode = v; onChange(c) }
            )) {
                ForEach(WorkflowStepMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .labelsHidden()
            .frame(width: 140)

            TextField("profile id（選填）", text: Binding(
                get: { step.profileId ?? "" },
                set: { v in
                    var c = step
                    let trimmed = v.trimmingCharacters(in: .whitespaces)
                    c.profileId = trimmed.isEmpty ? nil : trimmed
                    onChange(c)
                }
            ))

            Button {
                onRemove()
            } label: {
                Image(systemName: "minus.circle")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .help("移除步驟")
        }
    }
}

// MARK: - Preview strip

struct WorkflowPreview: View {
    @Binding var input: String
    let result: WorkflowExecutionResult?
    let isRunning: Bool
    let onRun: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("試跑")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    onRun()
                } label: {
                    if isRunning {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("執行", systemImage: "play.fill")
                    }
                }
                .disabled(isRunning)
            }

            HStack(alignment: .top, spacing: 8) {
                TextEditor(text: $input)
                    .font(.system(.callout, design: .monospaced))
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: .infinity)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(.secondary.opacity(0.3))
                    )

                ScrollView {
                    Text(resultText)
                        .font(.system(.callout, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                }
                .frame(maxWidth: .infinity)
                .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            }
        }
        .padding(12)
    }

    private var resultText: String {
        guard let result else {
            return isRunning ? "執行中…" : "（輸出結果會顯示在這裡）"
        }
        if result.stepOutputs.isEmpty {
            return result.finalOutput
        }
        var lines: [String] = []
        for (idx, step) in result.stepOutputs.enumerated() {
            let status = step.succeeded ? "✓" : "✗"
            lines.append("[\(idx + 1) \(step.mode.rawValue) \(status)]")
            lines.append(step.output)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}

#if DEBUG
#Preview("WorkflowsPane") {
    WorkflowsPane()
        .frame(width: 880, height: 600)
}
#endif
