import Foundation

extension WorkflowStepMode {
    /// Direct projection onto LLMRefiner's `RefineMode`. Cases line up 1:1
    /// because we deliberately exclude `.raw` (no transformation) and
    /// `.contextAware` (would recurse into Mode 4).
    var refineMode: RefineMode {
        switch self {
        case .refine: return .refine
        case .claudeCode: return .claudeCode
        case .structure: return .structure
        }
    }
}

/// Single step's contribution to the chain output. `succeeded == false`
/// means the LLM call for this step failed; `output` holds the previous
/// step's output (i.e. the fallback value the chain ended on).
struct WorkflowStepOutput: Equatable {
    let stepId: String
    let mode: WorkflowStepMode
    let output: String
    let succeeded: Bool
}

/// Result of running a workflow. `failedAtStep` is the index of the first
/// failed step (nil = all succeeded). Chain stops at the first failure so
/// downstream steps never run.
struct WorkflowExecutionResult: Equatable {
    let finalOutput: String
    let stepOutputs: [WorkflowStepOutput]
    let failedAtStep: Int?

    var didFail: Bool { failedAtStep != nil }
}

/// Injectable refiner closure. Production wires this to `LLMRefiner.shared`;
/// tests pass a closure that returns canned output or throws.
typealias WorkflowRefiner = @Sendable (_ text: String, _ mode: RefineMode) async throws -> String

/// Runs a `Workflow` as a sequential chain. Each step's output feeds the
/// next step's input. On failure, the chain stops and `finalOutput` falls
/// back to the previous step's output (or the original input if step 0
/// failed) — see REQ-NEW-D acceptance criterion 5.
final class WorkflowExecutor: @unchecked Sendable {
    static let shared: WorkflowExecutor = WorkflowExecutor(refiner: defaultRefiner)

    private let refiner: WorkflowRefiner

    init(refiner: @escaping WorkflowRefiner) {
        self.refiner = refiner
    }

    /// Production refiner: bridges LLMRefiner's completion-based API to
    /// async/await. `force: true` bypasses the `isEnabled && isConfigured`
    /// gate — a workflow run is an explicit user action, never a passive
    /// background refine, so the gate would be a footgun here.
    private static let defaultRefiner: WorkflowRefiner = { text, mode in
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            LLMRefiner.shared.refine(text, mode: mode, force: true) { result in
                cont.resume(with: result)
            }
        }
    }

    func execute(workflow: Workflow, input: String) async -> WorkflowExecutionResult {
        var currentOutput = input
        var stepOutputs: [WorkflowStepOutput] = []
        var failedAtStep: Int?

        for (idx, step) in workflow.steps.enumerated() {
            do {
                let output = try await refiner(currentOutput, step.mode.refineMode)
                stepOutputs.append(
                    WorkflowStepOutput(
                        stepId: step.id,
                        mode: step.mode,
                        output: output,
                        succeeded: true
                    )
                )
                currentOutput = output
            } catch {
                stepOutputs.append(
                    WorkflowStepOutput(
                        stepId: step.id,
                        mode: step.mode,
                        output: currentOutput,
                        succeeded: false
                    )
                )
                failedAtStep = idx
                break
            }
        }

        return WorkflowExecutionResult(
            finalOutput: currentOutput,
            stepOutputs: stepOutputs,
            failedAtStep: failedAtStep
        )
    }
}
