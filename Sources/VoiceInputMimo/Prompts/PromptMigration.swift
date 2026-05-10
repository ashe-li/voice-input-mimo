import Foundation

struct PromptMigrationResult {
    let didBootstrap: Bool
    let importedRefineProfileID: String?
    let importedClaudeCodeProfileID: String?
}

struct PromptMigration {
    let store: PromptStore
    let userDefaults: UserDefaults
    let hardcodedRefineDefault: String
    let hardcodedClaudeCodeDefault: String

    /// Run once on app launch. Idempotent — second call after the prompts/ tree
    /// is established becomes a no-op for the first-launch path, but always
    /// re-overwrites builtin profiles/skills so existing installs pick up
    /// shipped fixes (e.g. v1.0.2's reordered claude-code skills, prompt-v2
    /// content updates) without having to wipe `~/Library/Application Support`.
    func bootstrapIfNeeded() throws -> PromptMigrationResult {
        if try store.loadActiveSelection() != nil {
            try refreshBuiltins()
            return PromptMigrationResult(
                didBootstrap: false,
                importedRefineProfileID: nil,
                importedClaudeCodeProfileID: nil
            )
        }

        for skill in BuiltinPromptCatalog.skills {
            try store.saveSkill(skill)
        }
        for profile in BuiltinPromptCatalog.profiles {
            try store.saveProfile(profile)
        }
        try store.saveActiveSelection(
            ActiveSelection(
                refineProfileID: "builtin-default-refine",
                claudeCodeProfileID: "builtin-default-claude-code"
            )
        )

        let importedRefineID = try importLegacyOverride(
            key: "refineSystemPrompt",
            mode: .refine,
            hardcodedDefault: hardcodedRefineDefault,
            displayName: "Imported Refine"
        )
        let importedClaudeCodeID = try importLegacyOverride(
            key: "claudeCodeSystemPrompt",
            mode: .claudeCode,
            hardcodedDefault: hardcodedClaudeCodeDefault,
            displayName: "Imported ClaudeCode"
        )

        return PromptMigrationResult(
            didBootstrap: true,
            importedRefineProfileID: importedRefineID,
            importedClaudeCodeProfileID: importedClaudeCodeID
        )
    }

    /// Re-write builtin profiles/skills from the shipped catalog. User-created
    /// profiles/skills are untouched. `active.json` is also untouched so the
    /// user's chosen active profile sticks across upgrades.
    private func refreshBuiltins() throws {
        for skill in BuiltinPromptCatalog.skills {
            try store.saveSkill(skill)
        }
        for profile in BuiltinPromptCatalog.profiles {
            try store.saveProfile(profile)
        }
    }

    private func importLegacyOverride(
        key: String,
        mode: RefineMode,
        hardcodedDefault: String,
        displayName: String
    ) throws -> String? {
        guard let custom = userDefaults.string(forKey: key),
              !custom.isEmpty,
              custom != hardcodedDefault else {
            return nil
        }
        let now = Date()
        let id = "imported-\(mode.rawValue)-\(Int(now.timeIntervalSince1970))"
        let profile = PromptProfile(
            id: id,
            name: displayName,
            mode: mode,
            basePrompt: custom,
            skillIDs: [],
            displayLabel: displayName,
            createdAt: now,
            updatedAt: now,
            isBuiltin: false
        )
        try store.saveProfile(profile)
        return id
    }
}
