import XCTest
@testable import VoiceInputMimo

/// File-scope so it can be used inside `vm.now` closures without an implicit
/// `self` capture.
private func iso(_ s: String) -> Date {
    ISO8601DateFormatter().date(from: s)!
}

@MainActor
final class ClipboardArchiveViewModelTests: XCTestCase {
    func test_initialState_isEmpty() {
        let archive = MockClipboardArchive()
        let vm = ClipboardArchiveViewModel(archive: archive)
        XCTAssertTrue(vm.entries.isEmpty)
        XCTAssertTrue(vm.filteredEntries.isEmpty)
        XCTAssertEqual(vm.kindFilter, .all)
        XCTAssertEqual(vm.timeBucket, .recent)
        XCTAssertNil(vm.selectedEntryID)
    }

    func test_reload_populatesEntries_andSelectsFirst() {
        let archive = MockClipboardArchive(entries: [
            entry("2026-05-10T10:00:00Z", .session, "hello"),
            entry("2026-05-10T09:00:00Z", .clipboard, "world")
        ])
        let vm = ClipboardArchiveViewModel(archive: archive)
        vm.now = { iso("2026-05-10T11:00:00Z") }
        vm.reload()
        XCTAssertEqual(vm.entries.count, 2)
        XCTAssertEqual(vm.selectedEntry?.content, "hello")
    }

    func test_kindFilter_session_excludesClipboard() {
        let archive = MockClipboardArchive(entries: [
            entry("2026-05-10T10:00:00Z", .session, "voice"),
            entry("2026-05-10T09:00:00Z", .clipboard, "copy")
        ])
        let vm = ClipboardArchiveViewModel(archive: archive)
        vm.now = { iso("2026-05-10T11:00:00Z") }
        vm.reload()

        vm.kindFilter = .session
        XCTAssertEqual(vm.filteredEntries.map(\.content), ["voice"])

        vm.kindFilter = .clipboard
        XCTAssertEqual(vm.filteredEntries.map(\.content), ["copy"])

        vm.kindFilter = .all
        XCTAssertEqual(vm.filteredEntries.count, 2)
    }

    func test_timeBucket_today_yesterday_older() {
        let nowFixture = ISO8601DateFormatter().date(from: "2026-05-10T20:00:00Z")!
        let archive = MockClipboardArchive(entries: [
            entry("2026-05-10T08:00:00Z", .session, "today entry"),
            entry("2026-05-09T12:00:00Z", .session, "yesterday entry"),
            entry("2026-05-01T08:00:00Z", .clipboard, "older entry")
        ])
        let vm = ClipboardArchiveViewModel(archive: archive)
        vm.now = { nowFixture }
        vm.calendar = utcCalendar()
        vm.reload()

        vm.timeBucket = .today
        XCTAssertEqual(vm.filteredEntries.map(\.content), ["today entry"])

        vm.timeBucket = .yesterday
        XCTAssertEqual(vm.filteredEntries.map(\.content), ["yesterday entry"])

        vm.timeBucket = .older
        XCTAssertEqual(vm.filteredEntries.map(\.content), ["older entry"])

        vm.timeBucket = .all
        XCTAssertEqual(vm.filteredEntries.count, 3)
    }

    func test_kindAndBucket_intersection() {
        let nowFixture = ISO8601DateFormatter().date(from: "2026-05-10T20:00:00Z")!
        let archive = MockClipboardArchive(entries: [
            entry("2026-05-10T08:00:00Z", .session, "today voice"),
            entry("2026-05-10T09:00:00Z", .clipboard, "today copy"),
            entry("2026-05-09T08:00:00Z", .session, "yesterday voice")
        ])
        let vm = ClipboardArchiveViewModel(archive: archive)
        vm.now = { nowFixture }
        vm.calendar = utcCalendar()
        vm.reload()
        vm.kindFilter = .session
        vm.timeBucket = .today
        XCTAssertEqual(vm.filteredEntries.map(\.content), ["today voice"])
    }

