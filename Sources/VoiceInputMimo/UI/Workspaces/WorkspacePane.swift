import SwiftUI

/// Two-column workspace layout: a selectable item sidebar (left) plus a
/// caller-driven content panel (right), with an optional render-preview
/// strip pinned to the bottom of the content panel.
///
/// Mirrors the layout used by `PromptsPane`: sidebar fixed at
/// `sidebarWidth` + flexible content area + optional bottom strip. Avoids
/// `NavigationSplitView` because that collapses intrinsic width when
/// nested inside Settings' outer NavigationSplitView — see
/// `wiki/patterns/swiftui-macos-nested-navigationsplitview-collapses-detail.md`.
///
/// Caller owns `items` and `selection`; this view is purely presentational.
/// Sprint-2 workspaces (Glossary / Trace+Clipboard / Workflow Chain)
/// adopt this as a shared base — see plans/active/zerotype-aligned-roadmap.md.
struct WorkspacePane<Item: Identifiable, Row: View, Detail: View, Preview: View>: View {
    let items: [Item]
    @Binding var selection: Item.ID?

    var sidebarWidth: CGFloat = 240
    /// `nil` disables the preview region entirely.
    var previewHeight: CGFloat? = nil

    @ViewBuilder let row: (Item) -> Row
    @ViewBuilder let detail: (Item?) -> Detail
    @ViewBuilder let preview: (Item?) -> Preview

    var onAdd: (() -> Void)? = nil
    var onDelete: ((Item.ID) -> Void)? = nil

    var searchPrompt: String? = nil
    /// When non-nil, sidebar gains a `TextField` search bar that filters
    /// `items` via this predicate against the current query.
    var searchMatch: ((Item, String) -> Bool)? = nil

    @State private var searchText: String = ""

    private var filteredItems: [Item] {
        WorkspacePaneFilter.apply(items: items, query: searchText, match: searchMatch)
    }

    private var selectedItem: Item? {
        items.first(where: { $0.id == selection })
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: sidebarWidth)
            Divider()
            contentArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var sidebar: some View {
        VStack(spacing: 0) {
            if searchMatch != nil {
                TextField(searchPrompt ?? "Search", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
            }
            List(selection: $selection) {
                ForEach(filteredItems) { item in
                    row(item).tag(Optional(item.id))
                }
            }
            .listStyle(.sidebar)

            if onAdd != nil || onDelete != nil {
                HStack(spacing: 6) {
                    if let onAdd {
                        Button(action: onAdd) {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.borderless)
                        .help("Add")
                        .accessibilityLabel("Add item")
                    }
                    if let onDelete {
                        Button {
                            if let id = selection { onDelete(id) }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .disabled(selection == nil)
                        .help("Delete selected")
                        .accessibilityLabel("Delete selected item")
                    }
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
    }

    @ViewBuilder
    private var contentArea: some View {
        VStack(spacing: 0) {
            detail(selectedItem)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let previewHeight {
                Divider()
                preview(selectedItem)
                    .frame(maxWidth: .infinity)
                    .frame(height: previewHeight)
            }
        }
    }
}

// MARK: - No-preview convenience

extension WorkspacePane where Preview == EmptyView {
    init(
        items: [Item],
        selection: Binding<Item.ID?>,
        sidebarWidth: CGFloat = 240,
        @ViewBuilder row: @escaping (Item) -> Row,
        @ViewBuilder detail: @escaping (Item?) -> Detail,
        onAdd: (() -> Void)? = nil,
        onDelete: ((Item.ID) -> Void)? = nil,
        searchPrompt: String? = nil,
        searchMatch: ((Item, String) -> Bool)? = nil
    ) {
        self.items = items
        self._selection = selection
        self.sidebarWidth = sidebarWidth
        self.previewHeight = nil
        self.row = row
        self.detail = detail
        self.preview = { _ in EmptyView() }
        self.onAdd = onAdd
        self.onDelete = onDelete
        self.searchPrompt = searchPrompt
        self.searchMatch = searchMatch
    }
}

// MARK: - Pure filter helper (extracted for unit testing)

/// Pure function — applies the caller's match predicate to filter items
/// by the current search query. Extracted so unit tests can verify search
/// semantics without driving SwiftUI state.
enum WorkspacePaneFilter {
    static func apply<Item>(
        items: [Item],
        query: String,
        match: ((Item, String) -> Bool)?
    ) -> [Item] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard let match, !trimmed.isEmpty else { return items }
        return items.filter { match($0, trimmed) }
    }
}

#if DEBUG

private struct MockEntry: Identifiable, Equatable {
    let id: String
    var spoken: String
    var canonical: String
    var context: String
}

private struct MockWorkspaceDemo: View {
    @State private var entries: [MockEntry] = [
        .init(id: "1", spoken: "vocus", canonical: "vocus", context: "公司名稱，常被誤聽為 focus"),
        .init(id: "2", spoken: "PDT-9624", canonical: "PDT-9624", context: "Linear ticket ID"),
        .init(id: "3", spoken: "Lexical", canonical: "Lexical", context: "編輯器 framework 名稱"),
    ]
    @State private var selection: String? = "1"

    var body: some View {
        WorkspacePane(
            items: entries,
            selection: $selection,
            previewHeight: 160,
            row: { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.spoken).font(.callout)
                    Text(entry.context).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.vertical, 2)
            },
            detail: { selected in
                if let entry = selected, let idx = entries.firstIndex(where: { $0.id == entry.id }) {
                    Form {
                        TextField("Spoken", text: Binding(
                            get: { entries[idx].spoken },
                            set: { entries[idx].spoken = $0 }
                        ))
                        TextField("Canonical", text: Binding(
                            get: { entries[idx].canonical },
                            set: { entries[idx].canonical = $0 }
                        ))
                        TextField("Context", text: Binding(
                            get: { entries[idx].context },
                            set: { entries[idx].context = $0 }
                        ))
                    }
                    .formStyle(.grouped)
                } else {
                    Text("Select an entry").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            },
            preview: { selected in
                if let entry = selected {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Injected prompt fragment").font(.caption).foregroundStyle(.secondary)
                        Text("專有名詞：\(entry.spoken)（正字：\(entry.canonical)）— \(entry.context)")
                            .font(.system(.body, design: .monospaced))
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                    }
                    .padding(12)
                } else {
                    EmptyView()
                }
            },
            onAdd: {
                let id = UUID().uuidString.prefix(4)
                entries.append(.init(id: String(id), spoken: "new term", canonical: "", context: ""))
                selection = String(id)
            },
            onDelete: { id in
                entries.removeAll { $0.id == id }
                selection = entries.first?.id
            },
            searchPrompt: "Search terms",
            searchMatch: { entry, query in
                entry.spoken.localizedCaseInsensitiveContains(query)
                    || entry.context.localizedCaseInsensitiveContains(query)
            }
        )
    }
}

#Preview("WorkspacePane — Mock Glossary") {
    MockWorkspaceDemo()
        .frame(width: 880, height: 520)
}

#endif
