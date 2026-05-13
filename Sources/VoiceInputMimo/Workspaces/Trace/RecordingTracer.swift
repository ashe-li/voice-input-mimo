import Foundation

/// Captures one recording session as a `TraceEntry`, logging state
/// transitions through the pipeline and persisting on finalisation.
///
/// Lifecycle (driven by `AppDelegate` recording callbacks):
///   1. `begin()`            — recording starts (e.g. fnDown).
///   2. `recordAudio(path:)` — when audio file is written.
///   3. `recordASR(_:)`      — when ASR returns transcript.
///   4. `recordLLM(_:mode:)` — when LLM refine completes (skipped on raw).
///   5. `recordClipboard(timestamp:)` — links the ClipboardArchive entry.
///   6. `recordFinal(_:)`    — final text injected into the target app.
///   7. `recordError(_:)`    — failure at any stage.
///   8. `finalize()`         — appends current trace to TraceStore.
///
/// All `record*` methods are no-ops when no trace is active, so callers
/// in error / branch paths don't need to nil-check the active trace.
final class RecordingTracer: @unchecked Sendable {
    private(set) var currentTrace: TraceEntry?

    private let store: TraceStore
    private let now: () -> Date
    private let idGenerator: () -> String

    init(
        store: TraceStore = .shared,
        now: @escaping () -> Date = Date.init,
        idGenerator: @escaping () -> String = { "trace-\(UUID().uuidString.prefix(8))" }
    ) {
        self.store = store
        self.now = now
        self.idGenerator = idGenerator
    }

    /// Start a new trace. Discards any previously-active trace without
    /// persisting — callers should `finalize()` before starting a new
    /// session if they want the prior trace saved.
    @discardableResult
    func begin() -> TraceEntry {
        let stamp = now()
        let trace = TraceEntry(
            id: idGenerator(),
            startedAt: stamp,
            logEntries: [TraceEntry.LogEntry(timestamp: stamp, stage: .start)]
        )
        currentTrace = trace
        return trace
    }

    func recordAudio(path: String?, bytes: Int? = nil, sampleRate: Int? = nil) {
        guard currentTrace != nil else { return }
        currentTrace?.audioPath = path
        currentTrace?.audioBytes = bytes
        currentTrace?.sampleRate = sampleRate
        currentTrace?.logEntries.append(
            TraceEntry.LogEntry(timestamp: now(), stage: .recording)
        )
    }

    func recordASR(_ text: String) {
        guard currentTrace != nil else { return }
        currentTrace?.asrText = text
        currentTrace?.logEntries.append(
            TraceEntry.LogEntry(timestamp: now(), stage: .asrDone)
        )
    }

    func recordLLM(_ text: String, mode: String? = nil) {
        guard currentTrace != nil else { return }
        currentTrace?.llmText = text
        if let mode {
            currentTrace?.mode = mode
        }
        currentTrace?.logEntries.append(
            TraceEntry.LogEntry(timestamp: now(), stage: .refineDone, note: mode)
        )
    }

    /// Mark the ClipboardArchive entry created for this trace, keyed by
    /// the ISO8601 timestamp returned from `ClipboardArchive.save(...)` /
    /// `saveSession(...)`. Lets the trace UI cross-link back to the
    /// archive entry.
    func recordClipboard(timestamp: String) {
        guard currentTrace != nil else { return }
        currentTrace?.clipboardTimestamp = timestamp
        currentTrace?.logEntries.append(
            TraceEntry.LogEntry(timestamp: now(), stage: .archived)
        )
    }

    func recordFinal(_ text: String) {
        guard currentTrace != nil else { return }
        let stamp = now()
        currentTrace?.finalText = text
        currentTrace?.endedAt = stamp
        currentTrace?.logEntries.append(
            TraceEntry.LogEntry(timestamp: stamp, stage: .injectDone)
        )
    }

    /// Park mode: recording captured but intentionally not pasted.
    /// `mode` is stored on the trace for UI filtering.
    func recordPark(mode: String = "park") {
        guard currentTrace != nil else { return }
        let stamp = now()
        currentTrace?.mode = mode
        currentTrace?.endedAt = stamp
        currentTrace?.logEntries.append(
            TraceEntry.LogEntry(timestamp: stamp, stage: .park)
        )
    }

    func recordError(_ note: String) {
        guard currentTrace != nil else { return }
        let stamp = now()
        currentTrace?.endedAt = stamp
        currentTrace?.logEntries.append(
            TraceEntry.LogEntry(timestamp: stamp, stage: .error, note: note)
        )
    }

    /// Persist the current trace and clear. Returns the saved trace or
    /// nil if there was nothing active. TraceStore I/O failure is
    /// logged but not thrown — recording itself must not fail because
    /// of trace persistence issues.
    @discardableResult
    func finalize() -> TraceEntry? {
        guard let trace = currentTrace else { return nil }
        currentTrace = nil
        do {
            try store.append(trace)
        } catch {
            NSLog("[RecordingTracer] append failed: %@", error.localizedDescription)
        }
        return trace
    }

    /// Drop the active trace without persisting (e.g. zero-byte audio,
    /// user cancellation).
    func cancel() {
        currentTrace = nil
    }
}
