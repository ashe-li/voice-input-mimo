import XCTest
@testable import VoiceInputMimo

/// Covers the two pure rules extracted from AppDelegate's ASR path:
///   • ASRAudioGuard — when a capture is too small to send to ASR
///   • ASRFailureClassifier — how a raw transcribe error maps to user-facing text
final class ASRFailureClassifierTests: XCTestCase {

    // MARK: - ASRAudioGuard.isEffectivelyEmpty(declaredDataSize:)

    func test_declaredZero_isEmpty() {
        // The exact real failure: data chunk declares 0 bytes → engine length=0.
        XCTAssertTrue(ASRAudioGuard.isEffectivelyEmpty(declaredDataSize: 0))
    }

    func test_justBelowThreshold_isEmpty() {
        XCTAssertTrue(ASRAudioGuard.isEffectivelyEmpty(declaredDataSize: ASRAudioGuard.minPCMBytes - 1))
    }

    func test_atThreshold_isNotEmpty() {
        XCTAssertFalse(ASRAudioGuard.isEffectivelyEmpty(declaredDataSize: ASRAudioGuard.minPCMBytes))
    }

    func test_shortRealUtterance_isNotEmpty() {
        // A clipped "Yeah." ≈ 0.2 s = 6 400 B payload — must pass.
        XCTAssertFalse(ASRAudioGuard.isEffectivelyEmpty(declaredDataSize: 6_400))
    }

    // MARK: - ASRAudioGuard.declaredDataChunkSize (header parsing)

    func test_parsesBrokenAVAudioRecorderLayout_dataSizeZero() {
        // Replicates the real on-disk layout: JUNK(28) + fmt(16) + FLLR(4008) +
        // data(0). File is ~4 KB but declares zero audio.
        let header = Self.makeWav(fllrSize: 4_008, dataDeclaredSize: 0, payloadBytes: 0)
        XCTAssertEqual(ASRAudioGuard.declaredDataChunkSize(headerBytes: header), 0)
    }

    func test_parsesRealRecording_dataSizeNonZero() {
        let header = Self.makeWav(fllrSize: 4_008, dataDeclaredSize: 32_000, payloadBytes: 0)
        XCTAssertEqual(ASRAudioGuard.declaredDataChunkSize(headerBytes: header), 32_000)
    }

    func test_nonRiffBuffer_returnsNil() {
        XCTAssertNil(ASRAudioGuard.declaredDataChunkSize(headerBytes: Data("not a wav file".utf8)))
    }

    // MARK: - ASRAudioGuard.isEffectivelyEmpty(at:)

    func test_brokenFileOnDisk_isEmpty() throws {
        // 4 KB file, FLLR-padded, data size 0 — the actual length=0 producer.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("asr-broken-\(UUID().uuidString).wav")
        try Self.makeWav(fllrSize: 4_008, dataDeclaredSize: 0, payloadBytes: 0).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(ASRAudioGuard.isEffectivelyEmpty(at: url))
    }

    func test_realRecordingOnDisk_isNotEmpty() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("asr-real-\(UUID().uuidString).wav")
        // ~1 s of audio, declared and present.
        try Self.makeWav(fllrSize: 4_008, dataDeclaredSize: 32_000, payloadBytes: 32_000).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertFalse(ASRAudioGuard.isEffectivelyEmpty(at: url))
    }

    func test_missingFile_isNotEmpty_bestEffort() {
        // Can't open → false, so the normal transcribe fileRead path runs.
        let url = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).wav")
        XCTAssertFalse(ASRAudioGuard.isEffectivelyEmpty(at: url))
    }

    /// Build a WAV mirroring AVAudioRecorder's layout: RIFF/WAVE, JUNK, fmt,
    /// FLLR padding, then a data chunk declaring `dataDeclaredSize` followed by
    /// `payloadBytes` of actual zeros. Lets tests reproduce both the broken
    /// (declared 0) and healthy cases byte-for-byte.
    private static func makeWav(fllrSize: Int, dataDeclaredSize: Int, payloadBytes: Int) -> Data {
        func u32(_ v: Int) -> Data { withUnsafeBytes(of: UInt32(v).littleEndian) { Data($0) } }
        func u16(_ v: Int) -> Data { withUnsafeBytes(of: UInt16(v).littleEndian) { Data($0) } }
        var d = Data()
        d.append(Data("RIFF".utf8)); d.append(u32(0)); d.append(Data("WAVE".utf8))
        d.append(Data("JUNK".utf8)); d.append(u32(28)); d.append(Data(count: 28))
        d.append(Data("fmt ".utf8)); d.append(u32(16))
        d.append(u16(1)); d.append(u16(1)); d.append(u32(16_000))
        d.append(u32(32_000)); d.append(u16(2)); d.append(u16(16))
        d.append(Data("FLLR".utf8)); d.append(u32(fllrSize)); d.append(Data(count: fllrSize))
        d.append(Data("data".utf8)); d.append(u32(dataDeclaredSize)); d.append(Data(count: payloadBytes))
        return d
    }

    // MARK: - ASRFailureClassifier.classify

    func test_http500TooShort_mapsToEmptyTranscript() {
        let err = ASRClient.ASRError.httpError(500, #"{"detail":"Input is too short (length=0) for n_fft=960"}"#)
        XCTAssertEqual(ASRFailureClassifier.classify(err), .emptyTranscript)
    }

    func test_http502_mapsToBackendNotReady() {
        let err = ASRClient.ASRError.httpError(502, #"{"error":{"message":"Fetch failed for http://127.0.0.1:8766"}}"#)
        XCTAssertEqual(ASRFailureClassifier.classify(err), .backendNotReady)
    }

    func test_http503_mapsToBackendNotReady() {
        XCTAssertEqual(ASRFailureClassifier.classify(ASRClient.ASRError.httpError(503, "")), .backendNotReady)
    }

    func test_http500Other_passesThrough() {
        // A 500 that isn't the too-short case must not be silently relabelled.
        let err = ASRClient.ASRError.httpError(500, #"{"detail":"CUDA out of memory"}"#)
        XCTAssertEqual(ASRFailureClassifier.classify(err), .passthrough)
    }

    func test_http400_passesThrough() {
        XCTAssertEqual(ASRFailureClassifier.classify(ASRClient.ASRError.httpError(400, "bad")), .passthrough)
    }

    func test_cannotConnect_mapsToBackendUnreachable() {
        let err = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost)
        XCTAssertEqual(ASRFailureClassifier.classify(err), .backendUnreachable)
    }

    func test_timedOut_mapsToBackendUnreachable() {
        let err = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        XCTAssertEqual(ASRFailureClassifier.classify(err), .backendUnreachable)
    }

    func test_otherURLError_passesThrough() {
        // e.g. NSURLErrorCancelled — handled elsewhere, not our concern here.
        let err = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        XCTAssertEqual(ASRFailureClassifier.classify(err), .passthrough)
    }

    func test_nonURLError_passesThrough() {
        let err = NSError(domain: "SomeOther", code: 1)
        XCTAssertEqual(ASRFailureClassifier.classify(err), .passthrough)
    }
}
