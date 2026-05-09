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
    /// is established becomes a no-op.
    func bootstrapIfNeeded() throws -> PromptMigrationResult {
        if try store.loadActiveSelection() != nil {
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
