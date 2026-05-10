import XCTest
@testable import VoiceInputMimo

final class LLMRefinerPromptResolutionTests: XCTestCase {
    private var rootDirectory: URL!
    private var store: PromptStore!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MimoLLMRefinerResolutionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        store = PromptStore(rootDirectory: rootDirectory)

        suiteName = "MimoLLMRefinerResolutionTests-\(UUID().uuidString)"
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

    // MARK: - Fallback chain

    func testEmptyStoreAndDefaultsReturnsHardcodedRefineDefault() {
        let resolved = LLMRefiner.resolveSystemPrompt(
            for: .refine,
            store: store,
            userDefaults: defaults
        )
        XCTAssertEqual(resolved, LLMRefiner.defaultRefinePrompt)
    }

    func testEmptyStoreAndDefaultsReturnsHardcodedClaudeCodeDefault() {
        let resolved = LLMRefiner.resolveSystemPrompt(
            for: .claudeCode,
            store: store,
            userDefaults: defaults
        )
        XCTAssertEqual(resolved, LLMRefiner.defaultClaudeCodePrompt)
    }

    func testUserDefaultsOverrideTakesPrecedenceOverHardcodedWhenStoreEmpty() {
        defaults.set("OVERRIDE", forKey: "refineSystemPrompt")
        let resolved = LLMRefiner.resolveSystemPrompt(
            for: .refine,
            store: store,
            userDefaults: defaults
        )
        XCTAssertEqual(resolved, "OVERRIDE")
    }

    func testEmptyUserDefaultsStringFallsThroughToHardcoded() {
        defaults.set("", forKey: "refineSystemPrompt")
        let resolved = LLMRefiner.resolveSystemPrompt(
            for: .refine,
            store: store,
            userDefaults: defaults
        )
        XCTAssertEqual(resolved, LLMRefiner.defaultRefinePrompt)
    }

    func testStoreProfileTakesPrecedenceOverUserDefaultsAndHardcoded() throws {
        defaults.set("LEGACY", forKey: "refineSystemPrompt")

        let now = Date(timeIntervalSinceReferenceDate: 0)
        let profile = PromptProfile(
            id: "pX",
            name: "Test",
            mode: .refine,
            basePrompt: "BASE",
            skillIDs: [],
            createdAt: now,
            updatedAt: now,
            isBuiltin: false
        )
        try store.saveProfile(profile)
        try store.saveActiveSelection(
            ActiveSelection(refineProfileID: "pX", claudeCodeProfileID: "irrelevant")
        )

        let resolved = LLMRefiner.resolveSystemPrompt(
            for: .refine,
            store: store,
            userDefaults: defaults
        )
        XCTAssertEqual(resolved, "BASE")
    }

    func testStoreProfileWithSkillsRendersComposed() throws {
        let now = Date(timeIntervalSinceReferenceDate: 0)
        let skill = PromptSkill(
            id: "sX",
            name: "S",
            category: .style,
            content: "EXTRA RULE"
        )
        try store.saveSkill(skill)
        let profile = PromptProfile(
            id: "pX",
            name: "P",
            mode: .refine,
            basePrompt: "BASE",
            skillIDs: ["sX"],
            createdAt: now,
            updatedAt: now,
            isBuiltin: false
        )
        try store.saveProfile(profile)
        try store.saveActiveSelection(
            ActiveSelection(refineProfileID: "pX", claudeCodeProfileID: "irrelevant")
        )

        let resolved = LLMRefiner.resolveSystemPrompt(
            for: .refine,
            store: store,
            userDefaults: defaults
        )
        XCTAssertEqual(resolved, "BASE\n\nEXTRA RULE")
    }

    func testActiveSelectionPointingAtMissingProfileFallsThroughToUserDefaults() throws {
        try store.saveActiveSelection(
            ActiveSelection(refineProfileID: "ghost", claudeCodeProfileID: "ghost")
        )
        defaults.set("LEGACY", forKey: "refineSystemPrompt")

        let resolved = LLMRefiner.resolveSystemPrompt(
            for: .refine,
            store: store,
            userDefaults: defaults
        )
        XCTAssertEqual(resolved, "LEGACY")
    }

    // MARK: - End-to-end builtin profile

    func testBuiltinProfileResolvesToRenderedPromptThatContainsCriticalAnchors() throws {
        // Bootstrap full builtin catalog
        let migration = PromptMigration(
            store: store,
            userDefaults: defaults,
            hardcodedRefineDefault: LLMRefiner.defaultRefinePrompt,
            hardcodedClaudeCodeDefault: LLMRefiner.defaultClaudeCodePrompt
        )
        _ = try migration.bootstrapIfNeeded()

        let refineResolved = LLMRefiner.resolveSystemPrompt(
            for: .refine,
            store: store,
            userDefaults: defaults
        )
        XCTAssertTrue(refineResolved.contains("/no_think"))
        XCTAssertTrue(refineResolved.contains("配森"))
        XCTAssertTrue(refineResolved.contains("Examples"))

        let claudeResolved = LLMRefiner.resolveSystemPrompt(
            for: .claudeCode,
            store: store,
            userDefaults: defaults
        )
        XCTAssertTrue(claudeResolved.contains("/no_think"))
        XCTAssertTrue(claudeResolved.contains("REQUEST"))
        XCTAssertTrue(claudeResolved.contains("Output ONLY"))
    }
}
