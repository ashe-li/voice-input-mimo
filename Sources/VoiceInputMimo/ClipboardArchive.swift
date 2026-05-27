import AppKit
import Foundation

/// Persistent clipboard history snapshotted before each paste-injection.
/// Entries can be browsed + restored from the History window.
///
/// Path:  ~/Library/Application Support/VoiceInputMimo/clipboard-archive.txt
/// Layout: append-on-top plain text, separator + ISO timestamp, blank-line tail:
///
///     ─── 2026-05-08T05:43:22Z ───
///     <previous clipboard content>
///
///     ─── 2026-05-08T05:42:11Z ───
///     <previous clipboard content>
///
final class ClipboardArchive {
    static let shared = ClipboardArchive()

    static let separator = "─── "
    private static let maxBytes: Int = 1024 * 1024  // 1 MB cap
    private static let entryTerminator = "\n\n"

    enum EntryKind: String, Equatable {
        case clipboard
        case session

        var displayName: String {
            switch self {
            case .clipboard: return "Clipboard"
            case .session: return "Voice Session"
            }
        }
    }

    struct Entry: Equatable {
        let timestamp: String
        let kind: EntryKind
        let content: String
        /// Optional cross-reference to a `TraceEntry.id`. Serialised in the
        /// header as `trace=<id>`. Nil for entries saved before the trace
        /// pipeline existed (legacy) or for saves that don't originate from
        /// a recording session.
        let traceId: String?

        init(timestamp: String, kind: EntryKind, content: String, traceId: String? = nil) {
            self.timestamp = timestamp
            self.kind = kind
            self.content = content
            self.traceId = traceId
        }

        var preview: String {
            let oneLine = content
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
                .trimmingCharacters(in: .whitespaces)
            return String(oneLine.prefix(120))
        }
    }

    let archiveURL: URL = {
        if let path = ProcessInfo.processInfo.environment["VOICE_INPUT_MIMO_ARCHIVE_PATH"],
           !path.isEmpty {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            return url
        }
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/VoiceInputMimo")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("clipboard-archive.txt")
    }()

