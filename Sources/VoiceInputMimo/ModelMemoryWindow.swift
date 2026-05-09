import AppKit

final class ModelMemoryWindow: NSPanel, NSTableViewDataSource, NSTableViewDelegate {
    private var rows: [ModelMemoryRow] = []
    private let table = NSTableView()
    private let statusLabel = NSTextField(labelWithString: "")
    private var timer: Timer?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 320),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        title = "Model Memory"
        isReleasedWhenClosed = false
        minSize = NSSize(width: 560, height: 260)
        setupUI()
        center()
    }

    override func orderOut(_ sender: Any?) {
        stop()
        super.orderOut(sender)
    }

    func showAndStart() {
        makeKeyAndOrderFront(nil)
        if ProcessInfo.processInfo.environment["VOICE_INPUT_MIMO_PREVIEW"] == "1" {
            orderFrontRegardless()
        }
        NSApp.activate(ignoringOtherApps: true)
        refresh()
        start()
    }

    private func setupUI() {
        guard let cv = contentView else { return }

        let title = NSTextField(labelWithString: "App Model Memory")
        title.font = .systemFont(ofSize: 14, weight: .semibold)

        let refreshButton = NSButton(title: "Refresh", target: self, action: #selector(refresh))
        refreshButton.bezelStyle = .rounded

        let header = NSStackView(views: [title, NSView(), refreshButton])
        header.orientation = .horizontal
        header.alignment = .firstBaseline
        header.spacing = 8

        let name = NSTableColumn(identifier: .init("name"))
        name.title = "Model"
        name.width = 180
        let state = NSTableColumn(identifier: .init("state"))
        state.title = "State"
        state.width = 120
        let memory = NSTableColumn(identifier: .init("memory"))
        memory.title = "Memory"
        memory.width = 110
        let detail = NSTableColumn(identifier: .init("detail"))
        detail.title = "Detail"
        detail.width = 230
        [name, state, memory, detail].forEach(table.addTableColumn)
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 28
        table.usesAlternatingRowBackgroundColors = true
        table.style = .inset

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor

        for view in [header, scroll, statusLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            cv.addSubview(view)
        }

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: cv.topAnchor, constant: 16),
            header.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 20),
            header.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -20),

            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -20),

            statusLabel.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            statusLabel.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -20),
            statusLabel.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -14),
        ])
    }

    private func start() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }

    @objc private func refresh() {
        statusLabel.stringValue = "Refreshing..."
        ModelMemoryMonitor.shared.refresh { [weak self] rows in
            self?.rows = rows
            self?.table.reloadData()
            let formatter = DateFormatter()
            formatter.timeStyle = .medium
            self?.statusLabel.stringValue = "Auto-refreshes every 5 seconds · \(formatter.string(from: Date()))"
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, rows.indices.contains(row) else { return nil }
        let id = tableColumn.identifier.rawValue
        let cellID = NSUserInterfaceItemIdentifier("MemoryCell.\(id)")
        let cell: NSTableCellView
        if let recycled = tableView.makeView(withIdentifier: cellID, owner: self) as? NSTableCellView {
            cell = recycled
        } else {
            cell = NSTableCellView()
            cell.identifier = cellID
            let label = NSTextField(labelWithString: "")
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }

        let item = rows[row]
        switch id {
        case "name":
            cell.textField?.stringValue = item.name
        case "state":
            cell.textField?.stringValue = item.state
        case "memory":
            cell.textField?.stringValue = ModelMemoryParser.formatMB(item.primaryMB)
        default:
            cell.textField?.stringValue = item.detail
        }
        return cell
    }
}
