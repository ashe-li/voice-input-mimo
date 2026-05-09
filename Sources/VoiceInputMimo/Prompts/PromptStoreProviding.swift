import Foundation

/// Abstraction over the on-disk prompt store so SwiftUI views, view models, and
/// tests can be wired against in-memory mocks without touching Application Support.
///
/// PromptStore is the production conformer. Tests inject a fixture conformer and
/// assert against captured state without going through the file system.
protocol PromptStoreProviding: Sendable {
    func saveProfile(_ profile: PromptProfile) throws
    func loadProfile(id: String, mode: RefineMode) throws -> PromptProfile?
    func listProfiles(mode: RefineMode) throws -> [PromptProfile]
    func deleteProfile(id: String, mode: RefineMode) throws

    func saveSkill(_ skill: PromptSkill) throws
    func loadSkill(id: String) throws -> PromptSkill?
    func listSkills() throws -> [PromptSkill]
    func deleteSkill(id: String) throws

    func loadActiveSelection() throws -> ActiveSelection?
    func saveActiveSelection(_ selection: ActiveSelection) throws
    func activeProfile(for mode: RefineMode) throws -> PromptProfile?
}
