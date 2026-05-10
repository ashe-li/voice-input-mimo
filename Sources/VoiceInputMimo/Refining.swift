import Foundation

/// Abstraction over LLM refinement so SwiftUI views and view models can run
/// against an in-memory mock instead of issuing real HTTP calls.
///
/// LLMRefiner is the production conformer. Tests inject a fixture that records
/// invocations and returns canned `Result` values.
protocol Refining: AnyObject {
    var isEnabled: Bool { get set }
    var apiBaseURL: String { get set }
    var apiKey: String { get set }
    var model: String { get set }

    func refine(
        _ text: String,
        requestId: String,
        mode: RefineMode?,
        force: Bool,
        completion: @escaping (Result<String, Error>) -> Void
    )

    func cancel()
}

extension Refining {
    /// Convenience entry point matching the historical call site
    /// (`refiner.refine(text) { ... }`). Forwards to the explicit-arg variant.
    func refine(
        _ text: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        refine(text, requestId: "", mode: nil, force: false, completion: completion)
    }
}

extension LLMRefiner: Refining {}
