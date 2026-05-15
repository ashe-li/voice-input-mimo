import XCTest
@testable import VoiceInputMimo

final class FixtureExporterTests: XCTestCase {
    private var tempRoot: URL!
    private var storeDir: URL!
    private var exportDir: URL!
    private var store: TraceStore!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("fixture-exporter-tests-\(UUID().uuidString)")
        storeDir = tempRoot.appendingPathComponent("store")
        exportDir = tempRoot.appendingPathComponent("export")
        store = TraceStore(rootDirectory: storeDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeFakeWav(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(count: 1024).write(to: url)
    }

    private func makeEntry(
        id: String,
        audioPath: String?,
        asrText: String,
        durationSeconds: Double = 2.0
    ) -> TraceEntry {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        return TraceEntry(
            id: id,
            startedAt: start,
            endedAt: start.addingTimeInterval(durationSeconds),
            audioPath: audioPath,
            asrText: asrText
        )
    }

    // MARK: - Test 1: exports entries with audio + asrText

    func testExportsEntriesWithAudioAndAsrText() throws {
        let wav1 = storeDir.appendingPathComponent("audio/trace-1.wav")
        let wav2 = storeDir.appendingPathComponent("audio/trace-2.wav")
        try makeFakeWav(at: wav1)
        try makeFakeWav(at: wav2)

        try store.append(makeEntry(id: "trace-1", audioPath: wav1.path, asrText: "hello world"))
        try store.append(makeEntry(id: "trace-2", audioPath: wav2.path, asrText: "foo bar"))

        let results = try FixtureExporter.exportAll(from: store, destination: exportDir)

        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.allSatisfy { $0.skippedReason == nil }, "all should be exported")

        let audioDir = exportDir.appendingPathComponent("audio")
        let transcriptDir = exportDir.appendingPathComponent("transcripts")

        XCTAssertTrue(FileManager.default.fileExists(atPath: audioDir.appendingPathComponent("trace-1.wav").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioDir.appendingPathComponent("trace-2.wav").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: transcriptDir.appendingPathComponent("trace-1.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: transcriptDir.appendingPathComponent("trace-2.txt").path))

        let txt1 = try String(contentsOf: transcriptDir.appendingPathComponent("trace-1.txt"), encoding: .utf8)
        XCTAssertEqual(txt1, "hello world")
        let txt2 = try String(contentsOf: transcriptDir.appendingPathComponent("trace-2.txt"), encoding: .utf8)
        XCTAssertEqual(txt2, "foo bar")
    }

    // MARK: - Test 2: skips entries missing audioPath

    func testSkipsEntriesMissingAudioPath() throws {
        try store.append(makeEntry(id: "trace-nil", audioPath: nil, asrText: "text"))

        let results = try FixtureExporter.exportAll(from: store, destination: exportDir)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].skippedReason, "no audio path")
        XCTAssertNil(results[0].wavDestination)
        XCTAssertNil(results[0].transcriptDestination)
    }

    // MARK: - Test 3: skips entries with missing audio file (no archive copy)

    func testSkipsEntriesMissingAudioFile() throws {
        try store.append(makeEntry(id: "trace-missing", audioPath: "/nonexistent/path.wav", asrText: "text"))

        // Inject lookup that never finds anything — test must not depend on
        // the real `~/Library/.../recordings/` directory contents.
        let results = try FixtureExporter.exportAll(
            from: store,
            destination: exportDir,
            archiveLookup: { _ in nil }
        )

        XCTAssertEqual(results.count, 1)
        XCTAssertNotNil(results[0].skippedReason)
        XCTAssertTrue(
            results[0].skippedReason?.contains("missing") == true,
            "skippedReason should contain 'missing', got: \(results[0].skippedReason ?? "nil")"
        )
    }

    // MARK: - Test 3b: archive fallback rescues stale tmp audioPath

    func testArchiveFallbackResolvesStaleTmpAudioPath() throws {
        // Simulate: trace audioPath points at a now-deleted tmp wav, but the
        // archive directory still has a timestamp-prefixed copy.
        let staleAudioPath = "/var/folders/fake/T/voice-input-mimo-ABCDEF.wav"
        let archiveDir = tempRoot.appendingPathComponent("recordings")
        let archivedFile = archiveDir.appendingPathComponent("20260515-120000-voice-input-mimo-ABCDEF.wav")
        try makeFakeWav(at: archivedFile)

        try store.append(makeEntry(id: "trace-arch", audioPath: staleAudioPath, asrText: "rescued from archive"))

        let results = try FixtureExporter.exportAll(
            from: store,
            destination: exportDir,
            archiveLookup: { originalName in
                guard let entries = try? FileManager.default.contentsOfDirectory(atPath: archiveDir.path) else {
                    return nil
                }
                if let match = entries.first(where: { $0.hasSuffix(originalName) }) {
                    return archiveDir.appendingPathComponent(match).path
                }
                return nil
            }
        )

        XCTAssertEqual(results.count, 1)
        XCTAssertNil(results[0].skippedReason, "archive fallback should rescue stale tmp path")
        XCTAssertNotNil(results[0].wavDestination)

        let exportedWav = exportDir.appendingPathComponent("audio/trace-arch.wav")
        XCTAssertTrue(FileManager.default.fileExists(atPath: exportedWav.path))
        XCTAssertEqual(try Data(contentsOf: exportedWav).count, 1024)

        let exportedTxt = exportDir.appendingPathComponent("transcripts/trace-arch.txt")
        XCTAssertEqual(try String(contentsOf: exportedTxt, encoding: .utf8), "rescued from archive")
    }

    // MARK: - Test 4: skips empty asrText

    func testSkipsEmptyAsrText() throws {
        let wav = storeDir.appendingPathComponent("audio/trace-empty.wav")
        try makeFakeWav(at: wav)
        try store.append(makeEntry(id: "trace-empty", audioPath: wav.path, asrText: ""))

        let results = try FixtureExporter.exportAll(from: store, destination: exportDir)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].skippedReason, "empty asr text")
    }

    // MARK: - Test 5: skips below min duration

    func testSkipsBelowMinDuration() throws {
        let wav = storeDir.appendingPathComponent("audio/trace-short.wav")
        try makeFakeWav(at: wav)
        try store.append(makeEntry(id: "trace-short", audioPath: wav.path, asrText: "ok", durationSeconds: 0.2))

        let results = try FixtureExporter.exportAll(
            from: store,
            destination: exportDir,
            minDurationSeconds: 0.5
        )

        XCTAssertEqual(results.count, 1)
        XCTAssertNotNil(results[0].skippedReason)
        XCTAssertTrue(
            results[0].skippedReason?.hasPrefix("below min duration:") == true,
            "expected 'below min duration:' prefix, got: \(results[0].skippedReason ?? "nil")"
        )
    }

    // MARK: - Test 6: overwrites existing destination files

    func testOverwritesExistingDestinationFiles() throws {
        let wav = storeDir.appendingPathComponent("audio/trace-ow.wav")
        try makeFakeWav(at: wav)
        try store.append(makeEntry(id: "trace-ow", audioPath: wav.path, asrText: "overwrite me"))

        // Pre-create conflicting file
        let existingAudio = exportDir.appendingPathComponent("audio/trace-ow.wav")
        try FileManager.default.createDirectory(
            at: existingAudio.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([0xFF]).write(to: existingAudio)

        // Should not throw
        let results = try FixtureExporter.exportAll(from: store, destination: exportDir)

        XCTAssertEqual(results.count, 1)
        XCTAssertNil(results[0].skippedReason, "should overwrite without error")

        // File should be replaced with 1024-byte fake wav
        let data = try Data(contentsOf: existingAudio)
        XCTAssertEqual(data.count, 1024)
    }

    // MARK: - Test 7: transcript UTF-8, no trailing newline

    func testTranscriptUTF8NoTrailingNewline() throws {
        let wav = storeDir.appendingPathComponent("audio/trace-utf8.wav")
        try makeFakeWav(at: wav)
        let asrText = "繁體中文 ground truth"
        try store.append(makeEntry(id: "trace-utf8", audioPath: wav.path, asrText: asrText))

        _ = try FixtureExporter.exportAll(from: store, destination: exportDir)

        let txtURL = exportDir.appendingPathComponent("transcripts/trace-utf8.txt")
        let data = try Data(contentsOf: txtURL)
        XCTAssertEqual(data, asrText.data(using: .utf8), "data should be exact UTF-8 with no trailing newline")
    }

    // MARK: - Test 8: creates nested directories

    func testCreatesNestedDirectories() throws {
        let wav = storeDir.appendingPathComponent("audio/trace-dir.wav")
        try makeFakeWav(at: wav)
        try store.append(makeEntry(id: "trace-dir", audioPath: wav.path, asrText: "dir test"))

        // exportDir does not exist yet
        XCTAssertFalse(FileManager.default.fileExists(atPath: exportDir.path))

        _ = try FixtureExporter.exportAll(from: store, destination: exportDir)

        XCTAssertTrue(FileManager.default.fileExists(atPath: exportDir.appendingPathComponent("audio").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: exportDir.appendingPathComponent("transcripts").path))
    }

    // MARK: - Test 9: id with path separator is rejected (M2 path-traversal guard)

    func testSkipsEntryWithSlashInId() throws {
        let wav = storeDir.appendingPathComponent("audio/safe.wav")
        try makeFakeWav(at: wav)
        try store.append(makeEntry(id: "session/2026-05-14", audioPath: wav.path, asrText: "traversal probe"))

        let results = try FixtureExporter.exportAll(from: store, destination: exportDir)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].skippedReason, "invalid id")
        // Crucially, nothing should have been written outside audioDir
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: exportDir.appendingPathComponent("audio/session/2026-05-14.wav").path
        ))
    }

    // MARK: - Test 10: empty id is rejected

    func testSkipsEntryWithEmptyId() throws {
        let wav = storeDir.appendingPathComponent("audio/empty.wav")
        try makeFakeWav(at: wav)
        try store.append(makeEntry(id: "", audioPath: wav.path, asrText: "empty id probe"))

        let results = try FixtureExporter.exportAll(from: store, destination: exportDir)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].skippedReason, "invalid id")
    }
}
