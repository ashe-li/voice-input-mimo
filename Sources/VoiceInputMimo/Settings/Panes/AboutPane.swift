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
                LabeledContent("Version", value: appVersion)
                LabeledContent("Bundle ID", value: Bundle.main.bundleIdentifier ?? "?")
                LabeledContent("Application Support", value: promptsRoot)
            } header: {
                SectionHeading("About VoiceInputMimo", subtitle: "macOS LSUIElement menubar app")
            }

            Section {
                Text("VoiceInputMimo uses **MiMo-V2.5-ASR** (Xiaomi, MIT) for code-switching speech recognition and a local OpenAI-compatible LLM (Rapid-MLX by default) for cleanup / English translation.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Prompts and skills live as JSON in Application Support — safe to copy, share, or version-control.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                SectionHeading("Tech")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("About")
    }
}

#if DEBUG
#Preview("AboutPane") {
    AboutPane()
        .frame(width: 560, height: 420)
}
#endif
