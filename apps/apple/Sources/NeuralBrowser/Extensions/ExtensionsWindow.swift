// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import ExtensionTranslator
import UniformTypeIdentifiers
import WebKit

/// Plain-language summary of an installed extension: rights, what the translator
/// changed and what will probably not work. Shown before enabling and in Details.
enum ExtensionSummary {
    static func text(_ r: InstallRecord) -> String {
        var lines: [String] = []
        let file = (r.source.path as NSString).lastPathComponent
        lines.append("Version \(r.version) · Manifest V\(r.manifestVersion) · from \(file) (\(r.source.kind))")
        lines.append("SHA-256 \(r.sha256.prefix(16))…")
        lines.append("")
        lines.append("Permissions: \(r.permissions.isEmpty ? "none" : r.permissions.joined(separator: ", "))")
        let hosts = r.hostPermissions
        lines.append("Websites: \(hosts.isEmpty ? "none" : hosts.joined(separator: ", "))")
        if hosts.contains(where: { $0 == "<all_urls>" || $0.hasPrefix("*://*/") || $0.hasPrefix("https://*/") || $0.hasPrefix("http://*/") }) {
            lines.append("⚠︎ This extension can read and change every website you visit.")
        }

        let changes = r.translation.changes
        lines.append("")
        if changes.isEmpty {
            lines.append("Not changed by the translator.")
        } else {
            lines.append("Changed so it runs in this browser (translator rules v\(r.ruleSetVersion)):")
            for hit in changes {
                let title = RuleSet.all.first { $0.id == hit.rule }?.title ?? hit.rule
                let detail = hit.details.prefix(3).joined(separator: "; ") + (hit.details.count > 3 ? "; …" : "")
                lines.append("• \(title) (\(hit.count)×)\(detail.isEmpty ? "" : ": \(detail)")")
            }
        }
        let issues = r.translation.issues
        let notWorking = issues.filter { $0.severity == .broken || $0.severity == .missing }
        let stubbed = issues.filter { $0.severity == .stubbed }
        let ignored = issues.filter { $0.severity == .ignored }
        if !notWorking.isEmpty {
            lines.append("")
            lines.append("Will probably not work:")
            notWorking.forEach { lines.append("• \($0.severity == .broken ? "Main feature: " : "")\($0.text)") }
        }
        if !stubbed.isEmpty {
            lines.append("")
            lines.append("Replaced by stand-ins that do nothing:")
            stubbed.forEach { lines.append("• \($0.text)") }
        }
        if !ignored.isEmpty {
            lines.append("")
            lines.append("Ignored: " + ignored.map { $0.feature.replacingOccurrences(of: "manifest key ", with: "") }.joined(separator: ", "))
        }
        if !r.translation.warnings.isEmpty {
            lines.append("")
            r.translation.warnings.forEach { lines.append("Note: \($0)") }
        }
        lines.append("")
        lines.append("Extensions are always off in private windows. This is an estimate from the manifest, not a test.")
        return lines.joined(separator: "\n")
    }

    /// A scrollable, selectable text block for alerts.
    static func accessory(_ text: String) -> NSView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: 260))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let view = NSTextView(frame: scroll.bounds)
        view.isEditable = false
        view.isSelectable = true
        view.font = .systemFont(ofSize: 12)
        view.string = text
        view.textContainerInset = NSSize(width: 6, height: 6)
        view.autoresizingMask = [.width]
        scroll.documentView = view
        return scroll
    }
}

