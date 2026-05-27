import Foundation
import Observation

/// Sidebar kind filter for the History view. `.all` shows everything; the
/// other cases narrow to one ClipboardArchive.EntryKind.
enum HistoryKindFilter: String, CaseIterable, Sendable {
    case all
    case session
    case clipboard

    var label: String {
        switch self {
        case .all: return "All"
        case .session: return "Voice Sessions"
        case .clipboard: return "Clipboard"
        }
    }
}

/// Sidebar time bucket filter. Buckets are computed from each entry's
/// ISO timestamp at filter time (not stored). `.recent` is the default and
/// matches the loaded window; `.all` is the explicit "load everything,
/// including cold" trigger.
enum HistoryTimeBucket: String, CaseIterable, Sendable {
    case recent
    case today
    case yesterday
    case older
    case all

    var label: String {
        switch self {
        case .recent: return "Last 2 weeks"
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .older: return "Older"
        case .all: return "All Time"
        }
    }
}

/// Identifiable wrapper around `ClipboardArchive.Entry`. The id is derived
/// from timestamp + kind + position so SwiftUI selection survives reload
/// even though the archive itself is positional.
struct HistoryEntryViewItem: Identifiable, Equatable, Sendable {
    let index: Int
    let timestamp: String
    let kind: ClipboardArchive.EntryKind
    let content: String
    /// Cross-reference to a `TraceEntry.id`. Set when this clipboard entry
    /// was produced by a recording session that wrote to TraceStore.
    let traceId: String?
    /// Parsed once at construction. `ISO8601DateFormatter` is expensive, and
    /// bucketing + clock labels touch every loaded entry on each filter change;
    /// caching here keeps the History view responsive at thousands of entries.
    let parsedDate: Date?

    init(
        index: Int,
        timestamp: String,
        kind: ClipboardArchive.EntryKind,
        content: String,
        traceId: String? = nil
    ) {
        self.index = index
        self.timestamp = timestamp
        self.kind = kind
        self.content = content
        self.traceId = traceId
        self.parsedDate = Self.iso8601Parser.date(from: timestamp)
    }

    var id: String { "\(timestamp)|\(kind.rawValue)|\(index)" }

    var preview: String {
        let oneLine = content
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return String(oneLine.prefix(120))
    }

    var clockLabel: String {
        guard let date = parsedDate else { return timestamp }
        return Self.clockFormatter.string(from: date)
    }

    private static let iso8601Parser = ISO8601DateFormatter()
    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d, HH:mm:ss"
        return f
    }()
}

/// Provider abstraction so the view model can be unit-tested with an
/// in-memory fixture instead of touching the real archive file.
protocol ClipboardArchiveProviding: AnyObject {
    func entries() -> [ClipboardArchive.Entry]
    /// Windowed read: only entries at or newer than `cutoff`. `nil` = full set.
    func entries(since cutoff: Date?) -> [ClipboardArchive.Entry]
    @discardableResult func restore(at index: Int) -> Bool
    @discardableResult func delete(at index: Int) -> Bool
    func clear()
    var archiveURL: URL { get }
}

extension ClipboardArchiveProviding {
    /// Default in-memory windowing for fixtures. The real `ClipboardArchive`
    /// overrides this with an early-exit parse that avoids scanning the tail.
    /// Unparseable timestamps are kept so they stay reachable.
    func entries(since cutoff: Date?) -> [ClipboardArchive.Entry] {
        let all = entries()
        guard let cutoff else { return all }
        let parser = ISO8601DateFormatter()
        return all.filter { entry in
            guard let date = parser.date(from: entry.timestamp) else { return true }
            return date >= cutoff
        }
    }
}

extension ClipboardArchive: ClipboardArchiveProviding {}

/// MainActor `@Observable` adapter over `ClipboardArchive`. Owns the sidebar
/// filter state and exposes filtered + selected derived values to SwiftUI.
@MainActor
@Observable
final class ClipboardArchiveViewModel {
    private(set) var entries: [HistoryEntryViewItem] = []
    private(set) var filteredEntries: [HistoryEntryViewItem] = []
    private(set) var kindCounts: [HistoryKindFilter: Int] = [:]
    private(set) var bucketCounts: [HistoryTimeBucket: Int] = [:]

    var kindFilter: HistoryKindFilter = .all { didSet { recomputeFiltered() } }
    /// Defaults to `.recent` (the loaded window). Selecting `.all` while only a
    /// window is loaded triggers a one-time cold load of the full archive, so
    /// "All Time" never silently lies about showing everything.
    var timeBucket: HistoryTimeBucket = .recent {
        didSet {
            if timeBucket == .all && isWindowed {
                loadAllColdEntries()
            } else {
                recomputeFiltered()
            }
        }
    }
    var selectedEntryID: String?
    private(set) var lastError: String?

    /// Default load window in days. `reload()` only parses entries newer than
    /// `now() - windowDays`; older entries stay cold until `loadAllColdEntries()`.
    /// `nil` means the full cold archive is loaded.
    nonisolated static let defaultWindowDays = 14
    private(set) var windowDays: Int? = ClipboardArchiveViewModel.defaultWindowDays

    /// True while a bounded window is loaded — i.e. older (cold) entries may
    /// exist on disk but aren't loaded yet. The view shows a "Load older"
    /// affordance based on this.
    var isWindowed: Bool { windowDays != nil }

    /// `now` is injected so tests can pin "today" without time travel.
    var now: () -> Date = Date.init

    /// Calendar used for the day-bucket comparison. Tests pin this to UTC so
    /// the same fixture timestamps land in deterministic buckets regardless
    /// of the host's timezone.
    var calendar: Calendar = .current { didSet { recomputeAll() } }

