import Foundation

/// Side-effects required by the queue. AppDelegate adopts this so the queue
/// stays a pure scheduler with no AppKit / network dependencies (testable).
protocol JobRunner: AnyObject {
    /// Kick off ASR for `job`. The handler is responsible for completing on
    /// the main queue. Cancellation is handled separately via `cancelInflight`.
    func runASR(_ job: RecordingJob, completion: @escaping (Result<String, Error>) -> Void)

    /// Kick off LLM refine for the ASR text. Pass `nil` in the completion's
    /// success case if LLM is disabled — the queue treats LLM as optional and
    /// will still complete the job (paste raw ASR + archive).
    func runLLM(asr: String, job: RecordingJob, completion: @escaping (Result<String?, Error>) -> Void)

    /// Cancel the in-flight network task associated with `job`, if any.
    /// Called from `interruptForNewSegment`; the runner should also
    /// gracefully ignore stale callbacks that fire after cancel.
    func cancelInflight(_ job: RecordingJob)

    /// Surface the completed result: write to ClipboardArchive, inject paste,
    /// finalize tracer. Called once per job; if LLM failed, `llm` is nil and
    /// the runner pastes `asr` as fallback.
    func completeJob(_ job: RecordingJob, asr: String, llm: String?)

    /// Called when ASR fails outright (network/parse error). Runner records
    /// the error in tracer + overlay; queue proceeds to next job.
    func handleJobFailure(_ job: RecordingJob, error: Error)

    /// Called when an interrupted segment is too short to be worth resuming.
    /// Runner should finalize tracer with an error / dropped marker.
    func handleJobDropped(_ job: RecordingJob)
}

/// LIFO-priority queue that lets a freshly-started recording preempt an
/// in-flight job without losing the earlier segment. Sequential execution
/// (one job at a time) — second-segment ASR/LLM run first, the requeued
/// first segment runs afterwards. Both end up in history.
final class RecordingJobQueue {
    /// Recording duration below this threshold is treated as accidental
    /// (noise / mis-touch) on interrupt and dropped instead of requeued.
    var minInterruptDurationSeconds: Double = 1.5

    weak var runner: JobRunner?

    private(set) var pending: [RecordingJob] = []
    private(set) var currentJob: RecordingJob?

    enum InterruptOutcome: Equatable {
        case noOp                       // nothing in flight
        case dropped(jobId: UUID)       // current job too short, dropped
        case requeued(jobId: UUID)      // current job requeued, stage rewound
    }

    /// Called from `fnDown` when the user starts a new recording while a
    /// previous job is still in flight. The previous job is either dropped
    /// (if duration < threshold) or requeued at the tail so the new
    /// segment can run first.
    @discardableResult
    func interruptForNewSegment() -> InterruptOutcome {
        guard let cur = currentJob else { return .noOp }
        runner?.cancelInflight(cur)
        cur.markCancelled()
        cur.rewindForResume()
        currentJob = nil

        if cur.audioDurationSeconds < minInterruptDurationSeconds {
            runner?.handleJobDropped(cur)
            return .dropped(jobId: cur.id)
        }
        pending.append(cur)
        return .requeued(jobId: cur.id)
    }

    /// New segment is recorded — push to the head of the queue (highest
    /// priority) and start driving if idle.
    func enqueueHead(_ job: RecordingJob) {
        pending.insert(job, at: 0)
        runNextIfIdle()
    }

    /// Internal tail-enqueue, exposed for tests / future use.
    func enqueueTail(_ job: RecordingJob) {
        pending.append(job)
        runNextIfIdle()
    }

    /// Drive the next pending job if no current job is running. Called
    /// after enqueue and after a job completes / fails.
    func runNextIfIdle() {
        guard currentJob == nil, !pending.isEmpty else { return }
        let job = pending.removeFirst()
        // Clear cancelled so a resumed job's callbacks are accepted again.
        // Stage is already rewound to the matching pending stage by
        // `interruptForNewSegment` (or is fresh `.pendingASR` for new jobs).
        job.clearCancelled()
        currentJob = job
        drive(job)
    }

    private func drive(_ job: RecordingJob) {
        switch job.stage {
        case .pendingASR:
            job.advance(to: .asrInflight)
            runner?.runASR(job) { [weak self] result in
                self?.handleASRResult(job, result: result)
            }
        case .pendingLLM(let asr):
            job.advance(to: .llmInflight(asr: asr))
            runner?.runLLM(asr: asr, job: job) { [weak self] result in
                self?.handleLLMResult(job, asr: asr, result: result)
            }
        case .readyToPaste, .done, .asrInflight, .llmInflight:
            // Defensive: drive() should only be called with pending stages.
            // If we land here something is out of sync — finish the job to
            // keep the queue moving.
            finalizeRun(job)
        }
    }

    private func handleASRResult(_ job: RecordingJob, result: Result<String, Error>) {
        // Stale callback from an interrupted job — queue has already
        // rewound its stage, so just drop the result.
        if job.cancelled { return }
        switch result {
        case .success(let asr):
            job.advance(to: .pendingLLM(asr: asr))
            drive(job)
        case .failure(let error):
            runner?.handleJobFailure(job, error: error)
            finalizeRun(job)
        }
    }

    private func handleLLMResult(_ job: RecordingJob, asr: String, result: Result<String?, Error>) {
        if job.cancelled { return }
        switch result {
        case .success(let llm):
            job.advance(to: .readyToPaste(asr: asr, llm: llm))
            runner?.completeJob(job, asr: asr, llm: llm)
            finalizeRun(job)
        case .failure:
            // LLM error degrades to ASR-only — still archive + paste so the
            // user's speech isn't lost on a transient refine failure.
            job.advance(to: .readyToPaste(asr: asr, llm: nil))
            runner?.completeJob(job, asr: asr, llm: nil)
            finalizeRun(job)
        }
    }

    private func finalizeRun(_ job: RecordingJob) {
        job.advance(to: .done)
        if currentJob?.id == job.id {
            currentJob = nil
        }
        runNextIfIdle()
    }
}
