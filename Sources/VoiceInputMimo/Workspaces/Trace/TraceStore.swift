import Foundation

enum TraceStoreError: Error, Equatable {
    case ioFailure(String)
}

/// JSONL-backed store for `TraceEntry`. Append-only by default
/// (`append(_:)`) for cheap recording writes; full rewrite (`saveAll(_:)`)
/// is used when entries are edited or deleted.
///
/// Single file at `<rootDirectory>/traces.jsonl` — one trace per line.
/// Missing file is treated as "no traces yet" (first install), not an
/// error. Permanent retention by default; future GC will rotate to dated
/// files but is out of scope here.
final class TraceStore: @unchecked Sendable {
    static let shared: TraceStore = TraceStore(rootDirectory: TraceStore.defaultRootDirectory())

    let rootDirectory: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let queue = DispatchQueue(label: "com.shiun.VoiceInputMimo.TraceStore")

    init(rootDirectory: URL, fileManager: FileManager = .default) {
        self.rootDirectory = rootDirectory
        self.fileManager = fileManager

        let enc = JSONEncoder()
        // No prettyPrinting for JSONL — each line must be a single record.
        enc.outputFormatting = [.sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        self.encoder = enc

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec
    }

    static func defaultRootDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/VoiceInputMimo/workspaces/traces")
    }

    private var dataFileURL: URL {
        rootDirectory.appendingPathComponent("traces.jsonl")
    }

    // MARK: - Read

    func loadAll() throws -> [TraceEntry] {
        try queue.sync {
            guard fileManager.fileExists(atPath: dataFileURL.path) else { return [] }
            let raw = try String(contentsOf: dataFileURL, encoding: .utf8)
            return raw
                .split(separator: "\n", omittingEmptySubsequences: true)
                .compactMap { line in
                    guard let data = line.data(using: .utf8) else { return nil }
                    return try? decoder.decode(TraceEntry.self, from: data)
                }
        }
    }

    // MARK: - Write

    /// Append a single trace to the JSONL file. Cheap O(1) write — the
    /// hot path during recording.
    func append(_ entry: TraceEntry) throws {
        try queue.sync {
            try ensureDirectory(rootDirectory)
            let data = try encoder.encode(entry)
            guard var line = String(data: data, encoding: .utf8) else {
                throw TraceStoreError.ioFailure("encoded entry was not UTF-8")
            }
            line += "\n"
            try appendString(line, to: dataFileURL)
        }
    }

    /// Full rewrite — used when editing or deleting individual entries.
    func saveAll(_ entries: [TraceEntry]) throws {
        try queue.sync {
            try ensureDirectory(rootDirectory)
            let lines = try entries.map { entry -> String in
                let data = try encoder.encode(entry)
                guard let line = String(data: data, encoding: .utf8) else {
                    throw TraceStoreError.ioFailure("entry \(entry.id) was not UTF-8")
                }
                return line
            }
            let body = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
            try Data(body.utf8).write(to: dataFileURL, options: .atomic)
        }
    }

    func delete(id: String) throws {
        let all = try loadAll()
        try saveAll(all.filter { $0.id != id })
    }

    func update(_ entry: TraceEntry) throws {
        var all = try loadAll()
        if let idx = all.firstIndex(where: { $0.id == entry.id }) {
            all[idx] = entry
        } else {
            all.append(entry)
        }
        try saveAll(all)
    }

    // MARK: - Private

    private func ensureDirectory(_ url: URL) throws {
        if !fileManager.fileExists(atPath: url.path) {
            do {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            } catch {
                throw TraceStoreError.ioFailure("mkdir failed: \(error.localizedDescription)")
            }
        }
    }

    private func appendString(_ string: String, to url: URL) throws {
        let data = Data(string.utf8)
        if fileManager.fileExists(atPath: url.path) {
            do {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                throw TraceStoreError.ioFailure("append failed: \(error.localizedDescription)")
            }
        } else {
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                throw TraceStoreError.ioFailure("initial write failed: \(error.localizedDescription)")
            }
        }
    }
}
