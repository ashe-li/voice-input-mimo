import SwiftUI

/// Hosted both by `ClipboardHistoryWindow` (standalone) and by
/// `HistoryPane` (Settings) — same view tree, different shell. Uses
/// `HSplitView` rather than `NavigationSplitView` because the Settings
/// window already wraps everything in a NavigationSplitView (sidebar
/// listing the panes), and macOS does not lay out nested
/// NavigationSplitViews — the inner detail collapses to ~0 width and
/// cards render as one-character-wide vertical strips.
struct ClipboardHistoryView: View {
    @State private var vm = ClipboardArchiveViewModel()

    var body: some View {
        @Bindable var vm = vm

        VStack(spacing: 0) {
            inlineToolbar(vm: vm)
            HStack(spacing: 0) {
                sidebar(vm: vm)
                    .frame(width: 220)
                Divider()
                detailColumn(vm: vm)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { vm.reload() }
    }

    @ViewBuilder
    private func inlineToolbar(vm: ClipboardArchiveViewModel) -> some View {
        HStack(spacing: 8) {
            Text("Clipboard History").font(.headline)
            Spacer()
            Button {
                vm.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh")

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([vm.archiveURL])
            } label: {
                Image(systemName: "folder")
            }
            .help("Reveal archive in Finder")

            Button(role: .destructive) {
                confirmClear(vm: vm)
            } label: {
                Image(systemName: "trash")
            }
            .disabled(vm.entries.isEmpty)
            .help("Clear all history")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: - Sidebar

    @ViewBuilder
    private func sidebar(vm: ClipboardArchiveViewModel) -> some View {
        @Bindable var vm = vm

        List {
            Section("Kind") {
                ForEach(HistoryKindFilter.allCases, id: \.self) { f in
                    HStack {
                        Image(systemName: icon(for: f))
                            .frame(width: 16)
                        Text(f.label)
                        Spacer()
                        Text("\(vm.count(forKind: f))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { vm.kindFilter = f }
                    .background(vm.kindFilter == f ? Color.accentColor.opacity(0.15) : Color.clear)
                }
            }
            Section("Time") {
                ForEach(HistoryTimeBucket.allCases, id: \.self) { b in
                    HStack {
                        Image(systemName: bucketIcon(for: b))
                            .frame(width: 16)
                        Text(b.label)
                        Spacer()
                        Text("\(vm.count(forBucket: b))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { vm.timeBucket = b }
                    .background(vm.timeBucket == b ? Color.accentColor.opacity(0.15) : Color.clear)
                }
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: - Detail

    @ViewBuilder
    private func detailColumn(vm: ClipboardArchiveViewModel) -> some View {
        @Bindable var vm = vm

        VSplitView {
            ScrollView {
                if vm.filteredEntries.isEmpty {
                    ContentUnavailableView(
                        vm.entries.isEmpty ? "No history yet" : "No matches",
                        systemImage: "doc.on.clipboard",
                        description: Text(
                            vm.entries.isEmpty
                            ? "Voice sessions appear here after each completed dictation."
                            : "Adjust the sidebar filter to see entries."
                        )
                    )
                    .padding(40)
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 280, maximum: 360), spacing: 12)],
                        spacing: 12
                    ) {
                        ForEach(vm.filteredEntries) { item in
                            card(item, isSelected: vm.selectedEntryID == item.id)
                                .contentShape(Rectangle())
                                .onTapGesture { vm.selectedEntryID = item.id }
                                .contextMenu {
                                    Button("Copy to Clipboard") { _ = vm.restore(item) }
                                    Button("Delete", role: .destructive) { vm.delete(item) }
                                }
                        }
                    }
                    .padding(16)
                }
            }
            .frame(minHeight: 200)

            detailPanel(vm: vm)
                .frame(minHeight: 140)
        }
    }

    @ViewBuilder
    private func card(_ item: HistoryEntryViewItem, isSelected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(item.kind.displayName.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(item.kind == .session ? Color.accentColor : Color.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(
                            (item.kind == .session ? Color.accentColor : Color.secondary)
                                .opacity(0.12)
                        )
                    )
                Spacer()
                Text(item.clockLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(item.preview)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
    }

    @ViewBuilder
    private func detailPanel(vm: ClipboardArchiveViewModel) -> some View {
        if let entry = vm.selectedEntry {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(entry.kind.displayName).font(.caption).foregroundStyle(.secondary)
                    Text("·").foregroundStyle(.secondary)
                    Text(entry.clockLabel).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Copy") { _ = vm.restore(entry) }
                        .keyboardShortcut(.defaultAction)
                    Button("Delete", role: .destructive) { vm.delete(entry) }
                        .keyboardShortcut(.delete)
                }
                ScrollView {
                    Text(entry.content)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                if let err = vm.lastError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            }
            .padding(16)
        } else {
            ContentUnavailableView(
                "Pick an entry",
                systemImage: "rectangle.stack",
                description: Text("Tap a card above to see its full content here.")
            )
        }
    }

    // MARK: - Icons

    private func icon(for filter: HistoryKindFilter) -> String {
        switch filter {
        case .all: return "tray.full"
        case .session: return "waveform"
        case .clipboard: return "doc.on.clipboard"
        }
    }

    private func bucketIcon(for bucket: HistoryTimeBucket) -> String {
        switch bucket {
        case .all: return "calendar"
        case .today: return "sun.max"
        case .yesterday: return "moon"
        case .older: return "archivebox"
        }
    }

    // MARK: - Actions

    private func confirmClear(vm: ClipboardArchiveViewModel) {
        let alert = NSAlert()
        alert.messageText = "Clear all clipboard history?"
        alert.informativeText = "This removes all snapshots. The current system clipboard is unaffected."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear All")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            vm.clearAll()
        }
    }
}

#if DEBUG
#Preview("ClipboardHistoryView") {
    ClipboardHistoryView()
        .frame(width: 880, height: 560)
}
#endif
