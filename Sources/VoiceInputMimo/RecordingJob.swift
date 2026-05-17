import Foundation

/// One Fn-press recording, tracked through the ASR → LLM → paste pipeline.
///
/// Created in `fnUp` once the wav URL and duration are known. The queue
/// drives stage transitions; in-flight network callbacks check `cancelled`
/// before mutating state so an interrupted job's stale callback becomes a
/// no-op (the queue has already rewound stage in preparation for resume).
final class RecordingJob {
    /// Stage encodes both the lifecycle position AND the data captured so
    /// far. Resuming an interrupted job from the right enum case skips
    /// already-completed network calls — e.g. an interruption at
    /// `.llmInflight(asr:)` rewinds to `.pendingLLM(asr:)`, preserving the
    /// ASR text so we don't re-transcribe.
    enum Stage: Equatable {
        case pendingASR
        case asrInflight
        case pendingLLM(asr: String)
        case llmInflight(asr: String)
        case readyToPaste(asr: String, llm: String?)
        case done
    }

    let id: UUID
    let wavURL: URL
    let audioDurationSeconds: Double
    let tracer: RecordingTracer
    /// Park-mode job (Ctrl+Option+R hold-to-record). The runner archives + traces
    /// the ASR transcript but skips LLM refine and paste injection — the user
    /// retrieves the captured text later from history.
    let isPark: Bool

    private(set) var stage: Stage
    private(set) var cancelled: Bool

    init(
        wavURL: URL,
        audioDurationSeconds: Double,
        tracer: RecordingTracer,
        isPark: Bool = false,
        id: UUID = UUID()
    ) {
        self.id = id
        self.wavURL = wavURL
        self.audioDurationSeconds = audioDurationSeconds
        self.tracer = tracer
        self.isPark = isPark
        self.stage = .pendingASR
        self.cancelled = false
    }

    func advance(to stage: Stage) {
        self.stage = stage
    }

    func markCancelled() {
        self.cancelled = true
    }

    func clearCancelled() {
        self.cancelled = false
    }

    /// Roll an in-flight stage back to its preceding pending stage so the
    /// queue can resume from where the network call was interrupted. No-op
    /// for non-inflight stages (idempotent under repeated interrupts).
    func rewindForResume() {
        switch stage {
        case .asrInflight:
            stage = .pendingASR
        case .llmInflight(let asr):
            stage = .pendingLLM(asr: asr)
        default:
            break
        }
    }
}
