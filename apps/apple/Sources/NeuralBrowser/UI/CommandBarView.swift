// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit

/// The command bar: a floating panel over the window with one text field and
/// a list of suggestions. Enter opens the selected suggestion or resolves the
/// typed text (URL or search). Esc or a click outside dismisses it.
@MainActor
final class CommandBarView: NSView, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    struct Item {
        enum Target {
            case url(String)
            case tab(BrowserTab)
        }
        var title: String
        var subtitle: String
        var symbol: String
        var target: Target
    }

    var provider: ((String) -> [Item])?
    var onSubmit: ((Item?, String, Bool) -> Void)?

    private let panel = NSVisualEffectView()
    private let field = NSTextField()
    private let table = NSTableView()
    private var tableHeight: NSLayoutConstraint!
    private var items: [Item] = []
    private var newTab = false
    private let rowHeight: CGFloat = 38
    private let maxRows = 8

    init() {
        super.init(frame: .zero)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        panel.material = .popover
        panel.state = .active
        panel.wantsLayer = true
        panel.layer?.cornerRadius = 12
        panel.layer?.masksToBounds = true
        panel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 18)
        field.placeholderString = "Search or enter address"
        field.delegate = self
        field.cell?.usesSingleLineMode = true
        field.cell?.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false

        table.addTableColumn(NSTableColumn(identifier: .init("item")))
        table.headerView = nil
        table.rowHeight = rowHeight
        table.backgroundColor = .clear
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        table.translatesAutoresizingMaskIntoConstraints = false

        panel.addSubview(field)
        panel.addSubview(table)
        tableHeight = table.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            panel.centerXAnchor.constraint(equalTo: centerXAnchor),
            panel.topAnchor.constraint(equalTo: topAnchor, constant: 90),
            panel.widthAnchor.constraint(equalToConstant: 620),
            field.topAnchor.constraint(equalTo: panel.topAnchor, constant: 14),
            field.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 16),
            field.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -16),
            table.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 10),
            table.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 6),
            table.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -6),
            table.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -6),
            tableHeight,
        ])
    }

    func present(in parent: NSView, text: String, newTab: Bool) {
        self.newTab = newTab
        if superview !== parent {
            removeFromSuperview()
            frame = parent.bounds
            autoresizingMask = [.width, .height]
            parent.addSubview(self, positioned: .above, relativeTo: nil)
        }
        field.stringValue = text
        reloadItems()
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func dismiss() {
        removeFromSuperview()
    }

    // Clicks outside the panel dismiss the bar.
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if !panel.frame.contains(p) { dismiss() }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.12).setFill()
        dirtyRect.fill()
    }

    private func reloadItems() {
        items = Array((provider?(field.stringValue) ?? []).prefix(maxRows))
        table.reloadData()
        tableHeight.constant = CGFloat(items.count) * (rowHeight + table.intercellSpacing.height)
        if !items.isEmpty { table.selectRowIndexes([], byExtendingSelection: false) }
    }

    private func submit() {
        let row = table.selectedRow
        let item = row >= 0 && row < items.count ? items[row] : nil
        let text = field.stringValue
        let newTab = self.newTab
        dismiss()
        if item != nil || !text.trimmingCharacters(in: .whitespaces).isEmpty {
            onSubmit?(item, text, newTab)
        }
    }

    @objc private func rowClicked() {
        if table.clickedRow >= 0 { submit() }
    }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) { reloadItems() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            submit(); return true
        case #selector(NSResponder.cancelOperation(_:)):
            dismiss(); return true
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(1); return true
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(-1); return true
        default:
            return false
        }
    }

    private func moveSelection(_ delta: Int) {
        guard !items.isEmpty else { return }
        let next = max(-1, min(items.count - 1, table.selectedRow + delta))
        if next < 0 { table.deselectAll(nil) } else { table.selectRowIndexes([next], byExtendingSelection: false) }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        let icon = NSImageView(image: NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)!)
        icon.contentTintColor = .secondaryLabelColor
        let title = NSTextField(labelWithString: item.title)
        title.font = .systemFont(ofSize: 13)
        title.lineBreakMode = .byTruncatingTail
        let subtitle = NSTextField(labelWithString: item.subtitle)
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingMiddle
        let texts = NSStackView(views: [title, subtitle])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 1
        let row = NSStackView(views: [icon, texts])
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        texts.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return row
    }
}
