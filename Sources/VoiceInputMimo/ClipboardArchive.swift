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

    struct Entry: Equatable {
        let timestamp: String
        let content: String
        var preview: String {
            let oneLine = content
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
                .trimmingCharacters(in: .whitespaces)
            return String(oneLine.prefix(120))
        }
    }

    let archiveURL: URL = {
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
    func save(_ text: String?) {
        guard isEnabled, let text, !text.isEmpty else { return }

        let stamp = ISO8601DateFormatter().string(from: Date())
        let entry = "\(Self.separator)\(stamp) \(Self.separator)\n\(text)\(Self.entryTerminator)"

        let existing = (try? String(contentsOf: archiveURL, encoding: .utf8)) ?? ""
        let combined = entry + existing
        let trimmed = Self.truncate(combined, to: Self.maxBytes)
        try? trimmed.write(to: archiveURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Read

    /// Parse archive into newest-first entries.
    func entries() -> [Entry] {
        guard let raw = try? String(contentsOf: archiveURL, encoding: .utf8), !raw.isEmpty else {
            return []
        }
        return Self.parse(raw)
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
            .map { "\(Self.separator)\($0.timestamp) \(Self.separator)\n\($0.content)\(Self.entryTerminator)" }
            .joined()
        let trimmed = Self.truncate(body, to: Self.maxBytes)
        try? trimmed.write(to: archiveURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Parsing

    /// Parse the on-disk format into entries. Each entry starts with `─── ISO ─── \n`,
    /// then content, terminated by `\n\n` followed by the next separator (or EOF).
    static func parse(_ raw: String) -> [Entry] {
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
            guard let headerEnd = raw.range(of: " \(separator)\n", range: stampSearchRange) else {
                break
            }
            let stamp = String(raw[afterPrefix..<headerEnd.lowerBound])
            let contentStart = headerEnd.upperBound

            // Content runs to next "\n─── " or EOF
            let nextSeparatorMarker = "\n\(headerPrefix)"
            let contentEnd: String.Index
            if let nextHeader = raw.range(of: nextSeparatorMarker, range: contentStart..<raw.endIndex) {
                contentEnd = nextHeader.lowerBound
            } else {
                contentEnd = raw.endIndex
            }

            var content = String(raw[contentStart..<contentEnd])
            // Trim trailing "\n\n" terminator if present
            while content.hasSuffix("\n") {
                content.removeLast()
            }

            entries.append(Entry(timestamp: stamp, content: content))
            cursor = contentEnd
        }
        return entries
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
