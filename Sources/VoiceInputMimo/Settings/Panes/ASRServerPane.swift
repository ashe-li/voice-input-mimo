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
                LabeledContent("Server dir") {
                    HStack(spacing: 6) {
                        TextField("~/Documents/voice-input-mimo/server", text: $vm.serverDir)
                            .textFieldStyle(.roundedBorder)
                        Button("Browse…") { browseDirectory(into: $vm.serverDir) }
                    }
                }
                LabeledContent("Python") {
                    HStack(spacing: 6) {
                        TextField("<server>/.venv/bin/python", text: $vm.serverPython)
                            .textFieldStyle(.roundedBorder)
                        Button("Browse…") { browseFile(into: $vm.serverPython) }
                    }
                }
                LabeledContent("Port") {
                    TextField("8765", text: $vm.serverPort)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 100, alignment: .leading)
                }
                Picker("Precision", selection: $vm.serverPrecision) {
                    ForEach(precisions, id: \.self) { Text($0).tag($0) }
                }
                LabeledContent("Model root") {
                    HStack(spacing: 6) {
                        TextField("~/.cache/mimo-asr", text: $vm.serverModelRoot)
                            .textFieldStyle(.roundedBorder)
                        Button("Browse…") { browseDirectory(into: $vm.serverModelRoot) }
                    }
                }
                Toggle("Preload model on startup (avoids 1 s+ cold-start tax)", isOn: $vm.serverPreload)
            } header: {
                SectionHeading("ASR Server", subtitle: "Local supervised Python process")
            }

            Section {
                HStack {
                    StatusLineView(status: vm.serverStatus)
                    Button("Apply & Restart Server") { vm.applyAndRestartServer() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("ASR Server")
    }

    // MARK: - File browsers

    private func browseDirectory(into binding: Binding<String>) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Select directory"
        if panel.runModal() == .OK, let url = panel.url {
            binding.wrappedValue = url.path
        }
    }

    private func browseFile(into binding: Binding<String>) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Select python executable"
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
