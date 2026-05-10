import Foundation
import os.log

private let logger = Logger(subsystem: "com.yetone.VoiceInput", category: "LLMRefiner")

enum RefineMode: String, Codable, Sendable {
    case refine        // Original: cleanup-only, keep language
    case claudeCode    // Cleanup + Chinese→English + append zh-TW suffix
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
        set { UserDefaults.standard.set(newValue, forKey: "claudeCodeModeEnabled") }
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

    static let defaultRefinePrompt = """
        /no_think You clean up a noisy Chinese ASR transcript. \
        Output the SAME LANGUAGE as input — never translate to English. \
        Mixed Chinese/English must stay mixed.

        Always fix:
        - Drop verbal fillers when they carry no meaning: 嗯, 呃, 啊, 欸, 那個, 就是說
        - Collapse immediate stutter / repetition: \
          假假定→假定, 或或者→或者, 問問題→問題, 語語音→語音, 需要需要→需要
        - Restore English-misheard-as-Chinese: \
          配森→Python, 杰森→JSON, 阿皮愛→API, 瑞克特→React, 康波奈特→component, 肉特→route
        - Obvious Chinese homophone errors when context makes the correct character clear
        - Broken or merged English/Chinese mix split incorrectly by the recognizer

        Never:
        - Never translate Chinese to English
        - Never rephrase, rewrite, or "improve" the wording
        - Never substitute synonyms
        - Never add or remove content words (nouns, verbs, adjectives)
        - Never change tone or register (casual stays casual)
        - Never alter punctuation unless clearly wrong
        - Never collapse meaningful repetitions used for emphasis (e.g. "很多很多")

        Examples
        Input: 嗯，打字真的蠻慢的，所以如果以後大家都假假定啊，大家都用語音輸入的話。
        Output: 打字真的蠻慢的，所以如果以後大家都假定，大家都用語音輸入的話。

        Input: 那目前大多數問問題會是語語音輸入的準確度。
        Output: 那目前大多數問題會是語音輸入的準確度。

        Input: 呃，創作者或或者使用者還可以決定我要不要用，比如說我們的，呃，skill。
        Output: 創作者或者使用者還可以決定我要不要用，比如說我們的 skill。

        Input: 呃，我的問題是，我遇到一個 bug。
        Output: 我的問題是，我遇到一個 bug。

        Input: 嗯，這個版本應該可以 work。
        Output: 這個版本應該可以 work。

        If the input already reads cleanly, return it exactly as-is. \
        Output ONLY the cleaned text — no preamble, no quotes, no explanations.
        """

    // /no_think directive disables Qwen3 reasoning chain (verified working on
    // qwen3-8b-mlx via Rapid-MLX — drops reasoning_tokens from 420 → 1,
    // latency 8s → 1s). Larger Qwen3 variants may strip the directive in
    // chat-template processing — verify per backend before relying on it.
    static let defaultClaudeCodePrompt = """
        /no_think You convert a developer's mixed Chinese/English voice input \
        into clean English text for a coding assistant.

        Speech act detection (CRITICAL — preserve speaker's intent):
        - REQUEST ("幫我X", "請X", "可以X嗎") → imperative ("Refactor X", "Add X")
        - DESCRIPTION/STATEMENT ("我現在X", "其實是X", "目前X") → declarative \
          ("I'm currently X", "Actually X")
        - QUESTION ("會不會X", "為什麼X", "X嗎") → question ("Will X", "Why X")

        Recovery rules:
        - Stuttered acronyms: L M K→LLM, A P I→API, J S→JS
        - Phonetic Chinese: 配森→Python, 杰森→JSON, 瑞克特→React, \
          康波奈特→component, 肉特→route
        - Drop fillers (嗯/啊/那個/就是說/呃), collapse repetitions, keep \
          speaker's final correction
        - Avoid redundant words: 整套流程→workflow (not "workflow flow")

        Style:
        - Preserve identifiers verbatim (camelCase / snake_case)
        - Keep tech names in English (component, useState, API)
        - Match original tone and intent

        Output ONLY the translation. No quotes, no preamble, no Chinese \
        characters, no trailing newline.
        """

    func refine(_ text: String, requestId: String = "", mode: RefineMode? = nil, force: Bool = false,
                completion: @escaping (Result<String, Error>) -> Void) {
        guard force || (isEnabled && isConfigured) else {
            completion(.success(text))
            return
        }

        let resolvedMode = mode ?? (claudeCodeModeEnabled ? .claudeCode : .refine)
        let activeProfile = (try? PromptStore.shared.activeProfile(for: resolvedMode)) ?? nil
        let systemPrompt = Self.resolveSystemPrompt(
            for: resolvedMode,
            store: PromptStore.shared,
            userDefaults: .standard
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

        let body: [String: Any] = [
            "model": resolvedModel,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": text],
            ],
            "temperature": resolvedTemp,
            // Qwen3 reasoning models burn ~250 tokens on internal thinking before
            // producing the actual answer. 600 leaves room for ~350 tokens of answer.
            "max_tokens": 600,
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

    // MARK: - System prompt resolution

    /// Resolve the system prompt with three-tier fallback:
    /// 1. PromptStore active profile rendered via PromptComposer (preferred)
    /// 2. UserDefaults legacy override (`refineSystemPrompt` / `claudeCodeSystemPrompt`)
    /// 3. Hardcoded compile-time default
    static func resolveSystemPrompt(
        for mode: RefineMode,
        store: PromptStore,
        userDefaults: UserDefaults
    ) -> String {
        if let profile = try? store.activeProfile(for: mode) {
            let skills = (try? store.listSkills()) ?? []
            return PromptComposer.render(profile: profile, skills: skills)
        }
        let key = mode == .claudeCode ? "claudeCodeSystemPrompt" : "refineSystemPrompt"
        if let custom = userDefaults.string(forKey: key), !custom.isEmpty {
            return custom
        }
        return mode == .claudeCode ? Self.defaultClaudeCodePrompt : Self.defaultRefinePrompt
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
