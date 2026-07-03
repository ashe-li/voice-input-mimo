import XCTest
@testable import VoiceInputMimo

/// Unit tests for the record-start LLM warmup (S2.1). Exercises the pure,
/// AppKit-free pieces extracted from the `AppDelegate` prewarm glue:
///   - `LLMWarmState`         — staleness + freshness-clock stamping
///   - `LLMRefiner.warmUpSucceeded` — 2xx-only success classification
///   - `LLMRefiner.makeWarmUpRequest` — request shape (non-quick mode + timeout)
///
/// The fire-and-forget `LLMRefiner.warmUp` network wiring is intentionally not
/// unit-tested (it composes the three pieces above over `URLSession.shared`);
/// build + the pure-piece coverage stand in for it, matching how the repo tests
/// `warmUpASR` (via `ASRFailureClassifier`) rather than the live HTTP call.
final class LLMPrewarmTests: XCTestCase {

    // Mirror the AppDelegate staleness constant so the tests read as intended.
    private let idle: TimeInterval = 90

    // MARK: - LLMWarmState.needsWarmUp

    /// Req ①: the first recording after launch (no confirmed-hot LLM yet) must
    /// warm up — this is the tightest cold-load window.
    func testNeverActive_NeedsWarmUp() {
        let state = LLMWarmState(idleThreshold: idle)
        XCTAssertTrue(state.needsWarmUp(now: Date()))
    }

    /// Req ②: a second recording within the idle window must NOT re-warm.
    func testRecentActivity_DoesNotWarmUp() {
        let t0 = Date()
        var state = LLMWarmState(idleThreshold: idle)
        state.recordActivity(at: t0)
        XCTAssertFalse(state.needsWarmUp(now: t0.addingTimeInterval(30)))
    }

    /// Req ②: past the idle window, warm up again.
    func testStaleActivity_NeedsWarmUp() {
        let t0 = Date()
        var state = LLMWarmState(idleThreshold: idle)
        state.recordActivity(at: t0)
        XCTAssertTrue(state.needsWarmUp(now: t0.addingTimeInterval(idle + 1)))
    }

    /// Boundary is exclusive — exactly `idleThreshold` seconds is still fresh,
    /// matching the ASR `> prewarmIfIdleSeconds` check it mirrors.
    func testExactlyAtThreshold_IsStillFresh() {
        let t0 = Date()
        var state = LLMWarmState(idleThreshold: idle)
        state.recordActivity(at: t0)
        XCTAssertFalse(state.needsWarmUp(now: t0.addingTimeInterval(idle)))
    }

    // MARK: - LLMWarmState.recordActivity

    /// Req ③: a successful warmup (or refine) stamps the freshness clock, which
    /// flips a previously-stale state to fresh.
    func testRecordActivity_StampsClockAndClearsStaleness() {
        var state = LLMWarmState(idleThreshold: idle)
        XCTAssertNil(state.lastActivityAt)
        XCTAssertTrue(state.needsWarmUp(now: Date()))

        let t0 = Date()
        state.recordActivity(at: t0)
        XCTAssertEqual(state.lastActivityAt, t0)
        XCTAssertFalse(state.needsWarmUp(now: t0))
    }

    // MARK: - LLMRefiner.warmUpSucceeded

    /// Req ③: only a 2xx confirms the backend is hot.
    func testWarmUpSucceeded_2xxIsSuccess() {
        XCTAssertTrue(LLMRefiner.warmUpSucceeded(statusCode: 200, error: nil))
        XCTAssertTrue(LLMRefiner.warmUpSucceeded(statusCode: 204, error: nil))
    }

    /// Req ④: a gateway 503 (still cold / not ready) must NOT stamp — so the
    /// next record-start retries the warmup rather than assuming hot.
    func testWarmUpSucceeded_503IsFailure() {
        XCTAssertFalse(LLMRefiner.warmUpSucceeded(statusCode: 503, error: nil))
        XCTAssertFalse(LLMRefiner.warmUpSucceeded(statusCode: 500, error: nil))
    }

    /// Req ④: any transport error is a failure, even if a status somehow rode
    /// along — the error dominates. A nil status with no error is also a
    /// failure (nothing confirmed).
    func testWarmUpSucceeded_ErrorOrNilStatusIsFailure() {
        let err = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        XCTAssertFalse(LLMRefiner.warmUpSucceeded(statusCode: nil, error: err))
        XCTAssertFalse(LLMRefiner.warmUpSucceeded(statusCode: 200, error: err))
        XCTAssertFalse(LLMRefiner.warmUpSucceeded(statusCode: nil, error: nil))
    }

    // MARK: - LLMRefiner.makeWarmUpRequest

    /// Req ⑤: the warmup request must route through a non-`quick` gateway queue
    /// (quick's 5s timeout aborts a cold load) and carry a client timeout long
    /// enough to ride out a heavy cold load, with a minimal `max_tokens`.
    func testMakeWarmUpRequest_UsesNonQuickModeAndLongTimeout() throws {
        guard let request = LLMRefiner.shared.makeWarmUpRequest() else {
            return XCTFail("makeWarmUpRequest returned nil for a valid base URL")
        }

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.timeoutInterval, LLMRefiner.warmUpTimeoutSeconds)
        XCTAssertGreaterThanOrEqual(request.timeoutInterval, 30,
                                    "warmup timeout must cover a heavy cold load")
        XCTAssertTrue(request.url?.path.hasSuffix("/chat/completions") ?? false,
                      "warmup must hit the chat-completions endpoint")

        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        let mode = json["mode"] as? String
        XCTAssertNotEqual(mode, "quick", "warmup must not use the quick queue")
        XCTAssertEqual(mode, LLMRefiner.warmUpGatewayMode)
        XCTAssertEqual(json["max_tokens"] as? Int, LLMRefiner.warmUpMaxTokens)
    }

    /// Direct equality (not `contains`) so a typo in the constant is caught: the
    /// warmup queue must be the non-quick `default`, and the probe caps output at
    /// a single token.
    func testWarmUpConstants() {
        XCTAssertEqual(LLMRefiner.warmUpGatewayMode, "default")
        XCTAssertNotEqual(LLMRefiner.warmUpGatewayMode, "quick")
        XCTAssertEqual(LLMRefiner.warmUpMaxTokens, 1)
    }
}
