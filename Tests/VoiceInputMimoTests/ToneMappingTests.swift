import XCTest
@testable import VoiceInputMimo

final class ToneMappingTests: XCTestCase {
    func testExactMatch_AppleMail_DelegatesToRefine() {
        let ctx = CapturedContext(bundleID: "com.apple.mail", appName: "Mail")
        XCTAssertEqual(ToneMapping.resolve(context: ctx), .mode(.refine))
    }

    func testExactMatch_Cursor_DelegatesToClaudeCode() {
        let ctx = CapturedContext(bundleID: "com.todesktop.230313mzl4w4u92", appName: "Cursor")
        XCTAssertEqual(ToneMapping.resolve(context: ctx), .mode(.claudeCode))
    }

    func testExactMatch_Notion_DelegatesToStructure() {
        let ctx = CapturedContext(bundleID: "notion.id", appName: "Notion")
        XCTAssertEqual(ToneMapping.resolve(context: ctx), .mode(.structure))
    }

    func testUnknownBundle_FallsBackToRefine() {
        let ctx = CapturedContext(bundleID: "com.example.unknown", appName: "Unknown")
        XCTAssertEqual(ToneMapping.resolve(context: ctx), .mode(.refine))
    }

    func testEmptyContext_FallsBackToRefine() {
        XCTAssertEqual(ToneMapping.resolve(context: .empty), .mode(.refine))
    }

    func testNilBundleID_FallsBackToRefine() {
        let ctx = CapturedContext(bundleID: nil, appName: "Whatever")
        XCTAssertEqual(ToneMapping.resolve(context: ctx), .mode(.refine))
    }

    func testEmptyBundleID_FallsBackToRefine() {
        let ctx = CapturedContext(bundleID: "", appName: "")
        XCTAssertEqual(ToneMapping.resolve(context: ctx), .mode(.refine))
    }

    func testFirstMatchWins_WhenMultipleRulesCouldMatch() {
        let rules: [ToneRule] = [
            .init(bundleIDPrefix: "com.apple.mail", delegated: .claudeCode),
            .init(bundleIDPrefix: "com.apple.mail", delegated: .refine),
        ]
        let ctx = CapturedContext(bundleID: "com.apple.mail", appName: "Mail")
        XCTAssertEqual(ToneMapping.resolve(context: ctx, rules: rules), .mode(.claudeCode))
    }

    func testPrefixRule_MatchesNamespacedBundle() {
        let rules: [ToneRule] = [
            .init(bundleIDPrefix: "com.slack.", delegated: .refine),
        ]
        let ctx = CapturedContext(bundleID: "com.slack.client.subapp", appName: "Slack subapp")
        XCTAssertEqual(ToneMapping.resolve(context: ctx, rules: rules), .mode(.refine))
    }

    func testPrefixRule_DoesNotMatchWithoutTrailingDot() {
        let rules: [ToneRule] = [
            .init(bundleIDPrefix: "com.slack", delegated: .refine),  // No trailing dot → exact match
        ]
        let ctx = CapturedContext(bundleID: "com.slack.client", appName: "Slack")
        // Should fall back via the hard fallback at the end of resolve().
        XCTAssertEqual(ToneMapping.resolve(context: ctx, rules: rules), .mode(.refine))
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
        XCTAssertFalse(rule.matches("com.tinyspeck.slackmacgap"))
        XCTAssertFalse(rule.matches("com.tinyspeck"))
    }

    func testDefaultRules_HaveExpectedCoverage() {
        // Sanity-check the shipped table — these are the user-promised bundle IDs.
        let mustHave: [(String, ToneDelegate)] = [
            ("com.apple.mail", .mode(.refine)),
            ("com.todesktop.230313mzl4w4u92", .mode(.claudeCode)),
            ("com.apple.Terminal", .mode(.claudeCode)),
            ("com.tinyspeck.slackmacgap", .mode(.refine)),
            ("notion.id", .mode(.structure)),
            ("md.obsidian", .mode(.structure)),
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

    // MARK: - Workflow delegation (Sprint 3.2)

    func testWorkflowDelegate_ResolvesToWorkflowCase() {
        let rules: [ToneRule] = [
            .init(bundleIDPrefix: "com.example.coder", workflowId: "wf-test-chain"),
        ]
        let ctx = CapturedContext(bundleID: "com.example.coder", appName: "Coder")
        XCTAssertEqual(
            ToneMapping.resolve(context: ctx, rules: rules),
            .workflow(workflowId: "wf-test-chain")
        )
    }

    func testWorkflowAndModeRules_CoexistInSameTable() {
        let rules: [ToneRule] = [
            .init(bundleIDPrefix: "com.apple.mail", delegated: .refine),
            .init(bundleIDPrefix: "com.notion.client", workflowId: "wf-notes-chain"),
            .init(bundleIDPrefix: "com.example.editor", delegated: .structure),
        ]
        XCTAssertEqual(
            ToneMapping.resolve(
                context: CapturedContext(bundleID: "com.apple.mail", appName: nil),
                rules: rules
            ),
            .mode(.refine)
        )
        XCTAssertEqual(
            ToneMapping.resolve(
                context: CapturedContext(bundleID: "com.notion.client", appName: nil),
                rules: rules
            ),
            .workflow(workflowId: "wf-notes-chain")
        )
        XCTAssertEqual(
            ToneMapping.resolve(
                context: CapturedContext(bundleID: "com.example.editor", appName: nil),
                rules: rules
            ),
            .mode(.structure)
        )
    }

    func testToneDelegateEquatable() {
        XCTAssertEqual(ToneDelegate.mode(.refine), ToneDelegate.mode(.refine))
        XCTAssertNotEqual(ToneDelegate.mode(.refine), ToneDelegate.mode(.structure))
        XCTAssertEqual(
            ToneDelegate.workflow(workflowId: "wf-1"),
            ToneDelegate.workflow(workflowId: "wf-1")
        )
        XCTAssertNotEqual(
            ToneDelegate.workflow(workflowId: "wf-1"),
            ToneDelegate.workflow(workflowId: "wf-2")
        )
        XCTAssertNotEqual(
            ToneDelegate.mode(.refine),
            ToneDelegate.workflow(workflowId: "wf-1")
        )
    }
}
