import XCTest
@testable import VoiceInputMimo

/// Roundtrip verification — confirms the e2e fixture JSON files
/// (written by `_E2EFixtureDump`) decode cleanly and dispatch routing
/// resolves as expected against the user's actual ToneMappingStore.
final class _E2EFixtureVerify: XCTestCase {

    func testVerifyE2EFixtures() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["VIM_E2E_FIXTURE_VERIFY"] == "1",
            "Set VIM_E2E_FIXTURE_VERIFY=1 to run"
        )

        let appSupport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/VoiceInputMimo/workspaces")

        // --- Workflow roundtrip ---
        let wfStore = WorkflowStore(rootDirectory: appSupport.appendingPathComponent("workflows"))
        let wfs = try wfStore.loadAll()
        XCTAssertEqual(wfs.count, 1, "should load 1 workflow from fixture")
        let wf = try XCTUnwrap(wfs.first)
        XCTAssertEqual(wf.id, "wf-e2etest01")
        XCTAssertEqual(wf.steps.count, 3)
        XCTAssertEqual(wf.steps.map(\.mode), [.refine, .structure, .claudeCode])
        XCTAssertEqual(wf.outputPolicy, .final)
        print("VERIFY: workflow round-trip OK — name=\(wf.name) steps=\(wf.steps.map(\.mode.rawValue))")

        // --- ToneMapping roundtrip ---
        let tmStore = ToneMappingStore(rootDirectory: appSupport.appendingPathComponent("toneMapping"))
        let rules = try tmStore.loadAll()
        XCTAssertEqual(rules.count, 2, "should load 2 toneMapping rules from fixture")
        XCTAssertEqual(rules[0].bundleIDPrefix, "com.apple.mail")
        XCTAssertEqual(rules[0].delegated, .mode(.claudeCode))
        XCTAssertEqual(rules[1].bundleIDPrefix, "com.todesktop.230313mzl4w4u92")
        XCTAssertEqual(rules[1].delegated, .workflow(workflowId: "wf-e2etest01"))
        print("VERIFY: toneMapping round-trip OK — 2 rules (Mail→claudeCode, Cursor→workflow)")

        // --- Dispatch decision matrix (PR #16 Task #23 integration) ---
        // Simulates Mode 4 contextAware resolving against the fixtures via
        // effectiveRules first-match-wins, then decideDispatch() resolves
        // ToneDelegate to a concrete DispatchDecision.

        let userRules = rules
        let effective = ToneMapping.effectiveRules(userRules: userRules)
        XCTAssertTrue(
            effective.count >= 2,
            "effectiveRules should include both user rules first + defaults appended; got \(effective.count)"
        )

        // Build a fake findWorkflow closure that mirrors WorkflowStore.shared
        let findWorkflow: (String) -> Workflow? = { id in
            wfs.first(where: { $0.id == id })
        }

        // Helper — pick first matching rule for a given bundleID (first-match-wins)
        func resolveDelegate(forBundleID id: String) -> ToneDelegate? {
            effective.first(where: { rule in
                if rule.bundleIDPrefix.hasSuffix(".") {
                    return id.hasPrefix(rule.bundleIDPrefix)
                }
                return id == rule.bundleIDPrefix
            })?.delegated
        }

        // 1) Mail focus → user rule overrides default (claudeCode instead of refine)
        let mailDelegate = resolveDelegate(forBundleID: "com.apple.mail")
        XCTAssertEqual(mailDelegate, .mode(.claudeCode), "Mail user rule should override default")
        let mailDispatch = LLMRefiner.decideDispatch(
            rawMode: .contextAware,
            delegate: mailDelegate,
            findWorkflow: findWorkflow
        )
        XCTAssertEqual(mailDispatch, .singleMode(.claudeCode))
        print("VERIFY: Mode4@Mail → \(mailDispatch) (expected singleMode(claudeCode))")

        // 2) Cursor focus → workflow dispatch
        let cursorDelegate = resolveDelegate(forBundleID: "com.todesktop.230313mzl4w4u92")
        XCTAssertEqual(cursorDelegate, .workflow(workflowId: "wf-e2etest01"))
        let cursorDispatch = LLMRefiner.decideDispatch(
            rawMode: .contextAware,
            delegate: cursorDelegate,
            findWorkflow: findWorkflow
        )
        switch cursorDispatch {
        case .workflow(let w):
            XCTAssertEqual(w.id, "wf-e2etest01")
            print("VERIFY: Mode4@Cursor → workflow(\(w.name))")
        default:
            XCTFail("expected workflow dispatch, got \(cursorDispatch)")
        }

        // 3) Unknown bundle → default refine fallback
        let unknownDelegate = resolveDelegate(forBundleID: "com.random.app.not.in.any.rule")
        // could be nil (no match) — decideDispatch falls back to .refine
        let unknownDispatch = LLMRefiner.decideDispatch(
            rawMode: .contextAware,
            delegate: unknownDelegate,
            findWorkflow: findWorkflow
        )
        XCTAssertEqual(unknownDispatch, .singleMode(.refine), "unknown bundle should fallback to refine")
        print("VERIFY: Mode4@unknown → \(unknownDispatch) (expected refine fallback)")

        // 4) Non-contextAware mode passthrough (regression — Task #23 shouldn't change this)
        let directRefine = LLMRefiner.decideDispatch(
            rawMode: .refine,
            delegate: nil,
            findWorkflow: findWorkflow
        )
        XCTAssertEqual(directRefine, .singleMode(.refine))

        // 5) Workflow ID missing in store → fallback to refine
        let missingDispatch = LLMRefiner.decideDispatch(
            rawMode: .contextAware,
            delegate: .workflow(workflowId: "wf-does-not-exist"),
            findWorkflow: findWorkflow
        )
        XCTAssertEqual(missingDispatch, .workflowMissing(workflowId: "wf-does-not-exist"))
        print("VERIFY: Mode4@missingWorkflow → \(missingDispatch) (expected workflowMissing)")

        print("VERIFY: all dispatch matrix checks PASS")
    }
}
