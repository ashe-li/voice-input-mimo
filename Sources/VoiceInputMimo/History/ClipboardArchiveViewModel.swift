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

/// Identifiable wrapper around `ClipboardArchive.Entry` so SwiftUI `List` /
/// `LazyVGrid` selection has a stable id (timestamp+kind, since the archive
/// itself is positional).
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

    /// Pretty-printed clock label rendered on the card.
    var clockLabel: String {
        let parser = ISO8601DateFormatter()
        guard let date = parser.date(from: timestamp) else { return timestamp }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d, HH:mm:ss"
        return f.string(from: date)
    }

    fileprivate func parsedDate() -> Date? {
        ISO8601DateFormatter().date(from: timestamp)
    }
}

/// Provider abstraction so the view model can be unit-tested with an
/// in-memory fixture instead of touching the real archive file.
protocol ClipboardArchiveProviding: AnyObject {
    func entries() -> [ClipboardArchive.Entry]
    @discardableResult func restore(at index: Int) -> Bool
    @discardableResult func delete(at index: Int) -> Bool
    func clear()
}

extension ClipboardArchive: ClipboardArchiveProviding {}

/// MainActor `@Observable` adapter over `ClipboardArchive`. Owns the sidebar
/// filter state and exposes filtered + selected derived values to SwiftUI.
@MainActor
@Observable
final class ClipboardArchiveViewModel {
    private(set) var entries: [HistoryEntryViewItem] = []
    var kindFilter: HistoryKindFilter = .all
    var timeBucket: HistoryTimeBucket = .all
    var selectedEntryID: String?
    private(set) var lastError: String?

    /// `now` is injected so tests can pin "today" without time travel.
    var now: () -> Date = Date.init

    /// Calendar used for the day-bucket comparison. Tests pin this to UTC so
    /// the same fixture timestamps land in deterministic buckets regardless
    /// of the host's timezone.
    var calendar: Calendar = .current

    private let archive: any ClipboardArchiveProviding

    init(archive: any ClipboardArchiveProviding = ClipboardArchive.shared) {
        self.archive = archive
    }

    /// Reload from the archive. Called from `.task {}` on appearance, after
    /// restore/delete/clear, and on Refresh button.
    func reload() {
        let raw = archive.entries()
        entries = raw.enumerated().map { idx, e in
            HistoryEntryViewItem(index: idx, timestamp: e.timestamp, kind: e.kind, content: e.content)
        }
        // Keep the selection valid if the underlying entry survived the reload.
        if let id = selectedEntryID, !entries.contains(where: { $0.id == id }) {
            selectedEntryID = entries.first?.id
        } else if selectedEntryID == nil {
            selectedEntryID = entries.first?.id
        }
        lastError = nil
    }

    /// Filtered list view, applying kind + time bucket.
    var filteredEntries: [HistoryEntryViewItem] {
        entries.filter { matchesKind($0) && matchesBucket($0) }
    }

    /// Currently selected entry, or nil if selection got dropped.
    var selectedEntry: HistoryEntryViewItem? {
        guard let id = selectedEntryID else { return nil }
        return entries.first { $0.id == id }
    }

    /// Per-bucket counts, used by the sidebar to show e.g. "Today (12)".
    func count(forBucket bucket: HistoryTimeBucket) -> Int {
        switch bucket {
        case .all: return entries.count
        default: return entries.filter { matchesBucket($0, override: bucket) }.count
        }
    }

    func count(forKind kind: HistoryKindFilter) -> Int {
        switch kind {
        case .all: return entries.count
        case .session: return entries.filter { $0.kind == .session }.count
        case .clipboard: return entries.filter { $0.kind == .clipboard }.count
        }
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

    // MARK: - Filter helpers

    private func matchesKind(_ item: HistoryEntryViewItem) -> Bool {
        switch kindFilter {
        case .all: return true
        case .session: return item.kind == .session
        case .clipboard: return item.kind == .clipboard
        }
    }

    private func matchesBucket(_ item: HistoryEntryViewItem, override: HistoryTimeBucket? = nil) -> Bool {
        let bucket = override ?? timeBucket
        if bucket == .all { return true }
        guard let date = item.parsedDate() else {
            // Unparseable timestamps fall into "older" so they're still reachable.
            return bucket == .older
        }
        let nowDate = now()
        if calendar.isDate(date, inSameDayAs: nowDate) {
            return bucket == .today
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: nowDate),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return bucket == .yesterday
        }
        return bucket == .older
    }
}
