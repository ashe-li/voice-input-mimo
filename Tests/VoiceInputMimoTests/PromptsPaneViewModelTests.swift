import XCTest
@testable import VoiceInputMimo

@MainActor
final class PromptsPaneViewModelTests: XCTestCase {
    func test_initialState_hasDefaultsAndNoDraft() {
        let pane = PromptsPaneViewModel(refiner: MockRefiner())
        XCTAssertEqual(pane.selectedMode, .refine)
        XCTAssertNil(pane.selectedProfileID)
        XCTAssertNil(pane.draft)
        XCTAssertFalse(pane.isRunning)
        XCTAssertTrue(pane.testHistory.isEmpty)
        XCTAssertFalse(pane.testInput.isEmpty)  // Sample text seeded
    }

    func test_ensureSelection_picksActiveProfile_whenAvailable() async {
        let storeVM = await fixturedStore()
        storeVM.setActiveProfile(id: "p2", mode: .refine)

        let pane = PromptsPaneViewModel(refiner: MockRefiner())
        pane.ensureSelection(from: storeVM)

        XCTAssertEqual(pane.selectedProfileID, "p2")
        XCTAssertEqual(pane.draft?.id, "p2")
    }

    func test_ensureSelection_fallsBackToFirst_whenNoActive() async {
        let storeVM = await fixturedStore()

        let pane = PromptsPaneViewModel(refiner: MockRefiner())
        pane.ensureSelection(from: storeVM)

        XCTAssertNotNil(pane.selectedProfileID)
        XCTAssertNotNil(pane.draft)
    }

    func test_ensureSelection_clears_whenNoProfilesExist() {
        let store = MockPromptStore()
        let storeVM = PromptStoreViewModel(store: store)
        let pane = PromptsPaneViewModel(refiner: MockRefiner())
        pane.ensureSelection(from: storeVM)
        XCTAssertNil(pane.selectedProfileID)
        XCTAssertNil(pane.draft)
    }

    func test_toggleSkill_addsThenRemovesFromDraft() async {
        let storeVM = await fixturedStore()
        let pane = PromptsPaneViewModel(refiner: MockRefiner())
        pane.ensureSelection(from: storeVM)
        let originalCount = pane.draft?.skillIDs.count ?? 0

        pane.toggleSkill("new-skill")
        XCTAssertEqual(pane.draft?.skillIDs.count, originalCount + 1)
        XCTAssertTrue(pane.draft?.skillIDs.contains("new-skill") == true)

        pane.toggleSkill("new-skill")
        XCTAssertEqual(pane.draft?.skillIDs.count, originalCount)
        XCTAssertFalse(pane.draft?.skillIDs.contains("new-skill") == true)
    }

    func test_moveSkill_reorders() async {
        let storeVM = await fixturedStore()
        // Configure a draft with 3 ordered skills
        let p = PromptProfile(
            id: "p-order",
            name: "Order",
            mode: .refine,
            basePrompt: "base",
            skillIDs: ["a", "b", "c"],
            createdAt: Date(),
            updatedAt: Date()
        )
        let pane = PromptsPaneViewModel(refiner: MockRefiner())
        pane.draft = p

        pane.moveSkill(from: IndexSet(integer: 0), to: 3)  // a → end
        XCTAssertEqual(pane.draft?.skillIDs, ["b", "c", "a"])

        _ = storeVM  // silence unused
    }

    func test_runTest_appendsToHistory_onSuccess() async {
        let refiner = MockRefiner()
        let pane = PromptsPaneViewModel(refiner: refiner)
        pane.testInput = "input text"
        await pane.runTest()

        XCTAssertEqual(pane.testHistory.count, 1)
        XCTAssertEqual(pane.testHistory.first?.input, "input text")
        XCTAssertEqual(pane.testHistory.first?.output, "mocked: input text")
        XCTAssertNil(pane.testHistory.first?.error)
    }

    func test_runTest_skipsEmptyInput() async {
        let pane = PromptsPaneViewModel(refiner: MockRefiner())
        pane.testInput = "   "
        await pane.runTest()
        XCTAssertEqual(pane.testHistory.count, 0)
    }

    func test_runTest_capsHistoryAtMax() async {
        let refiner = MockRefiner()
        let pane = PromptsPaneViewModel(refiner: refiner)
        pane.testInput = "hi"
        for _ in 1...12 {
            await pane.runTest()
        }
        XCTAssertEqual(pane.testHistory.count, 10)
    }

    func test_clearHistory_emptiesEntries() async {
        let pane = PromptsPaneViewModel(refiner: MockRefiner())
        pane.testInput = "one"
        await pane.runTest()
        XCTAssertEqual(pane.testHistory.count, 1)
        pane.clearHistory()
        XCTAssertTrue(pane.testHistory.isEmpty)
    }

    // MARK: - Helpers

    private func fixturedStore() async -> PromptStoreViewModel {
        let store = MockPromptStore()
        store.refineProfiles = [
            PromptProfile(id: "p1", name: "Alpha", mode: .refine, basePrompt: "alpha", skillIDs: [], createdAt: Date(), updatedAt: Date()),
            PromptProfile(id: "p2", name: "Bravo", mode: .refine, basePrompt: "bravo", skillIDs: ["s1"], createdAt: Date(), updatedAt: Date())
        ]
        store.skills = [
            PromptSkill(id: "s1", name: "Skill 1", category: .style, content: "x")
        ]
        let vm = PromptStoreViewModel(store: store)
        await vm.reload()
        return vm
    }
}

@MainActor
final class PromptStoreViewModelMutationTests: XCTestCase {
    func test_saveProfile_persistsAndRefreshesList() async {
        let store = MockPromptStore()
        let vm = PromptStoreViewModel(store: store)
        let p = PromptProfile(id: "new", name: "Z", mode: .refine, basePrompt: "x", skillIDs: [], createdAt: Date(), updatedAt: Date())
        vm.saveProfile(p)
        XCTAssertEqual(vm.profiles(for: .refine).map(\.id), ["new"])
        XCTAssertEqual(store.refineProfiles.first?.id, "new")
    }

    func test_deleteProfile_removesIt() async {
        let store = MockPromptStore()
        store.refineProfiles = [
            PromptProfile(id: "x", name: "X", mode: .refine, basePrompt: "x", skillIDs: [], createdAt: Date(), updatedAt: Date())
        ]
        let vm = PromptStoreViewModel(store: store)
        await vm.reload()
        XCTAssertEqual(vm.profiles(for: .refine).count, 1)
        vm.deleteProfile(id: "x", mode: .refine)
        XCTAssertEqual(vm.profiles(for: .refine).count, 0)
    }

    func test_setActiveProfile_updatesActiveSelection_perMode() {
        let store = MockPromptStore()
        let vm = PromptStoreViewModel(store: store)
        vm.setActiveProfile(id: "rid", mode: .refine)
        XCTAssertEqual(vm.activeProfileID(for: .refine), "rid")

        vm.setActiveProfile(id: "cid", mode: .claudeCode)
        XCTAssertEqual(vm.activeProfileID(for: .refine), "rid")
        XCTAssertEqual(vm.activeProfileID(for: .claudeCode), "cid")
    }

    func test_saveSkill_thenDelete() async {
        let store = MockPromptStore()
        let vm = PromptStoreViewModel(store: store)
        let s = PromptSkill(id: "k", name: "K", category: .domain, content: "c")
        vm.saveSkill(s)
        XCTAssertEqual(vm.skills.map(\.id), ["k"])
        vm.deleteSkill(id: "k")
        XCTAssertEqual(vm.skills.count, 0)
    }
}
