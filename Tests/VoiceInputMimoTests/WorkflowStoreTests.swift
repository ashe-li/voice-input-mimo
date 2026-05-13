import XCTest
@testable import VoiceInputMimo

final class WorkflowStoreTests: XCTestCase {

    private var tempRoot: URL!
    private var store: WorkflowStore!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("workflow-store-tests-\(UUID().uuidString)")
        store = WorkflowStore(rootDirectory: tempRoot)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    private func makeStep(_ mode: WorkflowStepMode, id: String = "step-\(UUID().uuidString.prefix(6))", profile: String? = nil) -> WorkflowStep {
        WorkflowStep(id: id, mode: mode, profileId: profile)
    }

    func testLoadAllReturnsEmptyWhenFileMissing() throws {
        let workflows = try store.loadAll()
        XCTAssertTrue(workflows.isEmpty)
    }

    func testSaveAndLoadRoundTrip() throws {
        let wf = Workflow(
            id: "wf-test1",
            name: "Refine + Structure + EN",
            steps: [
                makeStep(.refine, id: "s1"),
                makeStep(.structure, id: "s2"),
                makeStep(.claudeCode, id: "s3", profile: "translator-en"),
            ],
            outputPolicy: .verbose,
            hotkey: "cmd+shift+1"
        )
        try store.saveAll([wf])
        let loaded = try store.loadAll()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.id, "wf-test1")
        XCTAssertEqual(loaded.first?.name, "Refine + Structure + EN")
        XCTAssertEqual(loaded.first?.steps.count, 3)
        XCTAssertEqual(loaded.first?.steps.map(\.mode), [.refine, .structure, .claudeCode])
        XCTAssertEqual(loaded.first?.steps[2].profileId, "translator-en")
        XCTAssertEqual(loaded.first?.outputPolicy, .verbose)
        XCTAssertEqual(loaded.first?.hotkey, "cmd+shift+1")
    }

    func testAddAppendsWorkflow() throws {
        try store.saveAll([
            Workflow(id: "wf-1", name: "A", steps: [makeStep(.refine)])
        ])
        try store.add(Workflow(id: "wf-2", name: "B", steps: [makeStep(.structure)]))
        let loaded = try store.loadAll()
        XCTAssertEqual(loaded.map(\.id), ["wf-1", "wf-2"])
    }

    func testUpdateReplacesWorkflowAndBumpsTimestamp() throws {
        let initial = Workflow(
            id: "wf-1",
            name: "舊名稱",
            steps: [makeStep(.refine)],
            createdAt: Date(timeIntervalSinceReferenceDate: 0),
            updatedAt: Date(timeIntervalSinceReferenceDate: 0)
        )
        try store.saveAll([initial])
        var changed = initial
        changed.name = "新名稱"
        changed.steps.append(makeStep(.structure))
        try store.update(changed)

        let loaded = try store.loadAll()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.name, "新名稱")
        XCTAssertEqual(loaded.first?.steps.count, 2)
        XCTAssertGreaterThan(
            loaded.first!.updatedAt.timeIntervalSinceReferenceDate,
            0,
            "update() must bump updatedAt"
        )
    }

    func testUpdateUnknownIdInsertsAsNew() throws {
        try store.saveAll([])
        let wf = Workflow(id: "wf-new", name: "X", steps: [makeStep(.refine)])
        try store.update(wf)
        let loaded = try store.loadAll()
        XCTAssertEqual(loaded.map(\.id), ["wf-new"])
    }

    func testDeleteRemovesById() throws {
        try store.saveAll([
            Workflow(id: "wf-1", name: "A", steps: [makeStep(.refine)]),
            Workflow(id: "wf-2", name: "B", steps: [makeStep(.structure)]),
        ])
        try store.delete(id: "wf-1")
        let loaded = try store.loadAll()
        XCTAssertEqual(loaded.map(\.id), ["wf-2"])
    }

    func testDeleteUnknownIdIsNoop() throws {
        try store.saveAll([
            Workflow(id: "wf-1", name: "A", steps: [makeStep(.refine)])
        ])
        try store.delete(id: "does-not-exist")
        let loaded = try store.loadAll()
        XCTAssertEqual(loaded.count, 1)
    }

    func testFindById() throws {
        try store.saveAll([
            Workflow(id: "wf-1", name: "A", steps: [makeStep(.refine)]),
            Workflow(id: "wf-2", name: "B", steps: [makeStep(.structure)]),
        ])
        let found = try store.find(id: "wf-2")
        XCTAssertEqual(found?.name, "B")
        let missing = try store.find(id: "wf-nope")
        XCTAssertNil(missing)
    }

    func testEmptyStepsAllowedAtModelLayer() throws {
        // Store should not enforce non-empty steps — UI is the gatekeeper.
        // Persistence layer stays neutral so partial drafts can be saved.
        let wf = Workflow(id: "wf-draft", name: "Draft", steps: [])
        try store.saveAll([wf])
        let loaded = try store.loadAll()
        XCTAssertEqual(loaded.first?.steps.count, 0)
    }
}
