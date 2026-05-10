import XCTest
@testable import VoiceInputMimo

final class PromptStoreTests: XCTestCase {
    private var rootDirectory: URL!
    private var store: PromptStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceInputMimoPromptStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        store = PromptStore(rootDirectory: rootDirectory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: rootDirectory)
        rootDirectory = nil
        store = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func makeProfile(
        id: String = UUID().uuidString,
        mode: RefineMode = .refine,
        name: String = "Test",
        isBuiltin: Bool = false
    ) -> PromptProfile {
        let now = Date(timeIntervalSinceReferenceDate: 1)
        return PromptProfile(
            id: id,
            name: name,
            mode: mode,
            basePrompt: "/no_think test",
            skillIDs: [],
            createdAt: now,
            updatedAt: now,
            isBuiltin: isBuiltin
        )
    }

    private func makeSkill(
        id: String = UUID().uuidString,
        name: String = "TestSkill",
        category: SkillCategory = .style,
        isBuiltin: Bool = false
    ) -> PromptSkill {
        PromptSkill(
            id: id,
            name: name,
            category: category,
            content: "- rule",
            isBuiltin: isBuiltin
        )
    }

    // MARK: - Profile CRUD

    func testSaveProfileThenLoadReturnsSameValue() throws {
        let profile = makeProfile(id: "p1", name: "First")
        try store.saveProfile(profile)
        let loaded = try store.loadProfile(id: "p1", mode: .refine)
        XCTAssertEqual(loaded, profile)
    }

    func testLoadProfileMissingReturnsNil() throws {
        let loaded = try store.loadProfile(id: "ghost", mode: .refine)
        XCTAssertNil(loaded)
    }

    func testListProfilesEmptyDirectoryReturnsEmpty() throws {
        let list = try store.listProfiles(mode: .refine)
        XCTAssertTrue(list.isEmpty)
    }

    func testListProfilesReturnsAllInModeSortedByName() throws {
        try store.saveProfile(makeProfile(id: "p2", name: "Bravo"))
        try store.saveProfile(makeProfile(id: "p1", name: "Alpha"))
        try store.saveProfile(makeProfile(id: "p3", name: "Charlie"))
        let list = try store.listProfiles(mode: .refine)
        XCTAssertEqual(list.map(\.name), ["Alpha", "Bravo", "Charlie"])
    }

    func testProfileModesAreIsolated() throws {
        try store.saveProfile(makeProfile(id: "p1", mode: .refine, name: "RefineOne"))
        try store.saveProfile(makeProfile(id: "p2", mode: .claudeCode, name: "ClaudeOne"))
        XCTAssertEqual(try store.listProfiles(mode: .refine).map(\.name), ["RefineOne"])
        XCTAssertEqual(try store.listProfiles(mode: .claudeCode).map(\.name), ["ClaudeOne"])
    }

    func testSaveProfileOverwritesExistingByID() throws {
        var profile = makeProfile(id: "p1", name: "First")
        try store.saveProfile(profile)
        profile.name = "Renamed"
        try store.saveProfile(profile)
        let loaded = try store.loadProfile(id: "p1", mode: .refine)
        XCTAssertEqual(loaded?.name, "Renamed")
        XCTAssertEqual(try store.listProfiles(mode: .refine).count, 1)
    }

    func testDeleteProfileRemovesFile() throws {
        try store.saveProfile(makeProfile(id: "p1"))
        try store.deleteProfile(id: "p1", mode: .refine)
        XCTAssertNil(try store.loadProfile(id: "p1", mode: .refine))
    }

    func testDeleteProfileRejectsBuiltin() throws {
        try store.saveProfile(makeProfile(id: "default-refine", isBuiltin: true))
        XCTAssertThrowsError(try store.deleteProfile(id: "default-refine", mode: .refine)) { error in
            guard case PromptStoreError.cannotDeleteBuiltin(let id) = error else {
                XCTFail("Wrong error: \(error)")
                return
            }
            XCTAssertEqual(id, "default-refine")
        }
        XCTAssertNotNil(try store.loadProfile(id: "default-refine", mode: .refine))
    }

    func testDeleteProfileMissingIsNoOp() throws {
        XCTAssertNoThrow(try store.deleteProfile(id: "ghost", mode: .refine))
    }

