import Foundation

/// Sidebar entries for the SwiftUI Settings window. Phase 3 ships 5 active
/// panes (general, shortcuts, speech, asrServer, about) and 2 placeholders
/// (prompts → Phase 4, history → Phase 5).
enum SettingsPane: String, CaseIterable, Identifiable, Hashable {
    case general
    case shortcuts
    case speech
    case asrServer
    case prompts
    case history
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .shortcuts: return "Shortcuts"
        case .speech: return "Speech Recognition"
        case .asrServer: return "ASR Server"
        case .prompts: return "Prompts"
        case .history: return "History"
        case .about: return "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .shortcuts: return "command"
        case .speech: return "waveform"
        case .asrServer: return "server.rack"
        case .prompts: return "text.append"
        case .history: return "clock.arrow.circlepath"
        case .about: return "info.circle"
        }
    }
}
