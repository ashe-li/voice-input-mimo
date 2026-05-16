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
/// All mutations of `currentTrace` go through `lock` so off-main callers
/// (e.g. URLSession completion handlers, background dispatch queues) don't
/// race the main-thread driver in `AppDelegate`. The class is
/// `@unchecked Sendable` because the lock guarantees the invariant the
/// compiler can't verify (`currentTrace` is mutable). Single `NSLock`
/// suffices — record-call frequency is bounded by recording cadence
/// (human hotkey), not loop work.
final class RecordingTracer: @unchecked Sendable {
    /// Snapshot accessor for callers that want to inspect the active trace
    /// without taking the lock (e.g. UI threads reading id for display).
    /// Returns a value-copy under the lock so callers see a consistent
    /// snapshot, never a partial mid-mutation state.
    var currentTrace: TraceEntry? {
        lock.lock(); defer { lock.unlock() }
        return _currentTrace
    }
    private var _currentTrace: TraceEntry?

    private let store: TraceStore
    private let now: () -> Date
    private let idGenerator: () -> String
    private let lock = NSLock()

    init(
        store: TraceStore = .shared,
        now: @escaping () -> Date = Date.init,
        idGenerator: @escaping () -> String = { "trace-\(UUID().uuidString.prefix(8))" }
    ) {
        self.store = store
        self.now = now
        self.idGenerator = idGenerator
    }

    /// Run `body` while holding the per-instance lock. Centralises the
    /// "check active trace + mutate" pattern so every record* method
    /// closes the TOCTOU window between the nil-check and the write.
    private func withTrace(_ body: (inout TraceEntry) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard var trace = _currentTrace else { return }
        body(&trace)
        _currentTrace = trace
    }

    /// Start a new trace. Discards any previously-active trace without
    /// persisting — callers should `finalize()` before starting a new
    /// session if they want the prior trace saved.
    @discardableResult
    func begin() -> TraceEntry {
        lock.lock(); defer { lock.unlock() }
        let stamp = now()
        let trace = TraceEntry(
            id: idGenerator(),
            startedAt: stamp,
            logEntries: [TraceEntry.LogEntry(timestamp: stamp, stage: .start)]
        )
        _currentTrace = trace
        return trace
    }

    func recordAudio(path: String?, bytes: Int? = nil, sampleRate: Int? = nil) {
        withTrace { trace in
            trace.audioPath = path
            trace.audioBytes = bytes
            trace.sampleRate = sampleRate
            trace.logEntries.append(
                TraceEntry.LogEntry(timestamp: now(), stage: .recording)
            )
        }
    }

    /// Repoint `audioPath` to the persistent archive location after
    /// RecordingArchive copies the tmp wav. Does NOT add a log entry —
    /// the original `recordAudio(...)` call already logged `.recording`,
    /// and we just want the final on-disk reference to survive
    /// AudioRecorder's tmp cleanup.
    func updateAudioPath(_ path: String) {
        withTrace { $0.audioPath = path }
    }

    /// Snapshot the frontmost-app context (captured at hotkey-down before
    /// any UI work). No-op when no trace is active. `nil` bundle/appName
    /// (login window / no UI session) is stored as-is, not dropped — the
    /// nil itself is a meaningful signal that no app was frontmost.
    func recordContext(bundleID: String?, appName: String?) {
        withTrace { trace in
            trace.contextBundleID = bundleID
            trace.contextAppName = appName
        }
    }

    /// Record the routing decision after `LLMRefiner.decideDispatch` runs.
    /// `inputMode` is what the user originally selected; `routing` is nil
    /// for non-`.contextAware` modes (they don't go through ToneMapping).
    func recordRouting(inputMode: String, routing: TraceEntry.Routing?) {
        withTrace { trace in
            trace.inputMode = inputMode
            trace.routing = routing
        }
    }

    func recordASR(_ text: String) {
        withTrace { trace in
            trace.asrText = text
            trace.logEntries.append(
                TraceEntry.LogEntry(timestamp: now(), stage: .asrDone)
            )
        }
    }

    func recordLLM(_ text: String, mode: String? = nil) {
        withTrace { trace in
            trace.llmText = text
            if let mode {
                trace.mode = mode
            }
            trace.logEntries.append(
                TraceEntry.LogEntry(timestamp: now(), stage: .refineDone, note: mode)
            )
        }
    }

    /// Mark the ClipboardArchive entry created for this trace, keyed by
    /// the ISO8601 timestamp returned from `ClipboardArchive.save(...)` /
    /// `saveSession(...)`. Lets the trace UI cross-link back to the
    /// archive entry.
    func recordClipboard(timestamp: String) {
        withTrace { trace in
            trace.clipboardTimestamp = timestamp
            trace.logEntries.append(
                TraceEntry.LogEntry(timestamp: now(), stage: .archived)
            )
        }
    }

    func recordFinal(_ text: String) {
        let stamp = now()
        withTrace { trace in
            trace.finalText = text
            trace.endedAt = stamp
            trace.logEntries.append(
                TraceEntry.LogEntry(timestamp: stamp, stage: .injectDone)
            )
        }
    }

    /// Park mode: recording captured but intentionally not pasted.
    /// `mode` is stored on the trace for UI filtering.
    func recordPark(mode: String = "park") {
        let stamp = now()
        withTrace { trace in
            trace.mode = mode
            trace.endedAt = stamp
            trace.logEntries.append(
                TraceEntry.LogEntry(timestamp: stamp, stage: .park)
            )
        }
    }

    func recordError(_ note: String) {
        let stamp = now()
        withTrace { trace in
            trace.endedAt = stamp
            trace.logEntries.append(
                TraceEntry.LogEntry(timestamp: stamp, stage: .error, note: note)
            )
        }
    }

    /// Persist the current trace and clear. Returns the saved trace or
    /// nil if there was nothing active. TraceStore I/O failure is
    /// logged but not thrown — recording itself must not fail because
    /// of trace persistence issues.
    @discardableResult
    func finalize() -> TraceEntry? {
        let trace: TraceEntry? = {
            lock.lock(); defer { lock.unlock() }
            let snapshot = _currentTrace
            _currentTrace = nil
            return snapshot
        }()
        guard let trace else { return nil }
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
        lock.lock(); defer { lock.unlock() }
        _currentTrace = nil
    }
}
