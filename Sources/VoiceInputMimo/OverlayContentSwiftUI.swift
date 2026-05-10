import SwiftUI
import Observation

/// Observable state backing the overlay's SwiftUI content. The owning
/// `OverlayPanel` mutates these properties on the main actor; the SwiftUI
/// view tree re-renders automatically via `@Observable` tracking.
@MainActor
@Observable
final class OverlayContentModel {
    var zh: String = ""
    var en: String = ""
    var showZh: Bool = false
    var animating: Bool = false
    var audioLevel: CGFloat = 0
    var accessibilityLabelText: String = ""
}

/// Production overlay content — labels + waveform only, no chrome
/// (background material, border, shadow stay in `OverlayPanel`'s NSVisualEffectView
/// + shadow host so we don't render material-on-material).
struct OverlayLabelsView: View {
    @Bindable var model: OverlayContentModel

    var body: some View {
        HStack(spacing: 14) {
            WaveformBars(level: model.audioLevel, animating: model.animating)
                .frame(width: 44, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                if model.showZh && !model.zh.isEmpty {
                    Text(model.zh)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Text(model.en)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Combine zh + en into a single VoiceOver utterance instead of two
        // separate Text-field announcements.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(model.accessibilityLabelText)
        .accessibilityHint("Voice translation overlay")
    }
}

/// Static 5-bar waveform driven by `level` (0...1). Idle (animating=false)
/// renders flat min-height bars. The original AppKit version added per-frame
/// jitter; SwiftUI relies on the natural fluctuation of the audio level
/// stream instead, which keeps the implementation declarative.
private struct WaveformBars: View {
    let level: CGFloat
    let animating: Bool

    private let weights: [CGFloat] = [0.5, 0.8, 1.0, 0.75, 0.55]
    private let minFraction: CGFloat = 0.15

    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .center, spacing: 3.5) {
                ForEach(weights.indices, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(.white.opacity(0.9))
                        .frame(
                            width: 4.5,
                            height: max(geo.size.height * fraction(for: i), 4)
                        )
                        .animation(.easeOut(duration: 0.08), value: level)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private func fraction(for index: Int) -> CGFloat {
        guard animating else { return minFraction }
        let weight = weights[index]
        let value = minFraction + (1 - minFraction) * level * weight
        return min(max(value, minFraction), 1.0)
    }
}

// MARK: - Demo wrapper (kept for OVERLAY_DEMO=swiftui snapshot mode)

/// Self-contained preview wrapper that bakes the model values + adds the
/// material/border/shadow chrome. Used by `AppDelegate.renderSwiftUIOverlayDemo`
/// for headless PNG snapshots and by SwiftUI #Preview blocks.
struct OverlayContentSwiftUI: View {
    let zh: String
    let en: String
    let translating: Bool

    @State private var model = OverlayContentModel()

    var body: some View {
        OverlayLabelsView(model: model)
            .background(
                RoundedRectangle(cornerRadius: 24)
                    .fill(.regularMaterial)
                    .environment(\.colorScheme, .dark)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24)
                    .strokeBorder(.white.opacity(0.1), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.45), radius: 16, x: 0, y: -2)
            .onAppear { configure() }
    }

    private func configure() {
        let isDual = translating && !en.isEmpty && zh != en
        model.zh = zh
        model.en = en.isEmpty ? zh : en
        model.showZh = isDual
        model.animating = false
        model.audioLevel = 0
        model.accessibilityLabelText = isDual
            ? "Voice translation: \(zh). English: \(en)"
            : "Ready: \(en.isEmpty ? zh : en)"
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Overlay (translating, dual-line)") {
    OverlayContentSwiftUI(
        zh: "幫我把 useState 改成 useReducer",
        en: "Refactor useState to useReducer",
        translating: true
    )
    .frame(width: 560, height: 80)
    .padding(40)
    .background(Color.gray.opacity(0.3))
}

#Preview("Overlay (ASR-only, single-line)") {
    OverlayContentSwiftUI(
        zh: "再測試一下",
        en: "再測試一下",
        translating: false
    )
    .frame(width: 320, height: 56)
    .padding(40)
    .background(Color.gray.opacity(0.3))
}

#Preview("Overlay (long text truncating)") {
    OverlayContentSwiftUI(
        zh: "然後幫我給到一個設計,是我希望我的中文 LLM 修正以及英文翻譯",
        en: "Then give me a design where I can customize the prompts for both my Chinese LLM refinement",
        translating: true
    )
    .frame(width: 640, height: 80)
    .padding(40)
    .background(Color.gray.opacity(0.3))
}
#endif
