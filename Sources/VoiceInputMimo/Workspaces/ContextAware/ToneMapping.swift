import Foundation

/// One mapping rule from a bundle-ID predicate to a delegated `RefineMode`.
struct ToneRule: Equatable, Sendable {
    /// Match against `CapturedContext.bundleID`. Two flavors:
    /// - exact match (`"com.apple.mail"` → matches that bundle only)
    /// - prefix match if `endsWithDot` (`"com.tinyspeck.slackmacgap."` matches
    ///   anything starting with that string).
    let bundleIDPrefix: String
    let delegated: RefineMode

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

/// Maps a captured app context to one of the explicit `RefineMode` cases.
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

    /// Resolve a captured context to a delegated mode. Falls back to `.refine`
    /// when no rule matches (safest default — does cleanup, doesn't translate,
    /// doesn't trigger router).
    static func resolve(context: CapturedContext, rules: [ToneRule] = defaultRules) -> RefineMode {
        for rule in rules where rule.matches(context.bundleID) {
            return rule.delegated
        }
        return .refine
    }
}
