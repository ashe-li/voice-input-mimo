import XCTest
@testable import VoiceInputMimo

/// Unit tests for the pure dispatch decision step extracted from
/// `LLMRefiner.refine()`. Exercises the contextAware → workflow / mode
/// branching without going through any singletons.
final class LLMRefinerDispatchDecisionTests: XCTestCase {

    private let noWorkflowFinder: (String) -> Workflow? = { _ in nil }

    private func always(_ wf: Workflow) -> (String) -> Workflow? {
        { id in id == wf.id ? wf : nil }
    }

    // MARK: - Non-contextAware passthrough

    func testNonContextAwareModePassesThroughUnchanged_Refine() {
        let d = LLMRefiner.decideDispatch(
            rawMode: .refine,
            delegate: nil,
            findWorkflow: noWorkflowFinder
        )
        XCTAssertEqual(d, .singleMode(.refine))
    }

    func testNonContextAwareModePassesThroughUnchanged_ClaudeCode() {
        let d = LLMRefiner.decideDispatch(
            rawMode: .claudeCode,
            delegate: nil,
            findWorkflow: noWorkflowFinder
        )
        XCTAssertEqual(d, .singleMode(.claudeCode))
    }

    func testNonContextAwareModePassesThroughUnchanged_Structure() {
        let d = LLMRefiner.decideDispatch(
            rawMode: .structure,
            delegate: nil,
            findWorkflow: noWorkflowFinder
        )
        XCTAssertEqual(d, .singleMode(.structure))
    }

    func testNonContextAwareIgnoresDelegateEvenIfProvided() {
        // Defensive: callers shouldn't pass a delegate for non-contextAware
        // raw mode, but the function must not honor it either way.
        let d = LLMRefiner.decideDispatch(
            rawMode: .refine,
            delegate: .workflow(workflowId: "wf-ignored"),
            findWorkflow: { _ in
                XCTFail("findWorkflow must not be called for non-contextAware rawMode")
                return nil
            }
        )
        XCTAssertEqual(d, .singleMode(.refine))
    }

    // MARK: - contextAware → mode dispatch

    func testContextAwareWithModeDelegate() {
        let d = LLMRefiner.decideDispatch(
            rawMode: .contextAware,
            delegate: .mode(.claudeCode),
            findWorkflow: noWorkflowFinder
        )
        XCTAssertEqual(d, .singleMode(.claudeCode))
    }

    func testContextAwareNilDelegateFallsBackToRefine() {
        // Defensive — refine() should always pass a non-nil delegate when
        // rawMode is .contextAware, but if it doesn't (e.g. ToneMapping
        // returns no rules), default to refine.
        let d = LLMRefiner.decideDispatch(
            rawMode: .contextAware,
            delegate: nil,
            findWorkflow: noWorkflowFinder
        )
        XCTAssertEqual(d, .singleMode(.refine))
    }

    // MARK: - contextAware → workflow dispatch

    func testContextAwareWithWorkflowDelegate_FoundInStore() {
        let wf = Workflow(
            id: "wf-test",
            name: "Test",
            steps: [WorkflowStep(mode: .refine)]
        )
        let d = LLMRefiner.decideDispatch(
            rawMode: .contextAware,
            delegate: .workflow(workflowId: "wf-test"),
            findWorkflow: always(wf)
        )
        if case .workflow(let resolved) = d {
            XCTAssertEqual(resolved.id, "wf-test")
        } else {
            XCTFail("expected .workflow, got \(d)")
        }
    }

    func testContextAwareWithWorkflowDelegate_MissingInStore() {
        let d = LLMRefiner.decideDispatch(
            rawMode: .contextAware,
            delegate: .workflow(workflowId: "wf-deleted"),
            findWorkflow: noWorkflowFinder
        )
        XCTAssertEqual(d, .workflowMissing(workflowId: "wf-deleted"))
    }

    func testWorkflowMissingIsDistinctFromFoundWithSameId() {
        let wf = Workflow(id: "wf-x", name: "X", steps: [WorkflowStep(mode: .refine)])
        let found = LLMRefiner.decideDispatch(
            rawMode: .contextAware,
            delegate: .workflow(workflowId: "wf-x"),
            findWorkflow: always(wf)
        )
        let missing = LLMRefiner.decideDispatch(
            rawMode: .contextAware,
            delegate: .workflow(workflowId: "wf-x"),
            findWorkflow: noWorkflowFinder
        )
        XCTAssertNotEqual(found, missing)
    }

    // MARK: - capturedContext wiring (B3 regression — captured-at-keydown semantics)

    /// Contract: when refine() receives a non-nil `capturedContext`, the
    /// dispatch must resolve via that captured value, not via
    /// `ContextCapture.capture()` (which would observe the WRONG frontmost
    /// app — by the time refine() runs, ASR has already returned and the user
    /// may have switched focus or the HUD may have stolen frontmost).
    ///
    /// This test documents the resolution chain at the level of pure
    /// functions: capturedContext → ToneMapping.resolve → decideDispatch.
    /// The wiring inside `LLMRefiner.refine` (capturedContext ?? capture())
    /// is verified separately via build + manual e2e.
    func testCapturedContextDrivesDispatch_MailGoesToClaudeCodeViaUserRule() {
        let mail = CapturedContext(bundleID: "com.apple.mail", appName: "Mail")
        let userRules: [ToneRule] = [
            .init(bundleIDPrefix: "com.apple.mail", delegated: .claudeCode),
        ]
        let delegate = ToneMapping.resolve(
            context: mail,
            rules: ToneMapping.effectiveRules(userRules: userRules)
        )
        let dispatch = LLMRefiner.decideDispatch(
            rawMode: .contextAware,
            delegate: delegate,
            findWorkflow: noWorkflowFinder
        )
        XCTAssertEqual(dispatch, .singleMode(.claudeCode),
                       "Mail user rule must override default refine when context is captured")
    }

    func testCapturedContextDrivesDispatch_VoiceInputMimoSelfBundleFallsBackToRefine() {
        // Counter-example: if refine() late-captured frontmost AND the HUD
        // had stolen focus, frontmost would be VoiceInputMimo itself. No
        // rule matches → fallback refine. This test asserts that *with* the
        // captured-at-keydown context, we don't hit this misroute.
        let voiceInputSelf = CapturedContext(
            bundleID: "com.shiun.VoiceInputMimo",
            appName: "VoiceInputMimo"
        )
        let userRules: [ToneRule] = [
            .init(bundleIDPrefix: "com.apple.mail", delegated: .claudeCode),
        ]
        let delegate = ToneMapping.resolve(
            context: voiceInputSelf,
            rules: ToneMapping.effectiveRules(userRules: userRules)
        )
        let dispatch = LLMRefiner.decideDispatch(
            rawMode: .contextAware,
            delegate: delegate,
            findWorkflow: noWorkflowFinder
        )
        XCTAssertEqual(dispatch, .singleMode(.refine),
                       "Self-bundle with no matching rule falls back to refine — this is the bug that B3 prevents by capturing at keydown")
    }
}
