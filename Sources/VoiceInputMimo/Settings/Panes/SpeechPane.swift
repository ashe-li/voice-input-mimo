import SwiftUI

/// Speech Recognition (ASR client) settings — base URL of the local server,
/// language hint, output locale (zh-TW post-process toggle), and the
/// smoke-transcribe Probe button.
struct SpeechPane: View {
    @Environment(SettingsViewModel.self) private var vm

    private let languages = ["auto", "zh", "en"]
    private let locales = ["zh-TW", "none"]

    var body: some View {
        @Bindable var vm = vm

        Form {
            Section {
                LabeledContent("Base URL") {
                    TextField("http://127.0.0.1:4000", text: $vm.asrBaseURL)
                        .textFieldStyle(.roundedBorder)
                }
                Picker("語言", selection: $vm.asrLanguage) {
                    ForEach(languages, id: \.self) { Text($0).tag($0) }
                }
                Picker("輸出語系", selection: $vm.asrOutputLocale) {
                    ForEach(locales, id: \.self) { Text($0).tag($0) }
                }
            } header: {
                SectionHeading("語音辨識", subtitle: "Whisper 相容端點 + zh-TW 後處理")
            }

            Section {
                HStack {
                    StatusLineView(status: vm.asrProbeStatus)
                    Button("測試 ASR") { vm.probeASR() }
                    Button("儲存") { vm.save() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("語音辨識")
    }
}

#if DEBUG
#Preview("SpeechPane") {
    SpeechPane()
        .environment(SettingsViewModel())
        .frame(width: 560, height: 360)
}
#endif
