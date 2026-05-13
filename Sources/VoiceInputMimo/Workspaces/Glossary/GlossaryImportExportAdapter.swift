import AppKit
import Foundation
import UniformTypeIdentifiers

/// Glossary JSON export / import. Mirrors `PromptImportExportAdapter` so
/// Settings code paths look symmetric.
///
/// File format: `{ "entries": [GlossaryEntry, ...] }` — same envelope the
/// store writes to disk. ISO8601 timestamps. Importing merges by `id`:
/// same-id entries are replaced, new ids are appended.
///
/// Only the panel-presenting methods (`exportEntries`, `importEntries`)
/// are `@MainActor`-pinned because AppKit panels must run on the main
/// thread. Pure encode/decode/merge functions stay non-isolated so
/// ViewModels can call them off the main actor.
enum GlossaryImportExportAdapter {

    enum ImportError: Error {
        case decodeFailed(String)
    }

    struct ImportResult {
        let added: Int
        let replaced: Int
    }

    @MainActor
    static func exportEntries(_ entries: [GlossaryEntry],
                              suggestedName: String = "glossary.json") throws -> URL? {
        let panel = NSSavePanel()
        panel.title = "Export Glossary"
        panel.allowedContentTypes = [UTType.json]
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let data = try encode(entries)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Returns the imported entries (decoded from the user-chosen file). Caller
    /// decides how to merge them into the current store.
    @MainActor
    static func importEntries() throws -> [GlossaryEntry]? {
        let panel = NSOpenPanel()
        panel.title = "Import Glossary"
        panel.allowedContentTypes = [UTType.json]
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let data = try Data(contentsOf: url)
        return try decode(data)
    }

    /// Pure merge — `incoming` overwrites `existing` entries with the same id,
    /// otherwise appended. Returned tuple summarises the result for banner UI.
    static func merge(existing: [GlossaryEntry],
                      incoming: [GlossaryEntry]) -> (entries: [GlossaryEntry], result: ImportResult) {
        var byId: [String: GlossaryEntry] = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        var added = 0
        var replaced = 0
        for entry in incoming {
            if byId[entry.id] != nil {
                replaced += 1
            } else {
                added += 1
            }
            byId[entry.id] = entry
        }
        // Stable order: existing entries first (in their original order), then
        // new ids appended in the order they appeared in `incoming`.
        let existingIds = existing.map(\.id)
        let existingOrdered = existingIds.compactMap { byId[$0] }
        let newOrdered = incoming.filter { entry in
            !existingIds.contains(entry.id)
        }
        return (existingOrdered + newOrdered, ImportResult(added: added, replaced: replaced))
    }

    // MARK: - Codec

    private static let encoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return enc
    }()

    private static let decoder: JSONDecoder = {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }()

    private struct Envelope: Codable {
        let entries: [GlossaryEntry]
    }

    static func encode(_ entries: [GlossaryEntry]) throws -> Data {
        try encoder.encode(Envelope(entries: entries))
    }

    static func decode(_ data: Data) throws -> [GlossaryEntry] {
        do {
            return try decoder.decode(Envelope.self, from: data).entries
        } catch {
            // Fallback: accept a top-level array `[GlossaryEntry]` for files
            // hand-edited without the envelope.
            if let array = try? decoder.decode([GlossaryEntry].self, from: data) {
                return array
            }
            throw ImportError.decodeFailed(error.localizedDescription)
        }
    }
}
