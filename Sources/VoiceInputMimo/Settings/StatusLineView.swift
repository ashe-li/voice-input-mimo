import SwiftUI

/// Renders a `StatusLine` as a small label, matching the AppKit form's
/// gray-idle / green-success / red-failure pattern.
struct StatusLineView: View {
    let status: StatusLine

    var body: some View {
        Text(status.text)
            .font(.caption)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .lineLimit(2)
    }

    private var color: Color {
        switch status {
        case .idle: return .secondary
        case .info: return .secondary
        case .success: return .green
        case .failure: return .red
        }
    }
}
