# Fn Double-Tap History Fix — Job Queue Design

**Branch:** `fix/fn-double-tap-history`
**Worktree:** `~/Documents/voice-input-mimo-fn-double-tap`
**Date:** 2026-05-17

## Root cause

`AppDelegate.fnDown()` 第 276–277 行：
```swift
LLMRefiner.shared.cancel()
ASRClient.shared.cancel()
```

第二次 Fn 按下時，會把第一段尚在 in-flight 的 ASR/LLM 任務全部 cancel。
第一段的 pipeline 鏈 `ASR → handleTranscription → completeWithEnglish → ClipboardArchive.saveSession` 中斷，
第一段永遠不會進入 history。第二段若是短/空訊息，`handleTranscription` 的 empty guard 也會 drop。
結果：兩段都從 history 消失。

## Goal

連按兩次 Fn 時，兩段錄音都必須進入 ClipboardArchive history；第二段優先 paste，第一段稍後 paste（覆蓋 clipboard）。

## Design

### Data model

```swift
final class RecordingJob {
    let id: UUID
    let wavURL: URL                  // set on fnUp
    let audioDurationSeconds: Double // set on fnUp
    var asrResult: String?           // populated after ASR completes
    var tracer: RecordingTracer      // per-job, not shared singleton
    var stage: Stage
    var cancelled: Bool              // if true, in-flight callbacks become no-op

    enum Stage {
        case pendingASR        // wavURL present, ASR not started
        case asrInflight       // ASR network task running
        case pendingLLM        // ASR done, LLM not started
        case llmInflight       // LLM network task running
        case readyToPaste      // LLM done (or skipped)
        case done
    }
}
```

### Queue semantics

`RecordingJobQueue` (singleton, main-thread):

- `enqueue(job, priority:)`: priority `.head` (urgent) or `.tail` (normal)
- `runNext()`: dequeue head, drive through stage machine
- On `fnDown` while a job is running:
  1. If `currentJob.audioDurationSeconds < 1.5`: drop it (don't requeue)
  2. Otherwise: cancel its in-flight network task, leave `cancelled=true`,
     `enqueue(currentJob, priority: .tail)`. Stage is preserved so we can resume from `pendingASR` or `pendingLLM`.
- The new (second) segment is the active job after `fnUp` and is processed first.
- After the new segment completes (paste + saveSession), `runNext()` picks up the earlier-deferred job and continues from its preserved stage.

### Threshold logic (1.5s default)

`audioDurationSeconds` is computed from `AudioRecorder` start/stop timestamps (already in scope when fnUp triggers).
Settings key `fnInterruptMinSeconds` (default 1.5) lets us tweak later.

### Partial-progress preservation

- `pendingASR` → `asrInflight`: cancel cancels the URLSessionDataTask only. wavURL persists. Resume = re-call `ASRClient.transcribe(wavURL:)`.
- `asrInflight` → `pendingLLM`: ASR result stored in `asrResult`. Resume = re-call `LLMRefiner.refine(asrResult)` without re-running ASR.
- `llmInflight` → `readyToPaste`: rare race. Either re-run LLM (cheaper) or fall back to ASR-only. Default: re-run LLM.

### Paste / archive ordering

```
T=0–10s   first segment recorded
T=10s     fnUp → first.stage=pendingASR, enqueue head, run
T=10.5s   first.stage=asrInflight (network)
T=10.7s   fnDown second → first cancelled, requeue tail, first.stage=pendingASR (or pendingLLM if ASR returned in time)
T=10.7–15.7s   second segment recorded
T=15.7s   fnUp second → second.stage=pendingASR, enqueue head, run
T=17s     second.stage=pendingLLM
T=18s     second.stage=readyToPaste → paste + saveSession (second entry added to history-top)
T=18s     runNext picks up first (now at queue head since second drained)
T=19s     first.stage=asrInflight again (re-running ASR)
T=21s     first.stage=pendingLLM
T=22s     first.stage=readyToPaste → paste (overwrites clipboard) + saveSession (first entry added to history-top)
```

Final state:
- Clipboard: first segment text
- History (top-to-bottom): first, second, …

### Cancellation safety

URLSession callbacks may fire even after `cancel()` if the response is mid-flight.
`RecordingJob.cancelled` is checked at the top of each completion handler;
if true, the handler returns immediately without mutating state or invoking
follow-on stages.

### UI / Overlay

- Second segment recording: overlay shows recording state for second (as today).
- After second's paste: overlay collapses, then re-opens for first's "resuming" state with `.transcribing` / `.refining` until first's paste.
- Single overlayPanel — sequential drive matches current single-pipeline assumption.

## Affected files

- `Sources/VoiceInputMimo/RecordingJob.swift` (NEW)
- `Sources/VoiceInputMimo/RecordingJobQueue.swift` (NEW)
- `Sources/VoiceInputMimo/AppDelegate.swift` (refactor `fnDown` / `fnUp` / `handleTranscription` / `completeWithEnglish` / `completeWithoutTranslation` to operate on a job)
- `Tests/VoiceInputMimoTests/RecordingJobQueueTests.swift` (NEW)

## Out of scope

- Concurrent ASR (sidecar would need queueing support); we serialise.
- N>2 stacking edge cases beyond the basic LIFO queue (handled naturally by the design).
- Park mode (`onParkDown` / `onParkUp`): untouched; park is a separate handler that already writes to history independently.
