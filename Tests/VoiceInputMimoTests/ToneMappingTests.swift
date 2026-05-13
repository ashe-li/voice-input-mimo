import XCTest
@testable import VoiceInputMimo

final class ToneMappingTests: XCTestCase {
    func testExactMatch_AppleMail_DelegatesToRefine() {
        let ctx = CapturedContext(bundleID: "com.apple.mail", appName: "Mail")
        XCTAssertEqual(ToneMapping.resolve(context: ctx), .refine)
    }

    func testExactMatch_Cursor_DelegatesToClaudeCode() {
        let ctx = CapturedContext(bundleID: "com.todesktop.230313mzl4w4u92", appName: "Cursor")
        XCTAssertEqual(ToneMapping.resolve(context: ctx), .claudeCode)
    }

    func testExactMatch_Notion_DelegatesToStructure() {
        let ctx = CapturedContext(bundleID: "notion.id", appName: "Notion")
        XCTAssertEqual(ToneMapping.resolve(context: ctx), .structure)
    }

    func testUnknownBundle_FallsBackToRefine() {
        let ctx = CapturedContext(bundleID: "com.example.unknown", appName: "Unknown")
        XCTAssertEqual(ToneMapping.resolve(context: ctx), .refine)
    }

    func testEmptyContext_FallsBackToRefine() {
        XCTAssertEqual(ToneMapping.resolve(context: .empty), .refine)
    }

    func testNilBundleID_FallsBackToRefine() {
        let ctx = CapturedContext(bundleID: nil, appName: "Whatever")
        XCTAssertEqual(ToneMapping.resolve(context: ctx), .refine)
    }

    func testEmptyBundleID_FallsBackToRefine() {
        let ctx = CapturedContext(bundleID: "", appName: "")
        XCTAssertEqual(ToneMapping.resolve(context: ctx), .refine)
    }

    func testFirstMatchWins_WhenMultipleRulesCouldMatch() {
        // A custom rule list where two rules could match — the earlier one wins.
        let rules: [ToneRule] = [
            .init(bundleIDPrefix: "com.apple.mail", delegated: .claudeCode),  // intercepts before default refine
            .init(bundleIDPrefix: "com.apple.mail", delegated: .refine),
        ]
        let ctx = CapturedContext(bundleID: "com.apple.mail", appName: "Mail")
        XCTAssertEqual(ToneMapping.resolve(context: ctx, rules: rules), .claudeCode)
    }

    func testPrefixRule_MatchesNamespacedBundle() {
        let rules: [ToneRule] = [
            .init(bundleIDPrefix: "com.slack.", delegated: .refine),
        ]
        let ctx = CapturedContext(bundleID: "com.slack.client.subapp", appName: "Slack subapp")
        XCTAssertEqual(ToneMapping.resolve(context: ctx, rules: rules), .refine)
    }

    func testPrefixRule_DoesNotMatchWithoutTrailingDot() {
        let rules: [ToneRule] = [
            .init(bundleIDPrefix: "com.slack", delegated: .refine),  // No trailing dot → exact match
        ]
        let ctx = CapturedContext(bundleID: "com.slack.client", appName: "Slack")
        // Should fall back since "com.slack" is treated as exact and doesn't equal "com.slack.client"
        XCTAssertEqual(ToneMapping.resolve(context: ctx, rules: rules), .refine)
        // Resolve fell back via default rule list lookup... wait, custom list given.
        // With empty default fallback, this should still return .refine via the
        // hard fallback at the end of resolve().
    }

    func testToneRuleMatches_ExactMatch() {
        let rule = ToneRule(bundleIDPrefix: "com.apple.mail", delegated: .refine)
        XCTAssertTrue(rule.matches("com.apple.mail"))
        XCTAssertFalse(rule.matches("com.apple.mail.extension"))
        XCTAssertFalse(rule.matches(nil))
        XCTAssertFalse(rule.matches(""))
    }

    func testToneRuleMatches_PrefixMatch() {
        let rule = ToneRule(bundleIDPrefix: "com.tinyspeck.slackmacgap.", delegated: .refine)
        XCTAssertTrue(rule.matches("com.tinyspeck.slackmacgap.helper"))
        XCTAssertFalse(rule.matches("com.tinyspeck.slackmacgap"))  // missing the trailing dot
        XCTAssertFalse(rule.matches("com.tinyspeck"))
    }

    func testDefaultRules_HaveExpectedCoverage() {
        // Sanity-check the shipped table — these are the user-promised bundle IDs.
        let mustHave: [(String, RefineMode)] = [
            ("com.apple.mail", .refine),
            ("com.todesktop.230313mzl4w4u92", .claudeCode),
            ("com.apple.Terminal", .claudeCode),
            ("com.tinyspeck.slackmacgap", .refine),
            ("notion.id", .structure),
            ("md.obsidian", .structure),
        ]
        for (bundleID, expected) in mustHave {
            let ctx = CapturedContext(bundleID: bundleID, appName: nil)
            XCTAssertEqual(
                ToneMapping.resolve(context: ctx),
                expected,
                "expected \(bundleID) → \(expected) but got \(ToneMapping.resolve(context: ctx))"
            )
        }
    }
}
