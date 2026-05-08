import AppKit

final class SettingsWindow: NSPanel {
    // ASR section
    private let asrBaseField = NSTextField()
    private let asrLanguagePopup = NSPopUpButton()
    private let asrLocalePopup = NSPopUpButton()
    private let asrProbeLabel = NSTextField(labelWithString: "")

    // ASR Server (local supervisor) section
    private let serverDirField = NSTextField()
    private let serverPythonField = NSTextField()
    private let serverPortField = NSTextField()
    private let serverPrecisionPopup = NSPopUpButton()
    private let serverModelRootField = NSTextField()
    private let serverPreloadCheckbox = NSButton(
        checkboxWithTitle: "Preload model on startup (avoids 1 s+ cold-start tax)",
        target: nil, action: nil)
    private let serverStatusLabel = NSTextField(labelWithString: "")

    // LLM section
    private let llmEnabledCheckbox = NSButton(checkboxWithTitle: "Enable LLM (uncheck = ASR only, fastest)", target: nil, action: nil)
    private let translateCheckbox = NSButton(checkboxWithTitle: "Translate to English (Claude Code mode)", target: nil, action: nil)
    private let llmBaseField = NSTextField()
    private let llmKeyField = NSTextField()
    private let llmModelField = NSTextField()
    private let suffixField = NSTextView()
    private let suffixScroll = NSScrollView()
    private let llmProbeLabel = NSTextField(labelWithString: "")

    private let statusLabel = NSTextField(labelWithString: "")

