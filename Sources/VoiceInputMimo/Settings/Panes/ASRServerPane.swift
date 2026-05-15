import AppKit
import SwiftUI

/// Local ASR server supervisor settings — venv directory, python path, port,
/// precision, model cache root, preload toggle. Apply&Restart writes the
/// config and restarts the supervised process.
struct ASRServerPane: View {
    @Environment(SettingsViewModel.self) private var vm

    private let precisions = ["int4", "bf16"]

    var body: some View {
        @Bindable var vm = vm

        Form {
            Section {
                LabeledContent("伺服器目錄") {
                    HStack(spacing: 6) {
                        TextField("~/Documents/voice-input-mimo/server", text: $vm.serverDir)
                            .textFieldStyle(.roundedBorder)
                        Button("瀏覽…") { browseDirectory(into: $vm.serverDir) }
                    }
                }
                LabeledContent("Python") {
                    HStack(spacing: 6) {
                        TextField("<server>/.venv/bin/python", text: $vm.serverPython)
                            .textFieldStyle(.roundedBorder)
                        Button("瀏覽…") { browseFile(into: $vm.serverPython) }
                    }
                }
                LabeledContent("Port") {
                    TextField("8765", text: $vm.serverPort)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 100, alignment: .leading)
                }
                Picker("精度", selection: $vm.serverPrecision) {
                    ForEach(precisions, id: \.self) { Text($0).tag($0) }
                }
                LabeledContent("Model 根目錄") {
                    HStack(spacing: 6) {
                        TextField("~/.cache/mimo-asr", text: $vm.serverModelRoot)
                            .textFieldStyle(.roundedBorder)
                        Button("瀏覽…") { browseDirectory(into: $vm.serverModelRoot) }
                    }
                }
                Toggle("啟動時預載模型（避免 1 秒以上冷啟延遲）", isOn: $vm.serverPreload)
            } header: {
                SectionHeading("ASR 伺服器", subtitle: "本機監管的 Python process")
            }

            Section {
                HStack {
                    StatusLineView(status: vm.serverStatus)
                    Button("套用並重啟伺服器") { vm.applyAndRestartServer() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("ASR 伺服器")
    }

    // MARK: - File browsers

    private func browseDirectory(into binding: Binding<String>) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "選擇目錄"
        if panel.runModal() == .OK, let url = panel.url {
            binding.wrappedValue = url.path
        }
    }

    private func browseFile(into binding: Binding<String>) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "選擇 python 執行檔"
        if panel.runModal() == .OK, let url = panel.url {
            binding.wrappedValue = url.path
        }
    }
}

#if DEBUG
#Preview("ASRServerPane") {
    ASRServerPane()
        .environment(SettingsViewModel())
        .frame(width: 640, height: 540)
}
#endif
