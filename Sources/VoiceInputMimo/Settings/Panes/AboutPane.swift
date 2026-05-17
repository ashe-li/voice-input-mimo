import SwiftUI

/// About — version, license summary, and key file paths so users can verify
/// what's running and find their data.
struct AboutPane: View {
    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    private var promptsRoot: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/VoiceInputMimo")
            .path
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("版本", value: appVersion)
                LabeledContent("Bundle ID", value: Bundle.main.bundleIdentifier ?? "?")
                LabeledContent("Application Support", value: promptsRoot)
            } header: {
                SectionHeading("關於 VoiceInputMimo", subtitle: "macOS LSUIElement menubar app")
            }

            Section {
                Text("VoiceInputMimo 使用 **MiMo-V2.5-ASR**（Xiaomi, MIT）做中英混說語音辨識，並透過本地 OpenAI 相容 LLM（預設 Rapid-MLX）做清理 / 英文翻譯。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Prompt 與 Skill 以 JSON 存在 Application Support — 可自由複製、分享、版本控管。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                SectionHeading("技術")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("關於")
    }
}

#if DEBUG
#Preview("AboutPane") {
    AboutPane()
        .frame(width: 560, height: 420)
}
#endif
