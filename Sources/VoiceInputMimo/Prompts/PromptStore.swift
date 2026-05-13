import Foundation

enum PromptStoreError: Error, Equatable {
    case cannotDeleteBuiltin(id: String)
    case ioFailure(String)
}

/// `@unchecked Sendable` is sound here because every mutating operation routes
/// through `queue.sync` (single serial dispatch queue) and all stored properties
/// are `let` after init. Future v1.5 plan: replace with proper actor isolation.
final class PromptStore: PromptStoreProviding, @unchecked Sendable {
    static let shared: PromptStore = PromptStore(rootDirectory: PromptStore.defaultRootDirectory())

    let rootDirectory: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let queue = DispatchQueue(label: "com.shiun.VoiceInputMimo.PromptStore")

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
            .appendingPathComponent("Library/Application Support/VoiceInputMimo/prompts")
    }

    // MARK: - Profiles

    func saveProfile(_ profile: PromptProfile) throws {
        try queue.sync {
            let dir = profileDirectory(for: profile.mode)
            try ensureDirectory(dir)
            let url = dir.appendingPathComponent("\(profile.id).json")
            let data = try encoder.encode(profile)
            try atomicWrite(data, to: url)
        }
    }

    func loadProfile(id: String, mode: RefineMode) throws -> PromptProfile? {
        let url = profileDirectory(for: mode).appendingPathComponent("\(id).json")
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try decoder.decode(PromptProfile.self, from: data)
    }

    func listProfiles(mode: RefineMode) throws -> [PromptProfile] {
        let dir = profileDirectory(for: mode)
        guard fileManager.fileExists(atPath: dir.path) else { return [] }
        let urls = try fileManager.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "json" }
        let profiles: [PromptProfile] = urls.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(PromptProfile.self, from: data)
        }
        return profiles.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    func deleteProfile(id: String, mode: RefineMode) throws {
        if let existing = try loadProfile(id: id, mode: mode), existing.isBuiltin {
            throw PromptStoreError.cannotDeleteBuiltin(id: id)
        }
        try queue.sync {
            let url = profileDirectory(for: mode).appendingPathComponent("\(id).json")
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }
    }

    // MARK: - Skills

    func saveSkill(_ skill: PromptSkill) throws {
        try queue.sync {
            let dir = skillsDirectory()
            try ensureDirectory(dir)
            let url = dir.appendingPathComponent("\(skill.id).json")
            let data = try encoder.encode(skill)
            try atomicWrite(data, to: url)
        }
    }

    func loadSkill(id: String) throws -> PromptSkill? {
        let url = skillsDirectory().appendingPathComponent("\(id).json")
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try decoder.decode(PromptSkill.self, from: data)
    }

    func listSkills() throws -> [PromptSkill] {
        let dir = skillsDirectory()
        guard fileManager.fileExists(atPath: dir.path) else { return [] }
        let urls = try fileManager.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "json" }
        let skills: [PromptSkill] = urls.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(PromptSkill.self, from: data)
        }
        return skills.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    func deleteSkill(id: String) throws {
        if let existing = try loadSkill(id: id), existing.isBuiltin {
            throw PromptStoreError.cannotDeleteBuiltin(id: id)
        }
        try queue.sync {
            let url = skillsDirectory().appendingPathComponent("\(id).json")
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }
    }

    // MARK: - Active selection

    func loadActiveSelection() throws -> ActiveSelection? {
        let url = activeSelectionURL()
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try decoder.decode(ActiveSelection.self, from: data)
    }

    func saveActiveSelection(_ selection: ActiveSelection) throws {
        try queue.sync {
            try ensureDirectory(rootDirectory)
            let data = try encoder.encode(selection)
            try atomicWrite(data, to: activeSelectionURL())
        }
    }

    func activeProfile(for mode: RefineMode) throws -> PromptProfile? {
        guard let selection = try loadActiveSelection() else { return nil }
        let id: String
        switch mode {
        case .refine: id = selection.refineProfileID
        case .claudeCode: id = selection.claudeCodeProfileID
        case .structure: id = selection.structureProfileID
        case .contextAware: return nil  // contextAware has no own active profile — delegate decides
        }
        return try loadProfile(id: id, mode: mode)
    }

    // MARK: - Path helpers

    private func profileDirectory(for mode: RefineMode) -> URL {
        rootDirectory
            .appendingPathComponent("profiles", isDirectory: true)
            .appendingPathComponent(mode.rawValue, isDirectory: true)
    }

    private func skillsDirectory() -> URL {
        rootDirectory.appendingPathComponent("skills", isDirectory: true)
    }

    private func activeSelectionURL() -> URL {
        rootDirectory.appendingPathComponent("active.json")
    }

    private func ensureDirectory(_ url: URL) throws {
        if !fileManager.fileExists(atPath: url.path) {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    /// Write data via temp file + atomic move so readers never observe a half-written file.
    private func atomicWrite(_ data: Data, to url: URL) throws {
        let temp = url.deletingPathExtension()
            .appendingPathExtension("\(UUID().uuidString).tmp")
        do {
            try data.write(to: temp, options: .atomic)
            if fileManager.fileExists(atPath: url.path) {
                _ = try fileManager.replaceItemAt(url, withItemAt: temp)
            } else {
                try fileManager.moveItem(at: temp, to: url)
            }
        } catch {
            try? fileManager.removeItem(at: temp)
            throw PromptStoreError.ioFailure(String(describing: error))
        }
    }
}
