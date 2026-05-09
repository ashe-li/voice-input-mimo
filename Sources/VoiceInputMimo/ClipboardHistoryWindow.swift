import AppKit

/// Browsable + interactive view over `ClipboardArchive`.
///
/// Layout (top → bottom):
///   • Toolbar row:  Refresh · Reveal in Finder · Clear All
///   • Content:
///       — Left  : visible NSTableView of entries (newest first)
///       — Right : NSTextView showing full content of selected entry
///   • Action row:  Copy · Delete · status label
final class ClipboardHistoryWindow: NSPanel, NSTableViewDataSource, NSTableViewDelegate {
    private var entries: [ClipboardArchive.Entry] = []

    private let table = NSTableView()
    private let detailView = NSTextView()
    private let detailScroll = NSScrollView()
    private let statusLabel = NSTextField(labelWithString: "")

    private let copyButton = NSButton(title: "Copy", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Delete", target: nil, action: nil)
    private let clearButton = NSButton(title: "Clear All", target: nil, action: nil)

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        title = "Clipboard History"
        isReleasedWhenClosed = false
        titlebarAppearsTransparent = false
        titleVisibility = .visible
        toolbarStyle = .unified
        minSize = NSSize(width: 720, height: 420)

        if let cv = contentView {
            cv.wantsLayer = true
            let visualEffect = NSVisualEffectView(frame: cv.bounds)
            visualEffect.autoresizingMask = [.width, .height]
            visualEffect.material = .windowBackground
            visualEffect.blendingMode = .behindWindow
            visualEffect.state = .active
            cv.addSubview(visualEffect, positioned: .below, relativeTo: nil)
        }

        setupUI()
        reload()
        center()
    }

    // MARK: - UI

    private func setupUI() {
        guard let cv = contentView else { return }

        // Title row
        let header = NSStackView()
        header.orientation = .horizontal
        header.spacing = 8
        header.alignment = .firstBaseline
        if let img = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil) {
            let iv = NSImageView(image: img)
            iv.contentTintColor = .controlAccentColor
            iv.symbolConfiguration = .init(pointSize: 14, weight: .semibold)
            header.addArrangedSubview(iv)
        }
        let titleLabel = NSTextField(labelWithString: "Voice Sessions & Clipboard Snapshots")
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        header.addArrangedSubview(titleLabel)
        header.addArrangedSubview(NSView())  // spacer

