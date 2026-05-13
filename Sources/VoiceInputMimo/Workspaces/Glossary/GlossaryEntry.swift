import Foundation

/// A single user-extensible glossary term — what the speaker says vs. how
/// it should appear in writing, plus an optional contextual note.
///
/// Stored as part of `GlossaryStore`'s single JSON file under
/// `~/Library/Application Support/VoiceInputMimo/workspaces/glossary/default.json`.
/// The store owns persistence; this type is pure data.
struct GlossaryEntry: Codable, Identifiable, Equatable, Hashable {
    let id: String
    var spoken: String
    var canonical: String
    var context: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: String = "term-\(UUID().uuidString.prefix(8))",
        spoken: String,
        canonical: String,
        context: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.spoken = spoken
        self.canonical = canonical
        self.context = context
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
