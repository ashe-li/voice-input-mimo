import SwiftUI

/// Hosted both by `ClipboardHistoryWindow` (standalone) and by `HistoryPane`
/// (Settings → History) — same view, different shell.
///
/// Layout discipline (after three failed attempts with SplitView nests):
///
/// - **No NavigationSplitView / HSplitView / VSplitView anywhere inside this
///   view.** Settings already wraps its detail in a NavigationSplitView, so
///   any inner split would compete for the same width budget and the inner
///   detail collapses toward 0px. The standalone window doesn't need split
///   chrome either — a single list with top filters is sufficient.
/// - **A single `List` is the most reliable SwiftUI macOS layout primitive.**
///   It computes its own width from the host context and never collapses.
/// - Filters live in a top toolbar (segmented Pickers), not a sibling sidebar
///   list, so there's only ever one List in the view tree.
/// - Selecting a row reveals an inline detail strip below the list (fixed
///   height, scrollable) — no popover, no sheet, no second split.
struct ClipboardHistoryView: View {
    @State private var vm = ClipboardArchiveViewModel()

    var body: some View {
        @Bindable var vm = vm

        VStack(spacing: 0) {
            topToolbar(vm: vm)
            Divider()
            filterBar(vm: vm)
            Divider()
            mainList(vm: vm)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if vm.selectedEntry != nil {
                Divider()
                detailStrip(vm: vm)
                    .frame(height: 180)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { vm.reload() }
    }

    // MARK: - Top toolbar

    @ViewBuilder
    private func topToolbar(vm: ClipboardArchiveViewModel) -> some View {
        HStack(spacing: 8) {
            Text("Clipboard History")
                .font(.headline)
            Text("\(vm.entries.count) entries")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button { vm.reload() } label: { Image(systemName: "arrow.clockwise") }
                .help("Refresh")
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([vm.archiveURL])
            } label: { Image(systemName: "folder") }
                .help("Reveal archive in Finder")
            Button(role: .destructive) {
                confirmClear(vm: vm)
            } label: { Image(systemName: "trash") }
                .disabled(vm.entries.isEmpty)
                .help("Clear all history")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    // MARK: - Filter bar (replaces the broken inner sidebar)

    @ViewBuilder
    private func filterBar(vm: ClipboardArchiveViewModel) -> some View {
        @Bindable var vm = vm

        HStack(spacing: 16) {
            HStack(spacing: 6) {
                Text("Kind").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $vm.kindFilter) {
                    ForEach(HistoryKindFilter.allCases, id: \.self) { f in
                        Text("\(f.label) (\(vm.count(forKind: f)))").tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            HStack(spacing: 6) {
                Text("Time").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $vm.timeBucket) {
                    ForEach(HistoryTimeBucket.allCases, id: \.self) { b in
                        Text("\(b.label) (\(vm.count(forBucket: b)))").tag(b)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Main list

    @ViewBuilder
    private func mainList(vm: ClipboardArchiveViewModel) -> some View {
        @Bindable var vm = vm

        if vm.filteredEntries.isEmpty {
            ContentUnavailableView(
                vm.entries.isEmpty ? "No history yet" : "No matches",
                systemImage: "doc.on.clipboard",
                description: Text(
                    vm.entries.isEmpty
                    ? "Voice sessions appear here after each completed dictation."
                    : "Adjust the filters above to see entries."
                )
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: $vm.selectedEntryID) {
                ForEach(vm.filteredEntries) { item in
                    row(item)
                        .tag(item.id)
                        .contextMenu {
                            Button("Copy to Clipboard") { _ = vm.restore(item) }
                            Button("Delete", role: .destructive) { vm.delete(item) }
                        }
                }
            }
            .listStyle(.inset)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func row(_ item: HistoryEntryViewItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: kindIcon(item.kind))
                .frame(width: 18, alignment: .center)
                .foregroundStyle(item.kind == .session ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.kind.displayName.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(item.kind == .session ? Color.accentColor : Color.secondary)
                    Text(item.clockLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(item.preview)
                    .font(.body)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .foregroundStyle(.primary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Inline detail strip

    @ViewBuilder
    private func detailStrip(vm: ClipboardArchiveViewModel) -> some View {
        @Bindable var vm = vm

        if let entry = vm.selectedEntry {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(entry.kind.displayName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(entry.kind == .session ? Color.accentColor : Color.secondary)
                    Text("·").foregroundStyle(.secondary)
                    Text(entry.clockLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let traceId = entry.traceId {
                        Text("·").foregroundStyle(.secondary)
                        Text("Trace: \(traceId)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .help("Linked TraceEntry id")
                    }
                    Spacer()
                    Button("Copy") { _ = vm.restore(entry) }
                        .keyboardShortcut(.defaultAction)
                    Button(role: .destructive) {
                        vm.delete(entry)
                    } label: { Image(systemName: "trash") }
                        .keyboardShortcut(.delete)
                    Button {
                        vm.selectedEntryID = nil
                    } label: { Image(systemName: "xmark") }
                        .help("Close detail")
                }
                ScrollView {
                    Text(entry.content)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(.vertical, 4)
                }
                if let err = vm.lastError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.bar)
        }
    }

    // MARK: - Helpers

    private func kindIcon(_ kind: ClipboardArchive.EntryKind) -> String {
        switch kind {
        case .session: return "waveform"
        case .clipboard: return "doc.on.clipboard"
        }
    }

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
