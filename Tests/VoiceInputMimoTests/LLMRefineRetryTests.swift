import XCTest
@testable import VoiceInputMimo

/// Unit tests for the 503-triggered single retry (S2.2, VIM side). Exercises the
/// pure decision + Retry-After parsing extracted from `LLMRefiner`'s refine path:
///   - `decideRetry(statusCode:retryAfterHeader:isRetry:)` — retry gating
///   - `parseRetryAfter(_:)`                               — delay parse + clamp
///
/// The network wiring (`performRefineRequest` send → wait → default-mode retry →
/// success/fallback) is not unit-tested here; it composes these pure pieces over
/// `URLSession.shared` and is covered by build + the unchanged AppDelegate
/// raw-ASR fallback path, matching how the repo tests `ASRFailureClassifier`
/// rather than the live HTTP call.
final class LLMRefineRetryTests: XCTestCase {

    // MARK: - decideRetry: only a gateway 503 (first attempt) retries

    /// Req: 503 + Retry-After on the first attempt → retry once, waiting the
    /// parsed delay (the send-then-default-retry outcome is integration-level).
    func testFirst503WithRetryAfter_RetriesWithParsedDelay() {
        let d = LLMRefiner.decideRetry(statusCode: 503, retryAfterHeader: "15", isRetry: false)
        XCTAssertEqual(d, .retry(afterSeconds: 15))
    }

    /// Req 4: 503 without a usable Retry-After still retries, using the default
    /// wait — a missing header must not suppress the retry.
    func testFirst503WithoutRetryAfter_RetriesWithDefaultDelay() {
        let d = LLMRefiner.decideRetry(statusCode: 503, retryAfterHeader: nil, isRetry: false)
        XCTAssertEqual(d, .retry(afterSeconds: LLMRefiner.defaultRetryAfterSeconds))
    }

    /// Req 5: retry exactly once — a second 503 (already retried) gives up, even
    /// with a valid Retry-After. This is what bounds the retry to a single shot.
    func testSecond503_GivesUp() {
        let d = LLMRefiner.decideRetry(statusCode: 503, retryAfterHeader: "5", isRetry: true)
        XCTAssertEqual(d, .giveUp)
    }

    /// Req 3: non-503 statuses never retry (prevents a retry storm; the 5s-abort
    /// timeout surfaces as a URLError with no 503 and must fall straight through
    /// to the raw-ASR fallback).
    func testNon503Statuses_NeverRetry() {
        for code in [200, 429, 500, 502, 504] {
            let d = LLMRefiner.decideRetry(statusCode: code, retryAfterHeader: "5", isRetry: false)
            XCTAssertEqual(d, .giveUp, "status \(code) must not retry")
        }
    }

    /// A transport error yields no HTTP status → treated as non-503 → no retry.
    func testNilStatus_NeverRetries() {
        let d = LLMRefiner.decideRetry(statusCode: nil, retryAfterHeader: "5", isRetry: false)
        XCTAssertEqual(d, .giveUp)
    }

    // MARK: - parseRetryAfter: parse + defensive clamp

    func testParsesPlainDeltaSeconds() {
        XCTAssertEqual(LLMRefiner.parseRetryAfter("15"), 15)
        XCTAssertEqual(LLMRefiner.parseRetryAfter("7"), 7)
    }

    func testTrimsSurroundingWhitespace() {
        XCTAssertEqual(LLMRefiner.parseRetryAfter("  20 "), 20)
    }

    /// Req 4: missing / non-numeric (incl. HTTP-date form we don't parse) → the
    /// named default constant.
    func testMissingOrNonNumeric_ReturnsDefault() {
        XCTAssertEqual(LLMRefiner.parseRetryAfter(nil), LLMRefiner.defaultRetryAfterSeconds)
        XCTAssertEqual(LLMRefiner.parseRetryAfter(""), LLMRefiner.defaultRetryAfterSeconds)
        XCTAssertEqual(LLMRefiner.parseRetryAfter("soon"), LLMRefiner.defaultRetryAfterSeconds)
        XCTAssertEqual(
            LLMRefiner.parseRetryAfter("Wed, 21 Oct 2015 07:28:00 GMT"),
            LLMRefiner.defaultRetryAfterSeconds
        )
    }

    /// Req 4: negative is malformed → fall back to the default wait rather than
    /// retrying immediately against a still-cold backend.
    func testNegative_ReturnsDefault() {
        XCTAssertEqual(LLMRefiner.parseRetryAfter("-5"), LLMRefiner.defaultRetryAfterSeconds)
    }

    /// Req 4: an oversized Retry-After is clamped to the upper bound so a buggy /
    /// hostile gateway can't stall refine for minutes.
    func testOversized_ClampsToMax() {
        XCTAssertEqual(LLMRefiner.parseRetryAfter("9999"), LLMRefiner.maxRetryAfterSeconds)
        XCTAssertEqual(
            LLMRefiner.parseRetryAfter(String(Int(LLMRefiner.maxRetryAfterSeconds) + 1)),
            LLMRefiner.maxRetryAfterSeconds
        )
    }

    func testExactlyMax_IsUnclamped() {
        XCTAssertEqual(
            LLMRefiner.parseRetryAfter(String(Int(LLMRefiner.maxRetryAfterSeconds))),
            LLMRefiner.maxRetryAfterSeconds
        )
    }

    /// Zero is a valid "retry now" delta and is honored as-is.
    func testZero_IsHonored() {
        XCTAssertEqual(LLMRefiner.parseRetryAfter("0"), 0)
    }

    // MARK: - retry mode + bounds sanity

    /// The retry must upgrade off the quick queue so it gets a real cold-load
    /// budget; and the wait bounds must stay inside the 90s client timeout.
    func testRetryConstants() {
        XCTAssertNotEqual(LLMRefiner.retryGatewayMode, "quick")
        XCTAssertTrue(["default", "batch"].contains(LLMRefiner.retryGatewayMode))
        XCTAssertLessThanOrEqual(LLMRefiner.maxRetryAfterSeconds, 90)
        XCTAssertLessThanOrEqual(
            LLMRefiner.defaultRetryAfterSeconds,
            LLMRefiner.maxRetryAfterSeconds
        )
    }
}
