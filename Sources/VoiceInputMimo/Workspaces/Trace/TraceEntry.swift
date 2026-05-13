import Foundation

/// One recording session captured end-to-end: audio file metadata, ASR
/// transcript, LLM refine output, user's final edit, plus a log of state
/// transitions over the recording lifecycle.
///
/// Stored one-per-line as JSON (JSONL) so the file is append-only and
/// streaming-parseable. Keeps audio data on disk separately — `audioPath`
/// is a relative or absolute filesystem path, NOT inlined bytes.
///
/// `clipboardTimestamp` lets us cross-reference a trace back to the
/// ClipboardArchive entry it produced (timestamp-keyed, since
/// ClipboardArchive doesn't carry UUIDs in v1). A future revision will
/// extend the ClipboardArchive header serialiser with `trace=<id>` for
/// the reverse direction.
struct TraceEntry: Codable, Identifiable, Equatable, Hashable {
    let id: String
    var startedAt: Date
    var endedAt: Date?
    var audioPath: String?
    var audioBytes: Int?
    var sampleRate: Int?

    /// Raw ASR output before any LLM processing.
    var asrText: String

    /// LLM refine output (refine / claudeCode / structure / contextAware).
    var llmText: String?

    /// User edit on top of `llmText` if they hand-tuned before paste.
    var finalText: String?

    /// State transition log: timestamped events from recording start →
    /// archived. Useful for debugging latency and for the long-term
    /// foundation app's training data.
    var logEntries: [LogEntry]

    /// Optional pointer to the ClipboardArchive entry produced by this
    /// trace, keyed by the archive entry's ISO8601 timestamp.
    var clipboardTimestamp: String?

    /// Tag for cross-cutting filters in the UI (e.g. mode used).
    var mode: String?

    init(
        id: String = "trace-\(UUID().uuidString.prefix(8))",
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        audioPath: String? = nil,
        audioBytes: Int? = nil,
        sampleRate: Int? = nil,
        asrText: String = "",
        llmText: String? = nil,
        finalText: String? = nil,
        logEntries: [LogEntry] = [],
        clipboardTimestamp: String? = nil,
        mode: String? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.audioPath = audioPath
        self.audioBytes = audioBytes
        self.sampleRate = sampleRate
        self.asrText = asrText
        self.llmText = llmText
        self.finalText = finalText
        self.logEntries = logEntries
        self.clipboardTimestamp = clipboardTimestamp
        self.mode = mode
    }

    struct LogEntry: Codable, Equatable, Hashable {
        let timestamp: Date
        let stage: Stage
        let note: String?

        init(timestamp: Date = Date(), stage: Stage, note: String? = nil) {
            self.timestamp = timestamp
            self.stage = stage
            self.note = note
        }

        enum Stage: String, Codable {
            case start
            case recording
            case asrDone = "asr-done"
            case refineDone = "refine-done"
            case injectDone = "inject-done"
            case archived
            case park  // "park mode" — recorded but not pasted, awaiting user
            case error
        }
    }
}
