import Foundation
import Observation

/// MainActor-isolated `@Observable` view model that drives every SwiftUI
/// settings pane. Holds the selected sidebar pane and a snapshot of every
/// editable preference (shortcuts, ASR, server config, LLM refinement).
///
/// View body has no I/O — every probe / save / browse / reset action goes
/// through methods on this class, which call back into the singleton services
/// (ASRClient / LocalASRServer / LLMRefiner) and republish updated state.
///
/// Phase 3 does not refactor ASRClient / LocalASRServer behind protocols; the
/// LLM side already has the `Refining` abstraction (Phase 2) and is injected.
/// Tests cover the UserDefaults round-trip and selectedPane mutations.
@MainActor
@Observable
final class SettingsViewModel {
    // MARK: - Sidebar selection

    var selectedPane: SettingsPane = .general

    // MARK: - Shortcuts

    var primaryShortcut: ShortcutBinding.Preset = .function
    var secondaryShortcut: ShortcutBinding.Preset = .disabled

    // MARK: - Speech (ASR client config)

    var asrBaseURL: String = ""
    var asrLanguage: String = "auto"
    var asrOutputLocale: String = "zh-TW"
    var asrProbeStatus: StatusLine = .idle

    // MARK: - ASR server (local supervisor)

    var serverDir: String = ""
    var serverPython: String = ""
    var serverPort: String = ""
    var serverPrecision: String = "int4"
    var serverModelRoot: String = ""
    var serverPreload: Bool = false
    var serverStatus: StatusLine = .idle

    // MARK: - LLM refinement

    var llmEnabled: Bool = false
    var llmEnglishMode: Bool = false   // claudeCodeModeEnabled
    var llmBaseURL: String = ""
    var llmAPIKey: String = ""
    var llmModel: String = ""
    var llmSuffix: String = ""
    var llmProbeStatus: StatusLine = .idle
    var generalStatus: StatusLine = .idle

    // MARK: - Dependencies

    private let refiner: any Refining
    private let userDefaults: UserDefaults

    init(
        refiner: any Refining = LLMRefiner.shared,
        userDefaults: UserDefaults = .standard
    ) {
        self.refiner = refiner
        self.userDefaults = userDefaults
        load()
    }

    // MARK: - Load / save

    /// Pull every editable value from disk-backed singletons + UserDefaults
    /// into the view model. Called from `init` and from `.task` modifiers
    /// when a pane appears, so values stay in sync if external code mutates
    /// them.
    func load() {
        primaryShortcut = ShortcutBinding.loadPrimary().preset
        secondaryShortcut = ShortcutBinding.loadSecondary().preset

        let asr = ASRClient.shared
        asrBaseURL = asr.baseURL
        asrLanguage = asr.language
        asrOutputLocale = asr.outputLocale

        let server = LocalASRServer.Configuration.current()
        serverDir = server.serverDir
        serverPython = server.pythonPath
        serverPort = String(server.port)
        serverPrecision = server.precision
        serverModelRoot = server.modelRoot
        serverPreload = server.preload

        llmEnabled = refiner.isEnabled
        llmEnglishMode = (refiner as? LLMRefiner)?.claudeCodeModeEnabled ?? false
        llmBaseURL = refiner.apiBaseURL
        llmAPIKey = refiner.apiKey
        llmModel = refiner.model
        llmSuffix = (refiner as? LLMRefiner)?.claudeCodeSuffix ?? ""
    }

    /// Commit every editable field back to its persisted home. Called from
    /// the Save button on each pane (and once when the window closes via the
    /// thin shell's `windowWillClose`).
    func save() {
        ShortcutBinding.save(primary: primaryShortcut, secondary: secondaryShortcut)
        // Notify EventTap thread to drop its cached shortcut snapshot.
        NotificationCenter.default.post(name: .shortcutBindingDidChange, object: nil)

        let asr = ASRClient.shared
        asr.baseURL = asrBaseURL
        asr.language = asrLanguage
        asr.outputLocale = asrOutputLocale

        applyServerFields()

        // Mirror the AppKit form's invariant: enabling English mode implies
        // LLM enabled. Pure cleanup mode keeps LLM enabled flag user-driven.
        refiner.isEnabled = llmEnglishMode || llmEnabled
        if let llm = refiner as? LLMRefiner {
            llm.claudeCodeModeEnabled = llmEnglishMode
            llm.claudeCodeSuffix = llmSuffix
        }
        refiner.apiBaseURL = llmBaseURL
        refiner.apiKey = llmAPIKey
        refiner.model = llmModel
    }

