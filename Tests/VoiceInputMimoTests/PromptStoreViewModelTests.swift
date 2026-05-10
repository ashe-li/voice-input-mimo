import XCTest
@testable import VoiceInputMimo

@MainActor
final class PromptStoreViewModelTests: XCTestCase {
    func test_initialState_isEmpty() {
        let store = MockPromptStore()
        let vm = PromptStoreViewModel(store: store)
        XCTAssertTrue(vm.profiles(for: .refine).isEmpty)
        XCTAssertTrue(vm.profiles(for: .claudeCode).isEmpty)
        XCTAssertTrue(vm.skills.isEmpty)
        XCTAssertNil(vm.activeSelection)
        XCTAssertFalse(vm.isLoading)
        XCTAssertNil(vm.lastError)
    }

    func test_reload_populatesFromStore() async {
        let store = MockPromptStore()
        let refineProfile = makeProfile(id: "p1", name: "Refine A", mode: .refine)
        let claudeProfile = makeProfile(id: "p2", name: "Claude A", mode: .claudeCode)
        let skill = makeSkill(id: "s1", name: "Skill A")
        store.refineProfiles = [refineProfile]
        store.claudeCodeProfiles = [claudeProfile]
        store.skills = [skill]
        store.activeSelection = ActiveSelection(refineProfileID: "p1", claudeCodeProfileID: "p2")

        let vm = PromptStoreViewModel(store: store)
        await vm.reload()

        XCTAssertEqual(vm.profiles(for: .refine).map(\.id), ["p1"])
        XCTAssertEqual(vm.profiles(for: .claudeCode).map(\.id), ["p2"])
        XCTAssertEqual(vm.skills.map(\.id), ["s1"])
        XCTAssertEqual(vm.activeSelection?.refineProfileID, "p1")
        XCTAssertNil(vm.lastError)
    }

    func test_reload_handlesError_capturesLastError() async {
        let store = MockPromptStore()
        store.shouldThrowOnList = true

        let vm = PromptStoreViewModel(store: store)
        await vm.reload()

        XCTAssertNotNil(vm.lastError)
        XCTAssertTrue(vm.profiles(for: .refine).isEmpty)
    }

    func test_reload_clearsLastError_onSuccess() async {
        let store = MockPromptStore()
        store.shouldThrowOnList = true
        let vm = PromptStoreViewModel(store: store)
        await vm.reload()
        XCTAssertNotNil(vm.lastError)

        store.shouldThrowOnList = false
        store.refineProfiles = [makeProfile(id: "p1", name: "Refine A", mode: .refine)]
        await vm.reload()
        XCTAssertNil(vm.lastError)
    }

    func test_activeProfileID_returnsCorrectIDPerMode() async {
        let store = MockPromptStore()
        store.activeSelection = ActiveSelection(refineProfileID: "rid", claudeCodeProfileID: "cid")
        let vm = PromptStoreViewModel(store: store)
        await vm.reload()

        XCTAssertEqual(vm.activeProfileID(for: .refine), "rid")
        XCTAssertEqual(vm.activeProfileID(for: .claudeCode), "cid")
    }

    func test_clearError_resetsLastError() async {
        let store = MockPromptStore()
        store.shouldThrowOnList = true
        let vm = PromptStoreViewModel(store: store)
        await vm.reload()
        XCTAssertNotNil(vm.lastError)

        vm.clearError()
        XCTAssertNil(vm.lastError)
    }

    // MARK: - Fixtures

    private func makeProfile(id: String, name: String, mode: RefineMode) -> PromptProfile {
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

    private func makeSkill(id: String, name: String) -> PromptSkill {
        PromptSkill(id: id, name: name, category: .style, content: "content")
    }
}

/// Minimal in-memory PromptStoreProviding fixture used by ViewModel tests.
/// Records mutations so future Phase 3 tests can also assert on saves/deletes.
final class MockPromptStore: PromptStoreProviding, @unchecked Sendable {
    var refineProfiles: [PromptProfile] = []
    var claudeCodeProfiles: [PromptProfile] = []
    var skills: [PromptSkill] = []
    var activeSelection: ActiveSelection?
    var shouldThrowOnList: Bool = false

    enum FixtureError: Error { case forced }

    func saveProfile(_ profile: PromptProfile) throws {
        switch profile.mode {
        case .refine:
            refineProfiles.removeAll { $0.id == profile.id }
            refineProfiles.append(profile)
        case .claudeCode:
            claudeCodeProfiles.removeAll { $0.id == profile.id }
            claudeCodeProfiles.append(profile)
        }
    }

    func loadProfile(id: String, mode: RefineMode) throws -> PromptProfile? {
        try listProfiles(mode: mode).first { $0.id == id }
    }

    func listProfiles(mode: RefineMode) throws -> [PromptProfile] {
        if shouldThrowOnList { throw FixtureError.forced }
        switch mode {
        case .refine: return refineProfiles
        case .claudeCode: return claudeCodeProfiles
        }
    }

    func deleteProfile(id: String, mode: RefineMode) throws {
        switch mode {
        case .refine: refineProfiles.removeAll { $0.id == id }
        case .claudeCode: claudeCodeProfiles.removeAll { $0.id == id }
        }
    }

    func saveSkill(_ skill: PromptSkill) throws {
        skills.removeAll { $0.id == skill.id }
        skills.append(skill)
    }

    func loadSkill(id: String) throws -> PromptSkill? {
        skills.first { $0.id == id }
    }

    func listSkills() throws -> [PromptSkill] {
        if shouldThrowOnList { throw FixtureError.forced }
        return skills
    }

    func deleteSkill(id: String) throws {
        skills.removeAll { $0.id == id }
    }

    func loadActiveSelection() throws -> ActiveSelection? {
        activeSelection
    }

    func saveActiveSelection(_ selection: ActiveSelection) throws {
        activeSelection = selection
    }

    func activeProfile(for mode: RefineMode) throws -> PromptProfile? {
        guard let sel = activeSelection else { return nil }
        let id = mode == .refine ? sel.refineProfileID : sel.claudeCodeProfileID
        return try loadProfile(id: id, mode: mode)
    }
}
