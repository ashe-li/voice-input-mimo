import XCTest
@testable import VoiceInputMimo

@MainActor
final class SettingsViewModelTests: XCTestCase {
    func test_initialSelectedPane_isGeneral() {
        let vm = SettingsViewModel(refiner: MockRefiner())
        XCTAssertEqual(vm.selectedPane, .general)
    }

    func test_init_pullsRefinerSnapshot() {
        let refiner = MockRefiner()
        refiner.isEnabled = true
        refiner.apiBaseURL = "http://localhost:9999/v1"
        refiner.apiKey = "test-key"
        refiner.model = "qwen-test"

        let vm = SettingsViewModel(refiner: refiner)

        XCTAssertTrue(vm.llmEnabled)
        XCTAssertEqual(vm.llmBaseURL, "http://localhost:9999/v1")
        XCTAssertEqual(vm.llmAPIKey, "test-key")
        XCTAssertEqual(vm.llmModel, "qwen-test")
    }

    func test_save_writesLLMFieldsBackToRefiner() {
        let refiner = MockRefiner()
        let vm = SettingsViewModel(refiner: refiner)

        vm.llmEnabled = true
        vm.llmBaseURL = "http://changed/v1"
        vm.llmAPIKey = "new-key"
        vm.llmModel = "new-model"
        vm.save()

        XCTAssertTrue(refiner.isEnabled)
        XCTAssertEqual(refiner.apiBaseURL, "http://changed/v1")
        XCTAssertEqual(refiner.apiKey, "new-key")
        XCTAssertEqual(refiner.model, "new-model")
    }

    func test_save_englishMode_implies_llmEnabled() {
        let refiner = MockRefiner()
        let vm = SettingsViewModel(refiner: refiner)
        vm.llmEnabled = false
        vm.llmEnglishMode = true
        vm.save()

        // English mode forces LLM enabled even if user toggled the LLM switch off.
        XCTAssertTrue(refiner.isEnabled)
    }

    func test_resetSuffix_restoresDefault() {
        let vm = SettingsViewModel(refiner: MockRefiner())
        vm.llmSuffix = "custom"
        vm.resetSuffix()
        XCTAssertEqual(vm.llmSuffix, LLMRefiner.defaultSuffix)
    }

    func test_selectedPane_isMutable() {
        let vm = SettingsViewModel(refiner: MockRefiner())
        vm.selectedPane = .shortcuts
        XCTAssertEqual(vm.selectedPane, .shortcuts)
        vm.selectedPane = .about
        XCTAssertEqual(vm.selectedPane, .about)
    }

    func test_statusLine_text_extractsPayload() {
        XCTAssertEqual(StatusLine.idle.text, "")
        XCTAssertEqual(StatusLine.info("loading").text, "loading")
        XCTAssertEqual(StatusLine.success("ok").text, "ok")
        XCTAssertEqual(StatusLine.failure("err").text, "err")
    }

    func test_settingsPane_titleAndIcon_areAllNonEmpty() {
        for pane in SettingsPane.allCases {
            XCTAssertFalse(pane.title.isEmpty, "pane \(pane.rawValue) missing title")
            XCTAssertFalse(pane.systemImage.isEmpty, "pane \(pane.rawValue) missing systemImage")
        }
    }
}

/// Minimal in-memory `Refining` fixture for SettingsViewModel tests. Captures
/// every setter so save() side-effects can be asserted directly.
final class MockRefiner: Refining, @unchecked Sendable {
    var isEnabled: Bool = false
    var apiBaseURL: String = "http://localhost/v1"
    var apiKey: String = "key"
    var model: String = "model"
    var lastRefineRequest: String?
    var cancelCount: Int = 0

    func refine(
        _ text: String,
        requestId: String,
        mode: RefineMode?,
        force: Bool,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        lastRefineRequest = text
        completion(.success("mocked: \(text)"))
    }

    func cancel() {
        cancelCount += 1
    }
}
