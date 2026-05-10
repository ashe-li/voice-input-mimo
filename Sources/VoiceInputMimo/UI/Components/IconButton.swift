import SwiftUI

/// Compact SF Symbol button used inside cards and toolbars (e.g. delete a
/// profile, copy a history entry, open a folder). Borderless style to keep
/// card layouts visually quiet; accessibility label is required so VoiceOver
/// users get a meaningful description.
struct IconButton: View {
    let systemImage: String
    let accessibilityLabel: String
    let action: () -> Void
    var help: String?

    init(
        systemImage: String,
        accessibilityLabel: String,
        help: String? = nil,
        action: @escaping () -> Void
    ) {
        self.systemImage = systemImage
        self.accessibilityLabel = accessibilityLabel
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help ?? accessibilityLabel)
        .accessibilityLabel(Text(accessibilityLabel))
    }
}

#if DEBUG
#Preview("IconButton — row") {
    HStack(spacing: 8) {
        IconButton(systemImage: "doc.on.doc", accessibilityLabel: "Copy") {}
        IconButton(systemImage: "trash", accessibilityLabel: "Delete", help: "Delete profile") {}
        IconButton(systemImage: "folder", accessibilityLabel: "Reveal in Finder") {}
    }
    .padding()
}
#endif
