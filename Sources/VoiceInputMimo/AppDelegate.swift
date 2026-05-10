import AppKit
import AVFoundation

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
    private var activeProfileMenuItem: NSMenuItem!
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
        overlayPanel.transition(to: .bothReady(zh: currentZH, en: english))
        ClipboardArchive.shared.saveSession(zh: currentZH, english: english)
        injectImmediately(english)
    }

    /// ASR-only path: still show the final state with the same text in both rows
    /// for a consistent visual; reuse zhReady (no EN row) for clarity.
    private func completeWithoutTranslation(_ text: String) {
        // Promote to bothReady with EN duplicated, so the linger countdown engages.
        overlayPanel.transition(to: .bothReady(zh: text, en: text))
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

        englishOutputMenuItem = NSMenuItem(
            title: "英文 Prompt（附回覆語言要求）",
            action: #selector(selectEnglishOutputMode),
            keyEquivalent: "v"
        )
        englishOutputMenuItem.keyEquivalentModifierMask = [.command, .option]
        englishOutputMenuItem.target = self
        outputMenu.addItem(englishOutputMenuItem)

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

        // Active Profile menu sits at top level, peer to "輸出模式". A second
        // submenu nested *inside* "輸出模式" caused a 3-level deep hover chain
        // that macOS handles unreliably (auto-open delays, sibling close
        // races). Hoisting it makes mode-switch and profile-switch responsive.
        activeProfileMenuItem = NSMenuItem(title: "啟用 Profile", action: nil, keyEquivalent: "")
        activeProfileMenuItem.submenu = NSMenu()
        menu.addItem(activeProfileMenuItem)

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
            outputModeMenuItem.title = "輸出模式：英文 Prompt"
        } else if isRefinedChinese {
            outputModeMenuItem.title = "輸出模式：中文修正"
        } else {
            outputModeMenuItem.title = "輸出模式：中文 ASR"
        }
        refreshActiveProfileMenu()
    }

    private func refreshActiveProfileMenu() {
        guard let menu = activeProfileMenuItem?.submenu else { return }
        menu.removeAllItems()
        MainActor.assumeIsolated {
            let vm = PromptStoreViewModel.shared
            appendSection(into: menu, title: "Refine（中文修正）", mode: .refine, vm: vm)
            menu.addItem(.separator())
            appendSection(into: menu, title: "Claude Code（英文 Prompt）", mode: .claudeCode, vm: vm)
            menu.addItem(.separator())
            let editItem = NSMenuItem(title: "編輯 Profiles…", action: #selector(openSettings), keyEquivalent: "")
            editItem.target = self
            menu.addItem(editItem)
        }

        // Update the parent menu item's title with the active labels.
        let refineActive = activeProfileLabel(for: .refine) ?? "—"
        let claudeActive = activeProfileLabel(for: .claudeCode) ?? "—"
        activeProfileMenuItem.title = "啟用 Profile：\(refineActive) / \(claudeActive)"
    }

    @MainActor
    private func appendSection(
        into menu: NSMenu,
        title: String,
        mode: RefineMode,
        vm: PromptStoreViewModel
    ) {
        let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let profiles = vm.profiles(for: mode)
        if profiles.isEmpty {
            let empty = NSMenuItem(title: "  （無 profile — 啟動仍在 bootstrap）", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        let activeID = vm.activeProfileID(for: mode)
        for profile in profiles {
            let item = NSMenuItem(
                title: "  \(profile.name)",
                action: #selector(selectProfileFromMenu(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.state = (profile.id == activeID) ? .on : .off
            // Carry the (mode, profileID) tuple in a representedObject so the
            // action can route without needing one selector per (mode, id).
            item.representedObject = ProfileSelection(mode: mode, profileID: profile.id)
            menu.addItem(item)
        }
    }

    @objc private func selectProfileFromMenu(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? ProfileSelection else { return }
        MainActor.assumeIsolated {
            PromptStoreViewModel.shared.setActiveProfile(id: selection.profileID, mode: selection.mode)
        }
        refreshActiveProfileMenu()
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

/// Routed via NSMenuItem.representedObject so a single selector handles
/// every (mode, profile) click.
private struct ProfileSelection {
    let mode: RefineMode
    let profileID: String
}
