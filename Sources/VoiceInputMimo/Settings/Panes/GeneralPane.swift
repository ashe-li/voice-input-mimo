import SwiftUI

/// Phase 3 General pane — LLM refinement settings + sample-text test action.
/// Phase 4 will move these to a richer Prompts pane; for now they live here so
/// no functionality is lost during the AppKit → SwiftUI migration.
struct GeneralPane: View {
    @Environment(SettingsViewModel.self) private var vm

    var body: some View {
        @Bindable var vm = vm

        Form {
            Section {
                Toggle("啟用 LLM 後處理（關閉＝只貼中文 ASR）", isOn: $vm.llmEnabled)
                Toggle("貼上英文 Prompt（附繁中回覆要求）", isOn: $vm.llmEnglishMode)
                Text("關閉英文模式：貼上中文 ASR 原文。開啟英文模式：貼上英文 prompt，History 保留中文 ASR 與英文輸出。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                SectionHeading("Text Refinement", subtitle: "Local LLM cleanup + optional English translation")
            }

            Section {
                LabeledContent("Base URL") {
                    TextField("http://127.0.0.1:8082/v1", text: $vm.llmBaseURL)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("API Key (optional)") {
                    TextField("local-api-key", text: $vm.llmAPIKey)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("Model") {
                    TextField("model-id", text: $vm.llmModel)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("Reply Suffix") {
                    TextEditor(text: $vm.llmSuffix)
                        .font(.system(size: 12, weight: .regular, design: .default))
                        .frame(minHeight: 100)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(.separator, lineWidth: 0.5)
                        )
                }
            }

            Section {
                HStack {
                    StatusLineView(status: vm.llmProbeStatus)
                    Button("Probe LLM") { vm.probeLLM() }
                    Button("Reset Suffix") { vm.resetSuffix() }
                }
            }

            Section {
                HStack {
                    StatusLineView(status: vm.generalStatus)
                    Button("Test (sample text)") { vm.test() }
                    Button("Save") { vm.save() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("General")
    }
}

#if DEBUG
#Preview("GeneralPane") {
    GeneralPane()
        .environment(SettingsViewModel())
        .frame(width: 640, height: 600)
}
#endif
