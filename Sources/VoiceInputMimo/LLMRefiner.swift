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
        get { UserDefaults.standard.string(forKey: "llmAPIBaseURL") ?? "http://127.0.0.1:4000/v1" }
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

    /// The scheduled 503 retry, if one is pending its `Retry-After` wait. Held so
    /// `cancel()` can drop it when an interrupting segment preempts the job —
    /// otherwise the wait would fire a stale retry after the job was requeued.
    /// Only touched on the main queue (see `scheduleRetry`).
    private var pendingRetryWork: DispatchWorkItem?

    /// Monotonic token bumped by `cancel()`. A 503 retry captures the value at
    /// send time and only fires while it still matches — so an interrupt that
    /// preempts the job drops the retry regardless of how it races the (background)
    /// URLSession completion that decided to retry. Closes the scheduleRetry ×
    /// cancel window where a stale retry could otherwise overwrite `currentTask`.
    /// Main-queue only.
    private var generation = 0

    /// Test seam: send-time generation snapshot (use a fresh instance per test).
    var currentGeneration: Int { generation }

    /// Test seam for the retry timer — production defers on the main queue; tests
    /// inject a synchronous / capturing variant so retry gating is verified
    /// without a real `Retry-After` sleep. Only invoked on the main queue.
    var scheduleRetryAfter: (TimeInterval, DispatchWorkItem) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

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

    /// Protocol-conformance entry point matching `Refining.refine`. Forwards
    /// to the captured-context variant with `nil` so non-recording callers
    /// (Settings "Test" button, Prompts pane preview) keep the original
    /// late-capture behavior — they have no hotkey moment to snapshot from.
    func refine(_ text: String, requestId: String = "", mode: RefineMode? = nil, force: Bool = false,
                completion: @escaping (Result<String, Error>) -> Void) {
        refine(text, requestId: requestId, mode: mode, force: force,
               capturedContext: nil, routingCallback: nil, completion: completion)
    }

    /// Recording-path entry point. `capturedContext` is the frontmost-app
    /// snapshot taken at hotkey-down time (see `AppDelegate.fnDown`). When
    /// non-nil, `.contextAware` dispatch routes via that bundle ID instead
    /// of re-capturing at refine() time (which would observe the wrong
    /// frontmost after ASR latency / focus changes).
    ///
    /// `routingCallback` is invoked synchronously after dispatch is decided
    /// (before LLM/workflow execution). Carries `(inputMode, routing)` so
    /// the caller can persist routing telemetry without LLMRefiner taking
    /// a hard dependency on RecordingTracer. `routing` is nil for non-
    /// `.contextAware` input modes — they bypass ToneMapping.
    func refine(_ text: String, requestId: String = "", mode: RefineMode? = nil, force: Bool = false,
                capturedContext: CapturedContext?,
                routingCallback: ((_ inputMode: RefineMode, _ routing: TraceEntry.Routing?) -> Void)? = nil,
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
        // contextAware delegates either to a concrete mode (`.mode(.refine)`)
        // or to a named workflow chain (Sprint 3.2). The workflow path
        // bypasses the prompt-resolution / single LLM-call code below entirely
        // — it runs the chain via WorkflowExecutor and returns the chain's
        // final output via completion. Missing workflow falls back to refine.
        // Capture the ToneMatch when routing through contextAware so we can
        // emit telemetry — `decideDispatch` only needs the delegate but
        // routingCallback wants the source/index/prefix too.
        let toneMatch: ToneMatch? = rawMode == .contextAware
            ? ToneMapping.resolveWithMatch(
                // Prefer the context captured at hotkey-down time. By the
                // time refine() runs, ASR has already finished and the
                // user may have switched focus (or the HUD overlay may
                // have stolen frontmost) — late capture would route to
                // the wrong app's rule. fall back to a live capture only
                // when callers don't pre-capture (e.g. tests, Settings
                // "Test" button).
                context: capturedContext ?? ContextCapture.capture(),
                userRules: (try? ToneMappingStore.shared.loadAll()) ?? []
            )
            : nil

        let resolvedMode: RefineMode
        let dispatchDecision = Self.decideDispatch(
            rawMode: rawMode,
            delegate: toneMatch?.delegate,
            findWorkflow: { try? WorkflowStore.shared.find(id: $0) }
        )
        // Emit routing telemetry before executing dispatch — caller persists
        // even if the LLM call or workflow run subsequently fails.
        if let routingCallback {
            routingCallback(rawMode, Self.makeRoutingTelemetry(match: toneMatch, decision: dispatchDecision))
        }
        switch dispatchDecision {
        case .singleMode(let m):
            resolvedMode = m
        case .workflow(let workflow):
            let inputText = text
            Task {
                let result = await WorkflowExecutor.shared.execute(
                    workflow: workflow,
                    input: inputText
                )
                completion(.success(result.finalOutput))
            }
            return
        case .workflowMissing(let workflowId):
            // ToneRule references a workflow id that isn't in the store. Fall
            // back to refine rather than failing the dispatch — mirrors
            // structure mode's "router miss → defaultRefinePrompt" fallback.
            logger.warning("ToneRule referenced missing workflow id \(workflowId, privacy: .public) — falling back to refine")
            resolvedMode = .refine
        }
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

        let resolvedModel = activeProfile?.modelOverride ?? model
        let resolvedTemp = activeProfile?.temperature ?? (resolvedMode == .claudeCode ? 0.2 : 0.3)
        // Structure mode produces multi-section Markdown documents — ~1500
        // gives room for ~1250 tokens of actual content after Qwen3 reasoning
        // overhead. Refine/ClaudeCode keep the original 600 cap (single-line
        // outputs).
        let resolvedMaxTokens = resolvedMode == .structure ? 1500 : 600

        let suffixToAppend: String
        if resolvedMode == .claudeCode {
            suffixToAppend = activeProfile?.suffix ?? claudeCodeSuffix
        } else {
            suffixToAppend = ""
        }

        let attempt = RefineAttempt(
            systemPrompt: systemPrompt,
            text: text,
            requestId: requestId,
            model: resolvedModel,
            temperature: resolvedTemp,
            maxTokens: resolvedMaxTokens,
            gatewayMode: Self.gatewayMode(for: resolvedMode),
            modeLabel: resolvedMode.rawValue,
            profileLabel: activeProfile?.id ?? "<none>",
            suffixToAppend: suffixToAppend,
            isRetry: false,
            generation: generation
        )
        performRefineRequest(attempt, completion: completion)
    }

    /// Immutable per-attempt parameters for one refine HTTP send. Bundled so the
    /// send path and its one-shot retry share a single value rather than an
    /// 11-argument call, and so `performRefineRequest` stays small.
    struct RefineAttempt {
        let systemPrompt: String
        let text: String
        let requestId: String
        let model: String
        let temperature: Double
        let maxTokens: Int
        let gatewayMode: String
        let modeLabel: String
        let profileLabel: String
        let suffixToAppend: String
        let isRetry: Bool
        /// Send-time generation; preserved across the retry so a superseded job's
        /// retry is still dropped by the generation guard.
        let generation: Int

        /// The one-shot retry: same request re-sent via the default (non-quick)
        /// queue with `isRetry` set.
        func retryAttempt() -> RefineAttempt {
            RefineAttempt(
                systemPrompt: systemPrompt, text: text, requestId: requestId,
                model: model, temperature: temperature, maxTokens: maxTokens,
                gatewayMode: LLMRefiner.retryGatewayMode, modeLabel: modeLabel,
                profileLabel: profileLabel, suffixToAppend: suffixToAppend,
                isRetry: true, generation: generation
            )
        }
    }

    /// Build and send one refine attempt. The 503-triggered retry / response
    /// handling lives in `handleCompletion` so this stays focused on send.
    ///
    /// Retry state (`currentTask`, `pendingRetryWork`, `generation`) is mutated
    /// only on the main queue — the job queue drives refine on main and `cancel()`
    /// runs on main, so there is no cross-thread race with an interrupting segment.
    private func performRefineRequest(
        _ attempt: RefineAttempt,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard let url = URL(string: "\(normalizedBaseURL())/chat/completions") else {
            completion(.failure(RefinerError.invalidURL))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if !attempt.requestId.isEmpty {
            request.setValue(attempt.requestId, forHTTPHeaderField: "X-Request-Id")
        }
        request.timeoutInterval = 90  // Qwen3 reasoning models can take 30s+ per inference
        request.httpBody = try? JSONSerialization.data(withJSONObject: Self.requestBody(for: attempt))

        let logTag = attempt.requestId.isEmpty ? "" : "[req=\(attempt.requestId)] "
        logger.debug("\(logTag)Request: \(url.absoluteString) model=\(attempt.model) mode=\(attempt.gatewayMode) profile=\(attempt.profileLabel) retry=\(attempt.isRetry)")

        currentTask = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            self?.handleCompletion(
                attempt: attempt, data: data, response: response, error: error,
                logTag: logTag, completion: completion
            )
        }
        currentTask?.resume()
    }

    private static func requestBody(for attempt: RefineAttempt) -> [String: Any] {
        [
            "model": attempt.model,
            "messages": [
                ["role": "system", "content": attempt.systemPrompt],
                ["role": "user", "content": attempt.text],
            ],
            "temperature": attempt.temperature,
            "max_tokens": attempt.maxTokens,
            "mode": attempt.gatewayMode,
        ]
    }

    /// URLSession completion (background queue): decide 503 retry vs terminal
    /// response. A gateway 503 on a first quick attempt schedules the one-shot
    /// retry; everything else falls through to `handleRefineResponse` → raw-ASR
    /// fallback in AppDelegate.
    private func handleCompletion(
        attempt: RefineAttempt,
        data: Data?,
        response: URLResponse?,
        error: Error?,
        logTag: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        // Cancelled mid-flight: caller (RecordingJobQueue) will resume this job
        // later. Don't fire completion — the JobRunner callback would mutate
        // overlay state belonging to the new in-flight segment.
        let nsErr = error as NSError?
        if nsErr?.code == NSURLErrorCancelled { return }

        let http = response as? HTTPURLResponse
        let decision = Self.decideRetry(
            statusCode: http?.statusCode,
            retryAfterHeader: http?.value(forHTTPHeaderField: "Retry-After"),
            isRetry: attempt.isRetry,
            gatewayMode: attempt.gatewayMode
        )
        if case .retry(let afterSeconds) = decision {
            // .notice (not .debug): os.Logger drops debug by default, and this is
            // the only signal that the S2.2 cold-load retry actually engaged.
            logger.notice("\(logTag)gateway 503 — retrying once via \(Self.retryGatewayMode) after \(afterSeconds)s")
            let retry = attempt.retryAttempt()
            scheduleRetry(generation: attempt.generation, afterSeconds: afterSeconds) { [weak self] in
                self?.performRefineRequest(retry, completion: completion)
            }
            return
        }
        Self.handleRefineResponse(
            data: data, error: error, suffixToAppend: attempt.suffixToAppend,
            modeLabel: attempt.modeLabel, text: attempt.text, logTag: logTag, completion: completion
        )
    }

    /// Parse a chat-completions response and fire `completion` on the main queue.
    /// Extracted from the request closure so `performRefineRequest` stays focused
    /// on send + retry orchestration. No instance state — the file-level `logger`
    /// is global — so it stays a static helper.
    private static func handleRefineResponse(
        data: Data?,
        error: Error?,
        suffixToAppend: String,
        modeLabel: String,
        text: String,
        logTag: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
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
        logger.debug("\(logTag)Refined (\(modeLabel)): '\(text)' -> '\(refined)' (suffix=\(suffixToAppend.count) chars)")
        DispatchQueue.main.async { completion(.success(finalText)) }
    }

    /// Hop the 503 retry onto the main queue, then arm it. The whole
    /// "check generation + set pendingRetryWork + schedule" runs in one main-queue
    /// turn, so a `cancel()` that raced the (background) completion is seen either
    /// before arming (generation guard drops it) or after (it cancelled the work /
    /// bumped the generation). Either ordering is caught.
    private func scheduleRetry(generation: Int, afterSeconds: TimeInterval, _ body: @escaping () -> Void) {
        DispatchQueue.main.async { [weak self] in
            self?.armRetry(generation: generation, afterSeconds: afterSeconds, body)
        }
    }

    /// Arm the single retry on the main queue. If `cancel()` already bumped the
    /// generation, the retry is dropped here; otherwise the deferred work re-checks
    /// the generation before running `body`, so an interrupt during the wait also
    /// drops it. Internal for tests (see `scheduleRetryAfter`).
    func armRetry(generation: Int, afterSeconds: TimeInterval, _ body: @escaping () -> Void) {
        guard generation == self.generation else { return }  // superseded before arming
        let work = DispatchWorkItem { [weak self] in
            self?.executeRetryIfCurrent(generation: generation, body)
        }
        pendingRetryWork = work
        scheduleRetryAfter(afterSeconds, work)
    }

    /// Run `body` only if the send-time `generation` is still current — i.e. no
    /// `cancel()` / interrupt happened since. Internal for tests.
    func executeRetryIfCurrent(generation: Int, _ body: () -> Void) {
        guard generation == self.generation else { return }  // superseded during wait
        body()
    }

    func cancel() {
        // Bump first: invalidates any in-flight retry (armed or mid-schedule) even
        // if it races this call on the main queue.
        generation &+= 1
        currentTask?.cancel()
        currentTask = nil
        pendingRetryWork?.cancel()
        pendingRetryWork = nil
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

    /// Map our internal RefineMode to the local-llm-backend gateway's mode field.
    /// The gateway routes by mode to per-mode priority queue + timeout config:
    ///   quick   (priority 10, 5s timeout, max_inflight 1) — refine: short single-line cleanup
    ///   default (priority 5, 30s timeout)                — claudeCode: medium with reasoning
    ///   batch   (priority 1, 60s timeout)                — structure: long multi-section markdown
    /// Outcome of resolving `rawMode` + `ToneDelegate` into a concrete
    /// dispatch action. Extracted so unit tests can exercise the orchestration
    /// without going through singletons (URLSession / WorkflowStore / etc.).
    enum DispatchDecision: Equatable {
        case singleMode(RefineMode)
        case workflow(Workflow)
        case workflowMissing(workflowId: String)
    }

    /// Pure decision step for `refine()`. `delegate` is the resolved
    /// `ToneDelegate` when `rawMode == .contextAware`, nil otherwise. The
    /// caller supplies `findWorkflow` so tests can inject a store snapshot
    /// instead of hitting `WorkflowStore.shared`.
    static func decideDispatch(
        rawMode: RefineMode,
        delegate: ToneDelegate?,
        findWorkflow: (String) -> Workflow?
    ) -> DispatchDecision {
        if rawMode != .contextAware {
            return .singleMode(rawMode)
        }
        switch delegate ?? .mode(.refine) {
        case .mode(let m):
            return .singleMode(m)
        case .workflow(let id):
            if let wf = findWorkflow(id) {
                return .workflow(wf)
            }
            return .workflowMissing(workflowId: id)
        }
    }

    /// Convert ToneMatch + DispatchDecision into the persisted Routing
    /// shape. Returns nil for non-contextAware dispatch (no toneMatch) —
    /// telemetry only makes sense when ToneMapping actually ran.
    ///
    /// `dispatchedTo` encodes the post-decideDispatch action; differs from
    /// `match.delegate` when the matched workflow id wasn't found
    /// (`.workflowMissing` path).
    static func makeRoutingTelemetry(
        match: ToneMatch?,
        decision: DispatchDecision
    ) -> TraceEntry.Routing? {
        guard let match else { return nil }
        let dispatchedTo: String
        switch decision {
        case .singleMode(let m):
            dispatchedTo = TraceEntry.Routing.modePrefix + m.rawValue
        case .workflow(let wf):
            dispatchedTo = TraceEntry.Routing.workflowPrefix + wf.id
        case .workflowMissing(let id):
            dispatchedTo = TraceEntry.Routing.workflowMissingPrefix + id
        }
        return TraceEntry.Routing(
            matchedSource: match.source.rawValue,
            matchedIndex: match.index,
            matchedPrefix: match.prefix,
            dispatchedTo: dispatchedTo
        )
    }

    static func gatewayMode(for refineMode: RefineMode) -> String {
        switch refineMode {
        case .refine: return "quick"
        case .claudeCode: return "default"
        case .structure: return "batch"
        case .contextAware:
            // Defensive — `.contextAware` is a dispatcher; refine() resolves it to
            // a concrete mode before reaching the gateway. Mirror `.refine`'s
            // "quick" queue if the dispatcher ever leaks through.
            return "quick"
        }
    }

    // MARK: - Cold-load warmup

    /// Gateway queue for the warmup probe. Deliberately NOT `quick`: quick's 5s
    /// gateway timeout aborts a Rapid-MLX cold load (heavy cold ≥14–25s) — the
    /// exact case warmup exists to hide. `default` (30s gateway queue) covers the
    /// observed cold-load range; the residual >30s tail is handled downstream by
    /// the gateway-503 + single-retry path, not here.
    static let warmUpGatewayMode = "default"

    /// Client-side timeout for the warmup request. Longer than `default`'s 30s
    /// gateway timeout so the client never gives up before the gateway returns
    /// (success or a 503 the caller can act on), while still bounding a hung probe.
    static let warmUpTimeoutSeconds: TimeInterval = 60

    /// Minimal user content for the warmup probe. One token in / one token out is
    /// enough to force the backend to load the model without paying for real
    /// generation.
    private static let warmUpProbeContent = "hi"

    /// Output cap for the warmup probe — a single token forces a model load with
    /// no real generation.
    static let warmUpMaxTokens = 1

    /// Build the warmup request: a minimal `max_tokens: 1` chat completion routed
    /// through the non-quick gateway queue. Pure/synchronous so the request shape
    /// (mode, timeout, max_tokens) is unit-testable without the network. Returns
    /// nil only when the configured base URL is malformed.
    func makeWarmUpRequest() -> URLRequest? {
        guard let url = URL(string: "\(normalizedBaseURL())/chat/completions") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = Self.warmUpTimeoutSeconds
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": Self.warmUpProbeContent]],
            "max_tokens": Self.warmUpMaxTokens,
            "mode": Self.warmUpGatewayMode,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Whether a warmup response confirms the backend is now hot. Only a 2xx
    /// counts: a gateway 503 (still cold / not ready) or any transport error must
    /// NOT stamp the freshness clock, so the next record-start retries. Pure —
    /// unit-tested in place of the fire-and-forget network wiring.
    static func warmUpSucceeded(statusCode: Int?, error: Error?) -> Bool {
        if error != nil { return false }
        guard let statusCode else { return false }
        return (200..<300).contains(statusCode)
    }

    /// Fire a fire-and-forget warmup probe to pull the LLM backend hot during the
    /// recording+ASR window, so the first refine after a Rapid-MLX process restart
    /// isn't aborted mid-cold-load. Uses its own URLSession task (NOT `currentTask`)
    /// so it can never be cancelled by — or cancel — an in-flight refine; the two
    /// are independent requests the gateway queues on its own side. `onSuccess`
    /// runs on the main queue after a confirmed-hot (2xx) response; failures are
    /// logged and swallowed so they never surface to the user or block recording.
    func warmUp(onSuccess: (() -> Void)? = nil) {
        guard isEnabled, isConfigured else { return }
        guard let request = makeWarmUpRequest() else {
            logger.error("warmUp skipped: invalid base URL")
            return
        }
        URLSession.shared.dataTask(with: request) { _, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode
            if Self.warmUpSucceeded(statusCode: status, error: error) {
                logger.debug("warmUp ok (backend hot)")
                DispatchQueue.main.async { onSuccess?() }
            } else if let error {
                logger.debug("warmUp failed (benign): \(error.localizedDescription)")
            } else {
                logger.debug("warmUp non-2xx (benign): status=\(status ?? -1)")
            }
        }.resume()
    }

    // MARK: - 503-triggered single retry

    /// Gateway queue for the 503 retry. Same rationale as `warmUpGatewayMode`:
    /// upgrade off `quick` (whose 5s abort caused the 503 fast-fail) to `default`
    /// so the retry gets the 30s budget to ride the residual cold load.
    static let retryGatewayMode = "default"

    /// Gateway queue whose 5s budget the cold-load retry exists to protect. Only
    /// a 503 on this queue triggers a retry (see `decideRetry`).
    static let quickGatewayMode = "quick"

    /// Wait applied when the gateway 503s without a usable `Retry-After`. Sized
    /// to the light-cold reload; the retry itself then has the 30s default-queue
    /// budget on top.
    static let defaultRetryAfterSeconds: TimeInterval = 15

    /// Upper bound on the honored `Retry-After`. A buggy / hostile gateway must
    /// not stall refine for minutes — and the wait plus a 30s retry must stay
    /// well inside the 90s client timeout.
    static let maxRetryAfterSeconds: TimeInterval = 30

    /// Outcome of the single-retry decision for a refine response. Extracted so
    /// the retry gating is unit-testable without the network.
    enum RefineRetryDecision: Equatable {
        case retry(afterSeconds: TimeInterval)
        case giveUp
    }

    /// Decide whether a refine response should trigger the one-shot retry. Retries
    /// only a gateway 503 on the FIRST attempt of a QUICK-queue request; everything
    /// else gives up so the caller falls through to the raw-ASR fallback:
    ///   - already retried → bounds the retry to exactly one (no storm)
    ///   - non-503 / no HTTP status → not the cold fast-fail (5s-abort timeout
    ///     surfaces as a URLError with no 503 and must not retry)
    ///   - non-quick queue → the mechanism is for quick's 5s budget; default(30s)
    ///     gains nothing by retrying as default, and structure(batch/60s) would be
    ///     downgraded to the 30s default queue. Their 503s take the failure path.
    static func decideRetry(
        statusCode: Int?,
        retryAfterHeader: String?,
        isRetry: Bool,
        gatewayMode: String
    ) -> RefineRetryDecision {
        guard !isRetry else { return .giveUp }
        guard gatewayMode == quickGatewayMode else { return .giveUp }
        guard statusCode == 503 else { return .giveUp }
        return .retry(afterSeconds: parseRetryAfter(retryAfterHeader))
    }

    /// Parse a `Retry-After` delta-seconds value, defensively. Missing /
    /// non-numeric (including the HTTP-date form we don't support) and negative
    /// values fall back to the default wait; oversized values clamp to the upper
    /// bound. Never throws — always yields a usable, bounded delay.
    static func parseRetryAfter(_ header: String?) -> TimeInterval {
        guard let raw = header?.trimmingCharacters(in: .whitespaces),
              let seconds = TimeInterval(raw), seconds >= 0
        else {
            return defaultRetryAfterSeconds
        }
        return min(seconds, maxRetryAfterSeconds)
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
    /// the local LLM backend (Rapid-MLX by default; ollama also works).
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
