import XCTest
@testable import VoiceInputMimo

final class GlossaryStoreTests: XCTestCase {

    private var tempRoot: URL!
    private var store: GlossaryStore!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("glossary-store-tests-\(UUID().uuidString)")
        store = GlossaryStore(rootDirectory: tempRoot)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    func testLoadAllReturnsEmptyWhenFileMissing() throws {
        let entries = try store.loadAll()
        XCTAssertTrue(entries.isEmpty)
    }

    func testSaveAndLoadRoundTrip() throws {
        let entry = GlossaryEntry(
            id: "term-test1",
            spoken: "vocus",
            canonical: "vocus",
            context: "公司名稱"
        )
        try store.saveAll([entry])
        let loaded = try store.loadAll()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.id, "term-test1")
        XCTAssertEqual(loaded.first?.spoken, "vocus")
        XCTAssertEqual(loaded.first?.canonical, "vocus")
        XCTAssertEqual(loaded.first?.context, "公司名稱")
    }

    func testAddAppendsEntry() throws {
        try store.saveAll([
            GlossaryEntry(id: "term-1", spoken: "A", canonical: "A")
        ])
        try store.add(GlossaryEntry(id: "term-2", spoken: "B", canonical: "B"))
        let loaded = try store.loadAll()
        XCTAssertEqual(loaded.map(\.id), ["term-1", "term-2"])
    }

    func testUpdateReplacesEntryAndBumpsTimestamp() throws {
        let initial = GlossaryEntry(
            id: "term-1",
            spoken: "vcs",
            canonical: "vocus",
            context: "舊註解",
            createdAt: Date(timeIntervalSinceReferenceDate: 0),
            updatedAt: Date(timeIntervalSinceReferenceDate: 0)
        )
        try store.saveAll([initial])
        var changed = initial
        changed.canonical = "VocUS"
        changed.context = "新註解"
        try store.update(changed)

        let loaded = try store.loadAll()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.canonical, "VocUS")
        XCTAssertEqual(loaded.first?.context, "新註解")
        XCTAssertGreaterThan(
            loaded.first!.updatedAt.timeIntervalSinceReferenceDate,
            0,
            "update() must bump updatedAt"
        )
    }

    func testUpdateUnknownIdInsertsAsNew() throws {
        try store.saveAll([])
        let entry = GlossaryEntry(id: "term-new", spoken: "x", canonical: "x")
        try store.update(entry)
        let loaded = try store.loadAll()
        XCTAssertEqual(loaded.map(\.id), ["term-new"])
    }

    func testDeleteRemovesById() throws {
        try store.saveAll([
            GlossaryEntry(id: "term-1", spoken: "A", canonical: "A"),
            GlossaryEntry(id: "term-2", spoken: "B", canonical: "B"),
        ])
        try store.delete(id: "term-1")
        let loaded = try store.loadAll()
        XCTAssertEqual(loaded.map(\.id), ["term-2"])
    }

    func testDeleteUnknownIdIsNoop() throws {
        try store.saveAll([
            GlossaryEntry(id: "term-1", spoken: "A", canonical: "A")
        ])
        try store.delete(id: "does-not-exist")
        let loaded = try store.loadAll()
        XCTAssertEqual(loaded.count, 1)
    }
}