    // Auto-poll timer — refreshes ASR + LLM probe labels every 5s while window is key,
    // so user sees live state without clicking Probe (loaded ↔ idle transitions, etc.).
    private var probeTimer: Timer?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 880),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        title = "VoiceInputMimo Settings"
        isReleasedWhenClosed = false
        titlebarAppearsTransparent = true
        titleVisibility = .visible
        toolbarStyle = .unified

        // Translucent vibrant background (modern macOS look — Sonoma/Sequoia style)
        if let cv = contentView {
            cv.wantsLayer = true
            let visualEffect = NSVisualEffectView(frame: cv.bounds)
            visualEffect.autoresizingMask = [.width, .height]
            visualEffect.material = .windowBackground
            visualEffect.blendingMode = .behindWindow
            visualEffect.state = .active
            cv.addSubview(visualEffect, positioned: .below, relativeTo: nil)
        }

        setupUI()
        loadSettings()
        center()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.probeASR()
        }
    }

    private func sectionLabel(_ s: String, icon: String? = nil) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .firstBaseline

        if let icon, let image = NSImage(systemSymbolName: icon, accessibilityDescription: nil) {
            let iv = NSImageView(image: image)
            iv.contentTintColor = .controlAccentColor
            iv.symbolConfiguration = .init(pointSize: 14, weight: .semibold)
            stack.addArrangedSubview(iv)
        }

        let lab = NSTextField(labelWithString: s)
        lab.font = .systemFont(ofSize: 14, weight: .semibold)
        lab.textColor = .labelColor
        stack.addArrangedSubview(lab)
        return stack
    }

    private func rightLabel(_ s: String) -> NSTextField {
        let lab = NSTextField(labelWithString: s)
        lab.alignment = .right
        lab.textColor = .secondaryLabelColor
        lab.font = .systemFont(ofSize: 12)
        return lab
    }

    private func setupUI() {
        guard let cv = contentView else { return }

        // ASR section
        asrBaseField.placeholderString = "http://127.0.0.1:8765"
        asrLanguagePopup.addItems(withTitles: ["auto", "zh", "en"])
        asrLocalePopup.addItems(withTitles: ["zh-TW", "none"])

        let asrHeader = sectionLabel("ASR — MiMo-V2.5-ASR", icon: "waveform")
        let asrGrid = NSGridView(views: [
            [rightLabel("Base URL:"), asrBaseField],
            [rightLabel("Language:"), asrLanguagePopup],
            [rightLabel("Output locale:"), asrLocalePopup],
        ])
        asrGrid.column(at: 0).xPlacement = .trailing
        asrGrid.rowSpacing = 10
        asrGrid.columnSpacing = 8
        asrGrid.translatesAutoresizingMaskIntoConstraints = false

        asrProbeLabel.translatesAutoresizingMaskIntoConstraints = false
        asrProbeLabel.font = .systemFont(ofSize: 11)
        asrProbeLabel.textColor = .secondaryLabelColor

        let asrProbeButton = NSButton(title: "Probe ASR", target: self, action: #selector(probeASR))
        asrProbeButton.bezelStyle = .rounded
        asrProbeButton.controlSize = .regular
        if #available(macOS 14, *) { asrProbeButton.bezelColor = .controlAccentColor }

        // LLM section
        llmBaseField.placeholderString = "http://localhost:1234/v1"
        llmKeyField.placeholderString = "lm-studio"
        llmModelField.placeholderString = "google/gemma-3-4b"

        suffixField.isEditable = true
        suffixField.isRichText = false
        suffixField.font = .systemFont(ofSize: 12)
        suffixField.textContainerInset = NSSize(width: 4, height: 4)
        suffixScroll.documentView = suffixField
        suffixScroll.hasVerticalScroller = true
        suffixScroll.borderType = .lineBorder
        suffixScroll.translatesAutoresizingMaskIntoConstraints = false

        let llmHeader = sectionLabel("LLM — LM Studio", icon: "brain.head.profile")

        llmEnabledCheckbox.translatesAutoresizingMaskIntoConstraints = false
        translateCheckbox.translatesAutoresizingMaskIntoConstraints = false
        let togglesStack = NSStackView(views: [llmEnabledCheckbox, translateCheckbox])
        togglesStack.orientation = .vertical
        togglesStack.alignment = .leading
        togglesStack.spacing = 4
        togglesStack.translatesAutoresizingMaskIntoConstraints = false

        let llmGrid = NSGridView(views: [
            [rightLabel("Mode:"), togglesStack],
            [rightLabel("Base URL:"), llmBaseField],
            [rightLabel("API Key:"), llmKeyField],
            [rightLabel("Model:"), llmModelField],
            [rightLabel("Claude Code Suffix:"), suffixScroll],
        ])
        llmGrid.column(at: 0).xPlacement = .trailing
        llmGrid.row(at: 4).yPlacement = .top  // Suffix is now row 4 (Mode toggles inserted at 0)
        llmGrid.rowSpacing = 10
        llmGrid.columnSpacing = 8
        llmGrid.translatesAutoresizingMaskIntoConstraints = false

        llmProbeLabel.translatesAutoresizingMaskIntoConstraints = false
        llmProbeLabel.font = .systemFont(ofSize: 11)
        llmProbeLabel.textColor = .secondaryLabelColor

        let llmProbeButton = NSButton(title: "Probe LLM", target: self, action: #selector(probeLLM))
        llmProbeButton.bezelStyle = .rounded

        let resetSuffixButton = NSButton(title: "Reset Suffix", target: self,
                                          action: #selector(resetSuffix))
        resetSuffixButton.bezelStyle = .rounded

        let testButton = NSButton(title: "Test (sample text)", target: self, action: #selector(test))
        testButton.bezelStyle = .rounded

        let saveButton = NSButton(title: "Save", target: self, action: #selector(save))
        saveButton.keyEquivalent = "\r"
        saveButton.bezelStyle = .rounded
        saveButton.controlSize = .regular
        if #available(macOS 14, *) {
            saveButton.bezelColor = .controlAccentColor
        }

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        let asrButtonRow = NSStackView(views: [asrProbeLabel, asrProbeButton])
        asrButtonRow.orientation = .horizontal
        asrButtonRow.spacing = 8
        asrButtonRow.translatesAutoresizingMaskIntoConstraints = false

        // Server (local ASR supervisor) section
        let serverHeader = sectionLabel("ASR Server (local process)", icon: "server.rack")

        serverDirField.placeholderString = "~/Documents/voice-input-mimo/server"
        serverPythonField.placeholderString = "<server>/.venv/bin/python"
        serverPortField.placeholderString = "8765"
        serverPrecisionPopup.addItems(withTitles: ["int4", "bf16"])
        serverModelRootField.placeholderString = "~/.cache/mimo-asr"

        let dirBrowse = NSButton(title: "Browse…", target: self, action: #selector(browseServerDir))
        dirBrowse.bezelStyle = .rounded
        let pythonBrowse = NSButton(title: "Browse…", target: self, action: #selector(browsePython))
        pythonBrowse.bezelStyle = .rounded
        let modelRootBrowse = NSButton(title: "Browse…", target: self, action: #selector(browseModelRoot))
        modelRootBrowse.bezelStyle = .rounded

        let dirRow = NSStackView(views: [serverDirField, dirBrowse])
        dirRow.orientation = .horizontal; dirRow.spacing = 6
        let pythonRow = NSStackView(views: [serverPythonField, pythonBrowse])
        pythonRow.orientation = .horizontal; pythonRow.spacing = 6
        let modelRootRow = NSStackView(views: [serverModelRootField, modelRootBrowse])
        modelRootRow.orientation = .horizontal; modelRootRow.spacing = 6

        serverPreloadCheckbox.translatesAutoresizingMaskIntoConstraints = false

        let serverGrid = NSGridView(views: [
            [rightLabel("Server dir:"), dirRow],
            [rightLabel("Python:"), pythonRow],
            [rightLabel("Port:"), serverPortField],
            [rightLabel("Precision:"), serverPrecisionPopup],
            [rightLabel("Model root:"), modelRootRow],
            [rightLabel("Mode:"), serverPreloadCheckbox],
        ])
        serverGrid.column(at: 0).xPlacement = .trailing
        serverGrid.rowSpacing = 10
        serverGrid.columnSpacing = 8
        serverGrid.translatesAutoresizingMaskIntoConstraints = false

        let applyRestartButton = NSButton(
            title: "Apply & Restart Server",
            target: self,
            action: #selector(applyAndRestartServer))
        applyRestartButton.bezelStyle = .rounded
        if #available(macOS 14, *) { applyRestartButton.bezelColor = .controlAccentColor }

        serverStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        serverStatusLabel.font = .systemFont(ofSize: 11)
        serverStatusLabel.textColor = .secondaryLabelColor

        let serverButtonRow = NSStackView(views: [serverStatusLabel, applyRestartButton])
        serverButtonRow.orientation = .horizontal
        serverButtonRow.spacing = 8
        serverButtonRow.translatesAutoresizingMaskIntoConstraints = false

        let llmButtonRow = NSStackView(views: [llmProbeLabel, llmProbeButton, resetSuffixButton])
        llmButtonRow.orientation = .horizontal
        llmButtonRow.spacing = 8
        llmButtonRow.translatesAutoresizingMaskIntoConstraints = false

        let bottomRow = NSStackView(views: [statusLabel, testButton, saveButton])
        bottomRow.orientation = .horizontal
        bottomRow.spacing = 8
        bottomRow.translatesAutoresizingMaskIntoConstraints = false

        let sep1 = NSBox(); sep1.boxType = .separator; sep1.translatesAutoresizingMaskIntoConstraints = false
        let sep2 = NSBox(); sep2.boxType = .separator; sep2.translatesAutoresizingMaskIntoConstraints = false

        for sub in [asrHeader, asrGrid, asrButtonRow,
                    sep1, serverHeader, serverGrid, serverButtonRow,
                    sep2, llmHeader, llmGrid, llmButtonRow, bottomRow] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            cv.addSubview(sub)
        }

        NSLayoutConstraint.activate([
            // 46 = 28 (titlebar height under .fullSizeContentView) + 18 (visual padding).
            asrHeader.topAnchor.constraint(equalTo: cv.topAnchor, constant: 46),
            asrHeader.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 20),

            asrGrid.topAnchor.constraint(equalTo: asrHeader.bottomAnchor, constant: 10),
            asrGrid.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 20),
            asrGrid.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -20),

            asrBaseField.widthAnchor.constraint(greaterThanOrEqualToConstant: 380),

            asrButtonRow.topAnchor.constraint(equalTo: asrGrid.bottomAnchor, constant: 10),
            asrButtonRow.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 20),
            asrButtonRow.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -20),

            sep1.topAnchor.constraint(equalTo: asrButtonRow.bottomAnchor, constant: 18),
            sep1.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 20),
            sep1.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -20),
            sep1.heightAnchor.constraint(equalToConstant: 1),

            serverHeader.topAnchor.constraint(equalTo: sep1.bottomAnchor, constant: 14),
            serverHeader.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 20),

            serverGrid.topAnchor.constraint(equalTo: serverHeader.bottomAnchor, constant: 10),
            serverGrid.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 20),
            serverGrid.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -20),
            serverDirField.widthAnchor.constraint(greaterThanOrEqualToConstant: 320),
            serverPythonField.widthAnchor.constraint(greaterThanOrEqualToConstant: 320),
            serverModelRootField.widthAnchor.constraint(greaterThanOrEqualToConstant: 320),
            serverPortField.widthAnchor.constraint(equalToConstant: 90),

            serverButtonRow.topAnchor.constraint(equalTo: serverGrid.bottomAnchor, constant: 10),
            serverButtonRow.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 20),
            serverButtonRow.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -20),

            sep2.topAnchor.constraint(equalTo: serverButtonRow.bottomAnchor, constant: 18),
            sep2.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 20),
            sep2.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -20),
            sep2.heightAnchor.constraint(equalToConstant: 1),

            llmHeader.topAnchor.constraint(equalTo: sep2.bottomAnchor, constant: 14),
            llmHeader.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 20),

            llmGrid.topAnchor.constraint(equalTo: llmHeader.bottomAnchor, constant: 10),
            llmGrid.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 20),
            llmGrid.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -20),

            llmBaseField.widthAnchor.constraint(greaterThanOrEqualToConstant: 380),
            llmKeyField.widthAnchor.constraint(greaterThanOrEqualToConstant: 380),
            llmModelField.widthAnchor.constraint(greaterThanOrEqualToConstant: 380),
            suffixScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 380),
            suffixScroll.heightAnchor.constraint(equalToConstant: 100),

            llmButtonRow.topAnchor.constraint(equalTo: llmGrid.bottomAnchor, constant: 10),
            llmButtonRow.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 20),
            llmButtonRow.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -20),

            bottomRow.topAnchor.constraint(greaterThanOrEqualTo: llmButtonRow.bottomAnchor, constant: 16),
            bottomRow.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -20),
            bottomRow.leadingAnchor.constraint(greaterThanOrEqualTo: cv.leadingAnchor, constant: 20),
            bottomRow.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -20),
        ])

        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Auto-poll lifecycle — run quick probe every 5s while window is key, stop when closing.
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleBecomeKey),
            name: NSWindow.didBecomeKeyNotification, object: self
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleWillClose),
            name: NSWindow.willCloseNotification, object: self
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        probeTimer?.invalidate()
    }

    @objc private func handleBecomeKey() {
        startProbeTimer()
    }

    @objc private func handleWillClose() {
        stopProbeTimer()
    }

    private func startProbeTimer() {
        stopProbeTimer()
        quickProbeASR()       // immediate refresh on open
        probeTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.quickProbeASR()
        }
    }

    private func stopProbeTimer() {
        probeTimer?.invalidate()
        probeTimer = nil
    }

    private func loadSettings() {
        let asr = ASRClient.shared
        asrBaseField.stringValue = asr.baseURL
        asrLanguagePopup.selectItem(withTitle: asr.language)
        asrLocalePopup.selectItem(withTitle: asr.outputLocale)

        let server = LocalASRServer.Configuration.current()
        serverDirField.stringValue = server.serverDir
        serverPythonField.stringValue = server.pythonPath
        serverPortField.stringValue = String(server.port)
        serverPrecisionPopup.selectItem(withTitle: server.precision)
        serverModelRootField.stringValue = server.modelRoot
        serverPreloadCheckbox.state = server.preload ? .on : .off
        showServerStatus(serverStateText(LocalASRServer.shared.state), success: nil)

        let llm = LLMRefiner.shared
        llmEnabledCheckbox.state = llm.isEnabled ? .on : .off
        translateCheckbox.state = llm.claudeCodeModeEnabled ? .on : .off
        llmBaseField.stringValue = llm.apiBaseURL
        llmKeyField.stringValue = llm.apiKey
        llmModelField.stringValue = llm.model
        suffixField.string = llm.claudeCodeSuffix
    }

    private func serverStateText(_ state: LocalASRServer.State) -> String {
        switch state {
        case .running: return "● running"
        case .starting: return "● starting…"
        case .stopped: return "○ stopped"
        case .failed(let m): return "✕ failed — \(m.prefix(60))"
        }
    }

    // MARK: - ASR Server actions

    @objc private func browseServerDir() { browseDirectory(into: serverDirField) }
    @objc private func browseModelRoot() { browseDirectory(into: serverModelRootField) }

    @objc private func browsePython() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Select python executable"
        panel.beginSheetModal(for: self) { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            self?.serverPythonField.stringValue = url.path
        }
    }

    private func browseDirectory(into field: NSTextField) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Select directory"
        panel.beginSheetModal(for: self) { resp in
            guard resp == .OK, let url = panel.url else { return }
            field.stringValue = url.path
        }
    }

    @objc private func applyAndRestartServer() {
        applyServerFields()
        let config = LocalASRServer.Configuration.current()
        if let err = config.validate() {
            showServerStatus("✕ \(err.localizedDescription)", success: false)
            return
        }
        showServerStatus("Restarting…", success: nil)
        LocalASRServer.shared.restart { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self?.showServerStatus("✅ Running on :\(config.port)", success: true)
                case .failure(let error):
                    self?.showServerStatus("❌ \(error.localizedDescription)", success: false)
                }
            }
        }
    }

    private func applyServerFields() {
        var c = LocalASRServer.Configuration.current()
        c.serverDir = serverDirField.stringValue.trimmingCharacters(in: .whitespaces)
        c.pythonPath = serverPythonField.stringValue.trimmingCharacters(in: .whitespaces)
        c.port = Int(serverPortField.stringValue) ?? c.port
        c.precision = serverPrecisionPopup.titleOfSelectedItem ?? c.precision
        c.modelRoot = serverModelRootField.stringValue.trimmingCharacters(in: .whitespaces)
        c.preload = (serverPreloadCheckbox.state == .on)
        c.write()
    }

    private func showServerStatus(_ text: String, success: Bool?) { paint(serverStatusLabel, text, success) }

    /// Manual Probe ASR button — runs a smoke transcribe (synthetic 1s silence WAV)
    /// to measure REAL end-to-end latency including any cold-load tax. /v1/health alone
    /// only confirms the server is up, not that transcribe is fast.
    @objc private func probeASR() {
        applyFields()
        showASRProbe("Smoke transcribe \(ASRClient.shared.baseURL) ...", success: nil)
        ASRClient.shared.smokeTranscribe { [weak self] result in
            switch result {
            case .success(let r):
                let coldStr = r.wasCold ? "cold" : "warm"
                self?.showASRProbe(
                    "✅ smoke \(coldStr) \(r.elapsedMs) ms",
                    success: true
                )
                // Refresh quick probe right after smoke (state likely changed: loaded=true now).
                self?.quickProbeASR()
            case .failure(let error):
                self?.showASRProbe("❌ smoke failed: \(error.localizedDescription)", success: false)
            }
        }
    }

    /// Lightweight refresh — combines /v1/health + /admin/memory into one status line.
    /// Distinguishes three states:
    ///   - loaded=true                                       → ✅ green
    ///   - loaded=false + reachable + adaptive idle context → ⏸ blue (idle by design, not error)
    ///   - unreachable                                       → ❌ red
    private func quickProbeASR() {
        ASRClient.shared.health { [weak self] healthResult in
            switch healthResult {
            case .failure(let error):
                self?.showASRProbe("❌ \(error.localizedDescription)", success: false)
            case .success(let health):
                ASRClient.shared.adminMemory { [weak self] memResult in
                    self?.renderQuickProbe(health: health, mem: try? memResult.get())
                }
            }
        }
    }

    private func renderQuickProbe(health: [String: Any], mem: [String: Any]?) {
        let asrLoaded = (health["asr_loaded"] as? Bool) ?? false
        let opencc = (health["opencc_config"] as? String) ?? "?"
        let zhtw = (health["zhtw_rules_loaded"] as? Int) ?? 0
        let zhtwStr = zhtw > 0 ? ", zhtw=\(zhtw)" : ""

        // /admin/memory provides idle ladder context for unloaded state.
        var idleSuffix = ""
        if let mem,
           let asr = mem["asr"] as? [String: Any],
           let idle = asr["idle"] as? [String: Any],
           let level = idle["level"] as? Int,
           let win = idle["current_window_seconds"] as? Double {
            let timeSinceUse = (asr["time_since_use_s"] as? Double) ?? 0
            let evictsIn = max(0, win - timeSinceUse)
            if asrLoaded {
                idleSuffix = ", L\(level)/\(Int(win))s, evicts in \(Int(evictsIn))s"
            } else {
                idleSuffix = ", L\(level)/\(Int(win))s, idle"
            }
        }

        // Color logic: loaded=true → green; loaded=false+reachable → blue (idle ok); unreachable → red.
        // unreachable case is handled in quickProbeASR's healthResult.failure branch.
        let mark = asrLoaded ? "✅" : "⏸"
        let success: Bool? = asrLoaded ? true : nil   // nil = secondaryLabel grey (per paint)
        showASRProbe("\(mark) loaded=\(asrLoaded), opencc=\(opencc)\(zhtwStr)\(idleSuffix)", success: success)
    }

    @objc private func probeLLM() {
        applyFields()
        showLLMProbe("Probing \(LLMRefiner.shared.apiBaseURL) ...", success: nil)
        LLMRefiner.shared.probeModels { [weak self] result in
            switch result {
            case .success(let ids):
                if ids.isEmpty {
                    self?.showLLMProbe("⚠️ Reachable, no models loaded.", success: false)
                } else {
                    let preview = ids.prefix(2).joined(separator: ", ")
                    let extra = ids.count > 2 ? " (+\(ids.count - 2))" : ""
                    self?.showLLMProbe("✅ \(ids.count) model(s): \(preview)\(extra)", success: true)
                }
            case .failure(let error):
                self?.showLLMProbe("❌ \(error.localizedDescription)", success: false)
            }
        }
    }

    @objc private func resetSuffix() {
        suffixField.string = LLMRefiner.defaultSuffix
    }

    @objc private func test() {
        applyFields()
        showStatus("Testing LLM with sample text...", success: nil)
        LLMRefiner.shared.refine("幫我重構這個函式", force: true) { [weak self] result in
            switch result {
            case .success(let text):
                let preview = text.prefix(120)
                self?.showStatus("OK: \(preview)", success: true)
            case .failure(let error):
                self?.showStatus(error.localizedDescription, success: false)
            }
        }
    }

    @objc private func save() {
        applyFields()
        close()
    }

    private func applyFields() {
        let asr = ASRClient.shared
        asr.baseURL = asrBaseField.stringValue
        asr.language = asrLanguagePopup.titleOfSelectedItem ?? "auto"
        asr.outputLocale = asrLocalePopup.titleOfSelectedItem ?? "zh-TW"

        // Server section persists via Apply & Restart, but Save also writes
        // (so closing the window without explicit restart still preserves intent).
        applyServerFields()

        let llm = LLMRefiner.shared
        llm.isEnabled = (llmEnabledCheckbox.state == .on)
        llm.claudeCodeModeEnabled = (translateCheckbox.state == .on)
        llm.apiBaseURL = llmBaseField.stringValue
        llm.apiKey = llmKeyField.stringValue
        llm.model = llmModelField.stringValue
        llm.claudeCodeSuffix = suffixField.string
    }

    private func showStatus(_ text: String, success: Bool?)  { paint(statusLabel, text, success) }
    private func showASRProbe(_ text: String, success: Bool?) { paint(asrProbeLabel, text, success) }
    private func showLLMProbe(_ text: String, success: Bool?) { paint(llmProbeLabel, text, success) }

    private func paint(_ label: NSTextField, _ text: String, _ success: Bool?) {
        label.stringValue = text
        switch success {
        case .some(true): label.textColor = .systemGreen
        case .some(false): label.textColor = .systemRed
        case .none: label.textColor = .secondaryLabelColor
        }
    }
}
