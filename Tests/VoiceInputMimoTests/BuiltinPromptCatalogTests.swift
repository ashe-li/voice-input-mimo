import XCTest
@testable import VoiceInputMimo

final class BuiltinPromptCatalogTests: XCTestCase {

    // MARK: - Skills inventory

    func testCatalogProvidesEightBuiltinSkills() {
        XCTAssertEqual(BuiltinPromptCatalog.skills.count, 8)
    }

    func testAllBuiltinSkillsHaveBuiltinFlag() {
        for skill in BuiltinPromptCatalog.skills {
            XCTAssertTrue(skill.isBuiltin, "skill \(skill.id) must be marked builtin")
        }
    }

    func testBuiltinSkillIDsAreUnique() {
        let ids = BuiltinPromptCatalog.skills.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testBuiltinSkillIDsArePrefixed() {
        for skill in BuiltinPromptCatalog.skills {
            XCTAssertTrue(skill.id.hasPrefix("builtin-"), "skill id \(skill.id) should start with 'builtin-'")
        }
    }

    func testEachExpectedSkillIsPresent() {
        let expectedIDs: Set<String> = [
            "builtin-output-same-language",
            "builtin-drop-fillers",
            "builtin-collapse-stutter",
            "builtin-recover-en-cn-homophones",
            "builtin-no-rephrase",
            "builtin-speech-act-detection",
            "builtin-style-preserve-identifiers",
            "builtin-output-english-only",
        ]
        let actualIDs = Set(BuiltinPromptCatalog.skills.map(\.id))
        XCTAssertEqual(actualIDs, expectedIDs)
    }

    func testSkillCategoriesMatchPlan() {
        let map = Dictionary(uniqueKeysWithValues: BuiltinPromptCatalog.skills.map { ($0.id, $0.category) })
        XCTAssertEqual(map["builtin-output-same-language"], .format)
        XCTAssertEqual(map["builtin-output-english-only"], .format)
        XCTAssertEqual(map["builtin-drop-fillers"], .style)
        XCTAssertEqual(map["builtin-no-rephrase"], .style)
        XCTAssertEqual(map["builtin-style-preserve-identifiers"], .style)
        XCTAssertEqual(map["builtin-collapse-stutter"], .recovery)
        XCTAssertEqual(map["builtin-recover-en-cn-homophones"], .recovery)
        XCTAssertEqual(map["builtin-speech-act-detection"], .speechAct)
    }

    func testAllBuiltinSkillsHaveNonEmptyContent() {
        for skill in BuiltinPromptCatalog.skills {
            XCTAssertFalse(
                skill.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "skill \(skill.id) has empty content"
            )
        }
    }

    // MARK: - Profiles

    func testCatalogProvidesTwoBuiltinProfiles() {
        XCTAssertEqual(BuiltinPromptCatalog.profiles.count, 2)
    }

    func testBuiltinProfilesAreMarkedBuiltin() {
        for profile in BuiltinPromptCatalog.profiles {
            XCTAssertTrue(profile.isBuiltin)
        }
    }

    func testDefaultRefineProfileExistsAndIsRefineMode() {
        let p = BuiltinPromptCatalog.profiles.first { $0.id == "builtin-default-refine" }
        XCTAssertNotNil(p)
        XCTAssertEqual(p?.mode, .refine)
    }

    func testDefaultClaudeCodeProfileExistsAndIsClaudeCodeMode() {
        let p = BuiltinPromptCatalog.profiles.first { $0.id == "builtin-default-claude-code" }
        XCTAssertNotNil(p)
        XCTAssertEqual(p?.mode, .claudeCode)
    }

    func testDefaultRefineSkillIDsResolveToBuiltinSkills() {
        let p = BuiltinPromptCatalog.profiles.first { $0.id == "builtin-default-refine" }!
        let skillIDSet = Set(BuiltinPromptCatalog.skills.map(\.id))
        for skillID in p.skillIDs {
            XCTAssertTrue(skillIDSet.contains(skillID), "skill \(skillID) referenced but not in catalog")
        }
    }

    func testDefaultClaudeCodeSkillIDsResolveToBuiltinSkills() {
        let p = BuiltinPromptCatalog.profiles.first { $0.id == "builtin-default-claude-code" }!
        let skillIDSet = Set(BuiltinPromptCatalog.skills.map(\.id))
        for skillID in p.skillIDs {
            XCTAssertTrue(skillIDSet.contains(skillID), "skill \(skillID) referenced but not in catalog")
        }
    }

    func testDefaultRefineSkillOrderMatchesPlan() {
        let p = BuiltinPromptCatalog.profiles.first { $0.id == "builtin-default-refine" }!
        XCTAssertEqual(p.skillIDs, [
            "builtin-output-same-language",
            "builtin-drop-fillers",
            "builtin-collapse-stutter",
            "builtin-recover-en-cn-homophones",
            "builtin-no-rephrase",
        ])
    }

    func testDefaultClaudeCodeSkillOrderMatchesPlan() {
        let p = BuiltinPromptCatalog.profiles.first { $0.id == "builtin-default-claude-code" }!
        XCTAssertEqual(p.skillIDs, [
            "builtin-speech-act-detection",
            "builtin-recover-en-cn-homophones",
            "builtin-drop-fillers",
            "builtin-collapse-stutter",
            "builtin-style-preserve-identifiers",
            "builtin-output-english-only",
        ])
    }

    // MARK: - Rendered content sanity checks (regression guard for backtest baseline)

    func testDefaultRefineRendersWithCriticalKeywords() {
        let profile = BuiltinPromptCatalog.profiles.first { $0.id == "builtin-default-refine" }!
        let rendered = PromptComposer.render(profile: profile, skills: BuiltinPromptCatalog.skills)

        // Anchor phrases that the v1.1 baseline relied on
        XCTAssertTrue(rendered.contains("/no_think"), "must keep /no_think directive for Qwen3")
        XCTAssertTrue(rendered.contains("配森"), "must teach Python misheard mapping")
        XCTAssertTrue(rendered.contains("Python"))
        XCTAssertTrue(rendered.contains("假假定") || rendered.contains("假定"), "must mention stutter example")
        XCTAssertTrue(rendered.contains("呃") || rendered.contains("filler") || rendered.contains("Filler"))
        XCTAssertTrue(rendered.contains("Examples"), "few-shot examples must remain in prompt")
    }

    func testDefaultClaudeCodeRendersWithCriticalKeywords() {
        let profile = BuiltinPromptCatalog.profiles.first { $0.id == "builtin-default-claude-code" }!
        let rendered = PromptComposer.render(profile: profile, skills: BuiltinPromptCatalog.skills)

        XCTAssertTrue(rendered.contains("/no_think"))
        XCTAssertTrue(rendered.contains("Speech act") || rendered.contains("speech act"))
        XCTAssertTrue(rendered.contains("REQUEST") || rendered.contains("imperative"))
        XCTAssertTrue(rendered.contains("Output ONLY") || rendered.contains("ONLY the translation"))
    }
}
