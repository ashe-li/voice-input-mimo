import Foundation
import SwiftUI

/// State container for `ToneMappingPane`. Owns the user's rule list, the
/// available workflows (for the delegate-workflow picker), selection, and
/// a transient banner.
///
/// Every mutating action writes through to `ToneMappingStore.shared` and
/// reloads — on-disk JSON is the source of truth, the in-memory `rules`
/// array is a cache.
@Observable
@MainActor
final class ToneMappingPaneViewModel {
    private(set) var rules: [ToneRule] = []
    private(set) var availableWorkflows: [Workflow] = []
    var selectionIndex: Int?
    var banner: String?

    private let store: ToneMappingStore
    private let workflowStore: WorkflowStore

    init(store: ToneMappingStore = .shared, workflowStore: WorkflowStore = .shared) {
        self.store = store
        self.workflowStore = workflowStore
    }

    var selectedRule: ToneRule? {
        guard let i = selectionIndex, rules.indices.contains(i) else { return nil }
        return rules[i]
    }

    func reload() {
        do {
            rules = try store.loadAll()
            availableWorkflows = (try? workflowStore.loadAll()) ?? []
            if let i = selectionIndex, !rules.indices.contains(i) {
                selectionIndex = rules.indices.first
            }
        } catch {
            banner = "Load failed: \(error.localizedDescription)"
        }
    }

    func select(index: Int?) {
        selectionIndex = index
    }

    func addBlank() {
        let rule = ToneRule(bundleIDPrefix: "com.example.app", delegated: .refine)
        do {
            try store.add(rule)
            rules = try store.loadAll()
            selectionIndex = rules.count - 1
            banner = nil
        } catch {
            banner = "Add failed: \(error.localizedDescription)"
        }
    }

    func commit(at index: Int, rule: ToneRule) {
        do {
            try store.replace(at: index, with: rule)
            rules = try store.loadAll()
            banner = nil
        } catch {
            banner = "Save failed: \(error.localizedDescription)"
        }
    }

    func delete(at index: Int) {
        do {
            try store.delete(at: index)
            rules = try store.loadAll()
            if let i = selectionIndex, !rules.indices.contains(i) {
                selectionIndex = rules.isEmpty ? nil : rules.indices.last
            }
            banner = nil
        } catch {
            banner = "Delete failed: \(error.localizedDescription)"
        }
    }
}
