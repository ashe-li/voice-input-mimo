import SwiftUI

/// Settings → Workspace → Glossary. First real consumer of `WorkspacePane`
/// (Phase 2.0 component). Users manage proper-noun terms that get injected
/// into every LLM call's system prompt — see `GlossaryInjector`.
///
/// Sidebar lists entries; right pane edits the selected entry inline; the
/// bottom strip previews the prompt fragment that will be appended.
struct GlossaryPane: View {
    @State private var model = GlossaryPaneViewModel()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                SectionHeading("Glossary",
                               subtitle: "Proper nouns the LLM should preserve verbatim")
                Spacer()
                if let banner = model.banner {
                    Text(banner)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Button("Import…") { runImport() }
                Button("Export…") { runExport() }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            WorkspacePane(
                items: model.entries,
                selection: Binding(
                    get: { model.selection },
                    set: { model.select($0) }
                ),
                previewHeight: 140,
                row: { entry in
                    GlossaryRow(entry: entry)
                },
                detail: { selected in
                    GlossaryDetail(
                        entry: selected,
                        onChange: { updated in model.commit(updated) }
                    )
                },
                preview: { selected in
                    GlossaryPreview(entry: selected)
                },
                onAdd: { model.addBlank() },
                onDelete: { id in model.delete(id: id) },
                searchPrompt: "Search terms",
                searchMatch: { entry, query in
                    entry.spoken.localizedCaseInsensitiveContains(query)
                        || entry.canonical.localizedCaseInsensitiveContains(query)
                        || entry.context.localizedCaseInsensitiveContains(query)
                }
            )
        }
        .navigationTitle("Glossary")
        .task { model.reload() }
    }

    // MARK: - Import / Export

    private func runExport() {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        do {
            if let url = try GlossaryImportExportAdapter.exportEntries(
                model.entries,
                suggestedName: "glossary-\(stamp).json"
            ) {
                model.banner = "Exported \(model.entries.count) terms to \(url.lastPathComponent)"
            }
        } catch {
            model.banner = "Export failed: \(error.localizedDescription)"
        }
    }

    private func runImport() {
        do {
            guard let incoming = try GlossaryImportExportAdapter.importEntries() else { return }
            model.applyImport(incoming)
        } catch {
            model.banner = "Import failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - Subviews

private struct GlossaryRow: View {
    let entry: GlossaryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(entry.spoken.isEmpty ? "(empty)" : entry.spoken)
                    .font(.callout)
                    .foregroundStyle(entry.spoken.isEmpty ? .secondary : .primary)
                if !entry.canonical.isEmpty, entry.canonical != entry.spoken {
                    Text("→ \(entry.canonical)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if !entry.context.isEmpty {
                Text(entry.context)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct GlossaryDetail: View {
    let entry: GlossaryEntry?
    let onChange: (GlossaryEntry) -> Void

    var body: some View {
        if let entry {
            Form {
                Section {
                    TextField("Spoken (講出來的形式)", text: Binding(
                        get: { entry.spoken },
                        set: { v in var c = entry; c.spoken = v; onChange(c) }
                    ))
                    TextField("Canonical (正字 / 正確寫法)", text: Binding(
                        get: { entry.canonical },
                        set: { v in var c = entry; c.canonical = v; onChange(c) }
                    ))
                    TextField("Context (觸發場景，可選)", text: Binding(
                        get: { entry.context },
                        set: { v in var c = entry; c.context = v; onChange(c) }
                    ))
                } footer: {
                    Text("LLM 會在輸出中遇到「Spoken」的同音 / 同拼字串時，改成「Canonical」。Context 不會送進 LLM，只供使用者自己記錄。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "character.book.closed")
                    .font(.system(size: 32))
                    .foregroundStyle(.tertiary)
                Text("Select a term, or click + to add a new one")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct GlossaryPreview: View {
    let entry: GlossaryEntry?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Injected prompt fragment")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView {
                Text(previewText)
                    .font(.system(.callout, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(12)
    }

    private var previewText: String {
        guard let entry, !entry.spoken.isEmpty, !entry.canonical.isEmpty else {
            return "(尚無內容；填上 Spoken 與 Canonical 後會顯示注入結果)"
        }
        // Show just the bullet line for this entry plus a hint about the header.
        let line = GlossaryInjector.renderLine(entry)
        return """
            \(GlossaryInjector.sectionHeader)
            ...
            \(line)
            """
    }
}

#if DEBUG
#Preview("GlossaryPane") {
    GlossaryPane()
        .frame(width: 880, height: 540)
}
#endif
