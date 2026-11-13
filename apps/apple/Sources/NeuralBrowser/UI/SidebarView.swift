// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit

/// Left sidebar: navigation buttons, compact address pill (opens the command
/// bar), vertical tab list, downloads and the extension action bar.
@MainActor
final class SidebarView: NSVisualEffectView, NSTableViewDataSource, NSTableViewDelegate {
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onNewTab: (() -> Void)?
    var onAddressClick: (() -> Void)?
    var onBack: (() -> Void)?
    var onForward: (() -> Void)?
    var onReload: (() -> Void)?

    var isPrivate = false {
        didSet { privateBadge.isHidden = !isPrivate }
    }

    private var tabs: [BrowserTab] = []
    private weak var activeTab: BrowserTab?
    private var updatingSelection = false

    private let backButton = SidebarView.iconButton("chevron.left", "Back")
    private let forwardButton = SidebarView.iconButton("chevron.right", "Forward")
    private let reloadButton = SidebarView.iconButton("arrow.clockwise", "Reload")
    private let privateBadge = NSTextField(labelWithString: "Private")
    private let addressButton = AddressPill()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let newTabButton = NSButton(title: "New Tab", image: NSImage(systemSymbolName: "plus", accessibilityDescription: nil)!, target: nil, action: nil)
    private let downloadsStack = NSStackView()
    private let extensionBar = NSStackView()

    init() {
        super.init(frame: .zero)
        material = .sidebar
        blendingMode = .behindWindow
        state = .followsWindowActiveState
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    static func iconButton(_ symbol: String, _ label: String) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!, target: nil, action: nil)
        b.isBordered = false
        b.bezelStyle = .accessoryBarAction
        b.contentTintColor = .secondaryLabelColor
        b.toolTip = label
        b.setContentHuggingPriority(.required, for: .horizontal)
        return b
    }

    private func build() {
        backButton.target = self; backButton.action = #selector(back)
        forwardButton.target = self; forwardButton.action = #selector(forward)
        reloadButton.target = self; reloadButton.action = #selector(reloadPage)
        privateBadge.font = .systemFont(ofSize: 11, weight: .semibold)
        privateBadge.textColor = .systemPurple
        privateBadge.isHidden = true

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let navRow = NSStackView(views: [spacer, privateBadge, backButton, forwardButton, reloadButton])
        navRow.spacing = 6

        addressButton.target = self
        addressButton.action = #selector(addressClicked)

        let column = NSTableColumn(identifier: .init("tab"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .sourceList
        table.rowHeight = 30
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        newTabButton.isBordered = false
        newTabButton.imagePosition = .imageLeading
        newTabButton.contentTintColor = .secondaryLabelColor
        newTabButton.alignment = .left
        newTabButton.target = self
        newTabButton.action = #selector(newTab)

        downloadsStack.orientation = .vertical
        downloadsStack.alignment = .leading
        downloadsStack.spacing = 2
        downloadsStack.isHidden = true

        extensionBar.orientation = .horizontal
        extensionBar.spacing = 6
        extensionBar.isHidden = true

        let stack = NSStackView(views: [navRow, addressButton, scroll, newTabButton, downloadsStack, extensionBar])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        for v in [navRow, addressButton, scroll] as [NSView] {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            navRow.heightAnchor.constraint(equalToConstant: 22),
            addressButton.heightAnchor.constraint(equalToConstant: 28),
        ])
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
    }

    // MARK: Updates

    func setTabs(_ tabs: [BrowserTab], active: BrowserTab?) {
        self.tabs = tabs
        activeTab = active
        updatingSelection = true
        table.reloadData()
        if let active, let i = tabs.firstIndex(of: active) {
            table.selectRowIndexes([i], byExtendingSelection: false)
            table.scrollRowToVisible(i)
        } else {
            table.deselectAll(nil)
        }
        updatingSelection = false
    }

    func reloadTab(at index: Int) {
        guard index < tabs.count else { return }
        table.reloadData(forRowIndexes: [index], columnIndexes: [0])
    }

    func setAddress(_ text: String, secure: Bool, canGoBack: Bool, canGoForward: Bool, loading: Bool) {
        addressButton.set(text: text, secure: secure, loading: loading)
        backButton.isEnabled = canGoBack
        forwardButton.isEnabled = canGoForward
    }

    func setExtensionButtons(_ buttons: [NSView]) {
        extensionBar.arrangedSubviews.forEach { $0.removeFromSuperview() }
        buttons.forEach { extensionBar.addArrangedSubview($0) }
        extensionBar.isHidden = buttons.isEmpty
    }

    func extensionButton(identifier: String) -> NSView? {
        extensionBar.arrangedSubviews.first { $0.identifier?.rawValue == identifier }
    }

    func setDownloads(_ items: [DownloadManager.Item]) {
        downloadsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for item in items.suffix(3) {
            let b = NSButton(title: item.label, target: item, action: #selector(DownloadManager.Item.reveal))
            b.isBordered = false
            b.font = .systemFont(ofSize: 11)
            b.contentTintColor = .secondaryLabelColor
            b.lineBreakMode = .byTruncatingMiddle
            b.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
            b.imagePosition = .imageLeading
            downloadsStack.addArrangedSubview(b)
        }
        downloadsStack.isHidden = items.isEmpty
    }

    // MARK: Actions

    @objc private func back() { onBack?() }
    @objc private func forward() { onForward?() }
    @objc private func reloadPage() { onReload?() }
    @objc private func addressClicked() { onAddressClick?() }
    @objc private func newTab() { onNewTab?() }
    @objc private func closeClicked(_ sender: NSButton) {
        let row = table.row(for: sender)
        if row >= 0 { onClose?(row) }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { tabs.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: TabCellView.identifier, owner: nil) as? TabCellView)
            ?? TabCellView()
        cell.closeButton.target = self
        cell.closeButton.action = #selector(closeClicked(_:))
        cell.configure(with: tabs[row])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !updatingSelection, table.selectedRow >= 0 else { return }
        onSelect?(table.selectedRow)
    }
}

/// One row in the tab list: favicon, title and a close button.
@MainActor
final class TabCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("TabCell")
    let icon = NSImageView()
    let title = NSTextField(labelWithString: "")
    let closeButton = SidebarView.iconButton("xmark", "Close Tab")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        imageView = icon
        textField = title
        title.lineBreakMode = .byTruncatingTail
        title.font = .systemFont(ofSize: 13)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        for v in [icon, title, closeButton] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 4),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(with tab: BrowserTab) {
        title.stringValue = tab.displayTitle
        title.textColor = tab.isAsleep ? .secondaryLabelColor : .labelColor
        icon.image = tab.favicon ?? NSImage(systemSymbolName: tab.isLoading ? "circle.dotted" : "globe",
                                            accessibilityDescription: nil)
        icon.contentTintColor = .secondaryLabelColor
        toolTip = tab.url?.absoluteString
    }
}

/// Compact rounded field showing the current address; clicking opens the command bar.
@MainActor
final class AddressPill: NSButton {
    init() {
        super.init(frame: .zero)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 7
        alignment = .left
        imagePosition = .imageLeading
        lineBreakMode = .byTruncatingTail
        font = .systemFont(ofSize: 12)
        contentTintColor = .secondaryLabelColor
        toolTip = "Search or enter address (⌘L)"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.12).cgColor
    }

    func set(text: String, secure: Bool, loading: Bool) {
        title = " " + text
        let symbol = loading ? "circle.dotted" : (secure ? "lock.fill" : "magnifyingglass")
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        needsDisplay = true
    }
}
