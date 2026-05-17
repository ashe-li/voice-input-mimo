import XCTest
@testable import VoiceInputMimo

/// Tests for the Fn-double-tap fix: when a second recording preempts an
/// in-flight one, both segments must complete (or the first must be dropped
/// only if its audio was shorter than the noise threshold).
final class RecordingJobQueueTests: XCTestCase {

    private var queue: RecordingJobQueue!
    private var runner: MockJobRunner!

    override func setUp() {
        super.setUp()
        queue = RecordingJobQueue()
        queue.minInterruptDurationSeconds = 1.5
        runner = MockJobRunner()
        queue.runner = runner
    }

    override func tearDown() {
        queue = nil
        runner = nil
        super.tearDown()
    }

    // MARK: - Single-job happy path

    func test_singleJob_runsASRThenLLMThenCompletes() {
        let job = makeJob(duration: 3.0)
        queue.enqueueHead(job)

        XCTAssertEqual(runner.asrCalls, [job.id], "ASR should start immediately")
        XCTAssertEqual(job.stage, .asrInflight)

        runner.completeASR(for: job, with: "你好")
        XCTAssertEqual(runner.llmCalls.map { $0.jobId }, [job.id])
        if case .llmInflight(let asr) = job.stage {
            XCTAssertEqual(asr, "你好")
        } else {
            XCTFail("Expected .llmInflight, got \(job.stage)")
        }

        runner.completeLLM(for: job, with: "Hello")
        XCTAssertEqual(runner.completed.map { $0.jobId }, [job.id])
        XCTAssertEqual(runner.completed.first?.asr, "你好")
        XCTAssertEqual(runner.completed.first?.llm, "Hello")
        XCTAssertEqual(job.stage, .done)
        XCTAssertNil(queue.currentJob)
    }

    // MARK: - Two-segment preemption: both should reach completeJob

    func test_secondSegmentPreemptsFirst_bothComplete_secondFirstThenFirst() {
        // First segment recorded (10s).
        let first = makeJob(duration: 10.0)
        queue.enqueueHead(first)
        XCTAssertEqual(runner.asrCalls, [first.id])
        XCTAssertEqual(first.stage, .asrInflight)

        // User starts a second recording while first's ASR is in flight.
        let outcome = queue.interruptForNewSegment()
        XCTAssertEqual(outcome, .requeued(jobId: first.id))
        XCTAssertEqual(first.stage, .pendingASR, "in-flight stage rewinds to pending so resume re-runs ASR")
        XCTAssertTrue(first.cancelled, "in-flight callback must be ignored")
        XCTAssertTrue(runner.cancelled.contains(first.id))
        XCTAssertNil(queue.currentJob)

        // Stale ASR callback fires after cancel — should be a no-op.
        runner.completeASR(for: first, with: "stale-text")
        XCTAssertEqual(first.stage, .pendingASR, "stale callback must not advance stage")

        // Second segment finishes recording (5s) → enqueue head.
        let second = makeJob(duration: 5.0)
        queue.enqueueHead(second)
        XCTAssertEqual(queue.currentJob?.id, second.id, "second runs first (LIFO head)")
        XCTAssertEqual(runner.asrCalls.last, second.id)

        // Drive second through ASR → LLM → complete.
        runner.completeASR(for: second, with: "短的")
        runner.completeLLM(for: second, with: "Short.")
        XCTAssertEqual(runner.completed.map { $0.jobId }, [second.id])

        // After second completes, queue should auto-resume first from pendingASR.
        XCTAssertEqual(queue.currentJob?.id, first.id, "first auto-resumes from queue tail")
        XCTAssertEqual(first.stage, .asrInflight)
        XCTAssertFalse(first.cancelled, "resumed job must accept callbacks again")
        XCTAssertEqual(runner.asrCalls.filter { $0 == first.id }.count, 2,
                       "first's ASR is re-run from scratch on resume")

        runner.completeASR(for: first, with: "長的十秒講話")
        runner.completeLLM(for: first, with: "A ten-second utterance.")
        XCTAssertEqual(runner.completed.map { $0.jobId }, [second.id, first.id],
                       "completion order: second first, then first second")
    }

    // MARK: - Threshold: short first segment is dropped, not requeued

    func test_firstSegmentBelowThreshold_isDroppedNotRequeued() {
        let first = makeJob(duration: 0.8) // below 1.5s threshold
        queue.enqueueHead(first)

        let outcome = queue.interruptForNewSegment()
        XCTAssertEqual(outcome, .dropped(jobId: first.id))
        XCTAssertTrue(runner.cancelled.contains(first.id))
        XCTAssertTrue(runner.dropped.contains(first.id))
        XCTAssertFalse(queue.pending.contains { $0.id == first.id },
                       "dropped job must not sit in queue")

        // Second segment runs normally and first never reappears.
        let second = makeJob(duration: 5.0)
        queue.enqueueHead(second)
        runner.completeASR(for: second, with: "ok")
        runner.completeLLM(for: second, with: "OK")
        XCTAssertEqual(runner.completed.map { $0.jobId }, [second.id])
        XCTAssertNil(queue.currentJob)
        XCTAssertTrue(queue.pending.isEmpty)
    }

    // MARK: - Preserve ASR partial progress across interrupt

