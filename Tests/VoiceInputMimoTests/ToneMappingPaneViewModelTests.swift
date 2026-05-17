import XCTest
@testable import VoiceInputMimo

@MainActor
final class ToneMappingPaneViewModelTests: XCTestCase {

    private var tempToneRoot: URL!
    private var tempWorkflowRoot: URL!
    private var toneStore: ToneMappingStore!
    private var workflowStore: WorkflowStore!

    override func setUp() {
        super.setUp()
        let stamp = UUID().uuidString
        tempToneRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("tone-vm-tests-\(stamp)")
        tempWorkflowRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("tone-vm-workflows-\(stamp)")
        toneStore = ToneMappingStore(rootDirectory: tempToneRoot)
        workflowStore = WorkflowStore(rootDirectory: tempWorkflowRoot)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempToneRoot)
        try? FileManager.default.removeItem(at: tempWorkflowRoot)
        super.tearDown()
    }

    private func makeVM() -> ToneMappingPaneViewModel {
        ToneMappingPaneViewModel(store: toneStore, workflowStore: workflowStore)
    }

    func testReloadEmpty() {
        let vm = makeVM()
        vm.reload()
        XCTAssertTrue(vm.rules.isEmpty)
        XCTAssertNil(vm.selectionIndex)
    }

    func testReloadLoadsRulesAndWorkflows() throws {
        try toneStore.saveAll([
            ToneRule(bundleIDPrefix: "com.test", delegated: .refine)
        ])
        try workflowStore.saveAll([
            Workflow(id: "wf-1", name: "Test", steps: [WorkflowStep(mode: .refine)])
        ])
        let vm = makeVM()
        vm.reload()
        XCTAssertEqual(vm.rules.count, 1)
        XCTAssertEqual(vm.availableWorkflows.count, 1)
        XCTAssertEqual(vm.availableWorkflows.first?.id, "wf-1")
    }

    func testAddBlankAppendsAndSelects() {
        let vm = makeVM()
        vm.reload()
        vm.addBlank()
        XCTAssertEqual(vm.rules.count, 1)
        XCTAssertEqual(vm.selectionIndex, 0)
        XCTAssertEqual(vm.selectedRule?.delegated, .mode(.refine))
    }

    func testCommitReplacesRule() throws {
        let vm = makeVM()
        vm.reload()
        vm.addBlank()
        var rule = vm.selectedRule!
        rule.bundleIDPrefix = "com.changed"
        rule.delegated = .mode(.claudeCode)
        vm.commit(at: 0, rule: rule)
        XCTAssertEqual(vm.rules[0].bundleIDPrefix, "com.changed")
        XCTAssertEqual(vm.rules[0].delegated, .mode(.claudeCode))
        // Persisted on disk
        let onDisk = try toneStore.loadAll()
        XCTAssertEqual(onDisk[0].bundleIDPrefix, "com.changed")
    }

    func testCommitToWorkflowDelegate() {
        let vm = makeVM()
        vm.reload()
        vm.addBlank()
        var rule = vm.selectedRule!
        rule.delegated = .workflow(workflowId: "wf-x")
        vm.commit(at: 0, rule: rule)
        XCTAssertEqual(vm.rules[0].delegated, .workflow(workflowId: "wf-x"))
    }

    func testDeleteRemovesAndAdvancesSelection() {
        let vm = makeVM()
        vm.reload()
        vm.addBlank()
        vm.addBlank()
        vm.addBlank()
        XCTAssertEqual(vm.rules.count, 3)
        vm.select(index: 0)
        vm.delete(at: 0)
        XCTAssertEqual(vm.rules.count, 2)
        // Selection 0 still valid (now points to what was rule[1])
        XCTAssertEqual(vm.selectionIndex, 0)
    }

    func testDeleteLastRuleClearsSelection() {
        let vm = makeVM()
        vm.reload()
        vm.addBlank()
        vm.select(index: 0)
        vm.delete(at: 0)
        XCTAssertTrue(vm.rules.isEmpty)
        XCTAssertNil(vm.selectionIndex)
    }

    func testSelectedRuleNilWhenIndexOutOfBounds() {
        let vm = makeVM()
        vm.reload()
        vm.addBlank()
        vm.select(index: 99)
        XCTAssertNil(vm.selectedRule)
    }
}
