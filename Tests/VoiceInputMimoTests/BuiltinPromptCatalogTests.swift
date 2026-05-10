import XCTest
@testable import VoiceInputMimo

final class BuiltinPromptCatalogTests: XCTestCase {

    // MARK: - Skills inventory

    func testCatalogProvidesTenBuiltinSkills() {
        XCTAssertEqual(BuiltinPromptCatalog.skills.count, 10)
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
            "builtin-speech-act-zh",
            "builtin-light-rewrite-zh",
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
        XCTAssertEqual(map["builtin-light-rewrite-zh"], .style)
        XCTAssertEqual(map["builtin-style-preserve-identifiers"], .style)
        XCTAssertEqual(map["builtin-collapse-stutter"], .recovery)
        XCTAssertEqual(map["builtin-recover-en-cn-homophones"], .recovery)
        XCTAssertEqual(map["builtin-speech-act-detection"], .speechAct)
        XCTAssertEqual(map["builtin-speech-act-zh"], .speechAct)
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

    func testCatalogProvidesThreeBuiltinProfiles() {
        XCTAssertEqual(BuiltinPromptCatalog.profiles.count, 3)
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

    func testPolishZhProfileExistsAndIsRefineMode() {
        let p = BuiltinPromptCatalog.profiles.first { $0.id == "builtin-polish-zh" }
        XCTAssertNotNil(p)
        XCTAssertEqual(p?.mode, .refine)
    }

    func testPolishZhSkillIDsResolveToBuiltinSkills() {
        let p = BuiltinPromptCatalog.profiles.first { $0.id == "builtin-polish-zh" }!
        let skillIDSet = Set(BuiltinPromptCatalog.skills.map(\.id))
        for skillID in p.skillIDs {
            XCTAssertTrue(skillIDSet.contains(skillID), "skill \(skillID) referenced but not in catalog")
        }
    }

    func testPolishZhSkillOrderMatchesPlan() {
        // output-same-language FIRST so the model commits to Chinese output
        // before any cleanup-style skills can drag it toward translation.
        // speech-act-zh BEFORE light-rewrite-zh so register-preservation rule
        // has higher priority than the rewrite license.
        let p = BuiltinPromptCatalog.profiles.first { $0.id == "builtin-polish-zh" }!
        XCTAssertEqual(p.skillIDs, [
            "builtin-output-same-language",
            "builtin-speech-act-zh",
            "builtin-light-rewrite-zh",
            "builtin-drop-fillers",
            "builtin-collapse-stutter",
            "builtin-recover-en-cn-homophones",
            "builtin-style-preserve-identifiers",
        ])
    }

    func testPolishZhDoesNotIncludeNoRephrase() {
        // The whole point of polish-zh is to lift the no-rephrase lock so the
        // model can do light spoken-to-written normalization. If no-rephrase
        // sneaks back in, polish degrades into Default Refine.
        let p = BuiltinPromptCatalog.profiles.first { $0.id == "builtin-polish-zh" }!
        XCTAssertFalse(p.skillIDs.contains("builtin-no-rephrase"))
    }

    func testPolishZhRendersWithCriticalKeywords() {
        let profile = BuiltinPromptCatalog.profiles.first { $0.id == "builtin-polish-zh" }!
        let rendered = PromptComposer.render(profile: profile, skills: BuiltinPromptCatalog.skills)

        XCTAssertTrue(rendered.contains("/no_think"))
        XCTAssertTrue(rendered.contains("Examples"), "few-shot examples must remain in prompt")
        XCTAssertTrue(rendered.contains("假定"), "must demonstrate stutter cleanup in examples")
        XCTAssertTrue(
            rendered.contains("light spoken-to-written") || rendered.contains("Light spoken-to-written"),
            "must license light rewrite"
        )
        XCTAssertTrue(rendered.contains("speech act") || rendered.contains("Speech act"))
        XCTAssertFalse(
            rendered.contains("translate to English") && !rendered.contains("Never translate to English"),
            "polish-zh must explicitly forbid English translation"
        )
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
        // `output-english-only` is FIRST so the LLM commits to translating
        // before any cleanup-style skills (which mostly discuss preserving
        // Chinese) drag it back into a "process this Chinese" mindset and
        // skip translation. v1.0.2 regression fix.
        let p = BuiltinPromptCatalog.profiles.first { $0.id == "builtin-default-claude-code" }!
        XCTAssertEqual(p.skillIDs, [
            "builtin-output-english-only",
            "builtin-speech-act-detection",
            "builtin-recover-en-cn-homophones",
            "builtin-drop-fillers",
            "builtin-collapse-stutter",
            "builtin-style-preserve-identifiers",
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
