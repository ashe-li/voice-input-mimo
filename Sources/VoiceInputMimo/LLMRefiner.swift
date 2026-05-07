import Foundation
import os.log

private let logger = Logger(subsystem: "com.yetone.VoiceInput", category: "LLMRefiner")

private func logToFile(_ message: String) {
    let msg = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
    let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/VoiceInput.log")
    if let handle = try? FileHandle(forWritingTo: logURL) {
        handle.seekToEndOfFile()
        handle.write(msg.data(using: .utf8)!)
        handle.closeFile()
    } else {
        FileManager.default.createFile(atPath: logURL.path, contents: msg.data(using: .utf8))
    }
}

enum RefineMode: String {
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
        get { UserDefaults.standard.string(forKey: "llmAPIBaseURL") ?? "http://localhost:1234/v1" }
        set { UserDefaults.standard.set(newValue, forKey: "llmAPIBaseURL") }
    }

    var apiKey: String {
        get { UserDefaults.standard.string(forKey: "llmAPIKey") ?? "lm-studio" }
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

    var isConfigured: Bool { !apiKey.isEmpty }

    private var currentTask: URLSessionDataTask?

    static let defaultRefinePrompt = """
        /no_think You are a conservative speech recognition error corrector. \
        ONLY fix clear, obvious transcription mistakes. When in doubt, leave the text unchanged.

        What to fix:
        - English words/acronyms wrongly rendered as Chinese characters \
        (e.g. "配森" → "Python", "杰森" → "JSON", "阿皮爱" → "API")
        - Obvious Chinese homophone errors where context makes the correct character clear
        - Broken English words or phrases split/merged incorrectly by the recognizer

        What NOT to do:
        - Do NOT rephrase, rewrite, or "improve" any text
        - Do NOT add or remove words beyond fixing recognition errors
        - Do NOT change text that could plausibly be correct
        - Do NOT alter punctuation unless clearly wrong

        If the input appears correct, return it exactly as-is. Return ONLY the text, nothing else.
        """

    // /no_think directive disables Qwen3 reasoning chain (verified working on
    // qwen3-8b-mlx — drops reasoning_tokens from 420 → 1, latency 8s → 1s).
    // Does NOT work on Qwen3.6-27B per LM Studio chat template.
    static let defaultClaudeCodePrompt = """
        /no_think You convert a developer's mixed Chinese/English voice input \
        into clean English text for Claude Code.

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

    func refine(_ text: String, mode: RefineMode? = nil, force: Bool = false,
                completion: @escaping (Result<String, Error>) -> Void) {
        guard force || (isEnabled && isConfigured) else {
            completion(.success(text))
            return
        }

        let resolvedMode = mode ?? (claudeCodeModeEnabled ? .claudeCode : .refine)
        let systemPrompt = (resolvedMode == .claudeCode) ? claudeCodeSystemPrompt : refineSystemPrompt

        let baseURL = apiBaseURL.hasSuffix("/") ? String(apiBaseURL.dropLast()) : apiBaseURL
        guard let url = URL(string: "\(baseURL)/chat/completions") else {
            completion(.failure(RefinerError.invalidURL))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 90  // Qwen3 reasoning models can take 30s+ per inference

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": text],
            ],
            "temperature": resolvedMode == .claudeCode ? 0.2 : 0.3,
            // Qwen3 reasoning models burn ~250 tokens on internal thinking before
            // producing the actual answer. 600 leaves room for ~350 tokens of answer.
            "max_tokens": 600,
        ]

        logToFile("Request: \(url.absoluteString) model=\(model) mode=\(resolvedMode.rawValue)")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let suffixToAppend = (resolvedMode == .claudeCode) ? claudeCodeSuffix : ""

        currentTask = URLSession.shared.dataTask(with: request) { data, _, error in
            if let error {
                logToFile("Network error: \(error.localizedDescription)")
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            guard let data else {
                logToFile("No data in response")
                DispatchQueue.main.async { completion(.failure(RefinerError.invalidResponse)) }
                return
            }
            if let raw = String(data: data, encoding: .utf8) {
                logToFile("Response: \(raw)")
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any]
            else {
                logToFile("Failed to parse response")
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
                logToFile("WARN: empty content. finish=\(finishReason) usage=\(usage ?? [:])")
            }
            let refined = content.trimmingCharacters(in: .whitespacesAndNewlines)
            let finalText = suffixToAppend.isEmpty ? refined : "\(refined)\(suffixToAppend)"
            logToFile("Refined (\(resolvedMode.rawValue)): '\(text)' -> '\(refined)' (suffix=\(suffixToAppend.count) chars)")
            DispatchQueue.main.async { completion(.success(finalText)) }
        }
        currentTask?.resume()
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
    }

    /// Probe an OpenAI-compatible /v1/models endpoint. Used by Settings to detect LM Studio.
    func probeModels(completion: @escaping (Result<[String], Error>) -> Void) {
        let baseURL = apiBaseURL.hasSuffix("/") ? String(apiBaseURL.dropLast()) : apiBaseURL
        guard let url = URL(string: "\(baseURL)/models") else {
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