    func testListProfilesIgnoresCorruptedJSONFiles() throws {
        try store.saveProfile(makeProfile(id: "p1", name: "Valid"))
        // Write a corrupted JSON file directly
        let badURL = rootDirectory
            .appendingPathComponent("profiles/refine/corrupt.json")
        try "not json".data(using: .utf8)!.write(to: badURL)
        let list = try store.listProfiles(mode: .refine)
        XCTAssertEqual(list.map(\.name), ["Valid"])
    }

    func testAtomicWriteLeavesNoTempFiles() throws {
        try store.saveProfile(makeProfile(id: "p1"))
        let dir = rootDirectory.appendingPathComponent("profiles/refine")
        let entries = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(entries, ["p1.json"])
    }

    // MARK: - Skill CRUD

    func testSaveSkillThenLoadReturnsSameValue() throws {
        let skill = makeSkill(id: "s1", name: "First")
        try store.saveSkill(skill)
        XCTAssertEqual(try store.loadSkill(id: "s1"), skill)
    }

    func testListSkillsReturnsAllSortedByName() throws {
        try store.saveSkill(makeSkill(id: "s2", name: "Bravo"))
        try store.saveSkill(makeSkill(id: "s1", name: "Alpha"))
        XCTAssertEqual(try store.listSkills().map(\.name), ["Alpha", "Bravo"])
    }

    func testDeleteSkillRejectsBuiltin() throws {
        try store.saveSkill(makeSkill(id: "builtin-x", isBuiltin: true))
        XCTAssertThrowsError(try store.deleteSkill(id: "builtin-x")) { error in
            guard case PromptStoreError.cannotDeleteBuiltin = error else {
                XCTFail("Wrong error: \(error)")
                return
            }
        }
    }

    func testDeleteSkillRemovesUserSkill() throws {
        try store.saveSkill(makeSkill(id: "s1"))
        try store.deleteSkill(id: "s1")
        XCTAssertNil(try store.loadSkill(id: "s1"))
    }

    // MARK: - ActiveSelection

    func testLoadActiveSelectionMissingReturnsNil() throws {
        XCTAssertNil(try store.loadActiveSelection())
    }

    func testSaveActiveSelectionThenLoadReturnsSame() throws {
        let sel = ActiveSelection(refineProfileID: "r1", claudeCodeProfileID: "c1")
        try store.saveActiveSelection(sel)
        XCTAssertEqual(try store.loadActiveSelection(), sel)
    }

    func testSaveActiveSelectionOverwrites() throws {
        try store.saveActiveSelection(
            ActiveSelection(refineProfileID: "r1", claudeCodeProfileID: "c1")
        )
        try store.saveActiveSelection(
            ActiveSelection(refineProfileID: "r2", claudeCodeProfileID: "c2")
        )
        XCTAssertEqual(
            try store.loadActiveSelection(),
            ActiveSelection(refineProfileID: "r2", claudeCodeProfileID: "c2")
        )
    }

    // MARK: - Active resolution

    func testActiveProfileResolvesViaSelection() throws {
        try store.saveProfile(makeProfile(id: "r1", mode: .refine, name: "Refine"))
        try store.saveProfile(makeProfile(id: "c1", mode: .claudeCode, name: "Claude"))
        try store.saveActiveSelection(
            ActiveSelection(refineProfileID: "r1", claudeCodeProfileID: "c1")
        )
        XCTAssertEqual(try store.activeProfile(for: .refine)?.id, "r1")
        XCTAssertEqual(try store.activeProfile(for: .claudeCode)?.id, "c1")
    }

    func testActiveProfileNilWhenSelectionMissing() throws {
        XCTAssertNil(try store.activeProfile(for: .refine))
    }

    func testActiveProfileNilWhenReferencedIDIsAbsent() throws {
        try store.saveActiveSelection(
            ActiveSelection(refineProfileID: "ghost", claudeCodeProfileID: "ghost")
        )
        XCTAssertNil(try store.activeProfile(for: .refine))
    }

    // MARK: - Concurrency smoke

    func testConcurrentSavesDoNotCrash() throws {
        let group = DispatchGroup()
        let queue = DispatchQueue.global(qos: .userInitiated)
        for i in 0..<20 {
            group.enter()
            queue.async {
                let p = self.makeProfile(id: "p\(i)", name: "P\(i)")
                try? self.store.saveProfile(p)
                group.leave()
            }
        }
        group.wait()
        XCTAssertEqual(try store.listProfiles(mode: .refine).count, 20)
    }
}
