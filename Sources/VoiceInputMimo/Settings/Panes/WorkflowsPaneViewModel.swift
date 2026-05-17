import Foundation
import SwiftUI

/// State container for `WorkflowsPane`. Owns the in-memory `workflows`
/// array, the currently selected workflow ID, a transient banner, and the
/// last preview-run result (so the bottom strip can render step-by-step
/// output).
///
/// Mirrors `GlossaryPaneViewModel`: every mutating action writes through
/// to `WorkflowStore.shared` and then reloads, so on-disk state stays the
/// source of truth.
@Observable
@MainActor
final class WorkflowsPaneViewModel {
    private(set) var workflows: [Workflow] = []
    var selection: String?
    var banner: String?

    private(set) var previewInput: String = ""
    private(set) var previewResult: WorkflowExecutionResult?
    private(set) var isRunningPreview: Bool = false

    private let store: WorkflowStore
    private let executor: WorkflowExecutor

    init(store: WorkflowStore = .shared, executor: WorkflowExecutor = .shared) {
        self.store = store
        self.executor = executor
    }

    var selectedWorkflow: Workflow? {
        workflows.first { $0.id == selection }
    }

    func reload() {
        do {
            workflows = try store.loadAll()
            if !workflows.contains(where: { $0.id == selection }) {
                selection = workflows.first?.id
            }
        } catch {
            banner = "Load failed: \(error.localizedDescription)"
        }
    }

    func select(_ id: String?) {
        selection = id
        previewResult = nil
    }

    func addBlank() {
        let wf = Workflow(
            name: "New workflow",
            steps: [WorkflowStep(mode: .refine)],
            outputPolicy: .final
        )
        do {
            try store.add(wf)
            workflows = try store.loadAll()
            selection = wf.id
            banner = nil
        } catch {
            banner = "Add failed: \(error.localizedDescription)"
        }
    }

    func commit(_ workflow: Workflow) {
        do {
            try store.update(workflow)
            workflows = try store.loadAll()
            banner = nil
        } catch {
            banner = "Save failed: \(error.localizedDescription)"
        }
    }

    func delete(id: String) {
        do {
            try store.delete(id: id)
            workflows = try store.loadAll()
            if !workflows.contains(where: { $0.id == selection }) {
                selection = workflows.first?.id
            }
            previewResult = nil
            banner = nil
        } catch {
            banner = "Delete failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Step manipulation

    func addStep(toWorkflowId id: String, mode: WorkflowStepMode = .refine) {
        guard var wf = workflows.first(where: { $0.id == id }) else { return }
        wf.steps.append(WorkflowStep(mode: mode))
        commit(wf)
    }

    func removeStep(at index: Int, fromWorkflowId id: String) {
        guard var wf = workflows.first(where: { $0.id == id }) else { return }
        guard wf.steps.indices.contains(index) else { return }
        wf.steps.remove(at: index)
        commit(wf)
    }

    func moveSteps(in workflowId: String, from source: IndexSet, to destination: Int) {
        guard var wf = workflows.first(where: { $0.id == workflowId }) else { return }
        wf.steps.move(fromOffsets: source, toOffset: destination)
        commit(wf)
    }

    // MARK: - Preview run

    func setPreviewInput(_ text: String) {
        previewInput = text
    }

    func runPreview() {
        guard let wf = selectedWorkflow else { return }
        guard !previewInput.trimmingCharacters(in: .whitespaces).isEmpty else {
            banner = "Enter sample input first"
            return
        }
        let workflow = wf
        let input = previewInput
        isRunningPreview = true
        previewResult = nil
        Task {
            let result = await executor.execute(workflow: workflow, input: input)
            await MainActor.run {
                self.previewResult = result
                self.isRunningPreview = false
                if result.didFail {
                    self.banner = "Run failed at step \(result.failedAtStep! + 1)"
                } else {
                    self.banner = "Run completed (\(result.stepOutputs.count) steps)"
                }
            }
        }
    }
}
