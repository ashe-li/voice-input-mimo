import Foundation

/// Pure, AppKit-free state for the record-start LLM warmup. Mirrors the ASR
/// `lastASRActivityAt` + `prewarmIfStale` pattern in `AppDelegate`, but extracted
/// as a value type so the staleness + stamping rules can be unit-tested without
/// standing up the app — same rationale as `ASRFailureClassifier`.
///
/// `AppDelegate` owns a single instance and only ever touches it on the main
/// thread (record-start reads it; warmup / refine successes stamp it via
/// main-queue callbacks), so no locking is needed.
struct LLMWarmState: Equatable {
    /// When the LLM backend was last observed hot — via a successful warmup
    /// probe or a successful real refine. `nil` means this process has never
    /// confirmed a hot LLM: the first recording right after launch, which is
    /// the tightest cold-load window.
    private(set) var lastActivityAt: Date?

    /// Idle window beyond which the backend is treated as possibly-cold and a
    /// fresh warmup is worthwhile. Reuses the ASR prewarm threshold (90s).
    let idleThreshold: TimeInterval

    init(idleThreshold: TimeInterval, lastActivityAt: Date? = nil) {
        self.idleThreshold = idleThreshold
        self.lastActivityAt = lastActivityAt
    }

    /// True when a warmup should fire: either this process has never confirmed a
    /// hot LLM, or the last confirmed-hot moment is older than the idle window.
    /// The boundary is exclusive — exactly `idleThreshold` seconds still counts
    /// as fresh, matching the ASR `> prewarmIfIdleSeconds` check it mirrors.
    func needsWarmUp(now: Date) -> Bool {
        guard let last = lastActivityAt else { return true }
        return now.timeIntervalSince(last) > idleThreshold
    }

    /// Stamp a confirmed-hot moment. Called after a successful warmup probe or a
    /// successful real refine so the next record-start doesn't re-warm within
    /// the idle window (PR #21 lesson: warmup must update the freshness clock,
    /// or the next recording schedules a redundant probe).
    mutating func recordActivity(at date: Date) {
        lastActivityAt = date
    }
}