    /// UserDefaults toggle. Default true.
    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "clipboardArchiveEnabled") as? Bool ?? true
    }

    // MARK: - Write

    /// Save a pre-paste snapshot. Skips if disabled or text empty/nil.
    /// `traceId` lets the caller cross-reference back to the originating
    /// `TraceEntry`; nil for non-pipeline saves. Returns the ISO8601
    /// timestamp the entry was stored under, or nil if the save was a
    /// no-op (disabled or empty text), so the trace pipeline can store
    /// it back in `TraceEntry.clipboardTimestamp`.
    @discardableResult
    func save(_ text: String?, traceId: String? = nil) -> String? {
        guard let text else { return nil }
        return saveContent(text, kind: .clipboard, traceId: traceId)
    }

    /// Save the voice-input session immediately, instead of waiting for the next
    /// paste to capture the previous clipboard. This preserves both ASR source
    /// text and final output for each session. Returns the stored timestamp;
    /// see `save(_:traceId:)` for rationale.
    @discardableResult
    func saveSession(zh: String, english: String, traceId: String? = nil) -> String? {
        let content = Self.formatSessionContent(zh: zh, english: english)
        return saveContent(content, kind: .session, traceId: traceId)
    }

    @discardableResult
    private func saveContent(_ text: String, kind: EntryKind, traceId: String? = nil) -> String? {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isEnabled, !cleaned.isEmpty else { return nil }

        let stamp = ISO8601DateFormatter().string(from: Date())
        let entry = Self.serialize(
            Entry(timestamp: stamp, kind: kind, content: cleaned, traceId: traceId)
        )

        let existing = (try? String(contentsOf: archiveURL, encoding: .utf8)) ?? ""
        let combined = entry + existing
        let trimmed = Self.truncate(combined, to: Self.maxBytes)
        try? trimmed.write(to: archiveURL, atomically: true, encoding: .utf8)
        return stamp
    }

    // MARK: - Read

    /// Parse archive into newest-first entries.
    func entries() -> [Entry] {
        entries(since: nil)
    }

    /// Windowed read. When `cutoff` is non-nil, parsing stops at the first
    /// entry older than `cutoff` — because the file is strictly newest-first,
    /// everything below it is older too, so the tail never gets scanned. This
    /// is what keeps the History view fast: the default window loads only
    /// recent entries instead of the whole (up to 1 MB) file. Pass `nil` to
    /// load the full cold archive on demand. Entries with an unparseable
    /// timestamp are kept (they stay reachable) and never trigger the early
    /// stop.
    func entries(since cutoff: Date?) -> [Entry] {
        guard let raw = try? String(contentsOf: archiveURL, encoding: .utf8), !raw.isEmpty else {
            return []
        }
        return Self.parse(raw, since: cutoff)
    }

    /// Reverse lookup: find the clipboard entry produced by the given trace.
    /// Returns nil if no entry references this trace id (e.g. archive trimmed
    /// past the 1 MB cap, or trace was park-only without a paste).
    func entryForTrace(_ traceId: String) -> Entry? {
        entries().first { $0.traceId == traceId }
    }

    /// Restore an entry's content to the system pasteboard. Marks as transient
    /// so clipboard managers / Universal Clipboard skip re-recording.
    @discardableResult
    func restore(at index: Int) -> Bool {
        let all = entries()
        guard all.indices.contains(index) else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(all[index].content, forType: .string)
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        item.setString("", forType: NSPasteboard.PasteboardType("com.apple.is-sensitive"))
        return pasteboard.writeObjects([item])
    }

    // MARK: - Mutate

    /// Drop a single entry by index (newest = 0). Returns true if removed.
    @discardableResult
    func delete(at index: Int) -> Bool {
        var all = entries()
        guard all.indices.contains(index) else { return false }
        all.remove(at: index)
        write(all)
        return true
    }

    /// Wipe the archive entirely.
    func clear() {
        try? FileManager.default.removeItem(at: archiveURL)
    }

    private func write(_ entries: [Entry]) {
        let body = entries
            .map(Self.serialize)
            .joined()
        let trimmed = Self.truncate(body, to: Self.maxBytes)
        try? trimmed.write(to: archiveURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Parsing

    /// ISO8601 parser reused across the early-exit window check. Allocating
    /// `ISO8601DateFormatter` is expensive, so we keep one static instance.
    private static let windowParser = ISO8601DateFormatter()

    /// Parse the on-disk format into entries. Each entry starts with `─── ISO ─── \n`,
    /// then content, terminated by `\n\n` followed by the next separator (or EOF).
    static func parse(_ raw: String) -> [Entry] {
        parse(raw, since: nil)
    }

    /// Early-exit variant. When `cutoff` is non-nil, stops parsing once an
    /// entry older than `cutoff` is reached (entries are newest-first, so the
    /// remainder is older). Unparseable timestamps are included and do not
    /// stop the scan.
    static func parse(_ raw: String, since cutoff: Date?) -> [Entry] {
        // Pattern for header: ─── <stamp> ─── newline
        // Stamp is ISO8601 (no embedded separator chars).
        let headerPrefix = "\(separator)"
        var entries: [Entry] = []
        var cursor = raw.startIndex

        while cursor < raw.endIndex {
            // Find next header
            guard let headerStart = raw.range(of: headerPrefix, range: cursor..<raw.endIndex) else {
                break
            }
            let afterPrefix = headerStart.upperBound
            // Find " ─── \n" terminating the header
            let stampSearchRange = afterPrefix..<raw.endIndex
            let spacedHeaderEnd = raw.range(of: " \(separator)\n", range: stampSearchRange)
            let compactHeaderEnd = raw.range(of: " ───\n", range: stampSearchRange)
            guard let headerEnd = spacedHeaderEnd ?? compactHeaderEnd else {
                break
            }
            let headerBody = String(raw[afterPrefix..<headerEnd.lowerBound])
            let (stamp, kind, traceId) = Self.parseHeaderBody(headerBody)
            let contentStart = headerEnd.upperBound

            // Content runs to next "\n─── " or EOF
            let nextSeparatorMarker = "\n\(headerPrefix)"
            let contentEnd: String.Index
            if let nextHeader = raw.range(of: nextSeparatorMarker, range: contentStart..<raw.endIndex) {
                contentEnd = nextHeader.lowerBound
            } else {
                contentEnd = raw.endIndex
            }

            // Early exit: once we reach an entry older than the window cutoff,
            // every later entry is older too (newest-first), so stop scanning.
            if let cutoff, let date = windowParser.date(from: stamp), date < cutoff {
                break
            }

            var content = String(raw[contentStart..<contentEnd])
            // Trim trailing "\n\n" terminator if present
            while content.hasSuffix("\n") {
                content.removeLast()
            }

            entries.append(Entry(timestamp: stamp, kind: kind, content: content, traceId: traceId))
            cursor = contentEnd
        }
        return entries
    }

    static func formatSessionContent(zh: String, english: String) -> String {
        let cleanedZH = zh.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedEnglish = english.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanedEnglish.isEmpty {
            return """
            Chinese (ASR)
            \(cleanedZH)
            """
        }
        if cleanedZH.isEmpty {
            return """
            English / Output
            \(cleanedEnglish)
            """
        }
        return """
        Chinese (ASR)
        \(cleanedZH)

        English / Output
        \(cleanedEnglish)
        """
    }

    private static func serialize(_ entry: Entry) -> String {
        var header = "\(entry.timestamp) | \(entry.kind.rawValue)"
        if let id = entry.traceId, !id.isEmpty {
            header += " | trace=\(id)"
        }
        return "\(separator)\(header) \(separator)\n\(entry.content)\(entryTerminator)"
    }

    /// Parse a header body like `2026-05-14T00:00:00Z | session | trace=trace-abc123`.
    /// The first segment is always the timestamp. Remaining segments are
    /// recognised by shape — `trace=<id>` populates traceId, anything matching
    /// an `EntryKind` rawValue sets kind. Order-independent for extension keys
    /// so future header fields don't break old parsers.
    private static func parseHeaderBody(_ raw: String) -> (String, EntryKind, String?) {
        let parts = raw.split(separator: "|").map {
            String($0).trimmingCharacters(in: .whitespaces)
        }
        guard let first = parts.first else { return (raw, .clipboard, nil) }
        let stamp = first
        var kind: EntryKind = .clipboard
        var traceId: String? = nil
        for part in parts.dropFirst() {
            if let valueRange = part.range(of: "trace=") {
                let id = String(part[valueRange.upperBound...])
                if !id.isEmpty { traceId = id }
            } else if let parsedKind = EntryKind(rawValue: part) {
                kind = parsedKind
            }
        }
        return (stamp, kind, traceId)
    }

    /// Trim from end to fit byte cap, snapping to the last entry boundary.
    private static func truncate(_ s: String, to maxBytes: Int) -> String {
        guard s.utf8.count > maxBytes else { return s }
        let utf8Bytes = Array(s.utf8.prefix(maxBytes))
        let candidate = String(decoding: utf8Bytes, as: UTF8.self)
        if let lastSeparator = candidate.range(of: separator, options: .backwards) {
            return String(candidate[..<lastSeparator.lowerBound])
        }
        return candidate
    }
}
