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
    private var llmMenuItem: NSMenuItem!
    private var claudeCodeMenuItem: NSMenuItem!
    private lazy var settingsWindow = SettingsWindow()
    private lazy var clipboardHistoryWindow = ClipboardHistoryWindow()

    // Phase progress timer (drives the elapsed-time counter shown in the overlay)
    private var phaseTimer: Timer?
    private var phaseStart: Date?
    private var phasePrefix: String = ""

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        terminateConflictingApps()
        setupStatusBar()
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
        ASRClient.shared.health { result in
            if case .failure(let error) = result {
                NSLog("[AppDelegate] ASR server probe failed: %@", error.localizedDescription)
            }
        }
    }

    // MARK: - Key events

    private func fnDown() {
        guard isEnabled, !isRecording else { return }
        LLMRefiner.shared.cancel()
        ASRClient.shared.cancel()
        isRecording = true

        updateStatusIcon(recording: true)
        overlayPanel.show(text: "🎙 Recording 0.0s")
        startPhaseTimer(prefix: "🎙 Recording")
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
            overlayPanel.updateText("⚠️ No audio")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.overlayPanel.dismiss()
            }
            return
        }

        // Stage 1: ASR (MiMo via :8765)
        overlayPanel.updateText("📝 Transcribing 0.0s")
        startPhaseTimer(prefix: "📝 Transcribing")
        ASRClient.shared.transcribe(wavURL: wavURL) { [weak self] result in
            guard let self else { return }
            self.stopPhaseTimer()
            switch result {
            case .success(let text):
                self.handleTranscription(text)
            case .failure(let error):
                NSLog("[AppDelegate] ASR failed: %@", error.localizedDescription)
                self.overlayPanel.updateText("❌ ASR: \(error.localizedDescription)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    self.overlayPanel.dismiss()
                }
            }
        }
    }

    private func handleTranscription(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            overlayPanel.updateText("⚠️ No speech detected")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.overlayPanel.dismiss()
            }
            return
        }

        // Show the raw transcription so user can see what MiMo heard
        overlayPanel.updateText("💬 \(trimmed)")

        let refiner = LLMRefiner.shared
        if refiner.isEnabled && refiner.isConfigured {
            // Stage 2: LLM cleanup / translate
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self else { return }
                self.overlayPanel.updateText("✨ Refining 0.0s")
                self.startPhaseTimer(prefix: "✨ Refining")
            }
            refiner.refine(trimmed) { [weak self] result in
                guard let self else { return }
                self.stopPhaseTimer()
                switch result {
                case .success(let refined):
                    let final = refined.isEmpty ? trimmed : refined
                    self.injectAndDismiss(final)
                case .failure(let error):
                    NSLog("[AppDelegate] LLM failed: %@", error.localizedDescription)
                    self.overlayPanel.updateText("❌ LLM: \(error.localizedDescription)")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        self.injectAndDismiss(trimmed)
                    }
                }
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.injectAndDismiss(trimmed)
            }
        }
    }

    private func injectAndDismiss(_ text: String) {
        overlayPanel.updateText("✨ \(text)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.overlayPanel.dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self?.textInjector.inject(text)
                NSSound(named: .init("Pop"))?.play()
            }
        }
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

    private func startPhaseTimer(prefix: String) {
        stopPhaseTimer()
        phasePrefix = prefix
        phaseStart = Date()
        // Update every 100ms (smooth feel)
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, let start = self.phaseStart else { return }
            let elapsed = Date().timeIntervalSince(start)
            self.overlayPanel.updateText(String(format: "%@ %.1fs", self.phasePrefix, elapsed))
        }
        RunLoop.main.add(t, forMode: .common)
        phaseTimer = t
    }

    private func stopPhaseTimer() {
        phaseTimer?.invalidate()
        phaseTimer = nil
        phaseStart = nil
    }

    // MARK: - Audio callbacks

    private func setupAudioCallbacks() {
        audioRecorder.onAudioLevel = { [weak self] level in
            self?.overlayPanel.updateAudioLevel(level)
        }
        audioRecorder.onError = { [weak self] msg in
            self?.stopPhaseTimer()
            self?.overlayPanel.updateText("❌ Audio: \(msg)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self?.overlayPanel.dismiss()
            }
        }
    }

    // MARK: - Status bar

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusIcon(recording: false)

        let menu = NSMenu()

        enableMenuItem = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
        enableMenuItem.target = self
        enableMenuItem.state = .on
        menu.addItem(enableMenuItem)

        menu.addItem(.separator())

        // Claude Code Mode toggle
        claudeCodeMenuItem = NSMenuItem(
            title: "Claude Code Mode (中譯英 + 繁中 suffix)",
            action: #selector(toggleClaudeCodeMode),
            keyEquivalent: "v"
        )
        claudeCodeMenuItem.keyEquivalentModifierMask = [.command, .option]
        claudeCodeMenuItem.target = self
        claudeCodeMenuItem.state = LLMRefiner.shared.claudeCodeModeEnabled ? .on : .off
        menu.addItem(claudeCodeMenuItem)

        menu.addItem(.separator())

        // LLM Refinement submenu
        let llmItem = NSMenuItem(title: "LLM Refinement", action: nil, keyEquivalent: "")
        let llmMenu = NSMenu()

        llmMenuItem = NSMenuItem(title: "Enabled", action: #selector(toggleLLM), keyEquivalent: "")
        llmMenuItem.target = self
        llmMenuItem.state = LLMRefiner.shared.isEnabled ? .on : .off
        llmMenu.addItem(llmMenuItem)

        llmMenu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: "")
        settingsItem.target = self
        llmMenu.addItem(settingsItem)

        llmItem.submenu = llmMenu
        menu.addItem(llmItem)

        // Clipboard History viewer
        let historyItem = NSMenuItem(
            title: "Clipboard History...",
            action: #selector(openClipboardHistory),
            keyEquivalent: "h"
        )
        historyItem.keyEquivalentModifierMask = [.command, .option]
        historyItem.target = self
        menu.addItem(historyItem)

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

    @objc private func toggleLLM() {
        let refiner = LLMRefiner.shared
        refiner.isEnabled.toggle()
        llmMenuItem.state = refiner.isEnabled ? .on : .off
    }

    @objc private func toggleClaudeCodeMode() {
        let refiner = LLMRefiner.shared
        refiner.claudeCodeModeEnabled.toggle()
        claudeCodeMenuItem.state = refiner.claudeCodeModeEnabled ? .on : .off
        if refiner.claudeCodeModeEnabled && !refiner.isEnabled {
            refiner.isEnabled = true
            llmMenuItem.state = .on
        }
    }

    @objc private func openSettings() {
        settingsWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openClipboardHistory() {
        clipboardHistoryWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
