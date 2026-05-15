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
    case glossary
    case workflows
    case toneMapping
    case history
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "一般"
        case .shortcuts: return "快捷鍵"
        case .speech: return "語音辨識"
        case .asrServer: return "ASR 伺服器"
        case .prompts: return "Prompts"
        case .glossary: return "Glossary"
        case .workflows: return "工作流程"
        case .toneMapping: return "對應規則"
        case .history: return "歷史紀錄"
        case .about: return "關於"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .shortcuts: return "command"
        case .speech: return "waveform"
        case .asrServer: return "server.rack"
        case .prompts: return "text.append"
        case .glossary: return "character.book.closed"
        case .workflows: return "arrow.triangle.branch"
        case .toneMapping: return "rectangle.dashed.and.paperclip"
        case .history: return "clock.arrow.circlepath"
        case .about: return "info.circle"
        }
    }
}
