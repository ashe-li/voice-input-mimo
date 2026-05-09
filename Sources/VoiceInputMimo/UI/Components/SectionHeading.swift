import SwiftUI

/// Reusable section title used by Settings panes and Prompt Profile cards.
/// Title + optional subtitle, with consistent typography and spacing so
/// every Phase 3+ surface has the same visual rhythm.
struct SectionHeading: View {
    let title: String
    let subtitle: String?

    init(_ title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#if DEBUG
#Preview("SectionHeading — title only") {
    SectionHeading("Shortcuts").padding()
}

#Preview("SectionHeading — with subtitle") {
    SectionHeading("Speech Recognition", subtitle: "Local engine + adaptive idle")
        .padding()
}
#endif
