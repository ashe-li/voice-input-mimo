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

    // MARK: - Mutations (Phase 4 — Prompts pane)

    /// Persist `profile` and refresh the in-memory list for its mode. Used by
    /// the ProfileEditor save action and by the duplicate-profile flow.
    func saveProfile(_ profile: PromptProfile) {
        do {
            try store.saveProfile(profile)
            profilesByMode[profile.mode] = try store.listProfiles(mode: profile.mode)
            lastError = nil
        } catch {
            lastError = error
        }
    }

    /// Remove a profile from disk + the in-memory list. Builtin profiles are
    /// guarded by the store; the resulting `cannotDeleteBuiltin` error
    /// surfaces via `lastError` for the view to render.
    func deleteProfile(id: String, mode: RefineMode) {
        do {
            try store.deleteProfile(id: id, mode: mode)
            profilesByMode[mode] = try store.listProfiles(mode: mode)
            lastError = nil
        } catch {
            lastError = error
        }
    }

    /// Persist `skill` and refresh the in-memory list. Used by SkillsLibrary
    /// (Phase 4B) plus by import/duplicate flows.
    func saveSkill(_ skill: PromptSkill) {
        do {
            try store.saveSkill(skill)
            skills = try store.listSkills()
            lastError = nil
        } catch {
            lastError = error
        }
    }

    /// Remove a skill from disk. Profiles that reference it lose the link
    /// silently — PromptComposer skips unknown skill IDs at render time.
    func deleteSkill(id: String) {
        do {
            try store.deleteSkill(id: id)
            skills = try store.listSkills()
            lastError = nil
        } catch {
            lastError = error
        }
    }

    /// Mark a profile as active for the given mode. Persisted to
    /// `active.json` so the next launch picks it up via PromptMigration.
    func setActiveProfile(id: String, mode: RefineMode) {
        let current = activeSelection ?? ActiveSelection(refineProfileID: "", claudeCodeProfileID: "")
        let updated: ActiveSelection
        switch mode {
        case .refine:
            updated = ActiveSelection(refineProfileID: id, claudeCodeProfileID: current.claudeCodeProfileID)
        case .claudeCode:
            updated = ActiveSelection(refineProfileID: current.refineProfileID, claudeCodeProfileID: id)
        }
        do {
            try store.saveActiveSelection(updated)
            activeSelection = updated
            lastError = nil
        } catch {
            lastError = error
        }
    }

    /// Look up a skill by id — used by ProfileEditor to render the linked
    /// skill chips inline with the profile form.
    func skill(id: String) -> PromptSkill? {
        skills.first { $0.id == id }
    }

    // MARK: - Import / Export (Phase 4B)

    /// Snapshot the current store state into a serializable bundle. Used by
    /// the export flow to write a JSON file via `PromptIO.encode`.
    func exportSnapshot() -> PromptBundle {
        let allProfiles = (profilesByMode[.refine] ?? []) + (profilesByMode[.claudeCode] ?? [])
        return PromptBundle(profiles: allProfiles, skills: skills)
    }

    /// Apply a planned set of profile + skill upserts to the store. Each
    /// record is written via `saveProfile` / `saveSkill`, then `reload()` to
    /// sync the cached state.
    func applyImport(profiles: [PromptProfile], skills: [PromptSkill]) async {
        for profile in profiles {
            do {
                try store.saveProfile(profile)
            } catch {
                lastError = error
            }
        }
        for skill in skills {
            do {
                try store.saveSkill(skill)
            } catch {
                lastError = error
            }
        }
        await reload()
    }
}
