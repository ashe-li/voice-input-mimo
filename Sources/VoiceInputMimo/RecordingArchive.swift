import Foundation

/// Local-only WAV retention. Copies wav into Application Support and prunes
/// LRU until both quotas hold:
///   - max files (default 10000 — bytes quota is primary; high cap avoids
///     premature prune when many small clips accumulate)
///   - total bytes (default 1 GB)
///
/// Toggleable via UserDefaults:
///   - recordingArchiveEnabled (Bool, default true)
///   - recordingArchiveMaxFiles (Int, default 10000)
///   - recordingArchiveMaxBytes (Int, default 1024 * 1024 * 1024)
enum RecordingArchive {
    private static let defaultMaxFiles = 10_000
    private static let defaultMaxBytes = 1024 * 1024 * 1024

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "recordingArchiveEnabled") as? Bool ?? true
    }

    static var maxFiles: Int {
        let v = UserDefaults.standard.integer(forKey: "recordingArchiveMaxFiles")
        return v > 0 ? v : defaultMaxFiles
    }

    static var maxBytes: Int {
        let v = UserDefaults.standard.integer(forKey: "recordingArchiveMaxBytes")
        return v > 0 ? v : defaultMaxBytes
    }

    static var directory: URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("VoiceInputMimo/recordings", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Copy wav into archive dir, then prune LRU. Returns the archived
    /// destination URL so callers (e.g. RecordingTracer) can pin the
    /// persistent path into the trace entry — fixes the lifecycle break
    /// where Tracer kept the soon-to-be-deleted tmp path while Archive
    /// silently held the only surviving copy.
    ///
    /// `audioBytes` is the in-memory size already known by caller (avoids extra stat).
    /// Returns nil when archive is disabled or the copy failed.
    @discardableResult
    static func archive(_ wavURL: URL, audioBytes: Int) -> URL? {
        guard isEnabled else { return nil }
        let fm = FileManager.default
        let stamp = Self.timestamp()
        let dest = directory.appendingPathComponent("\(stamp)-\(wavURL.lastPathComponent)")
        do {
            try fm.copyItem(at: wavURL, to: dest)
        } catch {
            NSLog("[RecordingArchive] copy failed: %@", error.localizedDescription)
            return nil
        }
        prune()
        return dest
    }

    /// Drop oldest files until file count ≤ maxFiles AND total bytes ≤ maxBytes.
    static func prune() {
        let fm = FileManager.default
        let dir = directory
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let urls = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return }

        struct Entry { let url: URL; let mtime: Date; let size: Int }
        let entries: [Entry] = urls.compactMap { url in
            let r = try? url.resourceValues(forKeys: Set(keys))
            guard r?.isRegularFile == true,
                  let m = r?.contentModificationDate,
                  let s = r?.fileSize else { return nil }
            return Entry(url: url, mtime: m, size: s)
        }
        // Oldest first.
        var sorted = entries.sorted { $0.mtime < $1.mtime }
        var totalBytes = sorted.reduce(0) { $0 + $1.size }
        var totalFiles = sorted.count
        let mf = maxFiles
        let mb = maxBytes
        while (totalFiles > mf || totalBytes > mb), let oldest = sorted.first {
            try? fm.removeItem(at: oldest.url)
            totalBytes -= oldest.size
            totalFiles -= 1
            sorted.removeFirst()
        }
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }
}
