import SwiftUI

/// Settings → History pane. Phase 5 embeds `ClipboardHistoryView` directly so
/// the in-Settings view and the standalone window share one SwiftUI tree.
struct HistoryPane: View {
    var body: some View {
        ClipboardHistoryView()
            .navigationTitle("History")
    }
}

#if DEBUG
#Preview("HistoryPane") {
    HistoryPane()
        .frame(width: 880, height: 560)
}
#endif
