import Foundation

/// Exports TraceEntry records (audio + transcript) to a flat directory layout
/// for use as ASR training / evaluation fixtures.
///
/// Output layout:
///   <destination>/audio/<id>.wav
///   <destination>/transcripts/<id>.txt
///
/// This type has no instance state; all behaviour is via static methods.
enum FixtureExporter {

    struct ExportResult: Equatable {
        let id: String
        let wavDestination: URL?        // nil if skipped
        let transcriptDestination: URL? // nil if skipped
        let skippedReason: String?      // nil if exported
    }

    enum ExportError: Error, Equatable {
        case ioFailure(String)
    }

    /// Export all eligible entries from `store` to `destination`.
    ///
    /// Filter rules (applied in order):
    /// 1. `audioPath == nil`                       → skip, "no audio path"
    /// 2. audio file does not exist on disk         → skip, "audio file missing: <path>"
    /// 3. `asrText.isEmpty`                         → skip, "empty asr text"
    /// 4. `endedAt - startedAt < minDurationSeconds`→ skip, "below min duration: <X>s"
    ///
    /// Passing entries are copied (not moved) so the TraceStore-managed
    /// source files remain intact.  Existing destination files are silently
    /// overwritten so re-export after curation works without friction.
    ///
    /// - Returns: one `ExportResult` per entry in the same order as
    ///   `store.loadAll()`, including skipped entries.
    /// - Throws: `ExportError.ioFailure` only for directory-creation or
    ///   file-write failures that affect the entire export (not per-entry
    ///   skip conditions, which are captured in `ExportResult.skippedReason`).
    static func exportAll(
        from store: TraceStore = .shared,
        destination: URL,
        minDurationSeconds: Double = 0.5,
        fileManager: FileManager = .default
    ) throws -> [ExportResult] {
        let entries = try store.loadAll()

        let audioDir = destination.appendingPathComponent("audio")
        let transcriptDir = destination.appendingPathComponent("transcripts")

        do {
            try fileManager.createDirectory(at: audioDir, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: transcriptDir, withIntermediateDirectories: true)
        } catch {
            throw ExportError.ioFailure("createDirectory failed: \(error.localizedDescription)")
        }

        return try entries.map { entry in
            try exportEntry(
                entry,
                audioDir: audioDir,
                transcriptDir: transcriptDir,
                minDurationSeconds: minDurationSeconds,
                fileManager: fileManager
            )
        }
    }

    // MARK: - Private

    private static func exportEntry(
        _ entry: TraceEntry,
        audioDir: URL,
        transcriptDir: URL,
        minDurationSeconds: Double,
        fileManager: FileManager
    ) throws -> ExportResult {
        // Filter 0: id must be a safe filename component — reject path
        // separators, parent-directory markers, and empties to prevent the
        // exported file from escaping audioDir / transcriptDir via id.
        guard !entry.id.isEmpty,
              !entry.id.contains("/"),
              !entry.id.contains("\\"),
              !entry.id.contains("..")
        else {
            return ExportResult(id: entry.id, wavDestination: nil, transcriptDestination: nil, skippedReason: "invalid id")
        }

        // Filter 1: audioPath must exist
        guard let audioPath = entry.audioPath else {
            return ExportResult(id: entry.id, wavDestination: nil, transcriptDestination: nil, skippedReason: "no audio path")
        }

        // Filter 2: audio file must exist on disk
        guard fileManager.fileExists(atPath: audioPath) else {
            return ExportResult(id: entry.id, wavDestination: nil, transcriptDestination: nil, skippedReason: "audio file missing: \(audioPath)")
        }

        // Filter 3: asrText must be non-empty
        guard !entry.asrText.isEmpty else {
            return ExportResult(id: entry.id, wavDestination: nil, transcriptDestination: nil, skippedReason: "empty asr text")
        }

        // Filter 4: duration check
        if let endedAt = entry.endedAt {
            let duration = endedAt.timeIntervalSince(entry.startedAt)
            if duration < minDurationSeconds {
                return ExportResult(
                    id: entry.id,
                    wavDestination: nil,
                    transcriptDestination: nil,
                    skippedReason: "below min duration: \(duration)s"
                )
            }
        }

        let wavDest = audioDir.appendingPathComponent("\(entry.id).wav")
        let txtDest = transcriptDir.appendingPathComponent("\(entry.id).txt")

        // Copy WAV — overwrite if already exists
        if fileManager.fileExists(atPath: wavDest.path) {
            do {
                try fileManager.removeItem(at: wavDest)
            } catch {
                throw ExportError.ioFailure("removeItem failed for \(wavDest.lastPathComponent): \(error.localizedDescription)")
            }
        }
        do {
            try fileManager.copyItem(atPath: audioPath, toPath: wavDest.path)
        } catch {
            throw ExportError.ioFailure("copyItem failed for \(entry.id): \(error.localizedDescription)")
        }

        // Write transcript as UTF-8, no trailing newline
        guard let txtData = entry.asrText.data(using: .utf8) else {
            throw ExportError.ioFailure("asrText encoding failed for \(entry.id)")
        }
        do {
            try txtData.write(to: txtDest, options: .atomic)
        } catch {
            throw ExportError.ioFailure("transcript write failed for \(entry.id): \(error.localizedDescription)")
        }

        return ExportResult(id: entry.id, wavDestination: wavDest, transcriptDestination: txtDest, skippedReason: nil)
    }
}
