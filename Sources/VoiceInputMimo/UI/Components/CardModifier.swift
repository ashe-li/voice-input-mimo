import SwiftUI

/// Visual treatment for card-like surfaces — Prompt Profile cards,
/// Clipboard History entries, Model Memory rows. Rounded background with
/// a subtle border that respects light/dark mode via system materials.
struct CardModifier: ViewModifier {
    var padding: CGFloat = 14
    var cornerRadius: CGFloat = 10

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.background.secondary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.separator, lineWidth: 0.5)
            )
    }
}

extension View {
    /// Apply the standard card treatment. Phase 3+ use sites: Prompt Profile
    /// grid item, Skill chip, History session row.
    func card(padding: CGFloat = 14, cornerRadius: CGFloat = 10) -> some View {
        modifier(CardModifier(padding: padding, cornerRadius: cornerRadius))
    }
}

#if DEBUG
#Preview("Card — text") {
    Text("This is a card.")
        .card()
        .padding()
}

#Preview("Card — composed") {
    VStack(alignment: .leading, spacing: 6) {
        Text("Profile A").font(.headline)
        Text("Refine mode · 3 skills").foregroundStyle(.secondary).font(.caption)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .card()
    .padding()
}
#endif