    func applyServerFields() {
        var c = LocalASRServer.Configuration.current()
        c.serverDir = serverDir.trimmingCharacters(in: .whitespaces)
        c.pythonPath = serverPython.trimmingCharacters(in: .whitespaces)
        c.port = Int(serverPort) ?? c.port
        c.precision = serverPrecision
        c.modelRoot = serverModelRoot.trimmingCharacters(in: .whitespaces)
        c.preload = serverPreload
        c.write()
    }

    // MARK: - Actions

    func resetSuffix() {
        llmSuffix = LLMRefiner.defaultSuffix
    }

    func probeASR() {
        save()
        asrProbeStatus = .info("Smoke transcribe \(asrBaseURL)…")
        ASRClient.shared.smokeTranscribe { [weak self] result in
            guard let self else { return }
            Task { @MainActor in
                switch result {
                case .success(let r):
                    let cold = r.wasCold ? "cold" : "warm"
                    self.asrProbeStatus = .success("✅ smoke \(cold) \(r.elapsedMs) ms")
                case .failure(let error):
                    self.asrProbeStatus = .failure("❌ \(error.localizedDescription)")
                }
            }
        }
    }

    func probeLLM() {
        save()
        llmProbeStatus = .info("Probing \(llmBaseURL)…")
        refiner.cancel()
        // Reuse LLMRefiner.probeModels via the concrete type. Phase 3
        // intentionally does not extend `Refining` with probeModels (that
        // touches /v1/models, not /chat/completions).
        guard let llm = refiner as? LLMRefiner else { return }
        llm.probeModels { [weak self] result in
            guard let self else { return }
            Task { @MainActor in
                switch result {
                case .success(let ids):
                    if ids.isEmpty {
                        self.llmProbeStatus = .failure("⚠️ Reachable, no models loaded.")
                    } else {
                        let preview = ids.prefix(2).joined(separator: ", ")
                        let extra = ids.count > 2 ? " (+\(ids.count - 2))" : ""
                        self.llmProbeStatus = .success("✅ \(ids.count) model(s): \(preview)\(extra)")
                    }
                case .failure(let error):
                    self.llmProbeStatus = .failure("❌ \(error.localizedDescription)")
                }
            }
        }
    }

    func test() {
        save()
        generalStatus = .info("Testing LLM with sample text…")
        refiner.refine("幫我重構這個函式", requestId: "", mode: nil, force: true) { [weak self] result in
            guard let self else { return }
            Task { @MainActor in
                switch result {
                case .success(let text):
                    self.generalStatus = .success("OK: \(text.prefix(120))")
                case .failure(let error):
                    self.generalStatus = .failure(error.localizedDescription)
                }
            }
        }
    }

    func applyAndRestartServer() {
        applyServerFields()
        let config = LocalASRServer.Configuration.current()
        if let err = config.validate() {
            serverStatus = .failure("✕ \(err.localizedDescription)")
            return
        }
        serverStatus = .info("Restarting…")
        LocalASRServer.shared.restart { [weak self] result in
            guard let self else { return }
            Task { @MainActor in
                switch result {
                case .success:
                    self.serverStatus = .success("✅ Running on :\(config.port)")
                case .failure(let error):
                    self.serverStatus = .failure("❌ \(error.localizedDescription)")
                }
            }
        }
    }
}

/// Status line state used by every probe / save action. Maps to label tint
/// in the SwiftUI panes (gray idle / gray info / green success / red failure).
enum StatusLine: Equatable, Sendable {
    case idle
    case info(String)
    case success(String)
    case failure(String)

    var text: String {
        switch self {
        case .idle: return ""
        case .info(let s), .success(let s), .failure(let s): return s
        }
    }
}
