import XCTest
@testable import VoiceInputMimo

@MainActor
final class WorkflowsPaneViewModelTests: XCTestCase {

    private var tempRoot: URL!
    private var store: WorkflowStore!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("workflow-vm-tests-\(UUID().uuidString)")
        store = WorkflowStore(rootDirectory: tempRoot)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    /// Stub executor that returns input as-is plus a tag so tests can assert
    /// it was invoked without needing an LLM endpoint.
    private func taggingExecutor(tag: String = "RAN") -> WorkflowExecutor {
        WorkflowExecutor(refiner: { text, _ in "\(text)<\(tag)>" })
    }

    private func makeVM(executor: WorkflowExecutor? = nil) -> WorkflowsPaneViewModel {
        WorkflowsPaneViewModel(
            store: store,
            executor: executor ?? taggingExecutor()
        )
    }

    // MARK: - Reload

    func testReloadOnEmptyStoreLeavesNoSelection() {
        let vm = makeVM()
        vm.reload()
        XCTAssertEqual(vm.workflows.count, 0)
        XCTAssertNil(vm.selection)
    }

    func testReloadPicksFirstWorkflowWhenSelectionMissing() throws {
        try store.saveAll([
            Workflow(id: "wf-1", name: "A", steps: [WorkflowStep(mode: .refine)]),
            Workflow(id: "wf-2", name: "B", steps: [WorkflowStep(mode: .structure)]),
        ])
        let vm = makeVM()
        vm.selection = "wf-nope"
        vm.reload()
        XCTAssertEqual(vm.selection, "wf-1")
    }

    func testReloadPreservesValidSelection() throws {
        try store.saveAll([
            Workflow(id: "wf-1", name: "A", steps: [WorkflowStep(mode: .refine)]),
            Workflow(id: "wf-2", name: "B", steps: [WorkflowStep(mode: .structure)]),
        ])
        let vm = makeVM()
        vm.selection = "wf-2"
        vm.reload()
        XCTAssertEqual(vm.selection, "wf-2")
    }

    // MARK: - CRUD

    func testAddBlankCreatesWorkflowWithSingleRefineStep() {
        let vm = makeVM()
        vm.reload()
        vm.addBlank()
        XCTAssertEqual(vm.workflows.count, 1)
        XCTAssertEqual(vm.workflows.first?.steps.count, 1)
        XCTAssertEqual(vm.workflows.first?.steps.first?.mode, .refine)
        XCTAssertEqual(vm.selection, vm.workflows.first?.id)
    }

    func testCommitPersistsChange() throws {
        let vm = makeVM()
        vm.reload()
        vm.addBlank()
        guard var wf = vm.selectedWorkflow else {
            XCTFail("expected selection after add")
            return
        }
        wf.name = "Renamed"
        vm.commit(wf)
        let onDisk = try store.loadAll()
        XCTAssertEqual(onDisk.first?.name, "Renamed")
    }

    func testDeleteRemovesAndAdvancesSelection() {
        let vm = makeVM()
        vm.reload()
        vm.addBlank()
        let firstId = vm.selection!
        vm.addBlank()
        let secondId = vm.selection!
        vm.select(firstId)
        vm.delete(id: firstId)
        XCTAssertEqual(vm.workflows.count, 1)
        XCTAssertEqual(vm.selection, secondId)
    }

    // MARK: - Step manipulation

    func testAddStepAppendsToSelectedWorkflow() {
        let vm = makeVM()
        vm.addBlank()
        let id = vm.selection!
        vm.addStep(toWorkflowId: id, mode: .structure)
        XCTAssertEqual(vm.selectedWorkflow?.steps.count, 2)
        XCTAssertEqual(vm.selectedWorkflow?.steps.last?.mode, .structure)
    }

    func testRemoveStepDeletesByIndex() {
        let vm = makeVM()
        vm.addBlank()
        let id = vm.selection!
        vm.addStep(toWorkflowId: id, mode: .structure)
        vm.addStep(toWorkflowId: id, mode: .claudeCode)
        XCTAssertEqual(vm.selectedWorkflow?.steps.count, 3)
        vm.removeStep(at: 1, fromWorkflowId: id)
        XCTAssertEqual(vm.selectedWorkflow?.steps.count, 2)
        XCTAssertEqual(vm.selectedWorkflow?.steps.map(\.mode), [.refine, .claudeCode])
    }

    func testRemoveStepOutOfBoundsIsNoop() {
        let vm = makeVM()
        vm.addBlank()
        let id = vm.selection!
        vm.removeStep(at: 99, fromWorkflowId: id)
        XCTAssertEqual(vm.selectedWorkflow?.steps.count, 1)
    }

    func testMoveStepsReorders() {
        let vm = makeVM()
        vm.addBlank()
        let id = vm.selection!
        vm.addStep(toWorkflowId: id, mode: .structure)
        vm.addStep(toWorkflowId: id, mode: .claudeCode)
        // Move first step to end (offset 3 in SwiftUI move semantics).
        vm.moveSteps(in: id, from: IndexSet(integer: 0), to: 3)
        XCTAssertEqual(vm.selectedWorkflow?.steps.map(\.mode), [.structure, .claudeCode, .refine])
    }

    // MARK: - Preview run

    func testRunPreviewWithoutInputShowsBanner() {
        let vm = makeVM()
        vm.addBlank()
        vm.setPreviewInput("   ")
        vm.runPreview()
        XCTAssertNil(vm.previewResult)
        XCTAssertEqual(vm.banner, "Enter sample input first")
    }

    func testRunPreviewExecutesChain() async {
        let vm = makeVM(executor: taggingExecutor(tag: "X"))
        vm.addBlank()
        let id = vm.selection!
        vm.addStep(toWorkflowId: id, mode: .structure)
        vm.setPreviewInput("hello")
        vm.runPreview()

        // Wait for async preview to finish — poll with a 1s timeout.
        let deadline = Date().addingTimeInterval(1.0)
        while vm.previewResult == nil && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertNotNil(vm.previewResult)
        XCTAssertEqual(vm.previewResult?.finalOutput, "hello<X><X>")
        XCTAssertEqual(vm.previewResult?.stepOutputs.count, 2)
        XCTAssertFalse(vm.isRunningPreview)
    }
}
