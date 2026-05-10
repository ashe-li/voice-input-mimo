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
/// ISO timestamp at filter time (not stored).
enum HistoryTimeBucket: String, CaseIterable, Sendable {
    case all
    case today
    case yesterday
    case older

    var label: String {
        switch self {
        case .all: return "All Time"
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .older: return "Older"
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

    var id: String { "\(timestamp)|\(kind.rawValue)|\(index)" }

    var preview: String {
        let oneLine = content
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return String(oneLine.prefix(120))
    }

    var clockLabel: String {
        guard let date = Self.iso8601Parser.date(from: timestamp) else { return timestamp }
        return Self.clockFormatter.string(from: date)
    }

    fileprivate func parsedDate() -> Date? {
        Self.iso8601Parser.date(from: timestamp)
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
    @discardableResult func restore(at index: Int) -> Bool
    @discardableResult func delete(at index: Int) -> Bool
    func clear()
    var archiveURL: URL { get }
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
    var timeBucket: HistoryTimeBucket = .all { didSet { recomputeFiltered() } }
    var selectedEntryID: String?
    private(set) var lastError: String?

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

    func reload() {
        let raw = archive.entries()
        entries = raw.enumerated().map { idx, e in
            HistoryEntryViewItem(index: idx, timestamp: e.timestamp, kind: e.kind, content: e.content)
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
        var bc: [HistoryTimeBucket: Int] = [.all: entries.count, .today: 0, .yesterday: 0, .older: 0]
        for item in entries {
            switch item.kind {
            case .session: kc[.session, default: 0] += 1
            case .clipboard: kc[.clipboard, default: 0] += 1
            }
            switch dayBucket(for: item) {
            case .today: bc[.today, default: 0] += 1
            case .yesterday: bc[.yesterday, default: 0] += 1
            case .older: bc[.older, default: 0] += 1
            case .all: break
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
        timeBucket == .all || dayBucket(for: item) == timeBucket
    }

    /// Bucket for `item` against the injected clock + calendar. Unparseable
    /// timestamps fall into `.older` so the entry stays reachable.
    private func dayBucket(for item: HistoryEntryViewItem) -> HistoryTimeBucket {
        guard let date = item.parsedDate() else { return .older }
        let nowDate = now()
        if calendar.isDate(date, inSameDayAs: nowDate) { return .today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: nowDate),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return .yesterday
        }
        return .older
    }
}
