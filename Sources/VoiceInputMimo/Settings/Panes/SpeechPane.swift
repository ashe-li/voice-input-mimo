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
                Picker("Language", selection: $vm.asrLanguage) {
                    ForEach(languages, id: \.self) { Text($0).tag($0) }
                }
                Picker("Output locale", selection: $vm.asrOutputLocale) {
                    ForEach(locales, id: \.self) { Text($0).tag($0) }
                }
            } header: {
                SectionHeading("Speech Recognition", subtitle: "Whisper-compat endpoint + zh-TW post-process")
            }

            Section {
                HStack {
                    StatusLineView(status: vm.asrProbeStatus)
                    Button("Probe ASR") { vm.probeASR() }
                    Button("Save") { vm.save() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Speech Recognition")
    }
}

#if DEBUG
#Preview("SpeechPane") {
    SpeechPane()
        .environment(SettingsViewModel())
        .frame(width: 560, height: 360)
}
#endif
