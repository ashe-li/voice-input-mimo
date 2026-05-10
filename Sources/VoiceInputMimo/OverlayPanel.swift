import AppKit
import QuartzCore
import SwiftUI

final class OverlayPanel: NSPanel {
    enum Phase {
        case recording(elapsed: Double)
        case transcribing(elapsed: Double)
        case zhReady(zh: String)
        case refining(zh: String, elapsed: Double, translating: Bool, profileLabel: String?)
        /// `translating` distinguishes "中翻英" (two-line ZH+EN display) from
        /// ASR-only / Chinese-refine paths (single-line preview). The overlay
        /// only renders dual-line when translating == true AND the strings
        /// differ — equal strings collapse to single-line to avoid duplicating
        /// the same text in both rows.
        case bothReady(zh: String, en: String, translating: Bool)
        case error(String)
    }

    // MARK: - Layout constants

    private let singleLineHeight: CGFloat = 56
    private let dualLineHeight: CGFloat = 80
    private let cornerRadius: CGFloat = 24
    private let hPad: CGFloat = 24
    private let waveSize: CGFloat = 44
    private let gap: CGFloat = 14
    private let minWidth: CGFloat = 160
    private let maxWidth: CGFloat = 640

    // MARK: - SwiftUI content

    /// Observable model driving the SwiftUI labels view. The panel mutates
    /// this on every `transition(to:)` / `updateAudioLevel(_:)` call.
    private let contentModel = OverlayContentModel()
    private var hostingView: NSHostingView<OverlayLabelsView>!

    // MARK: - AppKit chrome (shadow + material remain native for fidelity)

    private var effectLayer: CALayer?
    private var borderLayer: CALayer?

    // MARK: - State

