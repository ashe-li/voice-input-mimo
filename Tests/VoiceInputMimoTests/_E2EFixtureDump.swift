import XCTest
@testable import VoiceInputMimo

/// Disposable e2e fixture writer — runs once to populate
/// ~/Library/Application Support/VoiceInputMimo/workspaces/{workflows,toneMapping}/default.json
/// with a known workflow + toneMapping rule set, so the user can launch the
/// app and visually verify rendering without manually clicking + buttons.
///
/// Skipped via `XCTSkip` unless environment var VIM_E2E_FIXTURE_DUMP=1 so
/// normal `swift test` runs don't clobber user state.
final class _E2EFixtureDump: XCTestCase {

    func testDumpE2EFixtures() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["VIM_E2E_FIXTURE_DUMP"] == "1",
            "Set VIM_E2E_FIXTURE_DUMP=1 to run"
        )

        let appSupport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/VoiceInputMimo/workspaces")

        // --- Workflow fixture ---
        let workflowRoot = appSupport.appendingPathComponent("workflows")
        let workflowStore = WorkflowStore(rootDirectory: workflowRoot)
        let wf = Workflow(
            id: "wf-e2etest01",
            name: "refine -> structure -> claudeCode test",
            steps: [
                WorkflowStep(id: "step-1", mode: .refine),
                WorkflowStep(id: "step-2", mode: .structure),
                WorkflowStep(id: "step-3", mode: .claudeCode),
            ],
            outputPolicy: .final,
            hotkey: nil
        )
        try workflowStore.saveAll([wf])
        print("FIXTURE: wrote workflow to \(workflowRoot.path)/default.json")

        // --- ToneMapping fixtures ---
        let toneRoot = appSupport.appendingPathComponent("toneMapping")
        let toneStore = ToneMappingStore(rootDirectory: toneRoot)
        try toneStore.saveAll([
            ToneRule(bundleIDPrefix: "com.apple.mail", delegated: .claudeCode),
            ToneRule(bundleIDPrefix: "com.todesktop.230313mzl4w4u92", workflowId: "wf-e2etest01"),
        ])
        print("FIXTURE: wrote toneMapping to \(toneRoot.path)/default.json")
    }
}
