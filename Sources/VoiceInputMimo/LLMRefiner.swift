import Foundation
import os.log

private let logger = Logger(subsystem: "com.yetone.VoiceInput", category: "LLMRefiner")

enum RefineMode: String, Codable, Sendable {
    case refine        // Original: cleanup-only, keep language
    case claudeCode    // Cleanup + Chinese→English + append zh-TW suffix
    case structure     // Auto-classify input → route to template profile (meeting/task/requirement/letter/article)
    case contextAware  // Dispatch by frontmost-app bundle ID → delegate to refine/claudeCode/structure
}

final class LLMRefiner {
    static let shared = LLMRefiner()

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "llmEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "llmEnabled") }
    }

    var apiBaseURL: String {
        get { UserDefaults.standard.string(forKey: "llmAPIBaseURL") ?? "http://127.0.0.1:8082/v1" }
        set { UserDefaults.standard.set(newValue, forKey: "llmAPIBaseURL") }
    }

    var apiKey: String {
        get { UserDefaults.standard.string(forKey: "llmAPIKey") ?? "local-api-key" }
        set { UserDefaults.standard.set(newValue, forKey: "llmAPIKey") }
    }

    var model: String {
        get { UserDefaults.standard.string(forKey: "llmModel") ?? "qwen3-8b-mlx" }
        set { UserDefaults.standard.set(newValue, forKey: "llmModel") }
    }

    var claudeCodeModeEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "claudeCodeModeEnabled") }
        set {
            UserDefaults.standard.set(newValue, forKey: "claudeCodeModeEnabled")
            if newValue {
                UserDefaults.standard.set(false, forKey: "structureModeEnabled")
                UserDefaults.standard.set(false, forKey: "contextAwareModeEnabled")
            }
        }
    }

    /// When true, refine() routes through `.structure` mode and uses
    /// StructureRouter to pick a template profile based on input keywords.
    /// Mutually exclusive with the other LLM-driven modes — turning this on
    /// flips claudeCode and contextAware off.
    var structureModeEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "structureModeEnabled") }
        set {
            UserDefaults.standard.set(newValue, forKey: "structureModeEnabled")
            if newValue {
                UserDefaults.standard.set(false, forKey: "claudeCodeModeEnabled")
                UserDefaults.standard.set(false, forKey: "contextAwareModeEnabled")
            }
        }
    }

    /// When true, refine() captures the frontmost app context (bundle ID via
    /// `NSWorkspace.frontmostApplication`) and delegates to one of the other
    /// modes (refine / claudeCode / structure) per `ToneMapping`. Mutually
    /// exclusive with the explicit-mode flags above.
    var contextAwareModeEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "contextAwareModeEnabled") }
        set {
            UserDefaults.standard.set(newValue, forKey: "contextAwareModeEnabled")
            if newValue {
                UserDefaults.standard.set(false, forKey: "claudeCodeModeEnabled")
                UserDefaults.standard.set(false, forKey: "structureModeEnabled")
            }
        }
    }

    var claudeCodeSuffix: String {
        get {
            UserDefaults.standard.string(forKey: "claudeCodeSuffix") ?? Self.defaultSuffix
        }
        set { UserDefaults.standard.set(newValue, forKey: "claudeCodeSuffix") }
    }

    static let defaultSuffix = """

        ---
        Reply in Traditional Chinese (zh-TW). 請以繁體中文回覆。
        以下以繁體中文（台灣用語）回覆，不要使用簡體詞彙。
        """

    // System prompts are UserDefaults-backed so they can be tuned via
    //   defaults write com.shiun.VoiceInputMimo refineSystemPrompt "..."
    //   defaults write com.shiun.VoiceInputMimo claudeCodeSystemPrompt "..."
    // without rebuilding the app. To restore default, use `defaults delete`.
    var refineSystemPrompt: String {
        get { UserDefaults.standard.string(forKey: "refineSystemPrompt") ?? Self.defaultRefinePrompt }
        set { UserDefaults.standard.set(newValue, forKey: "refineSystemPrompt") }
    }

    var claudeCodeSystemPrompt: String {
        get { UserDefaults.standard.string(forKey: "claudeCodeSystemPrompt") ?? Self.defaultClaudeCodePrompt }
        set { UserDefaults.standard.set(newValue, forKey: "claudeCodeSystemPrompt") }
    }

    /// Local Rapid-MLX accepts any Bearer (including empty), so the gate only
    /// checks the endpoint URL. A previous version required `apiKey` to be
    /// non-empty, which silently dropped LLM calls when users left the field
    /// blank — the recording would still go through, but the "English / Output"
    /// pane echoed the Chinese ASR verbatim because the LLM path was skipped.
    var isConfigured: Bool { !apiBaseURL.trimmingCharacters(in: .whitespaces).isEmpty }

    private var currentTask: URLSessionDataTask?

    // Hardcoded defaults are composed from `BuiltinPromptCatalog` so the legacy
    // fallback (used only when `PromptStore` has no active profile) stays in
    // sync with the catalog version. Single source of truth — `/no_think`
    // directive disables Qwen3 reasoning chain (verified on qwen3-8b-mlx via
    // Rapid-MLX: reasoning_tokens 420 → 1, latency 8s → 1s). Larger Qwen3
    // variants may strip the directive in chat-template processing — verify
    // per backend before relying on it.
    static let defaultRefinePrompt: String = PromptComposer.render(
        profile: BuiltinPromptCatalog.defaultRefineProfile,
        skills: BuiltinPromptCatalog.skills
    )

    static let defaultClaudeCodePrompt: String = PromptComposer.render(
        profile: BuiltinPromptCatalog.defaultClaudeCodeProfile,
        skills: BuiltinPromptCatalog.skills
    )

    func refine(_ text: String, requestId: String = "", mode: RefineMode? = nil, force: Bool = false,
                completion: @escaping (Result<String, Error>) -> Void) {
        guard force || (isEnabled && isConfigured) else {
            completion(.success(text))
            return
        }

        let rawMode = mode ?? Self.activeModeFromToggles(
            claudeCodeEnabled: claudeCodeModeEnabled,
            structureEnabled: structureModeEnabled,
            contextAwareEnabled: contextAwareModeEnabled
        )
        // contextAware delegates to one of the explicit modes based on the
        // frontmost-app bundle ID. The delegate decision is captured here so
        // downstream branches (.structure router path, profile lookup, glossary
        // injection) treat the resolved mode uniformly.
        let resolvedMode: RefineMode = (rawMode == .contextAware)
            ? ToneMapping.resolve(context: ContextCapture.capture())
            : rawMode
        // For .structure mode the active profile is picked by the router based
        // on input content, not by ActiveSelection. For .refine / .claudeCode
        // it stays the user's chosen active profile.
        let activeProfile: PromptProfile?
        let basePrompt: String
        if resolvedMode == .structure {
            let routedID = StructureRouter.route(input: text)
            let routed = (try? PromptStore.shared.loadProfile(id: routedID, mode: .structure)) ?? nil
            activeProfile = routed
            if let routed {
                let skills = (try? PromptStore.shared.listSkills()) ?? []
                basePrompt = PromptComposer.render(profile: routed, skills: skills)
            } else {
                basePrompt = Self.defaultRefinePrompt
            }
        } else {
            activeProfile = (try? PromptStore.shared.activeProfile(for: resolvedMode)) ?? nil
            basePrompt = Self.resolveSystemPrompt(
                for: resolvedMode,
                store: PromptStore.shared,
                userDefaults: .standard
            )
        }
        // Glossary injection — append user-defined proper nouns so the LLM
        // preserves canonical spellings (vocus, PDT-9624, etc.). Empty
        // glossary returns the base prompt unchanged; failures (store IO)
        // also degrade to base prompt rather than aborting the request.
        let glossaryEntries = (try? GlossaryStore.shared.loadAll()) ?? []
        let systemPrompt = GlossaryInjector.inject(
            systemPrompt: basePrompt,
            entries: glossaryEntries
        )

        guard let url = URL(string: "\(normalizedBaseURL())/chat/completions") else {
            completion(.failure(RefinerError.invalidURL))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if !requestId.isEmpty {
            request.setValue(requestId, forHTTPHeaderField: "X-Request-Id")
        }
        request.timeoutInterval = 90  // Qwen3 reasoning models can take 30s+ per inference

        let resolvedModel = activeProfile?.modelOverride ?? model
        let resolvedTemp = activeProfile?.temperature ?? (resolvedMode == .claudeCode ? 0.2 : 0.3)
        // Structure mode produces multi-section Markdown documents — ~1500
        // gives room for ~1250 tokens of actual content after Qwen3 reasoning
        // overhead. Refine/ClaudeCode keep the original 600 cap (single-line
        // outputs).
        let resolvedMaxTokens = resolvedMode == .structure ? 1500 : 600

        let body: [String: Any] = [
            "model": resolvedModel,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": text],
            ],
            "temperature": resolvedTemp,
            "max_tokens": resolvedMaxTokens,
        ]

        let logTag = requestId.isEmpty ? "" : "[req=\(requestId)] "
        logger.debug("\(logTag)Request: \(url.absoluteString) model=\(resolvedModel) mode=\(resolvedMode.rawValue) profile=\(activeProfile?.id ?? "<none>")")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let suffixToAppend: String
        if resolvedMode == .claudeCode {
            suffixToAppend = activeProfile?.suffix ?? claudeCodeSuffix
        } else {
            suffixToAppend = ""
        }

        currentTask = URLSession.shared.dataTask(with: request) { data, _, error in
            if let error {
                logger.error("\(logTag)Network error: \(error.localizedDescription)")
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            guard let data else {
                logger.error("\(logTag)No data in response")
                DispatchQueue.main.async { completion(.failure(RefinerError.invalidResponse)) }
                return
            }
            if let raw = String(data: data, encoding: .utf8) {
                logger.debug("\(logTag)Response: \(raw)")
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any]
            else {
                logger.error("\(logTag)Failed to parse response")
                DispatchQueue.main.async { completion(.failure(RefinerError.invalidResponse)) }
                return
            }
            // Qwen3 reasoning models put the actual answer in `content` but if
            // max_tokens cut off mid-thinking, content may be empty — log usage
            // so we can detect that case.
            let content = (message["content"] as? String) ?? ""
            if content.isEmpty {
                let usage = json["usage"] as? [String: Any]
                let finishReason = (choices.first?["finish_reason"] as? String) ?? "?"
                logger.warning("\(logTag)empty content. finish=\(finishReason) usage=\(String(describing: usage ?? [:]))")
            }
            let refined = content.trimmingCharacters(in: .whitespacesAndNewlines)
            let finalText = suffixToAppend.isEmpty ? refined : "\(refined)\(suffixToAppend)"
            logger.debug("\(logTag)Refined (\(resolvedMode.rawValue)): '\(text)' -> '\(refined)' (suffix=\(suffixToAppend.count) chars)")
            DispatchQueue.main.async { completion(.success(finalText)) }
        }
        currentTask?.resume()
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
    }

    // MARK: - Mode dispatch

    /// Compute the effective `RefineMode` from the two compound toggles.
    /// Precedence (highest first): structure > claudeCode > refine. Both
    /// setters enforce mutual exclusion, but precedence here protects
    /// against any external race that leaves both flags on.
    static func activeModeFromToggles(claudeCodeEnabled: Bool, structureEnabled: Bool, contextAwareEnabled: Bool = false) -> RefineMode {
        if contextAwareEnabled { return .contextAware }
        if structureEnabled { return .structure }
        if claudeCodeEnabled { return .claudeCode }
        return .refine
    }

    // MARK: - System prompt resolution

    /// Resolve the system prompt with three-tier fallback:
    /// 1. PromptStore active profile rendered via PromptComposer (preferred)
    /// 2. UserDefaults legacy override (`refineSystemPrompt` / `claudeCodeSystemPrompt`)
    /// 3. Hardcoded compile-time default
    ///
    /// `.structure` mode is normally resolved inside `refine(_:requestId:mode:force:)`
    /// via the `StructureRouter` path (not through this function). It is still
    /// handled here defensively: there is no UserDefaults override key for
    /// structure (router-driven), so tier 2 is skipped and tier 3 falls back
    /// to the structure-fallback profile via the catalog. This way any future
    /// caller that invokes `resolveSystemPrompt(for: .structure, …)` gets a
    /// sensible result rather than the refine prompt.
    static func resolveSystemPrompt(
        for mode: RefineMode,
        store: PromptStore,
        userDefaults: UserDefaults
    ) -> String {
        if let profile = try? store.activeProfile(for: mode) {
            let skills = (try? store.listSkills()) ?? []
            return PromptComposer.render(profile: profile, skills: skills)
        }
        switch mode {
        case .claudeCode:
            if let custom = userDefaults.string(forKey: "claudeCodeSystemPrompt"), !custom.isEmpty {
                return custom
            }
            return Self.defaultClaudeCodePrompt
        case .refine:
            if let custom = userDefaults.string(forKey: "refineSystemPrompt"), !custom.isEmpty {
                return custom
            }
            return Self.defaultRefinePrompt
        case .structure:
            // No UserDefaults override key for structure mode (router-driven).
            // Tier 3 falls back to the catalog's structure-fallback profile.
            let skills = (try? store.listSkills()) ?? []
            return PromptComposer.render(
                profile: BuiltinPromptCatalog.structureFallbackProfile,
                skills: skills.isEmpty ? BuiltinPromptCatalog.skills : skills
            )
        case .contextAware:
            // contextAware is dispatched via ToneMapping in refine() before
            // reaching here, so this branch is purely defensive. Fall back to
            // refine's default if any caller invokes this with .contextAware.
            if let custom = userDefaults.string(forKey: "refineSystemPrompt"), !custom.isEmpty {
                return custom
            }
            return Self.defaultRefinePrompt
        }
    }

    // MARK: - Private helpers

    private func normalizedBaseURL() -> String {
        apiBaseURL.hasSuffix("/") ? String(apiBaseURL.dropLast()) : apiBaseURL
    }

    /// Probe an OpenAI-compatible /v1/models endpoint. Used by Settings to detect
    /// the local LLM backend (Rapid-MLX by default; LM Studio / ollama also work).
    func probeModels(completion: @escaping (Result<[String], Error>) -> Void) {
        guard let url = URL(string: "\(normalizedBaseURL())/models") else {
            completion(.failure(RefinerError.invalidURL))
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 2.0

        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let arr = json["data"] as? [[String: Any]]
            else {
                DispatchQueue.main.async { completion(.failure(RefinerError.invalidResponse)) }
                return
            }
            let ids = arr.compactMap { $0["id"] as? String }
            DispatchQueue.main.async { completion(.success(ids)) }
        }.resume()
    }

    enum RefinerError: LocalizedError {
        case invalidURL
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid API base URL"
            case .invalidResponse: return "Invalid response from LLM API"
            }
        }
    }
}