/// File ▸ Install Extension…: choose a package, unpack and translate it to a pending
/// folder, show what it asks for and what will not work, and only then enable it.
@MainActor
enum ExtensionInstallFlow {
    static func run(manager: ExtensionManager, extensionsDir: URL, completion: @escaping () -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.zip, .folder, UTType(filenameExtension: "crx") ?? .data]
        panel.message = "Choose an extension: a folder with manifest.json, a .zip or a .crx file."
        panel.prompt = "Install"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        install(url, manager: manager, extensionsDir: extensionsDir, completion: completion)
    }

    static func install(_ url: URL, manager: ExtensionManager, extensionsDir: URL, completion: @escaping () -> Void) {
        let pending = extensionsDir.appendingPathComponent(".pending-\(UUID().uuidString)", isDirectory: true)
        Task.detached {
            let result = Result { try Installer.install(from: url, into: pending) }
            await MainActor.run {
                defer { try? FileManager.default.removeItem(at: pending); completion() }
                switch result {
                case .failure(let error):
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = "The extension could not be installed"
                    alert.informativeText = "\(error)"
                    alert.runModal()
                case .success(let record):
                    let alert = NSAlert()
                    alert.messageText = "Install “\(record.name)”?"
                    alert.informativeText = "Check what it may do before you enable it."
                    alert.accessoryView = ExtensionSummary.accessory(ExtensionSummary.text(record))
                    alert.addButton(withTitle: "Install and Enable")
                    alert.addButton(withTitle: "Cancel")
                    guard alert.runModal() == .alertFirstButtonReturn else { return }
                    do {
                        manager.unload(id: record.id) // an update replaces a loaded version
                        try Installer.move(pending.appendingPathComponent(record.id), into: extensionsDir, id: record.id)
                        manager.rememberGrant(id: record.id, granted: true)
                        Task { await manager.setEnabled(true, id: record.id, in: extensionsDir) }
                    } catch {
                        let fail = NSAlert()
                        fail.messageText = "The extension could not be installed"
                        fail.informativeText = "\(error)"
                        fail.runModal()
                    }
                }
            }
        }
    }
}

