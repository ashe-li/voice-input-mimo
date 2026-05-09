import SwiftUI

/// Right column of the Prompts pane. Multi-line input + Run button → calls
/// the injected Refining (which uses the active profile via PromptStore →
/// PromptComposer chain) and appends the rendered result to history. Up to
/// 10 entries kept so users can compare outputs across profile tweaks.
struct PromptTestPanel: View {
    @Environment(PromptsPaneViewModel.self) private var pane

    var body: some View {
        @Bindable var pane = pane

        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionHeading("Test panel", subtitle: "Run input through the active profile")
                Spacer()
                if !pane.testHistory.isEmpty {
                    IconButton(systemImage: "trash", accessibilityLabel: "Clear history") {
                        pane.clearHistory()
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 8)

            TextEditor(text: $pane.testInput)
                .font(.system(size: 12))
                .frame(minHeight: 80, maxHeight: 140)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(.separator, lineWidth: 0.5)
                )
                .padding(.horizontal, 14)

            HStack {
                Spacer()
                if pane.isRunning {
                    ProgressView().controlSize(.small).padding(.trailing, 6)
                }
                Button("Run") {
                    Task { await pane.runTest() }
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(pane.isRunning || pane.testInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            if pane.testHistory.isEmpty {
                Spacer()
                Text("No runs yet — try the sample input above.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding()
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(pane.testHistory) { entry in
                            entryCard(entry)
                        }
                    }
                    .padding(14)
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 320, ideal: 380)
    }

    @ViewBuilder
    private func entryCard(_ entry: TestEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(entry.profileLabel)
                    .font(.caption)
                    .fontWeight(.semibold)
                Text(entry.mode.rawValue)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(entry.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text(entry.input)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)

            if let err = entry.error {
                Text(err).font(.caption).foregroundStyle(.red)
            } else {
                Text(entry.output).font(.callout).textSelection(.enabled)
            }
        }
        .card(padding: 10)
    }
}

#if DEBUG
#Preview("PromptTestPanel") {
    PromptTestPanel()
        .environment(PromptsPaneViewModel())
        .frame(width: 380, height: 480)
}
#endif