    func test_count_perKind_andPerBucket() {
        let nowFixture = ISO8601DateFormatter().date(from: "2026-05-10T20:00:00Z")!
        let archive = MockClipboardArchive(entries: [
            entry("2026-05-10T08:00:00Z", .session, "v"),
            entry("2026-05-10T09:00:00Z", .clipboard, "c"),
            entry("2026-05-09T08:00:00Z", .session, "v2"),
            entry("2026-05-01T08:00:00Z", .clipboard, "c2")
        ])
        let vm = ClipboardArchiveViewModel(archive: archive)
        vm.now = { nowFixture }
        vm.calendar = utcCalendar()
        vm.reload()
        XCTAssertEqual(vm.count(forKind: .all), 4)
        XCTAssertEqual(vm.count(forKind: .session), 2)
        XCTAssertEqual(vm.count(forKind: .clipboard), 2)
        XCTAssertEqual(vm.count(forBucket: .today), 2)
        XCTAssertEqual(vm.count(forBucket: .yesterday), 1)
        XCTAssertEqual(vm.count(forBucket: .older), 1)
    }

    func test_restore_callsArchiveAndReturnsResult() {
        let archive = MockClipboardArchive(entries: [
            entry("2026-05-10T10:00:00Z", .session, "hello")
        ])
        let vm = ClipboardArchiveViewModel(archive: archive)
        vm.now = { iso("2026-05-10T11:00:00Z") }
        vm.reload()
        let item = vm.entries.first!
        XCTAssertTrue(vm.restore(item))
        XCTAssertEqual(archive.restoreCallIndices, [0])
    }

    func test_delete_reloadsArchive_andDropsEntry() {
        let archive = MockClipboardArchive(entries: [
            entry("2026-05-10T10:00:00Z", .session, "a"),
            entry("2026-05-10T09:00:00Z", .clipboard, "b")
        ])
        let vm = ClipboardArchiveViewModel(archive: archive)
        vm.now = { iso("2026-05-10T11:00:00Z") }
        vm.reload()
        let first = vm.entries.first!
        vm.delete(first)
        XCTAssertEqual(vm.entries.count, 1)
        XCTAssertEqual(vm.entries.first?.content, "b")
    }

    func test_clearAll_emptiesArchive() {
        let archive = MockClipboardArchive(entries: [
            entry("2026-05-10T10:00:00Z", .session, "a")
        ])
        let vm = ClipboardArchiveViewModel(archive: archive)
        vm.now = { iso("2026-05-10T11:00:00Z") }
        vm.reload()
        vm.clearAll()
        XCTAssertTrue(vm.entries.isEmpty)
    }

    func test_reload_propagatesTraceIdToViewItem() {
        let archive = MockClipboardArchive(entries: [
            ClipboardArchive.Entry(
                timestamp: "2026-05-14T10:00:00Z",
                kind: .session,
                content: "linked",
                traceId: "trace-abc12345"
            ),
            ClipboardArchive.Entry(
                timestamp: "2026-05-14T09:00:00Z",
                kind: .clipboard,
                content: "unlinked"
            )
        ])
        let vm = ClipboardArchiveViewModel(archive: archive)
        vm.now = { iso("2026-05-14T11:00:00Z") }
        vm.reload()
        XCTAssertEqual(vm.entries[0].traceId, "trace-abc12345")
        XCTAssertNil(vm.entries[1].traceId)
    }

    func test_unparseableTimestamp_fallsIntoOlderBucket() {
        let archive = MockClipboardArchive(entries: [
            entry("not-a-timestamp", .session, "weird")
        ])
        let vm = ClipboardArchiveViewModel(archive: archive)
        vm.reload()
        vm.timeBucket = .older
        XCTAssertEqual(vm.filteredEntries.count, 1)
        vm.timeBucket = .today
        XCTAssertEqual(vm.filteredEntries.count, 0)
    }

    // MARK: - Windowing (default 2-week load + cold load on demand)

    func test_reload_defaultWindow_loadsOnlyRecentEntries() {
        let archive = MockClipboardArchive(entries: [
            entry("2026-05-27T08:00:00Z", .session, "recent"),
            entry("2026-05-20T08:00:00Z", .clipboard, "within window"),
            entry("2026-05-01T08:00:00Z", .clipboard, "cold"),
            entry("2026-04-01T08:00:00Z", .session, "very cold")
        ])
        let vm = ClipboardArchiveViewModel(archive: archive)
        vm.now = { iso("2026-05-27T20:00:00Z") }
        vm.reload()
        // Default 14-day window cuts off at 2026-05-13.
        XCTAssertTrue(vm.isWindowed)
        XCTAssertEqual(vm.entries.map(\.content), ["recent", "within window"])
    }

