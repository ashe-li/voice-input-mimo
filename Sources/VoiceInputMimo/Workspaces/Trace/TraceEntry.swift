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

    /// Tag for cross-cutting filters in the UI (e.g. mode used). For
    /// `.contextAware` input this holds the **resolved** mode (refine /
    /// claudeCode / structure) — read `inputMode` to see what the user
    /// originally selected.
    var mode: String?

    /// User-selected input mode at the moment refine() was called.
    /// `"contextAware"` means dispatch ran the context-aware routing;
    /// `.mode` field then holds the resolved concrete mode. Optional so
    /// pre-enhancement traces decode unchanged.
    var inputMode: String?

    /// Frontmost-app bundle ID captured at hotkey-down (not refine-time —
    /// see `AppDelegate.contextAtKeyDown`). Lets you cross-reference which
    /// app you were in vs which mode/workflow was picked.
    var contextBundleID: String?

    /// Display name of the frontmost app at hotkey-down. Same provenance as
    /// `contextBundleID`; redundant but spares analysis tools a bundleID-
    /// to-name lookup.
    var contextAppName: String?

    /// Routing breakdown for `.contextAware` dispatch — which rule matched
    /// (or fallback), what it delegated to. Nil for non-contextAware modes
    /// and for pre-enhancement traces.
    var routing: Routing?

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
        mode: String? = nil,
        inputMode: String? = nil,
        contextBundleID: String? = nil,
        contextAppName: String? = nil,
        routing: Routing? = nil
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
        self.inputMode = inputMode
        self.contextBundleID = contextBundleID
        self.contextAppName = contextAppName
        self.routing = routing
    }

    /// Routing decision for `.contextAware` dispatch. Captured so post-hoc
    /// analysis can answer "why was mode X picked for app Y" — without this
    /// you only see the final `mode` and have to re-run resolve() against
    /// stale rules to guess.
    struct Routing: Codable, Equatable, Hashable {
        /// Prefix tags for `dispatchedTo`. Exposed as static constants so
        /// `LLMRefiner.makeRoutingTelemetry` and downstream jq-style
        /// queries reference the same source of truth instead of
        /// duplicating literal strings.
        static let modePrefix = "mode:"
        static let workflowPrefix = "workflow:"
        static let workflowMissingPrefix = "workflow-missing:"

        /// Which rule table the match came from.
        /// - `"user"`: matched a user-defined rule (highest precedence)
        /// - `"default"`: matched a shipped default rule
        /// - `"fallback"`: no rule matched, fell back to `.mode(.refine)`
        let matchedSource: String

        /// Index within the matched table. Nil for `"fallback"` since no rule
        /// matched.
        let matchedIndex: Int?

        /// The `bundleIDPrefix` of the matched rule. Nil for `"fallback"`.
        let matchedPrefix: String?

        /// Dispatch target encoded as `"mode:<refine|claudeCode|structure>"`
        /// or `"workflow:<id>"` or `"workflow-missing:<id>"`. String form so
        /// the JSON stays human-greppable and survives schema changes to
        /// `RefineMode` / `Workflow.id`. Constructed via the `*Prefix`
        /// constants above to avoid string-literal drift.
        let dispatchedTo: String
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
