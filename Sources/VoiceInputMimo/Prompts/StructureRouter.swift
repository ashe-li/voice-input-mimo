import Foundation

/// Maps a free-form spoken Chinese transcript to one of the `.structure` mode
/// builtin profiles (meeting / task / requirement / letter / article) by
/// scoring keyword hits per rule and returning the best match. Pure value-type
/// API — no IO, no UserDefaults — so unit tests can exercise rules directly.
///
/// v1 ships a hardcoded rule table; a future phase will let users edit rules
/// from Settings. LLM-based routing (more semantic but doubles latency) is
/// also deferred — see plan for upgrade path.
enum StructureRouter {

    struct Rule: Equatable, Sendable {
        let keywords: [String]
        let profileID: String
    }

    /// Built-in routing rules. Keywords are lowercased before matching, so
    /// English keywords here must already be lowercase. Order is irrelevant —
    /// the route function picks whichever rule scores highest.
    static let defaultRules: [Rule] = [
        Rule(
            keywords: ["會議", "開會", "討論到", "決議", "議程", "會議紀錄", "會議記錄"],
            profileID: "builtin-structure-meeting"
        ),
        Rule(
            keywords: ["待辦", "任務清單", "todo", "to-do", "下一步", "等等做", "等一下做", "要做", "得做", "今天要"],
            profileID: "builtin-structure-task"
        ),
        Rule(
            keywords: ["需求", "客戶說", "希望能", "希望可以", "規格", "spec", "需求文件", "user story", "user-story"],
            profileID: "builtin-structure-requirement"
        ),
        Rule(
            keywords: ["寫信", "回信", "寫封信", "寫一封", "email", "e-mail", "跟他說", "回覆他", "麻煩他", "私訊"],
            profileID: "builtin-structure-letter"
        ),
        Rule(
            keywords: ["寫一篇", "整理成文章", "工作說明", "寫成文章", "寫個文章", "整篇", "書面"],
            profileID: "builtin-structure-article"
        ),
    ]

    static let defaultFallbackProfileID = "builtin-structure-fallback"

    /// Score each rule by counting how many of its keywords appear in `input`
    /// (case-insensitive substring match). Pick the rule with the highest
    /// score; ties resolve to the rule that appears earlier in `rules`. If
    /// no rule scores above zero, return `fallbackProfileID`.
    static func route(
        input: String,
        rules: [Rule] = defaultRules,
        fallbackProfileID: String = StructureRouter.defaultFallbackProfileID
    ) -> String {
        let lowerInput = input.lowercased()
        var best: (rule: Rule, score: Int)? = nil
        for rule in rules {
            let score = rule.keywords.reduce(into: 0) { acc, keyword in
                if lowerInput.contains(keyword.lowercased()) {
                    acc += 1
                }
            }
            guard score > 0 else { continue }
            if score > (best?.score ?? 0) {
                best = (rule, score)
            }
        }
        return best?.rule.profileID ?? fallbackProfileID
    }
}
