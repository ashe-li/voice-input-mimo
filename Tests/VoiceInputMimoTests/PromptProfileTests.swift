import XCTest
@testable import VoiceInputMimo

final class PromptProfileTests: XCTestCase {

    // MARK: - SkillCategory

    func testSkillCategoryRawValuesMatchExpected() {
        XCTAssertEqual(SkillCategory.recovery.rawValue, "recovery")
        XCTAssertEqual(SkillCategory.style.rawValue, "style")
        XCTAssertEqual(SkillCategory.format.rawValue, "format")
        XCTAssertEqual(SkillCategory.domain.rawValue, "domain")
        XCTAssertEqual(SkillCategory.speechAct.rawValue, "speechAct")
        XCTAssertEqual(SkillCategory.planning.rawValue, "planning")
    }

    func testSkillCategoryAllCasesIsExhaustive() {
        XCTAssertEqual(SkillCategory.allCases.count, 6)
    }

    func testSkillCategoryCodableRoundTrip() throws {
        for category in SkillCategory.allCases {
            let data = try JSONEncoder().encode(category)
            let decoded = try JSONDecoder().decode(SkillCategory.self, from: data)
            XCTAssertEqual(category, decoded)
        }
    }

    // MARK: - RefineMode (extended to Codable)

    func testRefineModeCodableRoundTrip() throws {
        for mode in [RefineMode.refine, .claudeCode, .structure] {
            let data = try JSONEncoder().encode(mode)
            let decoded = try JSONDecoder().decode(RefineMode.self, from: data)
            XCTAssertEqual(mode, decoded)
        }
    }

    // MARK: - PromptSkill

    func testPromptSkillCodableRoundTripFullyPopulated() throws {
        let skill = PromptSkill(
            id: "builtin-drop-fillers",
            name: "Drop verbal fillers",
            category: .style,
            content: "- Drop 嗯, 呃, 啊",
            slot: "style_rules",
            description: "Removes meaningless filler tokens",
            isBuiltin: true
        )
        let data = try JSONEncoder().encode(skill)
        let decoded = try JSONDecoder().decode(PromptSkill.self, from: data)
        XCTAssertEqual(skill, decoded)
    }

    func testPromptSkillCodableRoundTripMinimal() throws {
        let skill = PromptSkill(
            id: "user-xyz",
            name: "Custom",
            category: .domain,
            content: "- something"
        )
        XCTAssertNil(skill.slot)
        XCTAssertNil(skill.description)
        XCTAssertFalse(skill.isBuiltin)

        let data = try JSONEncoder().encode(skill)
        let decoded = try JSONDecoder().decode(PromptSkill.self, from: data)
        XCTAssertEqual(skill, decoded)
    }

    // MARK: - PromptProfile

    func testPromptProfileCodableRoundTripFullyPopulated() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let profile = PromptProfile(
            id: "default-refine",
            name: "Default Refine",
            mode: .refine,
            basePrompt: "/no_think You clean up Chinese ASR.",
            skillIDs: ["builtin-drop-fillers", "builtin-collapse-stutter"],
            suffix: nil,
            modelOverride: "qwen3-8b-mlx",
            temperature: 0.3,
            displayLabel: "Default Refine",
            slotOverrides: ["style_rules": "- custom rule"],
            createdAt: now,
            updatedAt: now,
            isBuiltin: true
        )
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(PromptProfile.self, from: data)
        XCTAssertEqual(profile, decoded)
    }

    func testPromptProfileCodableRoundTripMinimal() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let profile = PromptProfile(
            id: "user-xyz",
            name: "My Profile",
            mode: .claudeCode,
            basePrompt: "...",
            skillIDs: [],
            createdAt: now,
            updatedAt: now
        )
        XCTAssertNil(profile.suffix)
        XCTAssertNil(profile.modelOverride)
        XCTAssertNil(profile.temperature)
        XCTAssertNil(profile.displayLabel)
        XCTAssertNil(profile.slotOverrides)
        XCTAssertFalse(profile.isBuiltin)

        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(PromptProfile.self, from: data)
        XCTAssertEqual(profile, decoded)
    }

    func testPromptProfileMutateUpdatesValueSemantics() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var profile = PromptProfile(
            id: "p1",
            name: "First",
            mode: .refine,
            basePrompt: "a",
            skillIDs: [],
            createdAt: now,
            updatedAt: now
        )
        let original = profile
        profile.name = "Second"
        XCTAssertEqual(original.name, "First")
        XCTAssertEqual(profile.name, "Second")
        XCTAssertEqual(original.id, profile.id) // id stays
    }

    // MARK: - ActiveSelection

    func testActiveSelectionCodableRoundTrip() throws {
        let selection = ActiveSelection(
            refineProfileID: "default-refine",
            claudeCodeProfileID: "default-claude-code"
        )
        let data = try JSONEncoder().encode(selection)
        let decoded = try JSONDecoder().decode(ActiveSelection.self, from: data)
        XCTAssertEqual(selection.refineProfileID, decoded.refineProfileID)
        XCTAssertEqual(selection.claudeCodeProfileID, decoded.claudeCodeProfileID)
    }

    // MARK: - JSON shape stability (forward compat)

    func testPromptProfileJSONOmitsNilOptionalFields() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let profile = PromptProfile(
            id: "p1",
            name: "n",
            mode: .refine,
            basePrompt: "b",
            skillIDs: [],
            createdAt: now,
            updatedAt: now
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(profile)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("\"suffix\""), "nil suffix should not be encoded")
        XCTAssertFalse(json.contains("\"modelOverride\""))
        XCTAssertFalse(json.contains("\"temperature\""))
        XCTAssertFalse(json.contains("\"displayLabel\""))
        XCTAssertFalse(json.contains("\"slotOverrides\""))
    }

    func testPromptSkillJSONOmitsNilOptionalFields() throws {
        let skill = PromptSkill(id: "s1", name: "n", category: .style, content: "c")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(skill)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("\"slot\""))
        XCTAssertFalse(json.contains("\"description\""))
    }

    func testPromptProfileDecodingToleratesUnknownFields() throws {
        let json = """
        {
          "id": "p1",
          "name": "n",
          "mode": "refine",
          "basePrompt": "b",
          "skillIDs": [],
          "createdAt": -978307200,
          "updatedAt": -978307200,
          "isBuiltin": false,
          "futureField": "ignored"
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(PromptProfile.self, from: json)
        XCTAssertEqual(decoded.id, "p1")
    }
}