        let refreshButton = NSButton(title: "Refresh", target: self, action: #selector(reload))
        refreshButton.bezelStyle = .rounded
        let revealButton = NSButton(title: "Reveal in Finder", target: self, action: #selector(revealInFinder))
        revealButton.bezelStyle = .rounded
        clearButton.target = self
        clearButton.action = #selector(clearAll)
        clearButton.bezelStyle = .rounded
        header.addArrangedSubview(refreshButton)
        header.addArrangedSubview(revealButton)
        header.addArrangedSubview(clearButton)

        // Table
        let kindColumn = NSTableColumn(identifier: .init("kind"))
        kindColumn.title = "Type"
        kindColumn.width = 112
        kindColumn.minWidth = 96
        let timeColumn = NSTableColumn(identifier: .init("time"))
        timeColumn.title = "Time"
        timeColumn.width = 108
        timeColumn.minWidth = 96
        let previewColumn = NSTableColumn(identifier: .init("preview"))
        previewColumn.title = "Preview"
        previewColumn.width = 220
        previewColumn.minWidth = 160
        table.addTableColumn(kindColumn)
        table.addTableColumn(timeColumn)
        table.addTableColumn(previewColumn)
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 28
        table.usesAlternatingRowBackgroundColors = true
        table.style = .inset
        table.target = self
        table.doubleAction = #selector(copySelected)
        table.allowsMultipleSelection = false

        let tableScroll = NSScrollView()
        tableScroll.documentView = table
        tableScroll.hasVerticalScroller = true
        tableScroll.borderType = .noBorder
        tableScroll.translatesAutoresizingMaskIntoConstraints = false
        tableScroll.drawsBackground = false

        // Detail (read-only NSTextView)
        detailView.isEditable = false
        detailView.isRichText = false
        detailView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        detailView.textContainerInset = NSSize(width: 8, height: 8)
        detailView.drawsBackground = false
        detailScroll.documentView = detailView
        detailScroll.hasVerticalScroller = true
        detailScroll.borderType = .lineBorder
        detailScroll.translatesAutoresizingMaskIntoConstraints = false
        detailScroll.drawsBackground = false

        let contentRow = NSStackView(views: [tableScroll, detailScroll])
        contentRow.orientation = .horizontal
        contentRow.alignment = .top
        contentRow.spacing = 12
        contentRow.distribution = .fill
        contentRow.translatesAutoresizingMaskIntoConstraints = false
        tableScroll.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        detailScroll.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // Bottom row
        copyButton.target = self
        copyButton.action = #selector(copySelected)
        copyButton.bezelStyle = .rounded
        copyButton.keyEquivalent = "\r"
        if #available(macOS 14, *) { copyButton.bezelColor = .controlAccentColor }

        deleteButton.target = self
        deleteButton.action = #selector(deleteSelected)
        deleteButton.bezelStyle = .rounded
        deleteButton.keyEquivalent = "\u{8}"  // Backspace

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let bottom = NSStackView(views: [statusLabel, deleteButton, copyButton])
        bottom.orientation = .horizontal
        bottom.spacing = 8
        bottom.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        for sub in [header, contentRow, bottom] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            cv.addSubview(sub)
        }

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: cv.topAnchor, constant: 16),
            header.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 20),
            header.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -20),

            contentRow.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            contentRow.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 20),
            contentRow.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -20),
            tableScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 360),
            tableScroll.widthAnchor.constraint(lessThanOrEqualTo: cv.widthAnchor, multiplier: 0.58),
            detailScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 300),

            bottom.topAnchor.constraint(equalTo: contentRow.bottomAnchor, constant: 12),
            bottom.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 20),
            bottom.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -20),
            bottom.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -16),
        ])
        updateButtonsEnabled()
    }

    // MARK: - Data

    @objc private func reload() {
        entries = ClipboardArchive.shared.entries()
        table.reloadData()
        updateButtonsEnabled()
        if entries.isEmpty {
            detailView.string = ""
            statusLabel.stringValue = "No entries yet. Voice sessions appear here after each completed dictation."
        } else {
            statusLabel.stringValue = "\(entries.count) entr\(entries.count == 1 ? "y" : "ies")"
            // Auto-select first row
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    private func updateButtonsEnabled() {
        let hasSelection = table.selectedRow >= 0 && table.selectedRow < entries.count
        copyButton.isEnabled = hasSelection
        deleteButton.isEnabled = hasSelection
        clearButton.isEnabled = !entries.isEmpty
    }

    // MARK: - Actions

    @objc private func copySelected() {
        let row = table.selectedRow
        guard row >= 0, row < entries.count else { return }
        if ClipboardArchive.shared.restore(at: row) {
            let preview = entries[row].preview
            paint(success: true, "Copied: \(preview.prefix(60))…")
        } else {
            paint(success: false, "Copy failed")
        }
    }

    @objc private func deleteSelected() {
        let row = table.selectedRow
        guard row >= 0, row < entries.count else { return }
        let preview = entries[row].preview.prefix(60)
        ClipboardArchive.shared.delete(at: row)
        reload()
        paint(success: nil, "Deleted: \(preview)…")
    }

    @objc private func clearAll() {
        let alert = NSAlert()
        alert.messageText = "Clear all clipboard history?"
        alert.informativeText = "This removes all snapshots. The current system clipboard is unaffected."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear All")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            ClipboardArchive.shared.clear()
            reload()
            paint(success: nil, "History cleared.")
        }
    }

    @objc private func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([ClipboardArchive.shared.archiveURL])
    }

    private func paint(success: Bool?, _ text: String) {
        statusLabel.stringValue = text
        switch success {
        case .some(true):  statusLabel.textColor = .systemGreen
        case .some(false): statusLabel.textColor = .systemRed
        case .none:        statusLabel.textColor = .secondaryLabelColor
        }
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn, row < entries.count else { return nil }
        let entry = entries[row]
        let id = column.identifier.rawValue

        let cellID = NSUserInterfaceItemIdentifier("Cell.\(id)")
        let cell: NSTableCellView
        if let recycled = tableView.makeView(withIdentifier: cellID, owner: self) as? NSTableCellView {
            cell = recycled
        } else {
            cell = NSTableCellView()
            cell.identifier = cellID
            let tf = NSTextField(labelWithString: "")
            tf.font = id == "time"
                ? .monospacedSystemFont(ofSize: 11, weight: .regular)
                : .systemFont(ofSize: 12)
            tf.lineBreakMode = .byTruncatingTail
            tf.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(tf)
            cell.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        switch id {
        case "kind":
            cell.textField?.stringValue = entry.kind.displayName
            cell.textField?.textColor = entry.kind == .session ? .controlAccentColor : .secondaryLabelColor
        case "time":
            cell.textField?.stringValue = Self.formatStamp(entry.timestamp)
            cell.textField?.textColor = .secondaryLabelColor
        default:
            cell.textField?.stringValue = entry.preview
            cell.textField?.textColor = .labelColor
        }
        return cell
    }

    // MARK: - NSTableViewDelegate

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        if row >= 0, row < entries.count {
            detailView.string = entries[row].content
        } else {
            detailView.string = ""
        }
        updateButtonsEnabled()
    }

    // MARK: - Helpers

    private static func formatStamp(_ iso: String) -> String {
        let parser = ISO8601DateFormatter()
        guard let date = parser.date(from: iso) else { return iso }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d, HH:mm:ss"
        return f.string(from: date)
    }
}
