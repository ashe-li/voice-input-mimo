import Foundation

/// What a `ToneRule` resolves to: either a concrete `RefineMode` (existing
/// dispatch path) or a named workflow chain (Sprint 3.2 — runs the chain
/// via `WorkflowExecutor`). Keeping these in a sum type lets callers
/// branch explicitly instead of overloading `RefineMode` with a fake case.
enum ToneDelegate: Equatable, Sendable, Codable {
    case mode(RefineMode)
    case workflow(workflowId: String)
}

/// One mapping rule from a bundle-ID predicate to a delegated target.
struct ToneRule: Equatable, Sendable, Codable {
    /// Match against `CapturedContext.bundleID`. Two flavors:
    /// - exact match (`"com.apple.mail"` → matches that bundle only)
    /// - prefix match if the string ends with `"."` (`"com.tinyspeck.slackmacgap."`
    ///   matches anything starting with that string).
    let bundleIDPrefix: String
    let delegated: ToneDelegate

    init(bundleIDPrefix: String, delegated: ToneDelegate) {
        self.bundleIDPrefix = bundleIDPrefix
        self.delegated = delegated
    }

    /// Back-compat convenience: lets existing rule tables stay terse with
    /// `delegated: .refine` instead of `delegated: .mode(.refine)`. Swift
    /// picks this overload when the second argument resolves to `RefineMode`.
    init(bundleIDPrefix: String, delegated mode: RefineMode) {
        self.bundleIDPrefix = bundleIDPrefix
        self.delegated = .mode(mode)
    }

    /// Workflow-target convenience.
    init(bundleIDPrefix: String, workflowId: String) {
        self.bundleIDPrefix = bundleIDPrefix
        self.delegated = .workflow(workflowId: workflowId)
    }

    /// Test whether this rule matches the captured bundle. Empty / nil bundle
    /// never matches — caller falls back to default.
    func matches(_ bundleID: String?) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        if bundleIDPrefix.hasSuffix(".") {
            return bundleID.hasPrefix(bundleIDPrefix)
        }
        return bundleID == bundleIDPrefix
    }
}

/// Maps a captured app context to a `ToneDelegate` (either a concrete
/// `RefineMode` or a workflow id reference).
///
/// v1 uses a hardcoded rule list. v2 will read user-editable overrides from
/// `App Support/Workspaces/ToneMapping/rules.json` so power users can extend
/// the table per their workflow without rebuilding.
enum ToneMapping {
    /// Default rules shipped with the app. Ordered: first match wins. Bundle
    /// IDs sourced from `osascript -e 'id of app "<Name>"'` on stock macOS apps
    /// + observed bundle IDs of common third-party apps.
    static let defaultRules: [ToneRule] = [
        // 正式書信 — Mail / Spark / Airmail → refine (full Chinese cleanup, no EN)
        .init(bundleIDPrefix: "com.apple.mail", delegated: .refine),
        .init(bundleIDPrefix: "com.readdle.smartemail-Mac", delegated: .refine),
        .init(bundleIDPrefix: "it.bloop.airmail3", delegated: .refine),

        // Developer 環境 → claudeCode (ZH→EN with zh-TW reply suffix)
        .init(bundleIDPrefix: "com.todesktop.230313mzl4w4u92", delegated: .claudeCode),  // Cursor
        .init(bundleIDPrefix: "com.microsoft.VSCode", delegated: .claudeCode),
        .init(bundleIDPrefix: "com.apple.dt.Xcode", delegated: .claudeCode),
        .init(bundleIDPrefix: "com.googlecode.iterm2", delegated: .claudeCode),
        .init(bundleIDPrefix: "com.apple.Terminal", delegated: .claudeCode),
        .init(bundleIDPrefix: "dev.warp.Warp-Stable", delegated: .claudeCode),
        .init(bundleIDPrefix: "co.zeit.hyper", delegated: .claudeCode),

        // 即時通訊 → refine (casual cleanup, no translation)
        .init(bundleIDPrefix: "com.tinyspeck.slackmacgap", delegated: .refine),
        .init(bundleIDPrefix: "com.apple.MobileSMS", delegated: .refine),
        .init(bundleIDPrefix: "com.hnc.Discord", delegated: .refine),
        .init(bundleIDPrefix: "jp.naver.line.mac", delegated: .refine),
        .init(bundleIDPrefix: "com.facebook.archon", delegated: .refine),  // Messenger
        .init(bundleIDPrefix: "ru.keepcoder.Telegram", delegated: .refine),

        // 筆記 / 文件 → structure (template router for meeting/task/notes)
        .init(bundleIDPrefix: "notion.id", delegated: .structure),
        .init(bundleIDPrefix: "md.obsidian", delegated: .structure),
        .init(bundleIDPrefix: "net.shinyfrog.bear", delegated: .structure),
        .init(bundleIDPrefix: "com.apple.Notes", delegated: .structure),
        .init(bundleIDPrefix: "com.apple.iWork.Pages", delegated: .structure),

        // 瀏覽器 → refine (catch-all for web forms / search bars)
        .init(bundleIDPrefix: "com.apple.Safari", delegated: .refine),
        .init(bundleIDPrefix: "com.google.Chrome", delegated: .refine),
        .init(bundleIDPrefix: "company.thebrowser.Browser", delegated: .refine),  // Arc
    ]

    /// Resolve a captured context to a delegate. Falls back to `.mode(.refine)`
    /// when no rule matches (safest default — does cleanup, doesn't translate,
    /// doesn't trigger router or workflow).
    static func resolve(context: CapturedContext, rules: [ToneRule] = defaultRules) -> ToneDelegate {
        for rule in rules where rule.matches(context.bundleID) {
            return rule.delegated
        }
        return .mode(.refine)
    }

    /// Effective rule list = user rules first (highest precedence — first-match
    /// wins), then default rules as fallback. User adds / overrides without
    /// losing the shipped table.
    static func effectiveRules(userRules: [ToneRule]) -> [ToneRule] {
        userRules + defaultRules
    }
}
