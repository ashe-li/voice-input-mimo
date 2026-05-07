import Foundation

/// Local-only WAV retention. Copies wav into Application Support and prunes
/// LRU until both quotas hold:
///   - max files (default 10)
///   - total bytes (default 10 MB)
///
/// Toggleable via UserDefaults:
///   - recordingArchiveEnabled (Bool, default true)
///   - recordingArchiveMaxFiles (Int, default 10)
///   - recordingArchiveMaxBytes (Int, default 10 * 1024 * 1024)
enum RecordingArchive {
    private static let defaultMaxFiles = 10
    private static let defaultMaxBytes = 10 * 1024 * 1024

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

    /// Copy wav into archive dir, then prune LRU.
    /// `audioBytes` is the in-memory size already known by caller (avoids extra stat).
    static func archive(_ wavURL: URL, audioBytes: Int) {
        guard isEnabled else { return }
        let fm = FileManager.default
        let stamp = Self.timestamp()
        let dest = directory.appendingPathComponent("\(stamp)-\(wavURL.lastPathComponent)")
        do {
            try fm.copyItem(at: wavURL, to: dest)
        } catch {
            NSLog("[RecordingArchive] copy failed: %@", error.localizedDescription)
            return
        }
        prune()
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
