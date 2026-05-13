import Foundation

/// Pure function that appends a "Glossary" section to a system prompt
/// listing user-extensible domain terms (proper nouns, ticket IDs,
/// internal codenames). The LLM is asked to preserve the canonical
/// spelling exactly when it appears in user input.
///
/// Empty entries → returns the original prompt unchanged (no decorative
/// header). This keeps prompts minimal when the user hasn't added any
/// terms yet.
enum GlossaryInjector {
    static let sectionHeader = "## Glossary (專有名詞清單)"

    static let instruction = """
        以下為使用者定義的專有名詞。在輸出中遇到相同發音 / 拼音的字串時，
        必須使用「正字」欄位的寫法，不要改成同音字或翻譯成英文（除非該欄位
        本身就是英文）。
        """

    /// Compose the system prompt with an appended glossary section.
    /// - Parameters:
    ///   - systemPrompt: the base prompt from the active profile / catalog
    ///   - entries: zero or more glossary entries (already loaded by caller)
    /// - Returns: the prompt with a `## Glossary` section appended, or the
    ///   original prompt if `entries` is empty.
    static func inject(systemPrompt: String, entries: [GlossaryEntry]) -> String {
        let nonEmpty = entries.filter { !$0.spoken.isEmpty && !$0.canonical.isEmpty }
        guard !nonEmpty.isEmpty else { return systemPrompt }

        let lines = nonEmpty.map { renderLine($0) }
        let block = """
            \(sectionHeader)

            \(instruction)

            \(lines.joined(separator: "\n"))
            """

        // Single blank line separator between profile prompt and glossary.
        return systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            + "\n\n"
            + block
    }

    /// Render one entry as a bullet line. Includes context only when set.
    static func renderLine(_ entry: GlossaryEntry) -> String {
        let trimmedContext = entry.context.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedContext.isEmpty {
            return "- \(entry.spoken) → \(entry.canonical)"
        }
        return "- \(entry.spoken) → \(entry.canonical)（\(trimmedContext)）"
    }
}
