import Foundation

enum SkillCategory: String, Codable, CaseIterable {
    case recovery
    case style
    case format
    case domain
    case speechAct
}

struct PromptSkill: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var category: SkillCategory
    var content: String
    var slot: String?
    var description: String?
    var isBuiltin: Bool

    init(
        id: String,
        name: String,
        category: SkillCategory,
        content: String,
        slot: String? = nil,
        description: String? = nil,
        isBuiltin: Bool = false
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.content = content
        self.slot = slot
        self.description = description
        self.isBuiltin = isBuiltin
    }
}

struct PromptProfile: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var mode: RefineMode
    var basePrompt: String
    var skillIDs: [String]
    var suffix: String?
    var modelOverride: String?
    var temperature: Double?
    var displayLabel: String?
    var slotOverrides: [String: String]?
    var createdAt: Date
    var updatedAt: Date
    var isBuiltin: Bool

    init(
        id: String,
        name: String,
        mode: RefineMode,
        basePrompt: String,
        skillIDs: [String],
        suffix: String? = nil,
        modelOverride: String? = nil,
        temperature: Double? = nil,
        displayLabel: String? = nil,
        slotOverrides: [String: String]? = nil,
        createdAt: Date,
        updatedAt: Date,
        isBuiltin: Bool = false
    ) {
        self.id = id
        self.name = name
        self.mode = mode
        self.basePrompt = basePrompt
        self.skillIDs = skillIDs
        self.suffix = suffix
        self.modelOverride = modelOverride
        self.temperature = temperature
        self.displayLabel = displayLabel
        self.slotOverrides = slotOverrides
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isBuiltin = isBuiltin
    }
}

struct ActiveSelection: Codable, Equatable {
    var refineProfileID: String
    var claudeCodeProfileID: String

    init(refineProfileID: String, claudeCodeProfileID: String) {
        self.refineProfileID = refineProfileID
        self.claudeCodeProfileID = claudeCodeProfileID
    }
}
