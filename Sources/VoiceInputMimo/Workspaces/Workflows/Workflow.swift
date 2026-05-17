import Foundation

/// Modes a workflow step can dispatch to. Excludes `.raw` (no
/// transformation) and `.contextAware` (would recurse into Mode 4).
enum WorkflowStepMode: String, Codable, Equatable, CaseIterable, Sendable {
    case refine
    case claudeCode
    case structure
}

/// Single step in a workflow chain. `profileId` optionally pins the step
/// to a named prompt profile; nil means the step uses the mode's default.
struct WorkflowStep: Codable, Identifiable, Equatable, Hashable {
    let id: String
    var mode: WorkflowStepMode
    var profileId: String?

    init(
        id: String = "step-\(UUID().uuidString.prefix(8))",
        mode: WorkflowStepMode,
        profileId: String? = nil
    ) {
        self.id = id
        self.mode = mode
        self.profileId = profileId
    }
}

/// Controls what the executor returns when the chain completes.
/// `.final` returns only the last step's output. `.verbose` returns
/// step-by-step results, useful for the UI render preview.
enum WorkflowOutputPolicy: String, Codable, Equatable, Sendable {
    case final
    case verbose
}

/// A named chain of LLM steps, optionally bound to a global hotkey.
/// Persisted by `WorkflowStore` as part of a single JSON envelope file.
struct Workflow: Codable, Identifiable, Equatable, Hashable {
    let id: String
    var name: String
    var steps: [WorkflowStep]
    var outputPolicy: WorkflowOutputPolicy
    var hotkey: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: String = "wf-\(UUID().uuidString.prefix(8))",
        name: String,
        steps: [WorkflowStep] = [],
        outputPolicy: WorkflowOutputPolicy = .final,
        hotkey: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.steps = steps
        self.outputPolicy = outputPolicy
        self.hotkey = hotkey
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
