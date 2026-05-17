import XCTest
@testable import VoiceInputMimo

final class WorkflowExecutorTests: XCTestCase {

    private struct StubError: Error, Equatable {
        let message: String
    }

    /// Builds a refiner that appends the mode name to the input, simulating
    /// each step transforming the text in a deterministic way.
    private func appendingRefiner() -> WorkflowRefiner {
        { text, mode in
            "\(text)|\(mode.rawValue)"
        }
    }

    /// Builds a refiner that throws on the Nth call (0-indexed).
    private func failingAtCall(_ failIndex: Int) -> WorkflowRefiner {
        let counter = AtomicCounter()
        return { text, mode in
            let n = counter.incrementAndGet() - 1
            if n == failIndex {
                throw StubError(message: "step \(n) failed")
            }
            return "\(text)|\(mode.rawValue)"
        }
    }

    private final class AtomicCounter: @unchecked Sendable {
        private var value = 0
        private let lock = NSLock()
        func incrementAndGet() -> Int {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return value
        }
    }

    private func wf(_ modes: [WorkflowStepMode], policy: WorkflowOutputPolicy = .final) -> Workflow {
        Workflow(
            id: "wf-test",
            name: "test",
            steps: modes.enumerated().map { idx, mode in
                WorkflowStep(id: "s\(idx)", mode: mode)
            },
            outputPolicy: policy
        )
    }

    // MARK: - Happy path

    func testEmptyChainReturnsInputUnchanged() async {
        let exec = WorkflowExecutor(refiner: appendingRefiner())
        let result = await exec.execute(workflow: wf([]), input: "hi")
        XCTAssertEqual(result.finalOutput, "hi")
        XCTAssertTrue(result.stepOutputs.isEmpty)
        XCTAssertNil(result.failedAtStep)
        XCTAssertFalse(result.didFail)
    }

    func testSingleStepChain() async {
        let exec = WorkflowExecutor(refiner: appendingRefiner())
        let result = await exec.execute(workflow: wf([.refine]), input: "hi")
        XCTAssertEqual(result.finalOutput, "hi|refine")
        XCTAssertEqual(result.stepOutputs.count, 1)
        XCTAssertEqual(result.stepOutputs[0].mode, .refine)
        XCTAssertTrue(result.stepOutputs[0].succeeded)
        XCTAssertNil(result.failedAtStep)
    }

    func testThreeStepChainFeedsOutputForward() async {
        let exec = WorkflowExecutor(refiner: appendingRefiner())
        let result = await exec.execute(
            workflow: wf([.refine, .structure, .claudeCode]),
            input: "start"
        )
        // step 0: start|refine
        // step 1: start|refine|structure
        // step 2: start|refine|structure|claudeCode
        XCTAssertEqual(result.finalOutput, "start|refine|structure|claudeCode")
        XCTAssertEqual(result.stepOutputs.map(\.output), [
            "start|refine",
            "start|refine|structure",
            "start|refine|structure|claudeCode",
        ])
        XCTAssertEqual(result.stepOutputs.map(\.succeeded), [true, true, true])
    }

    // MARK: - Failure / fallback

    func testFailureAtStep0FallsBackToOriginalInput() async {
        let exec = WorkflowExecutor(refiner: failingAtCall(0))
        let result = await exec.execute(
            workflow: wf([.refine, .structure]),
            input: "original"
        )
        XCTAssertEqual(result.finalOutput, "original")
        XCTAssertEqual(result.failedAtStep, 0)
        XCTAssertTrue(result.didFail)
        XCTAssertEqual(result.stepOutputs.count, 1, "chain stops on first failure")
        XCTAssertFalse(result.stepOutputs[0].succeeded)
    }

    func testFailureAtStep1FallsBackToStep0Output() async {
        let exec = WorkflowExecutor(refiner: failingAtCall(1))
        let result = await exec.execute(
            workflow: wf([.refine, .structure, .claudeCode]),
            input: "start"
        )
        // step 0 succeeds → "start|refine"
        // step 1 fails → keep "start|refine" as final
        // step 2 never runs
        XCTAssertEqual(result.finalOutput, "start|refine")
        XCTAssertEqual(result.failedAtStep, 1)
        XCTAssertEqual(result.stepOutputs.count, 2)
        XCTAssertTrue(result.stepOutputs[0].succeeded)
        XCTAssertFalse(result.stepOutputs[1].succeeded)
        XCTAssertEqual(result.stepOutputs[1].output, "start|refine",
                       "failed step's output field carries the fallback value")
    }

    func testFailureMidChainSkipsSubsequentSteps() async {
        // Refiner that succeeds twice then throws on every subsequent call.
        let counter = AtomicCounter()
        let refiner: WorkflowRefiner = { text, mode in
            let n = counter.incrementAndGet() - 1
            if n >= 2 {
                throw StubError(message: "boom at \(n)")
            }
            return "\(text)|\(mode.rawValue)"
        }
        let exec = WorkflowExecutor(refiner: refiner)
        let result = await exec.execute(
            workflow: wf([.refine, .structure, .claudeCode, .refine]),
            input: "x"
        )
        XCTAssertEqual(result.failedAtStep, 2)
        XCTAssertEqual(result.stepOutputs.count, 3, "step 3 must not be invoked")
        XCTAssertEqual(result.finalOutput, "x|refine|structure")
    }

    // MARK: - WorkflowStepMode → RefineMode mapping

    func testWorkflowStepModeMapsToRefineMode() {
        XCTAssertEqual(WorkflowStepMode.refine.refineMode, .refine)
        XCTAssertEqual(WorkflowStepMode.claudeCode.refineMode, .claudeCode)
        XCTAssertEqual(WorkflowStepMode.structure.refineMode, .structure)
    }
}
