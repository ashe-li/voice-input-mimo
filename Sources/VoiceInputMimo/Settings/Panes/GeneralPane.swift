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
                SectionHeading("文字後處理", subtitle: "本地 LLM 清理＋可選英文翻譯")
            }

            Section {
                LabeledContent("Base URL") {
                    TextField("http://127.0.0.1:4000/v1", text: $vm.llmBaseURL)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("API Key（選填）") {
                    TextField("local-api-key", text: $vm.llmAPIKey)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("Model") {
                    TextField("model-id", text: $vm.llmModel)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("回覆後綴") {
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
                    Button("測試連線") { vm.probeLLM() }
                    Button("重設後綴") { vm.resetSuffix() }
                }
            }

            Section {
                HStack {
                    StatusLineView(status: vm.generalStatus)
                    Button("測試（樣本文字）") { vm.test() }
                    Button("儲存") { vm.save() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("一般")
    }
}

#if DEBUG
#Preview("GeneralPane") {
    GeneralPane()
        .environment(SettingsViewModel())
        .frame(width: 640, height: 600)
}
#endif
