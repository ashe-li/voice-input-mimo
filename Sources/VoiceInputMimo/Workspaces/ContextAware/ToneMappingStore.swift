import Foundation

enum ToneMappingStoreError: Error, Equatable {
    case ioFailure(String)
}

/// JSON-backed store for **user-defined** `ToneRule`s. The default rule
/// table (`ToneMapping.defaultRules`) is hardcoded and ships with the app;
/// this store only holds the user's additions/overrides.
///
/// At dispatch time the caller concats `userRules + defaultRules` so user
/// rules win on first-match (see `ToneMapping.effectiveRules`).
///
/// Mirrors `GlossaryStore` / `WorkflowStore`: serial queue + atomic write
/// + envelope wrapper so adding metadata fields later won't break existing
/// files. Single file `default.json` under `<rootDirectory>/`.
final class ToneMappingStore: @unchecked Sendable {
    static let shared: ToneMappingStore = ToneMappingStore(
        rootDirectory: ToneMappingStore.defaultRootDirectory()
    )

    let rootDirectory: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let queue = DispatchQueue(label: "com.shiun.VoiceInputMimo.ToneMappingStore")

    init(rootDirectory: URL, fileManager: FileManager = .default) {
        self.rootDirectory = rootDirectory
        self.fileManager = fileManager

        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = enc

        self.decoder = JSONDecoder()
    }

    static func defaultRootDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/VoiceInputMimo/workspaces/toneMapping")
    }

    private var dataFileURL: URL {
        rootDirectory.appendingPathComponent("default.json")
    }

    // MARK: - Public API

    func loadAll() throws -> [ToneRule] {
        try queue.sync {
            guard fileManager.fileExists(atPath: dataFileURL.path) else { return [] }
            let data = try Data(contentsOf: dataFileURL)
            let envelope = try decoder.decode(ToneMappingEnvelope.self, from: data)
            return envelope.rules
        }
    }

    func saveAll(_ rules: [ToneRule]) throws {
        try queue.sync {
            try ensureDirectory(rootDirectory)
            let envelope = ToneMappingEnvelope(rules: rules)
            let data = try encoder.encode(envelope)
            try atomicWrite(data, to: dataFileURL)
        }
    }

    func add(_ rule: ToneRule) throws {
        var all = try loadAll()
        all.append(rule)
        try saveAll(all)
    }

    func replace(at index: Int, with rule: ToneRule) throws {
        var all = try loadAll()
        guard all.indices.contains(index) else {
            try add(rule)
            return
        }
        all[index] = rule
        try saveAll(all)
    }

    func delete(at index: Int) throws {
        var all = try loadAll()
        guard all.indices.contains(index) else { return }
        all.remove(at: index)
        try saveAll(all)
    }

    // MARK: - Private

    private func ensureDirectory(_ url: URL) throws {
        if !fileManager.fileExists(atPath: url.path) {
            do {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            } catch {
                throw ToneMappingStoreError.ioFailure("mkdir failed: \(error.localizedDescription)")
            }
        }
    }

    private func atomicWrite(_ data: Data, to url: URL) throws {
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw ToneMappingStoreError.ioFailure("write failed: \(error.localizedDescription)")
        }
    }
}

private struct ToneMappingEnvelope: Codable {
    var rules: [ToneRule]
}
