import XCTest
@testable import VoiceInputMimo

final class TraceStoreTests: XCTestCase {

    private var tempRoot: URL!
    private var store: TraceStore!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("trace-store-tests-\(UUID().uuidString)")
        store = TraceStore(rootDirectory: tempRoot)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    func testLoadAllReturnsEmptyWhenFileMissing() throws {
        XCTAssertTrue(try store.loadAll().isEmpty)
    }

    func testAppendThenLoad() throws {
        let entry = TraceEntry(
            id: "trace-1",
            asrText: "你好",
            llmText: "Hello",
            mode: "claudeCode"
        )
        try store.append(entry)
        let loaded = try store.loadAll()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.id, "trace-1")
        XCTAssertEqual(loaded.first?.asrText, "你好")
        XCTAssertEqual(loaded.first?.llmText, "Hello")
        XCTAssertEqual(loaded.first?.mode, "claudeCode")
    }

    func testMultipleAppendsPreserveOrder() throws {
        try store.append(TraceEntry(id: "trace-1", asrText: "a"))
        try store.append(TraceEntry(id: "trace-2", asrText: "b"))
        try store.append(TraceEntry(id: "trace-3", asrText: "c"))
        let loaded = try store.loadAll()
        XCTAssertEqual(loaded.map(\.id), ["trace-1", "trace-2", "trace-3"])
    }

    func testSaveAllOverwritesExisting() throws {
        try store.append(TraceEntry(id: "trace-1", asrText: "a"))
        try store.saveAll([TraceEntry(id: "trace-X", asrText: "x")])
        XCTAssertEqual(try store.loadAll().map(\.id), ["trace-X"])
    }

    func testSaveAllEmptyTrimsFile() throws {
        try store.append(TraceEntry(id: "trace-1", asrText: "a"))
        try store.saveAll([])
        XCTAssertTrue(try store.loadAll().isEmpty)
    }

    func testDeleteRemovesById() throws {
        try store.append(TraceEntry(id: "trace-1", asrText: "a"))
        try store.append(TraceEntry(id: "trace-2", asrText: "b"))
        try store.delete(id: "trace-1")
        XCTAssertEqual(try store.loadAll().map(\.id), ["trace-2"])
    }

    func testUpdateReplacesById() throws {
        try store.append(TraceEntry(id: "trace-1", asrText: "before"))
        var changed = TraceEntry(id: "trace-1", asrText: "after")
        changed.llmText = "after-llm"
        try store.update(changed)
        let loaded = try store.loadAll()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.asrText, "after")
        XCTAssertEqual(loaded.first?.llmText, "after-llm")
    }

    func testUpdateUnknownIdAppends() throws {
        try store.append(TraceEntry(id: "trace-1", asrText: "a"))
        try store.update(TraceEntry(id: "trace-new", asrText: "new"))
        XCTAssertEqual(try store.loadAll().map(\.id), ["trace-1", "trace-new"])
    }

    func testMalformedLinesAreSkipped() throws {
        let url = tempRoot.appendingPathComponent("traces.jsonl")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let goodLine = """
            {"id":"trace-1","startedAt":"2026-05-14T00:00:00Z","asrText":"ok","logEntries":[]}
            """
        let mixed = goodLine + "\nnot-json-at-all\n" + goodLine.replacingOccurrences(of: "trace-1", with: "trace-2") + "\n"
        try Data(mixed.utf8).write(to: url)
        let loaded = try store.loadAll()
        XCTAssertEqual(loaded.map(\.id), ["trace-1", "trace-2"])
    }

    func testLogEntriesRoundTrip() throws {
        let stamp = Date(timeIntervalSinceReferenceDate: 100)
        let trace = TraceEntry(
            id: "trace-1",
            asrText: "x",
            logEntries: [
                .init(timestamp: stamp, stage: .start),
                .init(timestamp: stamp.addingTimeInterval(2), stage: .asrDone, note: "0.5s"),
            ]
        )
        try store.append(trace)
        let loaded = try store.loadAll()
        XCTAssertEqual(loaded.first?.logEntries.count, 2)
        XCTAssertEqual(loaded.first?.logEntries.first?.stage, .start)
        XCTAssertEqual(loaded.first?.logEntries.last?.note, "0.5s")
    }
}