    var archiveURL: URL { archive.archiveURL }

    private var entryByID: [String: HistoryEntryViewItem] = [:]
    private let archive: any ClipboardArchiveProviding

    init(archive: any ClipboardArchiveProviding = ClipboardArchive.shared) {
        self.archive = archive
    }

    /// Cutoff for the current window, or `nil` when the full archive is loaded.
    var windowCutoff: Date? {
        guard let windowDays else { return nil }
        return calendar.date(byAdding: .day, value: -windowDays, to: now())
            ?? now().addingTimeInterval(-Double(windowDays) * 86_400)
    }

    /// Load the full cold archive (drops the window) and refresh. Triggered by
    /// the "Load older" action in the History view.
    func loadAllColdEntries() {
        windowDays = nil
        reload()
    }

    /// Reset back to the bounded default window (e.g. on next open). Mainly for
    /// tests and future UI; not wired to a button today.
    func resetWindow(days: Int? = ClipboardArchiveViewModel.defaultWindowDays) {
        windowDays = days
        reload()
    }

    func reload() {
        let raw = archive.entries(since: windowCutoff)
        entries = raw.enumerated().map { idx, e in
            HistoryEntryViewItem(
                index: idx,
                timestamp: e.timestamp,
                kind: e.kind,
                content: e.content,
                traceId: e.traceId
            )
        }
        entryByID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        recomputeAll()
        if let id = selectedEntryID, entryByID[id] == nil {
            selectedEntryID = filteredEntries.first?.id
        } else if selectedEntryID == nil {
            selectedEntryID = filteredEntries.first?.id
        }
        lastError = nil
    }

    var selectedEntry: HistoryEntryViewItem? {
        guard let id = selectedEntryID else { return nil }
        return entryByID[id]
    }

    func count(forBucket bucket: HistoryTimeBucket) -> Int {
        bucketCounts[bucket] ?? 0
    }

    func count(forKind kind: HistoryKindFilter) -> Int {
        kindCounts[kind] ?? 0
    }

    // MARK: - Mutations

    func restore(_ entry: HistoryEntryViewItem) -> Bool {
        let ok = archive.restore(at: entry.index)
        if !ok { lastError = "Restore failed" }
        return ok
    }

    func delete(_ entry: HistoryEntryViewItem) {
        _ = archive.delete(at: entry.index)
        reload()
    }

    func clearAll() {
        archive.clear()
        reload()
    }

    // MARK: - Derivation

    private func recomputeAll() {
        recomputeFiltered()
        recomputeCounts()
    }

    private func recomputeFiltered() {
        filteredEntries = entries.filter { matchesKind($0) && matchesBucket($0) }
        // If selection fell out of the filtered set, point at first visible.
        if let id = selectedEntryID, !filteredEntries.contains(where: { $0.id == id }) {
            selectedEntryID = filteredEntries.first?.id
        }
    }

    private func recomputeCounts() {
        var kc: [HistoryKindFilter: Int] = [.all: entries.count, .session: 0, .clipboard: 0]
        var bc: [HistoryTimeBucket: Int] = [
            .all: entries.count, .recent: 0, .today: 0, .yesterday: 0, .older: 0
        ]
        let cutoff = recentCutoff
        for item in entries {
            switch item.kind {
            case .session: kc[.session, default: 0] += 1
            case .clipboard: kc[.clipboard, default: 0] += 1
            }
            if isRecent(item, cutoff: cutoff) { bc[.recent, default: 0] += 1 }
            switch dayBucket(for: item) {
            case .today: bc[.today, default: 0] += 1
            case .yesterday: bc[.yesterday, default: 0] += 1
            case .older: bc[.older, default: 0] += 1
            case .recent, .all: break
            }
        }
        kindCounts = kc
        bucketCounts = bc
    }

    // MARK: - Filter helpers

    private func matchesKind(_ item: HistoryEntryViewItem) -> Bool {
        switch kindFilter {
        case .all: return true
        case .session: return item.kind == .session
        case .clipboard: return item.kind == .clipboard
        }
    }

    private func matchesBucket(_ item: HistoryEntryViewItem) -> Bool {
        switch timeBucket {
        case .all: return true
        case .recent: return isRecent(item, cutoff: recentCutoff)
        case .today, .yesterday, .older: return dayBucket(for: item) == timeBucket
        }
    }

    /// `.recent` cutoff is always the default window back from `now`, even after
    /// the cold archive is loaded — so switching to "All Time" and back to
    /// "Last 2 weeks" filters in place without re-windowing the load.
    private var recentCutoff: Date {
        calendar.date(byAdding: .day, value: -Self.defaultWindowDays, to: now())
            ?? now().addingTimeInterval(-Double(Self.defaultWindowDays) * 86_400)
    }

    /// Entries with an unparseable timestamp are not "recent" (they sort into
    /// `.older` / `.all`), matching `dayBucket`'s fallback.
    private func isRecent(_ item: HistoryEntryViewItem, cutoff: Date) -> Bool {
        guard let date = item.parsedDate else { return false }
        return date >= cutoff
    }

    /// Bucket for `item` against the injected clock + calendar. Unparseable
    /// timestamps fall into `.older` so the entry stays reachable.
    private func dayBucket(for item: HistoryEntryViewItem) -> HistoryTimeBucket {
        guard let date = item.parsedDate else { return .older }
        let nowDate = now()
        if calendar.isDate(date, inSameDayAs: nowDate) { return .today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: nowDate),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return .yesterday
        }
        return .older
    }
}
