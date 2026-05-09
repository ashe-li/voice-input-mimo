import SwiftUI

/// Phase 3 placeholder. Phase 5 will embed `ClipboardHistoryView` (LazyVGrid
/// cards + sidebar filter for kind / time range) directly here so the
/// in-Settings history matches the standalone window.
struct HistoryPane: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            SectionHeading("History", subtitle: "Voice session archive — Phase 5")
            Text("Recent dictation sessions and clipboard snapshots will be browsable here, mirroring the standalone History window (⌘⌥H).")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .navigationTitle("History")
    }
}

#if DEBUG
#Preview("HistoryPane") {
    HistoryPane()
        .frame(width: 640, height: 480)
}
#endif
