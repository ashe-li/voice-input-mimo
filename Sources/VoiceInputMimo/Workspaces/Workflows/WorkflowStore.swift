import Foundation

enum WorkflowStoreError: Error, Equatable {
    case ioFailure(String)
}

/// JSON-backed store for `Workflow`. Mirrors `GlossaryStore` (serial queue
/// + atomic write + envelope wrapper) so adding metadata fields later
/// won't break existing files. Single file `default.json` under
/// `<rootDirectory>/` holds all workflows.
final class WorkflowStore: @unchecked Sendable {
    static let shared: WorkflowStore = WorkflowStore(
        rootDirectory: WorkflowStore.defaultRootDirectory()
    )

    let rootDirectory: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let queue = DispatchQueue(label: "com.shiun.VoiceInputMimo.WorkflowStore")

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
            .appendingPathComponent("Library/Application Support/VoiceInputMimo/workspaces/workflows")
    }

    private var dataFileURL: URL {
        rootDirectory.appendingPathComponent("default.json")
    }

    // MARK: - Public API

    func loadAll() throws -> [Workflow] {
        try queue.sync {
            guard fileManager.fileExists(atPath: dataFileURL.path) else { return [] }
            let data = try Data(contentsOf: dataFileURL)
            let envelope = try decoder.decode(WorkflowEnvelope.self, from: data)
            return envelope.workflows
        }
    }

    func saveAll(_ workflows: [Workflow]) throws {
        try queue.sync {
            try ensureDirectory(rootDirectory)
            let envelope = WorkflowEnvelope(workflows: workflows)
            let data = try encoder.encode(envelope)
            try atomicWrite(data, to: dataFileURL)
        }
    }

    func add(_ workflow: Workflow) throws {
        var all = try loadAll()
        all.append(workflow)
        try saveAll(all)
    }

    func update(_ workflow: Workflow) throws {
        var all = try loadAll()
        guard let idx = all.firstIndex(where: { $0.id == workflow.id }) else {
            try add(workflow)
            return
        }
        var updated = workflow
        updated.updatedAt = Date()
        all[idx] = updated
        try saveAll(all)
    }

    func delete(id: String) throws {
        var all = try loadAll()
        all.removeAll { $0.id == id }
        try saveAll(all)
    }

    func find(id: String) throws -> Workflow? {
        try loadAll().first { $0.id == id }
    }

    // MARK: - Private

    private func ensureDirectory(_ url: URL) throws {
        if !fileManager.fileExists(atPath: url.path) {
            do {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            } catch {
                throw WorkflowStoreError.ioFailure("mkdir failed: \(error.localizedDescription)")
            }
        }
    }

    private func atomicWrite(_ data: Data, to url: URL) throws {
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw WorkflowStoreError.ioFailure("write failed: \(error.localizedDescription)")
        }
    }
}

private struct WorkflowEnvelope: Codable {
    var workflows: [Workflow]
}
