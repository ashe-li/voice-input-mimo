import XCTest
@testable import VoiceInputMimo

/// Budgets that must grow with dictation length now that the engine returns the
/// full multi-minute transcript instead of truncating at ~500 chars:
///   - `LLMRefiner.maxTokens(for:inputText:)` — refine output cap
///   - `ASRClient.requestTimeout(audioBytes:)` — transcription client timeout
final class LongDictationBudgetTests: XCTestCase {

    // MARK: - LLMRefiner.maxTokens

    /// Short utterances keep the historical caps (600 single-line, 1500 structure).
    func testMaxTokens_ShortInputKeepsModeFloors() {
        let short = String(repeating: "字", count: 40)
        XCTAssertEqual(LLMRefiner.maxTokens(for: .refine, inputText: short), 600)
        XCTAssertEqual(LLMRefiner.maxTokens(for: .claudeCode, inputText: short), 600)
        XCTAssertEqual(LLMRefiner.maxTokens(for: .structure, inputText: short), 1500)
        XCTAssertEqual(LLMRefiner.maxTokens(for: .refine, inputText: ""), 600)
    }

    /// The 193 s dictation now yields ~1036 chars; its budget must clear the old
    /// 600 cap by a wide margin (translation observed at ~0.6 tokens/char).
    func testMaxTokens_LongInputScalesPastOldCap() {
        let long = String(repeating: "字", count: 1036)
        let cap = LLMRefiner.maxTokens(for: .claudeCode, inputText: long)
        XCTAssertEqual(cap, 1554 + 256)
        XCTAssertGreaterThan(cap, 600)
        XCTAssertEqual(LLMRefiner.maxTokens(for: .structure, inputText: long), 1810)
    }

    /// Structure keeps its higher floor until input outgrows it.
    func testMaxTokens_StructureFloorWinsUntilInputOutgrowsIt() {
        let mid = String(repeating: "字", count: 500)
        XCTAssertEqual(LLMRefiner.maxTokens(for: .claudeCode, inputText: mid), 1006)
        XCTAssertEqual(LLMRefiner.maxTokens(for: .structure, inputText: mid), 1500)
    }

    func testMaxTokens_HasCeiling() {
        let huge = String(repeating: "字", count: 20_000)
        XCTAssertEqual(LLMRefiner.maxTokens(for: .claudeCode, inputText: huge),
                       LLMRefiner.maxTokensCeiling)
    }

    // MARK: - ASRClient.requestTimeout

    private func wavBytes(seconds: Double) -> Int {
        ASRClient.wavHeaderBytes + Int(seconds * Double(ASRClient.wavBytesPerSecond))
    }

    func testEstimatedAudioSeconds() {
        XCTAssertEqual(ASRClient.estimatedAudioSeconds(audioBytes: wavBytes(seconds: 193)),
                       193, accuracy: 0.001)
        XCTAssertEqual(ASRClient.estimatedAudioSeconds(audioBytes: 10), 0)
    }

    /// Short clips keep the previous 60 s floor.
    func testRequestTimeout_ShortClipKeepsFloor() {
        XCTAssertEqual(ASRClient.requestTimeout(audioBytes: 0), 60)
        XCTAssertEqual(ASRClient.requestTimeout(audioBytes: wavBytes(seconds: 5)),
                       60 + 5 * 0.75, accuracy: 0.001)
    }

    /// 193 s of audio gets 60 + 193 × 0.75 ≈ 205 s — well above the ~26 s the
    /// full-length decode measured, and above a capped runaway.
    func testRequestTimeout_LongClipScales() {
        let timeout = ASRClient.requestTimeout(audioBytes: wavBytes(seconds: 193))
        XCTAssertEqual(timeout, 204.75, accuracy: 0.001)
        XCTAssertGreaterThan(timeout, 60)
    }

    func testRequestTimeout_HasCeiling() {
        XCTAssertEqual(ASRClient.requestTimeout(audioBytes: wavBytes(seconds: 3600)),
                       ASRClient.maxRequestTimeout)
    }

    // MARK: - ASRClient.gatewayMode

    func testGatewayMode_ShortClipStaysQuick() {
        XCTAssertEqual(ASRClient.gatewayMode(audioBytes: 0), "quick")
        XCTAssertEqual(ASRClient.gatewayMode(audioBytes: wavBytes(seconds: 15)), "quick")
        XCTAssertEqual(ASRClient.gatewayMode(audioBytes: wavBytes(seconds: 60)), "quick")
    }

    func testGatewayMode_LongClipUsesBatch() {
        XCTAssertEqual(ASRClient.gatewayMode(audioBytes: wavBytes(seconds: 61)), "batch")
        XCTAssertEqual(ASRClient.gatewayMode(audioBytes: wavBytes(seconds: 193)), "batch")
    }
}
