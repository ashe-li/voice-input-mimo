import Foundation
import Observation

/// MainActor-isolated view model for the Prompts pane (Phase 4). Holds the
/// transient UI state that's local to the editor — currently selected mode
/// and profile, draft of the profile being edited, test panel input/history,
/// and run status. Persistent CRUD goes through `PromptStoreViewModel`.
@MainActor
@Observable
final class PromptsPaneViewModel {
    // Sidebar selection
    var selectedMode: RefineMode = .refine
    var selectedProfileID: String?

    // Test panel
    var testInput: String = "嗯，幫我重構這個函式，把它拆成兩個小一點的"
    var testHistory: [TestEntry] = []
    var isRunning: Bool = false

    // Editor draft — set when sidebar selects a profile, mutated by
    // ProfileEditor, persisted via PromptStoreViewModel.saveProfile.
    var draft: PromptProfile?

    private let refiner: any Refining
    private let maxHistory: Int = 10

    init(refiner: any Refining = LLMRefiner.shared) {
        self.refiner = refiner
    }

    // MARK: - Selection

    /// Pick the first profile of `mode` if no selection exists. Called from
    /// `.task {}` on the pane and on mode picker change.
    func ensureSelection(from store: PromptStoreViewModel) {
        let profiles = store.profiles(for: selectedMode)
        if let id = selectedProfileID, profiles.contains(where: { $0.id == id }) {
            return
        }
        // Prefer the active profile, then first available.
        if let activeID = store.activeProfileID(for: selectedMode),
           let active = profiles.first(where: { $0.id == activeID }) {
            selectedProfileID = active.id
            draft = active
            return
        }
        if let first = profiles.first {
            selectedProfileID = first.id
            draft = first
        } else {
            selectedProfileID = nil
            draft = nil
        }
    }

    func selectProfile(_ profile: PromptProfile) {
        selectedMode = profile.mode
        selectedProfileID = profile.id
        draft = profile
    }

    // MARK: - Draft mutations

    /// Toggle a skill in the draft profile. Builtins ship with curated skills
    /// pre-linked; users can add/remove from the linked set.
    func toggleSkill(_ skillID: String) {
        guard var d = draft else { return }
        if let idx = d.skillIDs.firstIndex(of: skillID) {
            d.skillIDs.remove(at: idx)
        } else {
            d.skillIDs.append(skillID)
        }
        d.updatedAt = Date()
        draft = d
    }

    /// Move a skill within the draft's skill order. Used by drag-reorder in
    /// the editor — order matters because PromptComposer renders skills in
    /// list order.
    func moveSkill(from source: IndexSet, to destination: Int) {
        guard var d = draft else { return }
        d.skillIDs.move(fromOffsets: source, toOffset: destination)
        d.updatedAt = Date()
        draft = d
    }

    // MARK: - Test panel

    /// Run the current draft (or the saved active profile if no draft) against
    /// `testInput` via the injected Refining and append the result to history.
    func runTest() async {
        let input = testInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        let mode = selectedMode
        let profileLabel = draft?.name ?? "<active>"

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            refiner.refine(input, requestId: "", mode: mode, force: true) { [weak self] result in
                Task { @MainActor in
                    guard let self else { continuation.resume(); return }
                    let entry: TestEntry
                    switch result {
                    case .success(let output):
                        entry = TestEntry(
                            timestamp: Date(),
                            profileLabel: profileLabel,
                            mode: mode,
                            input: input,
                            output: output,
                            error: nil
                        )
                    case .failure(let err):
                        entry = TestEntry(
                            timestamp: Date(),
                            profileLabel: profileLabel,
                            mode: mode,
                            input: input,
                            output: "",
                            error: err.localizedDescription
                        )
                    }
                    self.testHistory.insert(entry, at: 0)
                    if self.testHistory.count > self.maxHistory {
                        self.testHistory.removeLast(self.testHistory.count - self.maxHistory)
                    }
                    continuation.resume()
                }
            }
        }
    }

    func clearHistory() {
        testHistory.removeAll()
    }
}

/// One run of the prompt test panel — kept lightweight so up to 10 fit in
/// memory without ceremony.
struct TestEntry: Identifiable, Equatable, Sendable {
    let id: UUID = UUID()
    let timestamp: Date
    let profileLabel: String
    let mode: RefineMode
    let input: String
    let output: String
    let error: String?
}
