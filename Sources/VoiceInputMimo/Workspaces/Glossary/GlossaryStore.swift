import Foundation

enum GlossaryStoreError: Error, Equatable {
    case ioFailure(String)
}

/// JSON-backed store for `GlossaryEntry`. Single file at
/// `<rootDirectory>/default.json` containing all entries. Mirrors the
/// PromptStore pattern (serial queue + atomic write + injectable root).
///
/// Missing file is treated as "no entries yet" (first-time bootstrap),
/// not an error — fresh installs return an empty array on `loadAll()`.
final class GlossaryStore: @unchecked Sendable {
    static let shared: GlossaryStore = GlossaryStore(
        rootDirectory: GlossaryStore.defaultRootDirectory()
    )

    let rootDirectory: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let queue = DispatchQueue(label: "com.shiun.VoiceInputMimo.GlossaryStore")

    init(rootDirectory: URL, fileManager: FileManager = .default) {
        self.rootDirectory = rootDirectory
        self.fileManager = fileManager

        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        self.encoder = enc

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec
    }

    static func defaultRootDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/VoiceInputMimo/workspaces/glossary")
    }

    private var dataFileURL: URL {
        rootDirectory.appendingPathComponent("default.json")
    }

    // MARK: - Public API

    func loadAll() throws -> [GlossaryEntry] {
        try queue.sync {
            guard fileManager.fileExists(atPath: dataFileURL.path) else { return [] }
            let data = try Data(contentsOf: dataFileURL)
            let envelope = try decoder.decode(GlossaryEnvelope.self, from: data)
            return envelope.entries
        }
    }

    func saveAll(_ entries: [GlossaryEntry]) throws {
        try queue.sync {
            try ensureDirectory(rootDirectory)
            let envelope = GlossaryEnvelope(entries: entries)
            let data = try encoder.encode(envelope)
            try atomicWrite(data, to: dataFileURL)
        }
    }

    func add(_ entry: GlossaryEntry) throws {
        var all = try loadAll()
        all.append(entry)
        try saveAll(all)
    }

    func update(_ entry: GlossaryEntry) throws {
        var all = try loadAll()
        guard let idx = all.firstIndex(where: { $0.id == entry.id }) else {
            try add(entry)
            return
        }
        var updated = entry
        updated.updatedAt = Date()
        all[idx] = updated
        try saveAll(all)
    }

    func delete(id: String) throws {
        var all = try loadAll()
        all.removeAll { $0.id == id }
        try saveAll(all)
    }

    // MARK: - Private

    private func ensureDirectory(_ url: URL) throws {
        if !fileManager.fileExists(atPath: url.path) {
            do {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            } catch {
                throw GlossaryStoreError.ioFailure("mkdir failed: \(error.localizedDescription)")
            }
        }
    }

    private func atomicWrite(_ data: Data, to url: URL) throws {
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw GlossaryStoreError.ioFailure("write failed: \(error.localizedDescription)")
        }
    }
}

/// JSON wrapper so we can add metadata fields (version, last-imported,
/// etc.) without breaking existing files.
private struct GlossaryEnvelope: Codable {
    var entries: [GlossaryEntry]
}
