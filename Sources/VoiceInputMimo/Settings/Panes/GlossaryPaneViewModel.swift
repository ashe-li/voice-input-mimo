import Foundation
import SwiftUI

/// State container for `GlossaryPane`. Owns the in-memory `entries` array,
/// the currently selected entry ID, and a transient banner message for
/// success / error feedback.
///
/// Every mutating action (`addBlank`, `commit`, `delete`) writes through to
/// `GlossaryStore.shared` immediately — the pane is "live", no separate save
/// button. Reloads from the store after each write to stay in sync with on-
/// disk truth.
@Observable
final class GlossaryPaneViewModel {
    private(set) var entries: [GlossaryEntry] = []
    var selection: String?
    private(set) var banner: String?

    private let store: GlossaryStore

    init(store: GlossaryStore = .shared) {
        self.store = store
    }

    func reload() {
        do {
            entries = try store.loadAll()
            if !entries.contains(where: { $0.id == selection }) {
                selection = entries.first?.id
            }
        } catch {
            banner = "Load failed: \(error.localizedDescription)"
        }
    }

    func select(_ id: String?) {
        selection = id
    }

    func addBlank() {
        let entry = GlossaryEntry(spoken: "", canonical: "", context: "")
        do {
            try store.add(entry)
            entries = try store.loadAll()
            selection = entry.id
            banner = nil
        } catch {
            banner = "Add failed: \(error.localizedDescription)"
        }
    }

    func commit(_ entry: GlossaryEntry) {
        do {
            try store.update(entry)
            entries = try store.loadAll()
            banner = nil
        } catch {
            banner = "Save failed: \(error.localizedDescription)"
        }
    }

    func delete(id: String) {
        do {
            try store.delete(id: id)
            entries = try store.loadAll()
            if !entries.contains(where: { $0.id == selection }) {
                selection = entries.first?.id
            }
            banner = nil
        } catch {
            banner = "Delete failed: \(error.localizedDescription)"
        }
    }
}