    /// Pending auto-dismiss work. Hover-to-stay cancels this on mouseEntered
    /// and re-schedules with the same delay on mouseExited.
    private var pendingDismiss: DispatchWorkItem?
    private var lastDismissDelay: TimeInterval = 0
    private var hoverTrackingArea: NSTrackingArea?
    private var isHovering: Bool = false
    /// True between `dismiss()` start and animation completion. Prevents
    /// hover events during fade-out from resurrecting the overlay.
    private var isDismissing: Bool = false

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 160, height: 56),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        // .popUpMenu sits above Dock (and Dock tooltips) but below the menu
        // bar — needed because the overlay's natural home is just above the
        // Dock, where Dock magnification + tooltips would otherwise overlap
        // a .floating-level panel.
        level = .popUpMenu
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        // Required for the contentView's NSTrackingArea to deliver
        // mouseEntered/mouseExited to this panel's responder chain.
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = false

        let cv = contentView!
        cv.wantsLayer = true

        // Shadow host — NSView with CALayer shadow gives a controlled,
        // soft drop shadow. SwiftUI's .shadow() inside the NSHostingView
        // would get clipped at the host's bounds, so the shadow stays here.
        let shadowHost = NSView(frame: cv.bounds)
        shadowHost.autoresizingMask = [.width, .height]
        shadowHost.wantsLayer = true
        shadowHost.layer?.shadowColor = NSColor.black.withAlphaComponent(0.45).cgColor
        shadowHost.layer?.shadowOffset = CGSize(width: 0, height: -2)
        shadowHost.layer?.shadowRadius = 16
        shadowHost.layer?.shadowOpacity = 1
        cv.addSubview(shadowHost)

        // Vibrancy capsule — native NSVisualEffectView gives the exact
        // macOS HUD blur. Replacing this with SwiftUI's .regularMaterial
        // would render correctly but produces a slightly different look
        // when the overlay sits over the Dock; native is the safer bet.
        let effect = NSVisualEffectView(frame: cv.bounds)
        effect.autoresizingMask = [.width, .height]
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = cornerRadius
        effect.layer?.masksToBounds = true
        effect.appearance = NSAppearance(named: .darkAqua)
        shadowHost.addSubview(effect)
        effectLayer = effect.layer

        // Subtle inner border for depth
        let border = NSView(frame: effect.bounds)
        border.autoresizingMask = [.width, .height]
        border.wantsLayer = true
        border.layer?.cornerRadius = cornerRadius
        border.layer?.borderWidth = 0.5
        border.layer?.borderColor = NSColor.white.withAlphaComponent(0.1).cgColor
        effect.addSubview(border)
        borderLayer = border.layer

        // SwiftUI labels + waveform — hosted inside the effect view so the
        // material renders behind them and the rounded mask clips correctly.
        let host = NSHostingView(rootView: OverlayLabelsView(model: contentModel))
        host.frame = effect.bounds
        host.autoresizingMask = [.width, .height]
        // Keep the hosting view transparent so NSVisualEffectView shows through.
        host.layer?.backgroundColor = NSColor.clear.cgColor
        effect.addSubview(host)
        hostingView = host
    }

    // MARK: - Public API

    func transition(to phase: Phase) {
        // Any state change cancels a pending dismiss — phases that should
        // re-arm dismissal will call scheduleDismiss again below.
        cancelPendingDismiss()
        isDismissing = false

        switch phase {
        case .recording(let elapsed):
            presentSingle("Listening \(Self.formatElapsed(elapsed))", animating: true)
        case .transcribing(let elapsed):
            presentSingle("Transcribing \(Self.formatElapsed(elapsed))", animating: true)
        case .zhReady(let zh):
            presentSingle("Chinese ready: \(Self.preview(zh))", animating: false)
        case .refining(_, let elapsed, let translating, let profileLabel):
            let action = translating ? "Converting to English" : "Refining Chinese"
            let suffix = profileLabel.flatMap { $0.isEmpty ? nil : " (\($0))" } ?? ""
            presentSingle("\(action)\(suffix) \(Self.formatElapsed(elapsed))", animating: true)
        case .bothReady(let zh, let en, let translating):
            let zhTrim = zh.trimmingCharacters(in: .whitespacesAndNewlines)
            let enTrim = en.trimmingCharacters(in: .whitespacesAndNewlines)
            let differ = !enTrim.isEmpty && zhTrim != enTrim
            if translating && differ {
                presentDual(zh: Self.preview(zhTrim), en: Self.preview(enTrim))
                scheduleDismiss(after: 1.8)
            } else {
                let shown = enTrim.isEmpty ? zhTrim : enTrim
                presentSingle("Ready: \(Self.preview(shown))", animating: false)
                scheduleDismiss(after: 0.7)
            }
        case .error(let message):
            presentSingle("Error: \(Self.preview(message))", animating: false)
            scheduleDismiss(after: 1.4)
        }
    }

    func updateAudioLevel(_ level: Float) {
        contentModel.audioLevel = CGFloat(level)
    }

    func dismiss() {
        cancelPendingDismiss()
        isDismissing = true
        contentModel.animating = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
            animator().setFrame(
                NSRect(
                    x: frame.origin.x + frame.width * 0.02,
                    y: frame.origin.y - 8,
                    width: frame.width * 0.96,
                    height: frame.height),
                display: true)
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
            self?.isDismissing = false
        })
    }

    // MARK: - Hover-to-stay

    /// Reinstall a tracking area covering the current contentView bounds.
    /// Called after every frame change so the area follows the resized panel.
    private func refreshHoverTracking() {
        guard let cv = contentView else { return }
        if let area = hoverTrackingArea {
            cv.removeTrackingArea(area)
        }
        let area = NSTrackingArea(
            rect: cv.bounds,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        cv.addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        guard !isDismissing else { return }
        isHovering = true
        cancelPendingDismiss()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        guard !isDismissing else { return }
        // Resume the same auto-dismiss delay that was originally requested.
        // Zero means the current phase wasn't an auto-dismiss phase
        // (e.g. recording/refining) — leave the overlay alone.
        if lastDismissDelay > 0 {
            scheduleDismiss(after: lastDismissDelay)
        }
    }

    // MARK: - Presentation

    private func presentSingle(_ text: String, animating: Bool) {
        contentModel.showZh = false
        contentModel.zh = ""
        contentModel.en = text
        contentModel.animating = animating
        contentModel.accessibilityLabelText = text
        present(targetHeight: singleLineHeight, animateIn: !isVisible)
    }

    private func presentDual(zh: String, en: String) {
        contentModel.zh = zh
        contentModel.en = en
        contentModel.showZh = true
        contentModel.animating = false
        // VoiceOver: announce both lines together. SwiftUI
        // .accessibilityElement(children: .combine) collapses the two Text
        // views; the accessibilityLabel below is what VoiceOver reads.
        contentModel.accessibilityLabelText = "Voice translation: \(zh). English: \(en)"
        present(targetHeight: dualLineHeight, animateIn: !isVisible)
    }

    /// Resize and reposition the panel to fit the current label content.
    /// Centers horizontally on the main screen, anchors to a fixed bottom
    /// margin. Animates in (alpha + slight rise) on first show.
    private func present(targetHeight: CGFloat, animateIn: Bool) {
        let w = idealWidth()
        guard let screen = NSScreen.main else { return }
        let area = screen.visibleFrame
        let x = area.midX - w / 2
        // Bottom margin must clear the Dock + give a comfortable hover gap.
        // visibleFrame already excludes the Dock when it's pinned, but
        // auto-hide Docks reappear over the visible area — 96 px keeps the
        // overlay above the magnified Dock icons in either configuration.
        let bottomMargin: CGFloat = 96
        let y = area.minY + bottomMargin
        let target = NSRect(x: x, y: y, width: w, height: targetHeight)

        if animateIn {
            // Slide in slightly from below + fade in
            setFrame(NSRect(x: x, y: y - 14, width: w, height: targetHeight), display: true)
            alphaValue = 0
            orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { [weak self] ctx in
                ctx.duration = 0.35
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.175, 0.885, 0.32, 1.1)
                self?.animator().alphaValue = 1
                self?.animator().setFrame(target, display: true)
            }
        } else {
            // Already visible — animate frame change in place
            NSAnimationContext.runAnimationGroup { [weak self] ctx in
                ctx.duration = 0.25
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.46, 0.45, 0.94)
                ctx.allowsImplicitAnimation = true
                self?.animator().setFrame(target, display: true)
            }
        }

        // Tracking area must be reinstalled after every resize so it covers
        // the new bounds — `inVisibleRect` updates the rect dynamically but
        // the area itself still has to exist on the contentView.
        refreshHoverTracking()
    }

    // MARK: - Sizing

    /// Compute panel width from current label text using NSAttributedString
    /// sizing (same algorithm as the AppKit version). Done at panel level
    /// rather than asking SwiftUI for fittingSize because NSPanel needs a
    /// concrete frame for positioning + slide-in animation.
    private func idealWidth() -> CGFloat {
        let zhFont = NSFont.systemFont(ofSize: 12, weight: .regular)
        let enFont = NSFont.systemFont(ofSize: 15, weight: .medium)
        let zhWidth = textWidth(contentModel.zh, font: zhFont)
        let enWidth = textWidth(contentModel.en, font: enFont)
        // When zhRow is hidden, ignore its width contribution.
        let textW = max(contentModel.showZh ? zhWidth : 0, enWidth)
        let total = hPad + waveSize + gap + textW + hPad
        return min(max(total, minWidth), maxWidth)
    }

    private func textWidth(_ text: String, font: NSFont) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        return ceil((text as NSString).size(withAttributes: attrs).width)
    }

    // MARK: - Dismiss scheduling

    private func scheduleDismiss(after seconds: TimeInterval) {
        cancelPendingDismiss()
        lastDismissDelay = seconds
        // Hover-to-stay: don't arm the timer if cursor is currently inside.
        // mouseExited will re-schedule when the cursor leaves.
        if isHovering { return }
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        pendingDismiss = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func cancelPendingDismiss() {
        pendingDismiss?.cancel()
        pendingDismiss = nil
    }

    // MARK: - Helpers

    private static func formatElapsed(_ elapsed: Double) -> String {
        String(format: "%.1fs", elapsed)
    }

    private static func preview(_ text: String) -> String {
        let oneLine = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(oneLine.prefix(80))
    }
}

// MARK: - Test hooks (debug only — exposes label state for assertion-based tests)

#if DEBUG
extension OverlayPanel {
    var debug_zhText: String { contentModel.zh }
    var debug_enText: String { contentModel.en }
    var debug_zhHidden: Bool { !contentModel.showZh }
    var debug_hasPendingDismiss: Bool { pendingDismiss != nil }
    var debug_lastDismissDelay: TimeInterval { lastDismissDelay }
    var debug_isHovering: Bool { isHovering }

    func debug_simulateMouseEntered() {
        mouseEntered(with: NSEvent())
    }

    func debug_simulateMouseExited() {
        mouseExited(with: NSEvent())
    }
}
#endif
