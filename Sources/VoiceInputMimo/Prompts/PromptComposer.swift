import Foundation

enum PromptComposer {

    /// Append-mode rendering: basePrompt + each enabled skill (separated by a blank line).
    /// Skills missing from `skills` or whose content is whitespace-only are silently skipped.
    static func render(profile: PromptProfile, skills: [PromptSkill]) -> String {
        let lookup = Dictionary(uniqueKeysWithValues: skills.map { ($0.id, $0) })

        var sections: [String] = []
        let trimmedBase = profile.basePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedBase.isEmpty {
            sections.append(trimmedBase)
        }
        for skillID in profile.skillIDs {
            guard let skill = lookup[skillID] else { continue }
            let trimmed = skill.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            sections.append(trimmed)
        }
        return sections.joined(separator: "\n\n")
    }

    /// Cheap token estimate: ceil(chars / 4). v1 approximation; v1.5 will swap to a real tokenizer.
    static func estimateTokenCount(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return (text.count + 3) / 4
    }
}
