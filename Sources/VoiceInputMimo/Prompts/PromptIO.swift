import Foundation

/// Conflict resolution strategy when an imported entity collides with an
/// existing one (same id). `replace` overwrites; `rename` rewrites the id and
/// inserts as a new record; `skip` drops the imported record.
enum PromptImportStrategy: String, Sendable {
    case replace
    case rename
    case skip
}

/// Serializable bundle of prompt store entities — produced by Export, consumed
/// by Import. Keeps `schemaVersion` so future v1.5 / v2 changes can migrate
/// older bundles forward.
struct PromptBundle: Codable, Equatable, Sendable {
    static let currentSchemaVersion: Int = 1

    let schemaVersion: Int
    let exportedAt: Date
    let profiles: [PromptProfile]
    let skills: [PromptSkill]

    init(
        profiles: [PromptProfile],
        skills: [PromptSkill],
        exportedAt: Date = Date(),
        schemaVersion: Int = PromptBundle.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.profiles = profiles
        self.skills = skills
    }
}

/// Errors raised while encoding/decoding a `PromptBundle`. Surfaced as toast
/// or alert by the import/export adapter.
enum PromptIOError: Error, Equatable {
    case unsupportedSchema(version: Int)
    case malformed(String)
}

/// Stateless codec that serializes / deserializes `PromptBundle` to JSON. Lives
/// in the Prompts module so PromptStoreViewModel + tests can both reach it.
enum PromptIO {
    static func encode(_ bundle: PromptBundle) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(bundle)
    }

    static func decode(_ data: Data) throws -> PromptBundle {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let bundle: PromptBundle
        do {
            bundle = try dec.decode(PromptBundle.self, from: data)
        } catch {
            throw PromptIOError.malformed(String(describing: error))
        }
        guard bundle.schemaVersion <= PromptBundle.currentSchemaVersion else {
            throw PromptIOError.unsupportedSchema(version: bundle.schemaVersion)
        }
        return bundle
    }
}

/// Result of an import pass — caller renders this as a summary banner so the
/// user sees what happened.
struct PromptImportResult: Equatable, Sendable {
    var profilesAdded: Int = 0
    var profilesReplaced: Int = 0
    var profilesRenamed: Int = 0
    var profilesSkipped: Int = 0
    var skillsAdded: Int = 0
    var skillsReplaced: Int = 0
    var skillsRenamed: Int = 0
    var skillsSkipped: Int = 0
}

/// Stateless merge planner — given an incoming bundle and the current store
/// state, decides what to write and returns the resulting `PromptImportResult`.
/// Pure function so it can be unit-tested without touching the filesystem.
enum PromptImportPlanner {
    /// Merge `incoming` into `existing*` snapshots using `strategy`. Returns
    /// the records to upsert plus a result summary. Caller is responsible for
    /// writing the records via PromptStore.
    static func plan(
        incoming: PromptBundle,
        existingProfiles: [PromptProfile],
        existingSkills: [PromptSkill],
        strategy: PromptImportStrategy
    ) -> (profiles: [PromptProfile], skills: [PromptSkill], result: PromptImportResult) {
        var profilesOut: [PromptProfile] = []
        var skillsOut: [PromptSkill] = []
        var result = PromptImportResult()

        let profileIDs = Set(existingProfiles.map(\.id))
        for profile in incoming.profiles {
            if profileIDs.contains(profile.id) {
                switch strategy {
                case .replace:
                    profilesOut.append(profile)
                    result.profilesReplaced += 1
                case .rename:
                    var copy = profile
                    copy = renameProfile(copy)
                    profilesOut.append(copy)
                    result.profilesRenamed += 1
                case .skip:
                    result.profilesSkipped += 1
                }
            } else {
                profilesOut.append(profile)
                result.profilesAdded += 1
            }
        }

        let skillIDs = Set(existingSkills.map(\.id))
        for skill in incoming.skills {
            if skillIDs.contains(skill.id) {
                switch strategy {
                case .replace:
                    skillsOut.append(skill)
                    result.skillsReplaced += 1
                case .rename:
                    var copy = skill
                    copy = renameSkill(copy)
                    skillsOut.append(copy)
                    result.skillsRenamed += 1
                case .skip:
                    result.skillsSkipped += 1
                }
            } else {
                skillsOut.append(skill)
                result.skillsAdded += 1
            }
        }

        return (profilesOut, skillsOut, result)
    }

    private static func renameProfile(_ profile: PromptProfile) -> PromptProfile {
        PromptProfile(
            id: "user-\(UUID().uuidString.prefix(8))",
            name: "\(profile.name) (Imported)",
            mode: profile.mode,
            basePrompt: profile.basePrompt,
            skillIDs: profile.skillIDs,
            suffix: profile.suffix,
            modelOverride: profile.modelOverride,
            temperature: profile.temperature,
            displayLabel: profile.displayLabel,
            slotOverrides: profile.slotOverrides,
            createdAt: profile.createdAt,
            updatedAt: Date(),
            isBuiltin: false
        )
    }

    private static func renameSkill(_ skill: PromptSkill) -> PromptSkill {
        PromptSkill(
            id: "user-\(UUID().uuidString.prefix(8))",
            name: "\(skill.name) (Imported)",
            category: skill.category,
            content: skill.content,
            slot: skill.slot,
            description: skill.description,
            isBuiltin: false
        )
    }
}
