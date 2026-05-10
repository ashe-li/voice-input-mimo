import XCTest
@testable import VoiceInputMimo

final class StructureRouterTests: XCTestCase {

    // MARK: - Default rules — happy path per template

    func testRoutesMeetingByKeyword() {
        XCTAssertEqual(
            StructureRouter.route(input: "我們今天開會討論到下一季的計畫"),
            "builtin-structure-meeting"
        )
    }

    func testRoutesTaskListByKeyword() {
        XCTAssertEqual(
            StructureRouter.route(input: "等等要做 A、B、C 三件事"),
            "builtin-structure-task"
        )
    }

    func testRoutesRequirementByKeyword() {
        XCTAssertEqual(
            StructureRouter.route(input: "客戶說他們需要一個新功能來處理批次匯入"),
            "builtin-structure-requirement"
        )
    }

    func testRoutesLetterByKeyword() {
        XCTAssertEqual(
            StructureRouter.route(input: "幫我寫信跟他說明我們的進度"),
            "builtin-structure-letter"
        )
    }

    func testRoutesArticleByKeyword() {
        XCTAssertEqual(
            StructureRouter.route(input: "我想寫一篇關於語音輸入的工作說明"),
            "builtin-structure-article"
        )
    }

    // MARK: - Fallback behavior

    func testFallsBackWhenNoKeywordMatches() {
        XCTAssertEqual(
            StructureRouter.route(input: "打字真的蠻慢的，所以以後大家都用語音輸入的話。"),
            "builtin-structure-fallback"
        )
    }

    func testFallsBackForEmptyInput() {
        XCTAssertEqual(StructureRouter.route(input: ""), "builtin-structure-fallback")
    }

    func testCustomFallbackProfileIDIsUsedOnMiss() {
        XCTAssertEqual(
            StructureRouter.route(input: "no keywords here", fallbackProfileID: "custom-fallback"),
            "custom-fallback"
        )
    }

    // MARK: - Scoring rules

    func testHighestScoringRuleWins() {
        // Mentions "需求" (1 hit, requirement rule) and "會議" + "決議" (2 hits, meeting rule).
        // Meeting rule should win on score.
        XCTAssertEqual(
            StructureRouter.route(input: "會議的決議是要先確認需求"),
            "builtin-structure-meeting"
        )
    }

    func testCaseInsensitiveEnglishKeyword() {
        XCTAssertEqual(
            StructureRouter.route(input: "I need to write a TODO list"),
            "builtin-structure-task"
        )
        XCTAssertEqual(
            StructureRouter.route(input: "send an Email to the team"),
            "builtin-structure-letter"
        )
    }

    func testTieResolvesToFirstRuleInList() {
        // Both meeting (1 hit: "會議") and task (1 hit: "待辦") match. Meeting
        // appears first in defaultRules, so meeting wins.
        XCTAssertEqual(
            StructureRouter.route(input: "會議結束後要追蹤待辦"),
            "builtin-structure-meeting"
        )
    }

    // MARK: - Custom rule injection

    func testCustomRulesOverrideDefaults() {
        let custom: [StructureRouter.Rule] = [
            .init(keywords: ["foobar"], profileID: "test-profile-x"),
        ]
        XCTAssertEqual(
            StructureRouter.route(input: "this contains foobar inside", rules: custom),
            "test-profile-x"
        )
        XCTAssertEqual(
            StructureRouter.route(
                input: "我們今天開會",  // would hit meeting under defaults
                rules: custom
            ),
            "builtin-structure-fallback",  // no custom rule matches, fall back
            "custom rules must fully replace defaults, not merge"
        )
    }

    func testEmptyRulesAlwaysFallsBack() {
        XCTAssertEqual(
            StructureRouter.route(input: "anything goes here", rules: []),
            "builtin-structure-fallback"
        )
    }

    // MARK: - Coverage of all default profile IDs

    func testEveryDefaultRuleProducesAValidBuiltinProfileID() {
        let validIDs = Set(BuiltinPromptCatalog.profiles.map(\.id))
        for rule in StructureRouter.defaultRules {
            XCTAssertTrue(
                validIDs.contains(rule.profileID),
                "rule profile \(rule.profileID) is not a builtin profile"
            )
        }
        XCTAssertTrue(
            validIDs.contains(StructureRouter.defaultFallbackProfileID),
            "default fallback profile must exist in the catalog"
        )
    }
}
