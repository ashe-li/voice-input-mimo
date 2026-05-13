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
        .navigationTitle("Workflows")
        .task { model.reload() }
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 12) {
            SectionHeading("Workflows",
                           subtitle: "Chain multiple LLM steps into a single pipeline")
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
                .help("Add workflow")

                Button {
                    if let id = model.selection { model.delete(id: id) }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(model.selection == nil)
                .help("Delete selected workflow")
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
            Text("Select a workflow, or click + to create one")
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
            Text(workflow.name.isEmpty ? "(unnamed)" : workflow.name)
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
        if workflow.steps.isEmpty { return "0 steps" }
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
            Section("Name") {
                TextField("Workflow name", text: Binding(
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
                    Label("Add step", systemImage: "plus")
                }
            } header: {
                Text("Steps (run top-to-bottom)")
            } footer: {
                Text("Each step's output feeds the next step. Drag to reorder. Failure at any step stops the chain and falls back to the previous step's output.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section("Output policy") {
                Picker("Return", selection: Binding(
                    get: { workflow.outputPolicy },
                    set: { v in var c = workflow; c.outputPolicy = v; onChange(c) }
                )) {
                    Text("Final step only").tag(WorkflowOutputPolicy.final)
                    Text("All step outputs").tag(WorkflowOutputPolicy.verbose)
                }
                .pickerStyle(.segmented)
            }

            Section {
                TextField("e.g. cmd+shift+1", text: Binding(
                    get: { workflow.hotkey ?? "" },
                    set: { v in
                        var c = workflow
                        let trimmed = v.trimmingCharacters(in: .whitespaces)
                        c.hotkey = trimmed.isEmpty ? nil : trimmed
                        onChange(c)
                    }
                ))
            } header: {
                Text("Hotkey (optional)")
            } footer: {
                Text("v1: value is stored but not globally bound yet — use the Run button above or Mode 4 dispatch (post PR #15) to invoke the chain. Free-form global hotkey binding is a follow-up.")
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

            TextField("profile id (optional)", text: Binding(
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
            .help("Remove step")
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
                Text("Try it")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    onRun()
                } label: {
                    if isRunning {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Run", systemImage: "play.fill")
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
            return isRunning ? "Running…" : "(Output appears here)"
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
