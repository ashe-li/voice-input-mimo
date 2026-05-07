import AppKit

final class SettingsWindow: NSPanel {
    // ASR section
    private let asrBaseField = NSTextField()
    private let asrLanguagePopup = NSPopUpButton()
    private let asrLocalePopup = NSPopUpButton()
    private let asrProbeLabel = NSTextField(labelWithString: "")

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

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 600),
            styleMask: [.titled, .closable, .fullSizeContentView],
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

        let llmButtonRow = NSStackView(views: [llmProbeLabel, llmProbeButton, resetSuffixButton])
        llmButtonRow.orientation = .horizontal
        llmButtonRow.spacing = 8
        llmButtonRow.translatesAutoresizingMaskIntoConstraints = false

        let bottomRow = NSStackView(views: [statusLabel, testButton, saveButton])
        bottomRow.orientation = .horizontal
        bottomRow.spacing = 8
        bottomRow.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        for sub in [asrHeader, asrGrid, asrButtonRow, separator, llmHeader, llmGrid, llmButtonRow, bottomRow] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            cv.addSubview(sub)
        }

        NSLayoutConstraint.activate([
            asrHeader.topAnchor.constraint(equalTo: cv.topAnchor, constant: 18),
            asrHeader.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 20),

            asrGrid.topAnchor.constraint(equalTo: asrHeader.bottomAnchor, constant: 10),
            asrGrid.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 20),
            asrGrid.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -20),

            asrBaseField.widthAnchor.constraint(greaterThanOrEqualToConstant: 380),

            asrButtonRow.topAnchor.constraint(equalTo: asrGrid.bottomAnchor, constant: 10),
            asrButtonRow.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 20),
            asrButtonRow.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -20),

            separator.topAnchor.constraint(equalTo: asrButtonRow.bottomAnchor, constant: 18),
            separator.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 20),
            separator.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -20),
            separator.heightAnchor.constraint(equalToConstant: 1),

            llmHeader.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 14),
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
    }

    private func loadSettings() {
        let asr = ASRClient.shared
        asrBaseField.stringValue = asr.baseURL
        asrLanguagePopup.selectItem(withTitle: asr.language)
        asrLocalePopup.selectItem(withTitle: asr.outputLocale)

        let llm = LLMRefiner.shared
        llmEnabledCheckbox.state = llm.isEnabled ? .on : .off
        translateCheckbox.state = llm.claudeCodeModeEnabled ? .on : .off
        llmBaseField.stringValue = llm.apiBaseURL
        llmKeyField.stringValue = llm.apiKey
        llmModelField.stringValue = llm.model
        suffixField.string = llm.claudeCodeSuffix
    }

    @objc private func probeASR() {
        applyFields()
        showASRProbe("Probing \(ASRClient.shared.baseURL) ...", success: nil)
        ASRClient.shared.health { [weak self] result in
            switch result {
            case .success(let json):
                let modelLoaded = (json["model_loaded"] as? Bool) ?? false
                let opencc = (json["opencc_config"] as? String) ?? "?"
                let zhtw = (json["zhtw_rules_loaded"] as? Int) ?? 0
                let mark = modelLoaded ? "✅" : "⚠️"
                let zhtwStr = zhtw > 0 ? ", zhtw=\(zhtw)" : ""
                self?.showASRProbe(
                    "\(mark) loaded=\(modelLoaded), opencc=\(opencc)\(zhtwStr)",
                    success: modelLoaded
                )
            case .failure(let error):
                self?.showASRProbe("❌ \(error.localizedDescription)", success: false)
            }
        }
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
