import Foundation
import Observation

/// MainActor-isolated `@Observable` adapter that bridges the on-disk PromptStore
/// to SwiftUI views via `.environment(_:)` injection.
///
/// Views never call `PromptStore` directly — they read derived state off this
/// view model. All mutations (CRUD on profiles / skills / active selection)
/// flow through methods on this class, which then call back into the store and
/// re-publish updated state.
///
/// Phase 2 v1: store reads happen synchronously on the main actor. Acceptable
/// for current data sizes (≤10 profiles, ≤16 skills). Phase v1.5 ticket:
/// migrate `PromptStore` to a proper actor and make `reload()` truly async.
@MainActor
@Observable
final class PromptStoreViewModel {
    static let shared = PromptStoreViewModel()

    private(set) var profilesByMode: [RefineMode: [PromptProfile]] = [:]
    private(set) var skills: [PromptSkill] = []
    private(set) var activeSelection: ActiveSelection?
    private(set) var isLoading: Bool = false
    private(set) var lastError: Error?

    private let store: any PromptStoreProviding

    init(store: any PromptStoreProviding = PromptStore.shared) {
        self.store = store
    }

    /// Reload all derived state from the underlying store. Call from view
    /// `.task {}` modifier on appearance, after a CRUD mutation, or after the
    /// migration bootstrap.
    func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            profilesByMode[.refine] = try store.listProfiles(mode: .refine)
            profilesByMode[.claudeCode] = try store.listProfiles(mode: .claudeCode)
            skills = try store.listSkills()
            activeSelection = try store.loadActiveSelection()
            lastError = nil
        } catch {
            lastError = error
        }
    }

    func profiles(for mode: RefineMode) -> [PromptProfile] {
        profilesByMode[mode] ?? []
    }

    func activeProfileID(for mode: RefineMode) -> String? {
        switch mode {
        case .refine: return activeSelection?.refineProfileID
        case .claudeCode: return activeSelection?.claudeCodeProfileID
        }
    }

    func clearError() {
        lastError = nil
    }
}
