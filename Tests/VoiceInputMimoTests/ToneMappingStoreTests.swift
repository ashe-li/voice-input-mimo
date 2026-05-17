import XCTest
@testable import VoiceInputMimo

final class ToneMappingStoreTests: XCTestCase {

    private var tempRoot: URL!
    private var store: ToneMappingStore!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("tonemapping-store-tests-\(UUID().uuidString)")
        store = ToneMappingStore(rootDirectory: tempRoot)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    func testLoadAllReturnsEmptyWhenFileMissing() throws {
        let rules = try store.loadAll()
        XCTAssertTrue(rules.isEmpty)
    }

    func testSaveAndLoadRoundTrip_ModeDelegate() throws {
        let rule = ToneRule(bundleIDPrefix: "com.example.app", delegated: .claudeCode)
        try store.saveAll([rule])
        let loaded = try store.loadAll()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.bundleIDPrefix, "com.example.app")
        XCTAssertEqual(loaded.first?.delegated, .mode(.claudeCode))
    }

    func testSaveAndLoadRoundTrip_WorkflowDelegate() throws {
        let rule = ToneRule(bundleIDPrefix: "com.notion.client", workflowId: "wf-notes")
        try store.saveAll([rule])
        let loaded = try store.loadAll()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.delegated, .workflow(workflowId: "wf-notes"))
    }

    func testSaveAndLoadRoundTrip_MixedDelegates() throws {
        let rules: [ToneRule] = [
            .init(bundleIDPrefix: "com.apple.mail", delegated: .refine),
            .init(bundleIDPrefix: "com.cursor.app", workflowId: "wf-dev-chain"),
            .init(bundleIDPrefix: "notion.id", delegated: .structure),
        ]
        try store.saveAll(rules)
        let loaded = try store.loadAll()
        XCTAssertEqual(loaded.count, 3)
        XCTAssertEqual(loaded[0].delegated, .mode(.refine))
        XCTAssertEqual(loaded[1].delegated, .workflow(workflowId: "wf-dev-chain"))
        XCTAssertEqual(loaded[2].delegated, .mode(.structure))
    }

    func testAddAppendsRule() throws {
        try store.saveAll([
            ToneRule(bundleIDPrefix: "com.example.first", delegated: .refine)
        ])
        try store.add(ToneRule(bundleIDPrefix: "com.example.second", delegated: .claudeCode))
        let loaded = try store.loadAll()
        XCTAssertEqual(loaded.map(\.bundleIDPrefix), ["com.example.first", "com.example.second"])
    }

    func testReplaceAtIndex() throws {
        try store.saveAll([
            ToneRule(bundleIDPrefix: "com.a", delegated: .refine),
            ToneRule(bundleIDPrefix: "com.b", delegated: .refine),
        ])
        try store.replace(at: 1, with: ToneRule(bundleIDPrefix: "com.b", delegated: .structure))
        let loaded = try store.loadAll()
        XCTAssertEqual(loaded[1].delegated, .mode(.structure))
    }

    func testReplaceOutOfBoundsAppends() throws {
        try store.saveAll([
            ToneRule(bundleIDPrefix: "com.a", delegated: .refine)
        ])
        try store.replace(at: 99, with: ToneRule(bundleIDPrefix: "com.new", delegated: .claudeCode))
        let loaded = try store.loadAll()
        XCTAssertEqual(loaded.map(\.bundleIDPrefix), ["com.a", "com.new"])
    }

    func testDeleteAtIndex() throws {
        try store.saveAll([
            ToneRule(bundleIDPrefix: "com.a", delegated: .refine),
            ToneRule(bundleIDPrefix: "com.b", delegated: .refine),
            ToneRule(bundleIDPrefix: "com.c", delegated: .refine),
        ])
        try store.delete(at: 1)
        let loaded = try store.loadAll()
        XCTAssertEqual(loaded.map(\.bundleIDPrefix), ["com.a", "com.c"])
    }

    func testDeleteOutOfBoundsIsNoop() throws {
        try store.saveAll([
            ToneRule(bundleIDPrefix: "com.a", delegated: .refine)
        ])
        try store.delete(at: 99)
        let loaded = try store.loadAll()
        XCTAssertEqual(loaded.count, 1)
    }

    // MARK: - effectiveRules

    func testEffectiveRulesUserFirstThenDefault() {
        let userRule = ToneRule(bundleIDPrefix: "com.user.custom", delegated: .structure)
        let merged = ToneMapping.effectiveRules(userRules: [userRule])
        XCTAssertEqual(merged.first?.bundleIDPrefix, "com.user.custom",
                       "user rule must come first so first-match-wins gives it precedence")
        XCTAssertEqual(merged.count, 1 + ToneMapping.defaultRules.count)
    }

    func testEffectiveRulesUserOverridesDefault_ViaFirstMatchWins() {
        // User-defined rule for com.apple.mail with workflow override.
        let userOverride = ToneRule(
            bundleIDPrefix: "com.apple.mail",
            workflowId: "wf-formal-email"
        )
        let merged = ToneMapping.effectiveRules(userRules: [userOverride])
        let ctx = CapturedContext(bundleID: "com.apple.mail", appName: "Mail")
        let resolved = ToneMapping.resolve(context: ctx, rules: merged)
        XCTAssertEqual(resolved, .workflow(workflowId: "wf-formal-email"),
                       "user rule for com.apple.mail must override default .refine")
    }

    func testEffectiveRulesEmptyUserPreservesDefaultBehavior() {
        let merged = ToneMapping.effectiveRules(userRules: [])
        XCTAssertEqual(merged.count, ToneMapping.defaultRules.count)
        let ctx = CapturedContext(bundleID: "com.apple.mail", appName: "Mail")
        XCTAssertEqual(ToneMapping.resolve(context: ctx, rules: merged), .mode(.refine))
    }
}