    func test_interruptAfterASRReturned_resumesAtPendingLLM_skippingASRRerun() {
        let first = makeJob(duration: 8.0)
        queue.enqueueHead(first)

        // First's ASR completes BEFORE the interrupt — so when the second
        // segment fires, first is at .llmInflight, not .asrInflight.
        runner.completeASR(for: first, with: "已經轉錄好的內容")
        if case .llmInflight(let asr) = first.stage {
            XCTAssertEqual(asr, "已經轉錄好的內容")
        } else {
            XCTFail("Expected .llmInflight, got \(first.stage)")
        }

        let outcome = queue.interruptForNewSegment()
        XCTAssertEqual(outcome, .requeued(jobId: first.id))
        XCTAssertEqual(first.stage, .pendingLLM(asr: "已經轉錄好的內容"),
                       "rewind preserves ASR result — resume skips ASR")

        let second = makeJob(duration: 4.0)
        queue.enqueueHead(second)
        runner.completeASR(for: second, with: "短")
        runner.completeLLM(for: second, with: "Short")
        XCTAssertEqual(runner.completed.map { $0.jobId }, [second.id])

        // First resumes — must call LLM directly without re-running ASR.
        XCTAssertEqual(queue.currentJob?.id, first.id)
        XCTAssertEqual(first.stage, .llmInflight(asr: "已經轉錄好的內容"))
        XCTAssertEqual(runner.asrCalls.filter { $0 == first.id }.count, 1,
                       "ASR should NOT be re-run when partial progress is preserved")

        runner.completeLLM(for: first, with: "Refined output.")
        XCTAssertEqual(runner.completed.map { $0.jobId }, [second.id, first.id])
        XCTAssertEqual(runner.completed.last?.asr, "已經轉錄好的內容")
        XCTAssertEqual(runner.completed.last?.llm, "Refined output.")
    }

    // MARK: - interruptForNewSegment with empty queue is a no-op

    func test_interruptWithNothingInflight_returnsNoOp() {
        let outcome = queue.interruptForNewSegment()
        XCTAssertEqual(outcome, .noOp)
        XCTAssertTrue(runner.cancelled.isEmpty)
        XCTAssertTrue(runner.dropped.isEmpty)
    }

    // MARK: - LLM failure degrades to ASR-only paste

    func test_llmFailure_pastesASRAsFallback() {
        let job = makeJob(duration: 3.0)
        queue.enqueueHead(job)
        runner.completeASR(for: job, with: "raw asr")
        runner.failLLM(for: job, error: TestError.boom)
        XCTAssertEqual(runner.completed.map { $0.jobId }, [job.id])
        XCTAssertEqual(runner.completed.first?.asr, "raw asr")
        XCTAssertNil(runner.completed.first?.llm, "LLM failure → llm=nil so runner pastes raw ASR")
    }

    // MARK: - Helpers

    private func makeJob(duration: Double) -> RecordingJob {
        RecordingJob(
            wavURL: URL(fileURLWithPath: "/tmp/test-\(UUID().uuidString).wav"),
            audioDurationSeconds: duration,
            tracer: RecordingTracer()
        )
    }
}

// MARK: - Mock runner

private enum TestError: Error { case boom }

private final class MockJobRunner: JobRunner {
    var asrCalls: [UUID] = []
    var llmCalls: [(jobId: UUID, asr: String)] = []
    var cancelled: [UUID] = []
    var dropped: [UUID] = []
    var failed: [UUID] = []
    var completed: [(jobId: UUID, asr: String, llm: String?)] = []

    private var pendingASR: [UUID: (Result<String, Error>) -> Void] = [:]
    private var pendingLLM: [UUID: (Result<String?, Error>) -> Void] = [:]

    func runASR(_ job: RecordingJob, completion: @escaping (Result<String, Error>) -> Void) {
        asrCalls.append(job.id)
        pendingASR[job.id] = completion
    }

    func runLLM(asr: String, job: RecordingJob, completion: @escaping (Result<String?, Error>) -> Void) {
        llmCalls.append((job.id, asr))
        pendingLLM[job.id] = completion
    }

    func cancelInflight(_ job: RecordingJob) {
        cancelled.append(job.id)
        // Real ASRClient cancel synchronously cancels the URLSession task;
        // we model this by dropping the pending completion so a later
        // completeASR(for:) on the same id wouldn't fire it twice.
        pendingASR[job.id] = nil
        pendingLLM[job.id] = nil
    }

    func completeJob(_ job: RecordingJob, asr: String, llm: String?) {
        completed.append((job.id, asr, llm))
    }

    func handleJobFailure(_ job: RecordingJob, error: Error) {
        failed.append(job.id)
    }

    func handleJobDropped(_ job: RecordingJob) {
        dropped.append(job.id)
    }

    // MARK: - Test driver

    /// Fire the most recently captured ASR callback for `job`. Used by tests
    /// to simulate the network returning success. Also models the "stale
    /// callback fires after cancel" case by not erroring when the callback
    /// is missing (caller checks job.cancelled / stage instead).
    func completeASR(for job: RecordingJob, with text: String) {
        if let cb = pendingASR.removeValue(forKey: job.id) {
            cb(.success(text))
        }
    }

    func completeLLM(for job: RecordingJob, with text: String) {
        if let cb = pendingLLM.removeValue(forKey: job.id) {
            cb(.success(text))
        }
    }

    func failLLM(for job: RecordingJob, error: Error) {
        if let cb = pendingLLM.removeValue(forKey: job.id) {
            cb(.failure(error))
        }
    }
}