/// Extensions window: list, on/off, details, re-translate, remove.
@MainActor
final class ExtensionsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private struct Row {
        let id: String
        let folder: URL
        let record: InstallRecord?
        let name: String
    }

    private let manager: ExtensionManager
    private let extensionsDir: URL
    private let table = NSTableView()
    private var rows: [Row] = []
    private var buttons: [NSButton] = []

    init(manager: ExtensionManager, extensionsDir: URL) {
        self.manager = manager
        self.extensionsDir = extensionsDir
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Extensions"
        window.minSize = NSSize(width: 520, height: 240)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        build()
        window.center()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func build() {
        guard let content = window?.contentView else { return }
        for (id, title, width) in [("on", "On", 36.0), ("name", "Name", 220.0), ("version", "Version", 90.0), ("status", "Translation", 250.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.doubleAction = #selector(details(_:))
        table.target = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scroll)

        let make = { (title: String, action: Selector) -> NSButton in
            let b = NSButton(title: title, target: self, action: action)
            b.bezelStyle = .rounded
            return b
        }
        let install = make("Install…", #selector(install(_:)))
        let details = make("Details…", #selector(details(_:)))
        let retranslate = make("Re-translate", #selector(retranslate(_:)))
        let remove = make("Remove", #selector(remove(_:)))
        buttons = [details, retranslate, remove]
        let bar = NSStackView(views: [install, NSView(), details, retranslate, remove])
        bar.orientation = .horizontal
        bar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(bar)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            bar.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
        updateButtons()
    }

    func reload() {
        rows = ExtensionManager.extensionFolders(in: extensionsDir).map { folder in
            let record = Installer.record(in: folder)
            return Row(id: folder.lastPathComponent, folder: folder, record: record, name: record?.name ?? folder.lastPathComponent)
        }
        table.reloadData()
        updateButtons()
    }

    private var selected: Row? { table.selectedRow >= 0 && table.selectedRow < rows.count ? rows[table.selectedRow] : nil }

    private func updateButtons() {
        buttons.forEach { $0.isEnabled = selected != nil }
        if let row = selected { buttons[1].isEnabled = row.record != nil } // plain unpacked folders have no original/
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row index: Int) -> NSView? {
        let row = rows[index]
        switch column?.identifier.rawValue {
        case "on":
            let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggle(_:)))
            box.state = manager.isEnabled(id: row.id) ? .on : .off
            box.tag = index
            return box
        case "name": return label(row.name)
        case "version": return label(row.record?.version ?? "–")
        default:
            guard let r = row.record else { return label("unpacked folder, not translated") }
            let notWorking = r.translation.issues.filter { $0.severity == .broken || $0.severity == .missing }.count
            let changes = r.translation.changes.reduce(0) { $0 + $1.count }
            return label("\(changes) change(s) · \(notWorking) feature(s) not available")
        }
    }

    private func label(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.lineBreakMode = .byTruncatingTail
        return l
    }

    @objc private func toggle(_ sender: NSButton) {
        guard sender.tag < rows.count else { return }
        let id = rows[sender.tag].id
        let on = sender.state == .on
        Task { await manager.setEnabled(on, id: id, in: extensionsDir); reload() }
    }

    @objc private func install(_ sender: Any?) {
        ExtensionInstallFlow.run(manager: manager, extensionsDir: extensionsDir) { [weak self] in self?.reload() }
    }

    @objc private func details(_ sender: Any?) {
        guard let row = selected else { return }
        let alert = NSAlert()
        alert.messageText = row.name
        if let r = row.record {
            alert.informativeText = "Installed in \(row.folder.path)"
            alert.accessoryView = ExtensionSummary.accessory(ExtensionSummary.text(r))
        } else {
            alert.informativeText = "Plain unpacked folder (\(row.folder.path)), loaded without translation."
        }
        alert.beginSheetModal(for: window!)
    }

    @objc private func retranslate(_ sender: Any?) {
        guard let row = selected, row.record != nil else { return }
        let wasLoaded = manager.context(id: row.id) != nil
        manager.unload(id: row.id)
        do {
            let r = try Installer.retranslate(row.folder)
            let alert = NSAlert()
            alert.messageText = "“\(row.name)” translated again with rules v\(r.ruleSetVersion)"
            alert.accessoryView = ExtensionSummary.accessory(ExtensionSummary.text(r))
            alert.beginSheetModal(for: window!)
        } catch {
            NSAlert(error: error).beginSheetModal(for: window!)
        }
        if wasLoaded { Task { await manager.setEnabled(true, id: row.id, in: extensionsDir) } }
        reload()
    }

    @objc private func remove(_ sender: Any?) {
        guard let row = selected else { return }
        let alert = NSAlert()
        alert.messageText = "Remove “\(row.name)”?"
        alert.informativeText = "Its files are deleted. Data the extension stored in the browser may remain."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window!) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated {
                self.manager.unload(id: row.id)
                try? FileManager.default.removeItem(at: row.folder)
                self.manager.rememberGrant(id: row.id, granted: false)
                self.reload()
            }
        }
    }
}

/// `--install-extension` / `--retranslate-extensions`: no UI, JSON on stdout.
@MainActor
enum ExtensionCLI {
    static func install(_ paths: [URL], into dir: URL) {
        var out: [[String: Any]] = []
        var ok = !paths.isEmpty
        for path in paths {
            do {
                out.append(json(try Installer.install(from: path, into: dir)))
            } catch {
                ok = false
                out.append(["path": path.path, "error": "\(error)"])
            }
        }
        ExtensionReport.writeJSON(["extensionsDirectory": dir.path, "installed": out])
        exit(ok ? 0 : 1)
    }

    static func retranslateAll(in dir: URL) {
        var out: [[String: Any]] = []
        var ok = true
        for folder in ExtensionManager.extensionFolders(in: dir) where Installer.record(in: folder) != nil {
            do { out.append(json(try Installer.retranslate(folder))) } catch {
                ok = false
                out.append(["folder": folder.lastPathComponent, "error": "\(error)"])
            }
        }
        ExtensionReport.writeJSON(["extensionsDirectory": dir.path, "retranslated": out])
        exit(ok ? 0 : 1)
    }

    static func json(_ record: InstallRecord) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(record),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return ["id": record.id] }
        return obj
    }
}
