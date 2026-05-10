import XCTest
@testable import VoiceInputMimo

final class PromptIOTests: XCTestCase {
    func test_encodeDecode_roundTrip() throws {
        let bundle = PromptBundle(
            profiles: [makeProfile(id: "p1", mode: .refine)],
            skills: [makeSkill(id: "s1")]
        )
        let data = try PromptIO.encode(bundle)
        let decoded = try PromptIO.decode(data)
        XCTAssertEqual(decoded.schemaVersion, PromptBundle.currentSchemaVersion)
        XCTAssertEqual(decoded.profiles.map(\.id), ["p1"])
        XCTAssertEqual(decoded.skills.map(\.id), ["s1"])
    }

    func test_decode_rejectsFutureSchema() {
        let bundle = PromptBundle(profiles: [], skills: [], schemaVersion: 99)
        let data = try! PromptIO.encode(bundle)
        XCTAssertThrowsError(try PromptIO.decode(data)) { err in
            guard case PromptIOError.unsupportedSchema(let v) = err else {
                return XCTFail("expected unsupportedSchema, got \(err)")
            }
            XCTAssertEqual(v, 99)
        }
    }

    func test_decode_rejectsMalformedJSON() {
        let data = "not json".data(using: .utf8)!
        XCTAssertThrowsError(try PromptIO.decode(data)) { err in
            guard case PromptIOError.malformed = err else {
                return XCTFail("expected malformed, got \(err)")
            }
        }
    }

    // MARK: - PromptImportPlanner

    func test_planner_addsNewRecords() {
        let bundle = PromptBundle(
            profiles: [makeProfile(id: "p-new", mode: .refine)],
            skills: [makeSkill(id: "s-new")]
        )
        let plan = PromptImportPlanner.plan(
            incoming: bundle,
            existingProfiles: [],
            existingSkills: [],
            strategy: .replace
        )
        XCTAssertEqual(plan.profiles.count, 1)
        XCTAssertEqual(plan.skills.count, 1)
        XCTAssertEqual(plan.result.profilesAdded, 1)
        XCTAssertEqual(plan.result.skillsAdded, 1)
    }

    func test_planner_replaceStrategy_overwritesByID() {
        let existing = makeProfile(id: "p1", mode: .refine, name: "Old")
        let incoming = makeProfile(id: "p1", mode: .refine, name: "New")
        let bundle = PromptBundle(profiles: [incoming], skills: [])
        let plan = PromptImportPlanner.plan(
            incoming: bundle,
            existingProfiles: [existing],
            existingSkills: [],
            strategy: .replace
        )
        XCTAssertEqual(plan.profiles.count, 1)
        XCTAssertEqual(plan.profiles.first?.name, "New")
        XCTAssertEqual(plan.result.profilesReplaced, 1)
        XCTAssertEqual(plan.result.profilesAdded, 0)
    }

    func test_planner_renameStrategy_assignsNewIDAndMarksUserSkill() {
        let existing = makeSkill(id: "s1", name: "Old")
        let incoming = makeSkill(id: "s1", name: "New", isBuiltin: true)
        let bundle = PromptBundle(profiles: [], skills: [incoming])
        let plan = PromptImportPlanner.plan(
            incoming: bundle,
            existingProfiles: [],
            existingSkills: [existing],
            strategy: .rename
        )
        XCTAssertEqual(plan.skills.count, 1)
        XCTAssertNotEqual(plan.skills.first?.id, "s1")
        XCTAssertTrue(plan.skills.first?.id.hasPrefix("user-") == true)
        XCTAssertEqual(plan.skills.first?.isBuiltin, false)
        XCTAssertEqual(plan.result.skillsRenamed, 1)
    }

    func test_planner_skipStrategy_dropsConflicts() {
        let existing = makeProfile(id: "p1", mode: .refine, name: "Keep")
        let incoming = makeProfile(id: "p1", mode: .refine, name: "Drop")
        let bundle = PromptBundle(profiles: [incoming], skills: [])
        let plan = PromptImportPlanner.plan(
            incoming: bundle,
            existingProfiles: [existing],
            existingSkills: [],
            strategy: .skip
        )
        XCTAssertTrue(plan.profiles.isEmpty)
        XCTAssertEqual(plan.result.profilesSkipped, 1)
    }

    // MARK: - Helpers

    private func makeProfile(id: String, mode: RefineMode, name: String = "P") -> PromptProfile {
        PromptProfile(
            id: id,
            name: name,
            mode: mode,
            basePrompt: "base",
            skillIDs: [],
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func makeSkill(id: String, name: String = "S", isBuiltin: Bool = false) -> PromptSkill {
        PromptSkill(
            id: id,
            name: name,
            category: .style,
            content: "content",
            isBuiltin: isBuiltin
        )
    }
}
