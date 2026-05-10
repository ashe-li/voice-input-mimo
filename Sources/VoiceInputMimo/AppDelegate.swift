import AppKit
import AVFoundation
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let keyMonitor = KeyMonitor()
    private let audioRecorder = AudioRecorder()
    private let textInjector = TextInjector()
    private lazy var overlayPanel = OverlayPanel()

    private var isEnabled = true
    private var isRecording = false

    private var enableMenuItem: NSMenuItem!
    private var outputModeMenuItem: NSMenuItem!
    private var englishOutputMenuItem: NSMenuItem!
    private var chineseOutputMenuItem: NSMenuItem!
    private var refinedChineseOutputMenuItem: NSMenuItem!
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

    // Cancellable "show .refining after holding ZH for 0.4 s" deferred work.
    // If the LLM completes within 0.4 s we cancel this so the overlay isn't
    // resurrected back to .refining after .bothReady.
    private var refiningHoldWork: DispatchWorkItem?

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

        updateStatusIcon(recording: true)
        overlayPanel.transition(to: .recording(elapsed: 0))
        startPhaseTimer { .recording(elapsed: $0) }
        NSSound(named: .init("Tink"))?.play()

        audioRecorder.startRecording()
    }

    private func fnUp() {
        guard isRecording else { return }
        isRecording = false
        updateStatusIcon(recording: false)
        stopPhaseTimer()

        let wavURL = audioRecorder.stopRecording()
        guard let wavURL else {
            overlayPanel.transition(to: .error("No audio captured"))
            return
        }

        // Stage 1: ASR (MiMo via :8765)
        overlayPanel.transition(to: .transcribing(elapsed: 0))
        startPhaseTimer { .transcribing(elapsed: $0) }
        ASRClient.shared.transcribe(wavURL: wavURL) { [weak self] result in
            guard let self else { return }
            self.stopPhaseTimer()
            switch result {
            case .success(let asrResult):
                self.handleTranscription(asrResult.text, requestId: asrResult.requestId)
            case .failure(let error):
                NSLog("[AppDelegate] ASR failed: %@", error.localizedDescription)
                self.overlayPanel.transition(to: .error("ASR: \(error.localizedDescription)"))
            }
        }
    }

    private func handleTranscription(_ text: String, requestId: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            overlayPanel.transition(to: .error("No speech detected"))
            return
        }
        currentZH = trimmed

        let refiner = LLMRefiner.shared
        if refiner.isEnabled && refiner.isConfigured {
            // ZH-ready preview only when LLM stage is going to follow; ASR-only
            // path skips this so we don't show "Chinese ready" then immediately
            // "Ready" 0.6 s later.
            overlayPanel.transition(to: .zhReady(zh: trimmed))
            // Stage 2: LLM cleanup / translate. Hold ZH for ~0.4 s so user sees
            // it clearly before the refining indicator appears — but only if
            // the LLM is actually slower than 0.4 s. Cancel the deferred work
            // when the result arrives early, otherwise we'd resurrect the
            // overlay back into .refining and start a phase timer that nobody
            // stops (orphan tick → "Refining 42.7s" stuck).
            refiningHoldWork?.cancel()
            let translating = refiner.claudeCodeModeEnabled
            let activeMode: RefineMode = translating ? .claudeCode : .refine
            let profileLabel = activeProfileLabel(for: activeMode)
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.overlayPanel.transition(
                    to: .refining(
                        zh: self.currentZH,
                        elapsed: 0,
                        translating: translating,
                        profileLabel: profileLabel
                    )
                )
                self.startPhaseTimer { [weak self] elapsed in
                    .refining(
                        zh: self?.currentZH ?? "",
                        elapsed: elapsed,
                        translating: translating,
                        profileLabel: profileLabel
                    )
                }
            }
            refiningHoldWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)

            refiner.refine(trimmed, requestId: requestId) { [weak self] result in
                guard let self else { return }
                self.refiningHoldWork?.cancel()
                self.refiningHoldWork = nil
                self.stopPhaseTimer()
                switch result {
                case .success(let refined):
                    let final = refined.isEmpty ? trimmed : refined
                    self.completeWithEnglish(final)
                case .failure(let error):
                    NSLog("[AppDelegate] LLM failed: %@", error.localizedDescription)
                    self.overlayPanel.transition(to: .error("LLM: \(error.localizedDescription)"))
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
        let translating = LLMRefiner.shared.claudeCodeModeEnabled
        overlayPanel.transition(to: .bothReady(zh: currentZH, en: english, translating: translating))
        ClipboardArchive.shared.saveSession(zh: currentZH, english: english)
        injectImmediately(english)
    }

    /// ASR-only path: still show the final state with the same text in both rows
    /// for a consistent visual; reuse zhReady (no EN row) for clarity.
    private func completeWithoutTranslation(_ text: String) {
        // Promote to bothReady with EN duplicated, so the linger countdown engages.
        // translating=false: ASR-only path, overlay renders single line (no
        // duplicate ZH/EN rows).
        overlayPanel.transition(to: .bothReady(zh: text, en: text, translating: false))
        ClipboardArchive.shared.saveSession(zh: text, english: text)
        injectImmediately(text)
    }

    private func injectImmediately(_ text: String) {
        textInjector.inject(text)
        NSSound(named: .init("Pop"))?.play()
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
        refiner.claudeCodeModeEnabled = true
        refreshOutputModeMenu()
    }

    @objc private func selectChineseOutputMode() {
        let refiner = LLMRefiner.shared
        refiner.isEnabled = false
        refiner.claudeCodeModeEnabled = false
        refreshOutputModeMenu()
    }

    @objc private func selectRefinedChineseOutputMode() {
        let refiner = LLMRefiner.shared
        refiner.isEnabled = true
        refiner.claudeCodeModeEnabled = false
        refreshOutputModeMenu()
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
        let refiner = LLMRefiner.shared
        let isEnglish = refiner.isEnabled && refiner.claudeCodeModeEnabled
        let isRefinedChinese = refiner.isEnabled && !refiner.claudeCodeModeEnabled
        let isChinese = !refiner.isEnabled

        englishOutputMenuItem.state = isEnglish ? .on : .off
        chineseOutputMenuItem.state = isChinese ? .on : .off
        refinedChineseOutputMenuItem.state = isRefinedChinese ? .on : .off

        if isEnglish {
            outputModeMenuItem.title = "輸出模式：英文翻譯"
        } else if isRefinedChinese {
            outputModeMenuItem.title = "輸出模式：中文修正"
        } else {
            outputModeMenuItem.title = "輸出模式：中文 ASR"
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