    func test_loadAllColdEntries_loadsEverything_andClearsWindow() {
        let archive = MockClipboardArchive(entries: [
            entry("2026-05-27T08:00:00Z", .session, "recent"),
            entry("2026-05-01T08:00:00Z", .clipboard, "cold"),
            entry("2026-04-01T08:00:00Z", .session, "very cold")
        ])
        let vm = ClipboardArchiveViewModel(archive: archive)
        vm.now = { iso("2026-05-27T20:00:00Z") }
        vm.reload()
        XCTAssertEqual(vm.entries.count, 1)

        vm.loadAllColdEntries()
        XCTAssertFalse(vm.isWindowed)
        XCTAssertEqual(vm.entries.count, 3)
        XCTAssertEqual(vm.count(forKind: .all), 3)
    }

    func test_defaultBucket_recent_hidesColdWithinLoadedSet() {
        // Even if the loaded set somehow contains an older entry, the default
        // `.recent` filter must not surface it — the user's complaint that the
        // default still showed "All".
        let archive = MockClipboardArchive(entries: [
            entry("2026-05-27T08:00:00Z", .session, "recent"),
            entry("2026-05-01T08:00:00Z", .clipboard, "old")
        ])
        let vm = ClipboardArchiveViewModel(archive: archive)
        vm.now = { iso("2026-05-27T20:00:00Z") }
        vm.loadAllColdEntries()           // full set loaded (both entries)
        vm.timeBucket = .recent           // but default filter is recent-only
        XCTAssertEqual(vm.filteredEntries.map(\.content), ["recent"])
        XCTAssertEqual(vm.count(forBucket: .recent), 1)
    }

    func test_selectingAllTime_triggersColdLoad() {
        let archive = MockClipboardArchive(entries: [
            entry("2026-05-27T08:00:00Z", .session, "recent"),
            entry("2026-05-01T08:00:00Z", .clipboard, "cold")
        ])
        let vm = ClipboardArchiveViewModel(archive: archive)
        vm.now = { iso("2026-05-27T20:00:00Z") }
        vm.reload()
        XCTAssertEqual(vm.entries.count, 1)   // windowed: only recent
        XCTAssertTrue(vm.isWindowed)

        vm.timeBucket = .all                  // "All Time" loads everything
        XCTAssertFalse(vm.isWindowed)
        XCTAssertEqual(vm.filteredEntries.count, 2)
    }

    func test_windowCutoff_nilWhenColdLoaded() {
        let vm = ClipboardArchiveViewModel(archive: MockClipboardArchive())
        XCTAssertNotNil(vm.windowCutoff)
        vm.loadAllColdEntries()
        XCTAssertNil(vm.windowCutoff)
    }

    func test_parsedDate_isCachedOnViewItem() {
        let item = HistoryEntryViewItem(
            index: 0,
            timestamp: "2026-05-14T10:00:00Z",
            kind: .session,
            content: "x"
        )
        XCTAssertEqual(item.parsedDate, iso("2026-05-14T10:00:00Z"))
        let bad = HistoryEntryViewItem(index: 0, timestamp: "nope", kind: .session, content: "x")
        XCTAssertNil(bad.parsedDate)
        XCTAssertEqual(bad.clockLabel, "nope")
    }

    // MARK: - Helpers

    private func entry(_ ts: String, _ kind: ClipboardArchive.EntryKind, _ content: String) -> ClipboardArchive.Entry {
        ClipboardArchive.Entry(timestamp: ts, kind: kind, content: content)
    }

    private func utcCalendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        return cal
    }
}

/// In-memory fixture for `ClipboardArchiveProviding`. Tracks restore/delete
/// calls so tests can assert the view model wired through correctly.
final class MockClipboardArchive: ClipboardArchiveProviding, @unchecked Sendable {
    private var stored: [ClipboardArchive.Entry]
    var restoreCallIndices: [Int] = []
    var deleteCallIndices: [Int] = []
    var clearCalls: Int = 0
    var archiveURL: URL = URL(fileURLWithPath: "/tmp/mock-clipboard-archive.txt")

    init(entries: [ClipboardArchive.Entry] = []) {
        self.stored = entries
    }

    func entries() -> [ClipboardArchive.Entry] { stored }

    @discardableResult
    func restore(at index: Int) -> Bool {
        restoreCallIndices.append(index)
        return stored.indices.contains(index)
    }

    @discardableResult
    func delete(at index: Int) -> Bool {
        deleteCallIndices.append(index)
        guard stored.indices.contains(index) else { return false }
        stored.remove(at: index)
        return true
    }

    func clear() {
        clearCalls += 1
        stored.removeAll()
    }
}
