import XCTest
@testable import VoiceInputMimo

final class PromptMigrationTests: XCTestCase {
    private var rootDirectory: URL!
    private var store: PromptStore!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceInputMimoMigrationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        store = PromptStore(rootDirectory: rootDirectory)

        suiteName = "MimoMigrationTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: rootDirectory)
        defaults.removePersistentDomain(forName: suiteName)
        rootDirectory = nil
        store = nil
        defaults = nil
        suiteName = nil
        try super.tearDownWithError()
    }

    private func makeMigration() -> PromptMigration {
        PromptMigration(
            store: store,
            userDefaults: defaults,
            hardcodedRefineDefault: "REFINE-DEFAULT",
            hardcodedClaudeCodeDefault: "CLAUDE-DEFAULT"
        )
    }

    // MARK: - Fresh bootstrap

    func testFreshBootstrapWritesTwelveBuiltinSkills() throws {
        let result = try makeMigration().bootstrapIfNeeded()
        XCTAssertTrue(result.didBootstrap)
        XCTAssertEqual(try store.listSkills().count, 12)
    }

    func testFreshBootstrapWritesNineBuiltinProfiles() throws {
        _ = try makeMigration().bootstrapIfNeeded()
        // .refine: Default Refine + Polish ZH (2)
        // .claudeCode: Default ClaudeCode (1)
        // .structure: meeting/task/requirement/letter/article/fallback (6)
        XCTAssertEqual(try store.listProfiles(mode: .refine).count, 2)
        XCTAssertEqual(try store.listProfiles(mode: .claudeCode).count, 1)
        XCTAssertEqual(try store.listProfiles(mode: .structure).count, 6)
    }

    func testFreshBootstrapWritesActiveSelectionPointingAtBuiltinDefaults() throws {
        _ = try makeMigration().bootstrapIfNeeded()
        let selection = try store.loadActiveSelection()
        XCTAssertEqual(selection?.refineProfileID, "builtin-default-refine")
        XCTAssertEqual(selection?.claudeCodeProfileID, "builtin-default-claude-code")
        XCTAssertEqual(selection?.structureProfileID, "builtin-structure-fallback")
    }

    func testFreshBootstrapResolvesActiveProfileEndToEnd() throws {
        _ = try makeMigration().bootstrapIfNeeded()
        XCTAssertEqual(try store.activeProfile(for: .refine)?.id, "builtin-default-refine")
        XCTAssertEqual(try store.activeProfile(for: .claudeCode)?.id, "builtin-default-claude-code")
        XCTAssertEqual(try store.activeProfile(for: .structure)?.id, "builtin-structure-fallback")
    }

    /// Legacy `active.json` written before the structure mode shipped only had
    /// `refineProfileID` and `claudeCodeProfileID`. The Codable migration in
    /// ActiveSelection must default the missing field to fallback so existing
    /// installs decode without crash.
    func testLegacyActiveSelectionDecodesWithDefaultStructureID() throws {
        let legacyJSON = """
            {
                "refineProfileID": "builtin-default-refine",
                "claudeCodeProfileID": "builtin-default-claude-code"
            }
            """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ActiveSelection.self, from: legacyJSON)
        XCTAssertEqual(decoded.refineProfileID, "builtin-default-refine")
        XCTAssertEqual(decoded.claudeCodeProfileID, "builtin-default-claude-code")
        XCTAssertEqual(decoded.structureProfileID, ActiveSelection.defaultStructureProfileID)
    }

    // MARK: - Idempotency

    func testBootstrapTwiceDoesNotDuplicate() throws {
        let migration = makeMigration()
        let first = try migration.bootstrapIfNeeded()
        XCTAssertTrue(first.didBootstrap)

        let second = try migration.bootstrapIfNeeded()
        XCTAssertFalse(second.didBootstrap, "second run must detect existing active.json and skip")
        XCTAssertEqual(try store.listSkills().count, 12)
        XCTAssertEqual(try store.listProfiles(mode: .refine).count, 2)
        XCTAssertEqual(try store.listProfiles(mode: .structure).count, 6)
    }

    // MARK: - UserDefaults import

    func testCustomRefinePromptImportsAsProfile() throws {
        defaults.set("USER CUSTOM REFINE PROMPT", forKey: "refineSystemPrompt")
        let result = try makeMigration().bootstrapIfNeeded()
        XCTAssertNotNil(result.importedRefineProfileID)
        let profiles = try store.listProfiles(mode: .refine)
        XCTAssertEqual(profiles.count, 3)  // 2 builtin (Default Refine + Polish ZH) + 1 imported
        let imported = profiles.first { !$0.isBuiltin }
        XCTAssertEqual(imported?.basePrompt, "USER CUSTOM REFINE PROMPT")
        XCTAssertFalse(imported?.isBuiltin ?? true)
    }

    func testRefinePromptMatchingHardcodedDoesNotImport() throws {
        defaults.set("REFINE-DEFAULT", forKey: "refineSystemPrompt")
        let result = try makeMigration().bootstrapIfNeeded()
        XCTAssertNil(result.importedRefineProfileID)
        XCTAssertEqual(try store.listProfiles(mode: .refine).count, 2)  // Default Refine + Polish ZH
    }

    func testCustomClaudeCodePromptImportsAsProfile() throws {
        defaults.set("USER CLAUDE PROMPT", forKey: "claudeCodeSystemPrompt")
        let result = try makeMigration().bootstrapIfNeeded()
        XCTAssertNotNil(result.importedClaudeCodeProfileID)
        let profiles = try store.listProfiles(mode: .claudeCode)
        XCTAssertEqual(profiles.count, 2)
    }

    func testNoUserDefaultsOverrideMeansNoImport() throws {
        let result = try makeMigration().bootstrapIfNeeded()
        XCTAssertNil(result.importedRefineProfileID)
        XCTAssertNil(result.importedClaudeCodeProfileID)
    }

    func testBootstrapSkippedDoesNotReimportLegacyDefaults() throws {
        // Pre-populate state so bootstrap is skipped
        let migration = makeMigration()
        _ = try migration.bootstrapIfNeeded()
        defaults.set("LATE CUSTOM PROMPT", forKey: "refineSystemPrompt")
        let second = try migration.bootstrapIfNeeded()
        XCTAssertFalse(second.didBootstrap)
        XCTAssertNil(second.importedRefineProfileID, "imports only happen during initial bootstrap")
    }
}
