import AppKit
import AVFoundation
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let keyMonitor = KeyMonitor()
    private let audioRecorder = AudioRecorder()
    private let textInjector = TextInjector()
    private lazy var overlayPanel = OverlayPanel()
    private let tracer = RecordingTracer()

    private var isEnabled = true
    private var isRecording = false
    /// Set during a Ctrl+Option+R recording — gates the post-ASR
    /// pipeline to skip LLM + paste and route to a park trace instead.
    private var isParkMode = false

    private var enableMenuItem: NSMenuItem!
    private var outputModeMenuItem: NSMenuItem!
    private var englishOutputMenuItem: NSMenuItem!
    private var chineseOutputMenuItem: NSMenuItem!
    private var refinedChineseOutputMenuItem: NSMenuItem!
    private var structureOutputMenuItem: NSMenuItem!
    private var contextAwareOutputMenuItem: NSMenuItem!
    private var asrServerMenuItem: NSMenuItem!
    private var asrServerStatusMenuItem: NSMenuItem!
    private lazy var settingsWindow = SettingsWindow()
    private lazy var clipboardHistoryWindow = ClipboardHistoryWindow()
    private lazy var modelMemoryWindow = ModelMemoryWindow()

    // Phase progress timer (drives the elapsed-time counter shown in the overlay)
    private var phaseTimer: Timer?
    private var phaseStart: Date?
    private var phaseBuilder: ((Double) -> OverlayPanel.Phase)?

    // Last-seen ZH transcript, kept across LLM refining so refining/bothReady phases
    // can show the original text alongside the translated output.
    private var currentZH: String = ""

    // Snapshot of the frontmost-app context captured at the moment the
    // recording hotkey is pressed. Used for `.contextAware` dispatch instead
    // of late-capturing inside `LLMRefiner.refine`. By the time refine() runs,
    // ASR has already completed and the user may have switched focus — late
    // capture would route to the wrong app's tone-mapping rule (Mode 4
    // misjudgment). Cleared after the LLM call completes / errors.
    private var contextAtKeyDown: CapturedContext?

    // Cancellable "show .refining after holding ZH for 0.4 s" deferred work.
    // If the LLM completes within 0.4 s we cancel this so the overlay isn't
    // resurrected back to .refining after .bothReady.
    private var refiningHoldWork: DispatchWorkItem?

    // Latency instrumentation — set on fnUp entry, read by logLatency() to emit
    // `[Latency] fnUp +<marker>: <ms>ms` lines at each pipeline stage. Used to
    // RCA cutover overhead via Console.app log stream. Zero-cost when disabled
    // (Bool flag short-circuits before any timing math).
    private static let latencyLoggingEnabled = true
    private var fnUpStart: CFAbsoluteTime?

    private func logLatency(_ marker: String) {
        guard Self.latencyLoggingEnabled, let start = fnUpStart else { return }
        let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
        NSLog("[Latency] fnUp +%@: %dms", marker, ms)
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("[AppDelegate] launch preview=%@", isPreviewMode ? "YES" : "NO")
        terminateConflictingApps()
        setupStatusBar()
        bootstrapPromptStore()

        if ProcessInfo.processInfo.environment["VOICE_INPUT_MIMO_PREVIEW"] == "1" {
            installPreviewArchive()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.openClipboardHistory()
                self?.openModelMemory()
                // Auto-open Settings in PREVIEW so smoke tests can drive
                // pane switching via osascript without having to click the
                // status bar item (which lives in SystemUIServer, not in
                // this process's accessibility tree).
                self?.openSettings()
            }
            return
        }

        // Standalone overlay-only preview for visual verification of the
        // bothReady dual-line layout (zh top, en bottom) and hover-to-stay
        // behaviour. Skips audio/keyboard wiring so the overlay can be
        // captured by a screenshot script without a real recording. Uses a
        // 1 s repeating transition to keep cancelling the auto-dismiss
        // timer — overlay stays visible until the process is killed.
        if ProcessInfo.processInfo.environment["VOICE_INPUT_MIMO_OVERLAY_DEMO"] == "swiftui" {
            renderSwiftUIOverlayDemo()
            return
        }

        if ProcessInfo.processInfo.environment["VOICE_INPUT_MIMO_OVERLAY_DEMO"] == "1" {
            // Demo text via env vars (defaults to a long realistic sample so
            // we can see truncation behaviour). Both ZH and EN can be
            // overridden independently for visual testing.
            let zhText = ProcessInfo.processInfo.environment["VOICE_INPUT_MIMO_OVERLAY_ZH"]
                ?? "然後幫我給到一個設計，是我希望我的中文 LLM 修正以及英文翻譯，這兩個都可以是我可以 customize 我的 prompt"
            let enText = ProcessInfo.processInfo.environment["VOICE_INPUT_MIMO_OVERLAY_EN"]
                ?? "Then give me a design where I can customize the prompts for both my Chinese LLM refinement and English translation"
            let phase = OverlayPanel.Phase.bothReady(
                zh: zhText,
                en: enText,
                translating: true
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.overlayPanel.transition(to: phase)
            }
            Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.overlayPanel.transition(to: phase)
            }
            // Self-snapshot to disk so a parent process without Screen
            // Recording permission can still inspect the rendered overlay.
            // Output path is overridable via VOICE_INPUT_MIMO_OVERLAY_OUT.
            let out = ProcessInfo.processInfo.environment["VOICE_INPUT_MIMO_OVERLAY_OUT"]
                ?? "/tmp/voice-input-mimo-overlay.png"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.snapshotOverlay(to: out)
            }
            return
        }

        setupAudioCallbacks()

        AudioRecorder.requestPermissions { [weak self] granted, errorMsg in
            NSLog("[AppDelegate] Microphone permission granted=%@", granted ? "YES" : "NO")
            if !granted, let msg = errorMsg {
                self?.showAlert(title: "Permission Required", message: msg)
            }
        }

        // Probe Accessibility permission — required for CGEvent.tap to deliver flagsChanged
        let axTrusted = AXIsProcessTrusted()
        NSLog("[AppDelegate] AXIsProcessTrusted=%@", axTrusted ? "YES" : "NO")
        if !axTrusted {
            // Trigger system prompt + open settings pane
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            _ = AXIsProcessTrustedWithOptions(opts as CFDictionary)
        }

        let started = keyMonitor.start()
        NSLog("[AppDelegate] KeyMonitor.start() returned %@", started ? "YES" : "NO")
        if !started {
            showAccessibilityAlert()
        }

        keyMonitor.onFnDown = { [weak self] in self?.fnDown() }
        keyMonitor.onFnUp = { [weak self] in self?.fnUp() }
        keyMonitor.onCycleNext = { [weak self] in self?.cycleOutputMode(direction: 1) }
        keyMonitor.onCyclePrev = { [weak self] in self?.cycleOutputMode(direction: -1) }
        keyMonitor.onParkDown = { [weak self] in self?.parkDown() }
        keyMonitor.onParkUp = { [weak self] in self?.parkUp() }
        NotificationCenter.default.addObserver(
            forName: .shortcutBindingDidChange, object: nil, queue: .main
        ) { [weak self] _ in self?.keyMonitor.invalidateShortcutCache() }

        // Probe ASR server in the background to surface readiness in menu/log
        LocalASRServer.shared.onStateChange = { [weak self] _ in
            DispatchQueue.main.async { self?.refreshASRServerMenu() }
        }
        LocalASRServer.shared.refresh { [weak self] _ in
            DispatchQueue.main.async { self?.refreshASRServerMenu() }
        }

        // Warm up the ASR pipeline on launch so the user's first recording
        // doesn't hit the MLX cold-load tax (~1s). Sends a 1s silence WAV
        // through gateway → MiMo sidecar. Delay 3s to let LocalASRServer
        // either adopt the running sidecar or finish spawn before we hit it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.warmUpASR()
        }

        // Auto-sync fixtures at launch if a destination is remembered.
        // Delayed 5s to stagger I/O after warmup and let UI settle.
        // No remembered destination → silently skip (user hasn't configured).
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            self?.runFixtureExport(silent: true)
        }
    }

    /// One-shot ASR warmup at launch. Fire-and-forget — smokeTranscribe
    /// internally probes adminMemory then transcribes a 1s silence WAV via
    /// gateway → MiMo, triggering the MLX cold-load if model evicted. Failure
    /// silently NSLogs (sidecar/gateway may be down at launch — user gets the
    /// real error on first manual recording).
    private func warmUpASR() {
        ASRClient.shared.smokeTranscribe { result in
            switch result {
            case .success(let r):
                NSLog(
                    "[AppDelegate] ASR warmup done: elapsed=%dms wasCold=%@",
                    r.elapsedMs,
                    r.wasCold ? "YES" : "NO"
                )
            case .failure(let err):
                NSLog("[AppDelegate] ASR warmup failed: %@", err.localizedDescription)
            }
        }
    }

    /// Idempotent: once `prompts/active.json` exists `bootstrapIfNeeded`
    /// short-circuits, so this is safe to call on every launch.
    private func bootstrapPromptStore() {
        let migration = PromptMigration(
            store: PromptStore.shared,
            userDefaults: .standard,
            hardcodedRefineDefault: LLMRefiner.defaultRefinePrompt,
            hardcodedClaudeCodeDefault: LLMRefiner.defaultClaudeCodePrompt
        )
        do {
            let result = try migration.bootstrapIfNeeded()
            if result.didBootstrap {
                NSLog(
                    "[AppDelegate] prompts bootstrapped (importedRefine=%@ importedClaudeCode=%@)",
                    result.importedRefineProfileID ?? "-",
                    result.importedClaudeCodeProfileID ?? "-"
                )
            }
        } catch {
            NSLog("[AppDelegate] prompt bootstrap failed: %@", String(describing: error))
        }
        Task { @MainActor in
            await PromptStoreViewModel.shared.reload()
            self.refreshOutputModeMenu()
        }
    }

    private func installPreviewArchive() {
        let path = ProcessInfo.processInfo.environment["VOICE_INPUT_MIMO_ARCHIVE_PATH"]
            ?? "\(NSTemporaryDirectory())voice-input-mimo-preview-archive.txt"
        let url = URL(fileURLWithPath: path)
        let sample = """
        ─── 2026-05-09T05:40:00Z | session ───
        Chinese (ASR)
        請把 clipboard history 修成真的清單，並且每次 session 都保留中文原文。

        English / Output
        Fix the clipboard history so it shows a real list, and preserve the Chinese source text for every session.

        ─── 2026-05-09T05:38:00Z | session ───
        Chinese (ASR)
        這個模式關掉以後應該會只貼中文 ASR 原文。

        English / Output
        When this mode is off, paste only the Chinese ASR transcript.

        ─── 2026-05-09T05:35:00Z | clipboard ───
        Previous clipboard content before VoiceInputMimo pasted output.

        """
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? sample.write(to: url, atomically: true, encoding: .utf8)
        setenv("VOICE_INPUT_MIMO_ARCHIVE_PATH", url.path, 1)
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSLog("[AppDelegate] will terminate preview=%@", isPreviewMode ? "YES" : "NO")
        if isPreviewMode { return }
        LocalASRServer.shared.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private var isPreviewMode: Bool {
        ProcessInfo.processInfo.environment["VOICE_INPUT_MIMO_PREVIEW"] == "1"
    }

    // MARK: - Key events

    private func fnDown() {
        guard isEnabled, !isRecording else { return }
        LLMRefiner.shared.cancel()
        ASRClient.shared.cancel()
        isRecording = true
        currentZH = ""
        // Snapshot frontmost BEFORE any UI work that might steal focus (HUD
        // is a non-activating panel, but be defensive — and the user's
        // intent is captured at the moment of press, not at ASR-completion).
        contextAtKeyDown = ContextCapture.capture()
        tracer.begin()

        updateStatusIcon(recording: true)
        overlayPanel.transition(to: .recording(elapsed: 0))
        startPhaseTimer { .recording(elapsed: $0) }
        NSSound(named: .init("Tink"))?.play()

        audioRecorder.startRecording()
    }

    private func fnUp() {
        guard isRecording else { return }
        fnUpStart = CFAbsoluteTimeGetCurrent()
        isRecording = false
        updateStatusIcon(recording: false)
        stopPhaseTimer()

        let wavURL = audioRecorder.stopRecording()
        logLatency("stopRec")
        guard let wavURL else {
            overlayPanel.transition(to: .error("No audio captured"))
            tracer.recordError("No audio captured")
            tracer.finalize()
            isParkMode = false
            return
        }
        tracer.recordAudio(path: wavURL.path)

        // Stage 1: ASR via local-llm-backend gateway :4000 (was direct :8766 pre-cutover).
        overlayPanel.transition(to: .transcribing(elapsed: 0))
        startPhaseTimer { .transcribing(elapsed: $0) }
        ASRClient.shared.transcribe(
            wavURL: wavURL,
            onArchived: { [weak self] archivedURL in
                // Repoint trace audioPath to the persistent archive copy so
                // downstream fixture export / replay can find the file after
                // AudioRecorder removes the tmp wav.
                self?.tracer.updateAudioPath(archivedURL.path)
            }
        ) { [weak self] result in
            guard let self else { return }
            self.logLatency("ASR")
            self.stopPhaseTimer()
            switch result {
            case .success(let asrResult):
                self.handleTranscription(asrResult.text, requestId: asrResult.requestId)
            case .failure(let error):
                NSLog("[AppDelegate] ASR failed: %@", error.localizedDescription)
                self.overlayPanel.transition(to: .error("ASR: \(error.localizedDescription)"))
                self.tracer.recordError("ASR: \(error.localizedDescription)")
                self.tracer.finalize()
                self.isParkMode = false
            }
        }
    }

    private func handleTranscription(_ text: String, requestId: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            overlayPanel.transition(to: .error("No speech detected"))
            tracer.recordError("No speech detected")
            tracer.finalize()
            isParkMode = false
            return
        }
        currentZH = trimmed
        tracer.recordASR(trimmed)

        // Park mode short-circuit: archive + trace the ASR transcript,
        // but no LLM refine and no paste injection. The user grabs the
        // captured text later from clipboard history or trace UI.
        if isParkMode {
            completePark(trimmed)
            return
        }

        let refiner = LLMRefiner.shared
        if refiner.isEnabled && refiner.isConfigured {
            refiningHoldWork?.cancel()
            // Resolve the effective mode from BOTH toggles. Hardcoding the
            // ternary against `claudeCodeModeEnabled` would silently fall
            // back to `.refine` when structure mode is active, which would
            // make the overlay show the wrong profile label (LLM call
            // itself uses the routed structure profile via LLMRefiner).
            let activeMode = LLMRefiner.activeModeFromToggles(
                claudeCodeEnabled: refiner.claudeCodeModeEnabled,
                structureEnabled: refiner.structureModeEnabled,
                contextAwareEnabled: refiner.contextAwareModeEnabled
            )
            let translating = activeMode == .claudeCode
            let profileLabel = activeProfileLabel(for: activeMode)

            if translating {
                // Translation flow: show bare ZH single-line for the entire
                // LLM latency. Waveform keeps animating to signal "still
                // working". When EN arrives, transition once to dual-line
                // (56→80 reflow happens exactly once). No intermediate
                // "Converting…" status — that would add a second reflow.
                overlayPanel.transition(to: .zhReady(zh: trimmed))
            } else {
                // LLM-Chinese refine: single-line "Refining Chinese …"
                // status throughout. The final `.bothReady` surfaces the
                // refined result. Skip zhReady — separate ZH preview adds
                // latency without info on this path.
                overlayPanel.transition(
                    to: .refining(
                        zh: trimmed,
                        elapsed: 0,
                        translating: false,
                        profileLabel: profileLabel
                    )
                )
                startPhaseTimer { [weak self] elapsed in
                    .refining(
                        zh: self?.currentZH ?? "",
                        elapsed: elapsed,
                        translating: false,
                        profileLabel: profileLabel
                    )
                }
            }

            refiner.refine(
                trimmed,
                requestId: requestId,
                capturedContext: contextAtKeyDown
            ) { [weak self] result in
                guard let self else { return }
                self.logLatency("refine")
                self.refiningHoldWork?.cancel()
                self.refiningHoldWork = nil
                self.stopPhaseTimer()
                // Recording cycle complete — clear the captured context so a
                // subsequent fnDown() recaptures fresh (avoid stale carry-over
                // across recordings).
                self.contextAtKeyDown = nil
                switch result {
                case .success(let refined):
                    let final = refined.isEmpty ? trimmed : refined
                    self.tracer.recordLLM(final, mode: activeMode.rawValue)
                    self.completeWithEnglish(final)
                case .failure(let error):
                    NSLog("[AppDelegate] LLM failed: %@", error.localizedDescription)
                    self.overlayPanel.transition(to: .error("LLM: \(error.localizedDescription)"))
                    // Finalize the trace now with the ASR fallback as final.
                    // The injectImmediately closure below fires 1.2s later
                    // and intentionally does not save to ClipboardArchive
                    // (preserving prior behaviour); if the user records
                    // again before then, the next `begin()` would discard
                    // this trace, so persist eagerly.
                    self.tracer.recordError("LLM: \(error.localizedDescription)")
                    self.tracer.recordFinal(trimmed)
                    self.tracer.finalize()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                        self?.injectImmediately(trimmed)
                    }
                }
            }
        } else {
            // ASR-only path: single ready state. `.bothReady` already lingers
            // ~0.7 s before dismissing, so a separate ZH-preview is redundant.
            completeWithoutTranslation(trimmed)
        }
    }

    /// LLM succeeded: show ZH + EN side-by-side for the linger window, then inject
    /// the English. Overlay handles dismissal internally after `overlayLingerSeconds`.
    private func completeWithEnglish(_ english: String) {
        // `translating` controls dual-line (ZH+EN) vs single-line overlay
        // render. Only ClaudeCode mode actually translates to a different
        // language; structure mode and refine mode both stay zh-TW so the
        // overlay collapses to single-line.
        let refiner = LLMRefiner.shared
        let activeMode = LLMRefiner.activeModeFromToggles(
            claudeCodeEnabled: refiner.claudeCodeModeEnabled,
            structureEnabled: refiner.structureModeEnabled,
            contextAwareEnabled: refiner.contextAwareModeEnabled
        )
        let translating = activeMode == .claudeCode
        overlayPanel.transition(to: .bothReady(zh: currentZH, en: english, translating: translating))
        let stamp = ClipboardArchive.shared.saveSession(
            zh: currentZH,
            english: english,
            traceId: tracer.currentTrace?.id
        )
        if let stamp { tracer.recordClipboard(timestamp: stamp) }
        tracer.recordFinal(english)
        tracer.finalize()
        injectImmediately(english)
    }

    /// ASR-only path: still show the final state with the same text in both rows
    /// for a consistent visual; reuse zhReady (no EN row) for clarity.
    private func completeWithoutTranslation(_ text: String) {
        // Promote to bothReady with EN duplicated, so the linger countdown engages.
        // translating=false: ASR-only path, overlay renders single line (no
        // duplicate ZH/EN rows).
        overlayPanel.transition(to: .bothReady(zh: text, en: text, translating: false))
        let stamp = ClipboardArchive.shared.saveSession(
            zh: text,
            english: text,
            traceId: tracer.currentTrace?.id
        )
        if let stamp { tracer.recordClipboard(timestamp: stamp) }
        tracer.recordFinal(text)
        tracer.finalize()
        injectImmediately(text)
    }

    private func injectImmediately(_ text: String) {
        textInjector.inject(text)
        logLatency("inject")
        NSSound(named: .init("Pop"))?.play()
    }

    /// Park-mode completion: ASR-only transcript is archived to clipboard
    /// history (kind=session) and the trace is finalised with mode=park.
    /// No LLM, no paste — the user retrieves it later from history.
    private func completePark(_ text: String) {
        overlayPanel.transition(to: .bothReady(zh: text, en: text, translating: false))
        let stamp = ClipboardArchive.shared.saveSession(
            zh: text,
            english: "",
            traceId: tracer.currentTrace?.id
        )
        if let stamp { tracer.recordClipboard(timestamp: stamp) }
        tracer.recordPark()
        tracer.finalize()
        NSSound(named: .init("Pop"))?.play()
        isParkMode = false
    }

    // MARK: - Park-mode hotkey

    private func parkDown() {
        guard isEnabled, !isRecording else { return }
        isParkMode = true
        // Reuse fnDown's setup path so the audio + tracer + overlay
        // boilerplate stays in one place; the divergence happens in
        // handleTranscription where isParkMode is checked.
        fnDown()
    }

    private func parkUp() {
        // Same end-side as fnUp. handleTranscription routes to
        // completePark when isParkMode is set.
        fnUp()
    }

    // MARK: - Conflict detection

    /// Terminate any sibling VoiceInput app that would also intercept the Fn key.
    /// Both apps install a CGEvent tap on `flagsChanged`, so running concurrently
    /// causes the same Fn press to trigger two recordings.
    private func terminateConflictingApps() {
        let conflictBundleIDs = [
            "com.yetone.VoiceInput",  // upstream Apple Speech-based app
        ]
        let myPID = ProcessInfo.processInfo.processIdentifier
        var terminated: [String] = []

        for bid in conflictBundleIDs {
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: bid)
                .filter { $0.processIdentifier != myPID }
            for app in running {
                let name = app.localizedName ?? bid
                let pid = app.processIdentifier
                NSLog("[AppDelegate] Terminating conflicting app: %@ (pid=%d)", name, pid)
                _ = app.terminate()
                terminated.append(name)
                // terminate() is graceful and may be ignored by event-tap-only apps.
                // Force-kill if it's still alive after 600ms.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak app] in
                    if let app, !app.isTerminated {
                        NSLog("[AppDelegate] forceTerminate %@ (pid=%d)", name, pid)
                        _ = app.forceTerminate()
                    }
                }
            }
        }

        if !terminated.isEmpty {
            // Brief, non-blocking notice in stderr for visibility
            NSLog("[AppDelegate] Resolved Fn-key conflict: terminated %@",
                  terminated.joined(separator: ", "))
        }
    }

    // MARK: - Phase progress timer

    private func startPhaseTimer(builder: @escaping (Double) -> OverlayPanel.Phase) {
        stopPhaseTimer()
        phaseBuilder = builder
        phaseStart = Date()
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, let start = self.phaseStart, let make = self.phaseBuilder else { return }
            let elapsed = Date().timeIntervalSince(start)
            self.overlayPanel.transition(to: make(elapsed))
        }
        RunLoop.main.add(t, forMode: .common)
        phaseTimer = t
    }

    private func stopPhaseTimer() {
        phaseTimer?.invalidate()
        phaseTimer = nil
        phaseStart = nil
        phaseBuilder = nil
    }

    // MARK: - Audio callbacks

    private func setupAudioCallbacks() {
        audioRecorder.onAudioLevel = { [weak self] level in
            self?.overlayPanel.updateAudioLevel(level)
        }
        audioRecorder.onError = { [weak self] msg in
            self?.stopPhaseTimer()
            self?.overlayPanel.transition(to: .error("Audio: \(msg)"))
        }
    }

    // MARK: - Status bar

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusIcon(recording: false)

        let menu = NSMenu()

        enableMenuItem = NSMenuItem(title: "啟用 VoiceInputMimo", action: #selector(toggleEnabled), keyEquivalent: "")
        enableMenuItem.target = self
        enableMenuItem.state = .on
        menu.addItem(enableMenuItem)

        menu.addItem(.separator())

        outputModeMenuItem = NSMenuItem(title: "輸出模式", action: nil, keyEquivalent: "")
        let outputMenu = NSMenu()

        // Order: raw → refined → translated. Reflects increasing processing
        // weight so the user reads the menu top-to-bottom as a ladder.
        chineseOutputMenuItem = NSMenuItem(
            title: "中文 ASR 原文（最快）",
            action: #selector(selectChineseOutputMode),
            keyEquivalent: ""
        )
        chineseOutputMenuItem.target = self
        outputMenu.addItem(chineseOutputMenuItem)

        refinedChineseOutputMenuItem = NSMenuItem(
            title: "中文 LLM 修正（不翻譯）",
            action: #selector(selectRefinedChineseOutputMode),
            keyEquivalent: ""
        )
        refinedChineseOutputMenuItem.target = self
        outputMenu.addItem(refinedChineseOutputMenuItem)

        englishOutputMenuItem = NSMenuItem(
            title: "英文翻譯（附回覆語言要求）",
            action: #selector(selectEnglishOutputMode),
            keyEquivalent: "v"
        )
        englishOutputMenuItem.keyEquivalentModifierMask = [.command, .option]
        englishOutputMenuItem.target = self
        outputMenu.addItem(englishOutputMenuItem)

        structureOutputMenuItem = NSMenuItem(
            title: "中文 複合情境（會議／任務／需求…）",
            action: #selector(selectStructureOutputMode),
            keyEquivalent: ""
        )
        structureOutputMenuItem.target = self
        outputMenu.addItem(structureOutputMenuItem)

        contextAwareOutputMenuItem = NSMenuItem(
            title: "自動辨識（依前景 app 自動選 mode）",
            action: #selector(selectContextAwareOutputMode),
            keyEquivalent: ""
        )
        contextAwareOutputMenuItem.target = self
        outputMenu.addItem(contextAwareOutputMenuItem)

        outputMenu.addItem(.separator())

        let outputHelpItem = NSMenuItem(
            title: "每次 session 會保留 ASR 原文與貼上內容",
            action: nil,
            keyEquivalent: ""
        )
        outputHelpItem.isEnabled = false
        outputMenu.addItem(outputHelpItem)

        outputModeMenuItem.submenu = outputMenu
        menu.addItem(outputModeMenuItem)

        refreshOutputModeMenu()

        // Clipboard History viewer
        let historyItem = NSMenuItem(
            title: "Clipboard History...",
            action: #selector(openClipboardHistory),
            keyEquivalent: "h"
        )
        historyItem.keyEquivalentModifierMask = [.command, .option]
        historyItem.target = self
        menu.addItem(historyItem)

        let memoryItem = NSMenuItem(
            title: "Model Memory...",
            action: #selector(openModelMemory),
            keyEquivalent: "m"
        )
        memoryItem.keyEquivalentModifierMask = [.command, .option]
        memoryItem.target = self
        menu.addItem(memoryItem)

        menu.addItem(.separator())

        // ASR Server submenu
        let asrItem = NSMenuItem(title: "ASR Server", action: nil, keyEquivalent: "")
        let asrSubmenu = NSMenu()

        asrServerStatusMenuItem = NSMenuItem(title: "Status: …", action: nil, keyEquivalent: "")
        asrServerStatusMenuItem.isEnabled = false
        asrSubmenu.addItem(asrServerStatusMenuItem)

        asrSubmenu.addItem(.separator())

        asrServerMenuItem = NSMenuItem(
            title: "Start Local ASR Server",
            action: #selector(toggleASRServer),
            keyEquivalent: ""
        )
        asrServerMenuItem.target = self
        asrSubmenu.addItem(asrServerMenuItem)

        let showLogItem = NSMenuItem(title: "Show Log…", action: #selector(showASRLog), keyEquivalent: "")
        showLogItem.target = self
        asrSubmenu.addItem(showLogItem)

        let revealScriptItem = NSMenuItem(title: "Reveal Script…", action: #selector(revealASRScript), keyEquivalent: "")
        revealScriptItem.target = self
        asrSubmenu.addItem(revealScriptItem)

        asrItem.submenu = asrSubmenu
        menu.addItem(asrItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "偏好設定...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let exportFixturesItem = NSMenuItem(
            title: "匯出錄音與文字稿…",
            action: #selector(exportFixtures),
            keyEquivalent: ""
        )
        exportFixturesItem.target = self
        menu.addItem(exportFixturesItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit VoiceInputMimo", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func updateStatusIcon(recording: Bool) {
        guard let button = statusItem.button else { return }
        let name = recording ? "waveform.circle.fill" : "waveform.circle"
        button.image = NSImage(systemSymbolName: name, accessibilityDescription: "Voice Input MiMo")
        button.contentTintColor = recording ? .systemRed : nil
    }

    // MARK: - Actions

    @objc private func toggleEnabled() {
        isEnabled.toggle()
        enableMenuItem.state = isEnabled ? .on : .off
        if isEnabled {
            if !keyMonitor.start() { showAccessibilityAlert() }
        } else {
            keyMonitor.stop()
            if isRecording {
                audioRecorder.cancel()
                stopPhaseTimer()
                overlayPanel.dismiss()
                isRecording = false
                updateStatusIcon(recording: false)
            }
        }
    }

    @objc private func selectEnglishOutputMode() {
        let refiner = LLMRefiner.shared
        refiner.isEnabled = true
        refiner.claudeCodeModeEnabled = true  // setter clears structureModeEnabled
        refreshOutputModeMenu()
    }

    @objc private func selectChineseOutputMode() {
        let refiner = LLMRefiner.shared
        refiner.isEnabled = false
        refiner.claudeCodeModeEnabled = false
        refiner.structureModeEnabled = false
        refiner.contextAwareModeEnabled = false
        refreshOutputModeMenu()
    }

    @objc private func selectRefinedChineseOutputMode() {
        let refiner = LLMRefiner.shared
        refiner.isEnabled = true
        refiner.claudeCodeModeEnabled = false
        refiner.structureModeEnabled = false
        refiner.contextAwareModeEnabled = false
        refreshOutputModeMenu()
    }

    @objc private func selectStructureOutputMode() {
        let refiner = LLMRefiner.shared
        refiner.isEnabled = true
        refiner.structureModeEnabled = true  // setter clears claudeCodeModeEnabled + contextAwareModeEnabled
        refreshOutputModeMenu()
    }

    @objc private func selectContextAwareOutputMode() {
        let refiner = LLMRefiner.shared
        refiner.isEnabled = true
        refiner.contextAwareModeEnabled = true  // setter clears the explicit-mode flags
        refreshOutputModeMenu()
    }

    /// Output mode in the order used by the Ctrl+Option+arrow cycle hotkey.
    /// Matches the menu-bar reading order (top→bottom) so users build a
    /// consistent mental model: → moves "down the menu", ← moves "up".
    private enum OutputModeChoice: CaseIterable {
        case raw           // ASR-only, LLM disabled
        case refine        // ZH cleanup
        case claudeCode    // ZH→EN
        case structure     // ZH→template
        case contextAware  // Auto-dispatch per frontmost app

        static let cycleOrder: [OutputModeChoice] = [.raw, .refine, .claudeCode, .structure, .contextAware]
    }

    private func currentOutputModeChoice() -> OutputModeChoice {
        let refiner = LLMRefiner.shared
        if !refiner.isEnabled { return .raw }
        if refiner.contextAwareModeEnabled { return .contextAware }
        if refiner.structureModeEnabled { return .structure }
        if refiner.claudeCodeModeEnabled { return .claudeCode }
        return .refine
    }

    private func applyOutputModeChoice(_ choice: OutputModeChoice) {
        switch choice {
        case .raw: selectChineseOutputMode()
        case .refine: selectRefinedChineseOutputMode()
        case .claudeCode: selectEnglishOutputMode()
        case .structure: selectStructureOutputMode()
        case .contextAware: selectContextAwareOutputMode()
        }
    }

    private func cycleOutputMode(direction: Int) {
        let order = OutputModeChoice.cycleOrder
        let current = currentOutputModeChoice()
        let idx = order.firstIndex(of: current) ?? 0
        let nextIdx = ((idx + direction) % order.count + order.count) % order.count
        applyOutputModeChoice(order[nextIdx])
    }

    /// Bridged through `MainActor.assumeIsolated` because the Phase enum is
    /// constructed on the main thread (DispatchWorkItem on `.main`) but the
    /// surrounding AppDelegate isn't actor-isolated.
    private func activeProfileLabel(for mode: RefineMode) -> String? {
        MainActor.assumeIsolated {
            let vm = PromptStoreViewModel.shared
            guard let id = vm.activeProfileID(for: mode),
                  let profile = vm.profiles(for: mode).first(where: { $0.id == id }) else {
                return nil
            }
            return profile.name
        }
    }

    private func refreshOutputModeMenu() {
        let choice = currentOutputModeChoice()

        chineseOutputMenuItem.state = (choice == .raw) ? .on : .off
        refinedChineseOutputMenuItem.state = (choice == .refine) ? .on : .off
        englishOutputMenuItem.state = (choice == .claudeCode) ? .on : .off
        structureOutputMenuItem.state = (choice == .structure) ? .on : .off
        contextAwareOutputMenuItem.state = (choice == .contextAware) ? .on : .off

        switch choice {
        case .raw: outputModeMenuItem.title = "輸出模式：中文 ASR"
        case .refine: outputModeMenuItem.title = "輸出模式：中文修正"
        case .claudeCode: outputModeMenuItem.title = "輸出模式：英文翻譯"
        case .structure: outputModeMenuItem.title = "輸出模式：複合情境"
        case .contextAware: outputModeMenuItem.title = "輸出模式：自動辨識"
        }
    }

    /// Host the SwiftUI `OverlayContentSwiftUI` view inside an NSHostingView,
    /// add it to a borderless panel, render to PNG. Pure visual preview —
    /// no behaviour, no lifecycle, just snapshot-then-quit.
    private func renderSwiftUIOverlayDemo() {
        // Variant: short / long. Selected via VOICE_INPUT_MIMO_OVERLAY_VAR.
        // Direct env-var injection of CJK text via `open ... -e` corrupts the
        // UTF-8 byte stream (mojibake) — bake the demo strings here instead.
        let variant = ProcessInfo.processInfo.environment["VOICE_INPUT_MIMO_OVERLAY_VAR"] ?? "short"
        let zhText: String
        let enText: String
        switch variant {
        case "long":
            zhText = "然後幫我給到一個設計,是我希望我的中文 LLM 修正以及英文翻譯,這兩個都可以是我可以 customize"
            enText = "Then give me a design where I can customize the prompts for both my Chinese LLM refinement and English translation"
        case "asr":
            zhText = "再測試一下"
            enText = "再測試一下"
        default:
            zhText = "幫我把 useState 改成 useReducer"
            enText = "Refactor useState to useReducer"
        }
        let out = ProcessInfo.processInfo.environment["VOICE_INPUT_MIMO_OVERLAY_OUT"]
            ?? "/tmp/voice-input-mimo-overlay-swiftui.png"

        let host = NSHostingView(rootView:
            OverlayContentSwiftUI(zh: zhText, en: enText, translating: true)
                .frame(maxWidth: 640)
                .fixedSize(horizontal: true, vertical: true)
        )
        host.frame = NSRect(x: 0, y: 0, width: 640, height: 100)
        host.layoutSubtreeIfNeeded()
        let fitting = host.fittingSize
        host.frame = NSRect(origin: .zero, size: fitting)
        host.layoutSubtreeIfNeeded()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            let bounds = host.bounds
            guard let rep = host.bitmapImageRepForCachingDisplay(in: bounds) else { return }
            host.cacheDisplay(in: bounds, to: rep)
            guard let data = rep.representation(using: .png, properties: [:]) else { return }
            try? data.write(to: URL(fileURLWithPath: out))
            NSLog("[AppDelegate] SwiftUI overlay snapshot → %@ (%dx%d)", out, Int(fitting.width), Int(fitting.height))
        }
    }

    /// Render the overlay panel's contentView to a PNG at the given path.
    /// Used by OVERLAY_DEMO mode so a parent process without Screen Recording
    /// permission can still see what the overlay renders. Self-snapshot uses
    /// `cacheDisplay(in:to:)` which doesn't require any TCC permissions.
    private func snapshotOverlay(to path: String) {
        guard let cv = overlayPanel.contentView else { return }
        let bounds = cv.bounds
        guard let rep = cv.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        cv.cacheDisplay(in: bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        let url = URL(fileURLWithPath: path)
        do {
            try data.write(to: url)
            NSLog("[AppDelegate] overlay snapshot saved to %@ (%dx%d)", path, Int(bounds.width), Int(bounds.height))
        } catch {
            NSLog("[AppDelegate] overlay snapshot write failed: %@", error.localizedDescription)
        }
    }

    @objc private func openSettings() {
        settingsWindow.makeKeyAndOrderFront(nil)
        if ProcessInfo.processInfo.environment["VOICE_INPUT_MIMO_PREVIEW"] == "1" {
            settingsWindow.orderFrontRegardless()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openClipboardHistory() {
        clipboardHistoryWindow.makeKeyAndOrderFront(nil)
        if ProcessInfo.processInfo.environment["VOICE_INPUT_MIMO_PREVIEW"] == "1" {
            clipboardHistoryWindow.orderFrontRegardless()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openModelMemory() {
        modelMemoryWindow.showAndStart()
    }

    /// Menu action — manual export. Always interactive (silent=false): shows
    /// alert on completion, and prompts for destination if none remembered.
    @objc private func exportFixtures() {
        runFixtureExport(silent: false)
    }

    /// UserDefaults key for the remembered fixture export destination.
    /// `silent=true` mode skips entirely when this key is absent.
    private static let fixtureDestinationKey = "fixtureExportDestination"

    /// Core fixture export flow used by both the menu action and launch
    /// auto-sync.
    ///
    /// - `silent=false`: interactive — prompts for destination if missing,
    ///   shows completion / failure alert.
    /// - `silent=true`: launch auto-sync — no UI; skip if no destination
    ///   remembered; log result via NSLog.
    private func runFixtureExport(silent: Bool) {
        let savedPath = UserDefaults.standard.string(forKey: Self.fixtureDestinationKey)
        let destinationURL: URL

        if let savedPath, FileManager.default.fileExists(atPath: savedPath) {
            destinationURL = URL(fileURLWithPath: savedPath)
        } else {
            guard !silent else {
                NSLog("[AppDelegate] Fixture auto-sync skipped: no destination configured")
                return
            }
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.prompt = "選擇匯出目錄"
            panel.message = "選擇要存放錄音檔與文字稿的目錄(每筆 trace 會輸出 audio/*.wav + transcripts/*.txt 一組;之後 App 啟動時會自動同步到此目錄)"
            guard panel.runModal() == .OK, let dest = panel.url else { return }
            UserDefaults.standard.set(dest.path, forKey: Self.fixtureDestinationKey)
            destinationURL = dest
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let results = try FixtureExporter.exportAll(destination: destinationURL)
                let exported = results.filter { $0.skippedReason == nil }.count
                let skipped = results.count - exported
                if silent {
                    NSLog(
                        "[AppDelegate] Fixture auto-sync: %d exported, %d skipped → %@",
                        exported,
                        skipped,
                        destinationURL.path
                    )
                } else {
                    DispatchQueue.main.async { [weak self] in
                        self?.showAlert(
                            title: "匯出完成",
                            message: "已匯出 \(exported) 筆,略過 \(skipped) 筆\n目的地:\(destinationURL.path)\n\n(App 啟動時會自動同步到此目錄,已校對的 transcript 不會被覆寫)"
                        )
                    }
                }
            } catch {
                if silent {
                    NSLog("[AppDelegate] Fixture auto-sync failed: %@", error.localizedDescription)
                } else {
                    DispatchQueue.main.async { [weak self] in
                        self?.showAlert(title: "匯出失敗", message: error.localizedDescription)
                    }
                }
            }
            _ = self // silence weak-self unused warning when silent
        }
    }

    // MARK: - ASR server controls

    @objc private func toggleASRServer() {
        let server = LocalASRServer.shared
        switch server.state {
        case .running:
            server.stop()
            refreshASRServerMenu()
        case .starting:
            // No-op; user double-clicked while spinning up.
            break
        case .stopped, .failed:
            asrServerMenuItem.isEnabled = false
            asrServerStatusMenuItem.title = "Status: starting…"
            server.start { [weak self] result in
                DispatchQueue.main.async {
                    self?.refreshASRServerMenu()
                    if case .failure(let error) = result {
                        self?.showAlert(title: "ASR Server Failed to Start",
                                        message: error.localizedDescription)
                    }
                }
            }
        }
    }

    @objc private func showASRLog() {
        let url = LocalASRServer.shared.logURL
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: Data())
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func revealASRScript() {
        let path = LocalASRServer.Configuration.current().serverDir
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            showAlert(title: "Server Directory Not Found",
                      message: "Expected at:\n\(path)\n\nAdjust via Settings… → ASR Server.")
        }
    }

    private func refreshASRServerMenu() {
        let state = LocalASRServer.shared.state
        let port = LocalASRServer.Configuration.current().port
        switch state {
        case .running:
            asrServerStatusMenuItem.title = "Status: running on :\(port)"
            asrServerMenuItem.title = "Stop Local ASR Server"
            asrServerMenuItem.isEnabled = true
        case .starting:
            asrServerStatusMenuItem.title = "Status: starting…"
            asrServerMenuItem.title = "Starting…"
            asrServerMenuItem.isEnabled = false
        case .stopped:
            asrServerStatusMenuItem.title = "Status: stopped"
            asrServerMenuItem.title = "Start Local ASR Server"
            asrServerMenuItem.isEnabled = true
        case .failed(let msg):
            let oneLine = msg.replacingOccurrences(of: "\n", with: " ")
            asrServerStatusMenuItem.title = "Status: failed — \(oneLine.prefix(60))"
            asrServerMenuItem.title = "Retry Start"
            asrServerMenuItem.isEnabled = true
        }
    }

    @objc private func quit() {
        keyMonitor.stop()
        NSApp.terminate(nil)
    }

    // MARK: - Alerts

    private func showAccessibilityAlert() {
        let alert = NSAlert()
        alert.messageText = "Accessibility Permission Required"
        alert.informativeText = """
            VoiceInputMimo needs Accessibility permission to monitor the Fn key.

            1. Open System Settings → Privacy & Security → Accessibility
            2. Add and enable VoiceInputMimo
            3. Restart the app
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Quit")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            )
        }
        NSApp.terminate(nil)
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

