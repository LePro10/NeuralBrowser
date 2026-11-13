// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import WebKit

/// Loads unpacked web extensions (folders with manifest.json) through
/// WKWebExtensionController and forwards tab/window events to it.
@MainActor
final class ExtensionManager: NSObject, WKWebExtensionControllerDelegate {
    struct LoadResult {
        let folder: URL
        var webExtension: WKWebExtension?
        var context: WKWebExtensionContext?
        var error: String?
    }

    unowned let app: AppDelegate
    let controller: WKWebExtensionController
    private(set) var contexts: [WKWebExtensionContext] = []

    /// Smoke-test hook: called when an action popup is presented.
    var onPopupPresented: ((WKWebExtension.Action, WKWebExtensionContext) -> Void)?

    init(app: AppDelegate, persistent: Bool) {
        self.app = app
        controller = WKWebExtensionController(configuration: Self.configuration(app: app, persistent: persistent))
        super.init()
        controller.delegate = self
    }

    /// Extension storage: in memory for self tests, per profile for `--data-dir`, else WebKit's default.
    static func configuration(app: AppDelegate, persistent: Bool) -> WKWebExtensionController.Configuration {
        let config: WKWebExtensionController.Configuration
        if !persistent || app.isEphemeralProfile {
            config = .nonPersistent()
        } else if let id = app.options.profileIdentifier {
            config = WKWebExtensionController.Configuration(identifier: id)
        } else {
            config = .default()
        }
        config.defaultWebsiteDataStore = app.websiteDataStore
        // Base for the background, popup and options web views. We load Chrome packages, and
        // they branch on navigator.userAgent: with no browser token Bitwarden crashes on start,
        // with a Safari token it waits for its native Safari app and spins at 100 % CPU.
        // A Chrome token selects the code path these packages were built and tested for.
        let base = WKWebViewConfiguration()
        base.applicationNameForUserAgent = app.options.extensionUserAgentName ?? Self.extensionUserAgentName
        config.webViewConfiguration = base
        return config
    }

    static let extensionUserAgentName = "Chrome/142.0.0.0 Safari/605.1.15"

    // MARK: Discovery and loading

    static func extensionFolders(in dir: URL) -> [URL] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                                      options: [.skipsHiddenFiles]) else { return [] }
        return items
            .filter { fm.fileExists(atPath: $0.appendingPathComponent("manifest.json").path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func hasExtensions(in dir: URL) -> Bool { !extensionFolders(in: dir).isEmpty }

    static func identifier(for folder: URL) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-."))
        let name = String(folder.lastPathComponent.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        return "org.neuralbrowser.extension.\(name)"
    }

    func loadAll(from dir: URL, autoGrant: Bool) async -> [LoadResult] {
        var results: [LoadResult] = []
        for folder in Self.extensionFolders(in: dir) {
            results.append(await load(folder: folder, autoGrant: autoGrant))
        }
        return results
    }

    func load(folder: URL, autoGrant: Bool) async -> LoadResult {
        var result = LoadResult(folder: folder)
        do {
            let ext = try await WKWebExtension(resourceBaseURL: folder)
            result.webExtension = ext
            let context = WKWebExtensionContext(for: ext)
            context.uniqueIdentifier = Self.identifier(for: folder)
            context.isInspectable = true
            context.inspectionName = ext.displayName
            result.context = context

            guard autoGrant || userAllows(ext, id: context.uniqueIdentifier) else {
                result.error = "not allowed by user"
                return result
            }
            grantRequested(ext, in: context)
            try controller.load(context)
            contexts.append(context)
        } catch {
            result.error = Self.describe(error)
        }
        return result
    }

    /// Grants everything the manifest requests (permissions, host and content-script patterns).
    private func grantRequested(_ ext: WKWebExtension, in context: WKWebExtensionContext) {
        for permission in ext.requestedPermissions {
            context.setPermissionStatus(.grantedExplicitly, for: permission)
        }
        for pattern in ext.allRequestedMatchPatterns {
            context.setPermissionStatus(.grantedExplicitly, for: pattern)
        }
    }

    /// Asks once per extension; the decision is remembered in the store.
    private func userAllows(_ ext: WKWebExtension, id: String) -> Bool {
        let key = SettingKey.extensionGrant(id)
        if let saved = (try? app.store.getSetting(key: key)) ?? nil { return saved == "granted" }
        let perms = ext.requestedPermissions.map(\.rawValue).sorted()
        let hosts = ext.allRequestedMatchPatterns.map(\.string).sorted()
        let alert = NSAlert()
        alert.messageText = "Allow the extension “\(ext.displayName ?? id)”?"
        alert.informativeText = """
            Permissions: \(perms.isEmpty ? "none" : perms.joined(separator: ", "))
            Websites: \(hosts.isEmpty ? "none" : hosts.joined(separator: ", "))
            """
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don’t Allow")
        let allowed = alert.runModal() == .alertFirstButtonReturn
        try? app.store.setSetting(key: key, value: allowed ? "granted" : "denied")
        return allowed
    }

    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        var text = ns.localizedDescription
        if let reason = ns.localizedFailureReason, !text.contains(reason) { text += " (\(reason))" }
        return "\(text) [\(ns.domain) \(ns.code)]"
    }

    /// Configuration for web views showing pages of an extension (webkit-extension://…).
    func extensionConfiguration(for url: URL) -> WKWebViewConfiguration? {
        guard url.scheme == "webkit-extension" else { return nil }
        return controller.extensionContext(for: url)?.webViewConfiguration
    }

    // MARK: Event forwarding (the API only knows what we report)

    func windowOpened(_ w: BrowserWindowController) { controller.didOpenWindow(w) }
    func windowClosed(_ w: BrowserWindowController) { controller.didCloseWindow(w) }
    func windowFocused(_ w: BrowserWindowController?) { controller.didFocusWindow(w) }
    func tabOpened(_ tab: BrowserTab) { controller.didOpenTab(tab) }

    func tabClosed(_ tab: BrowserTab, windowIsClosing: Bool) {
        controller.didCloseTab(tab, windowIsClosing: windowIsClosing)
    }

    func tabActivated(_ tab: BrowserTab, previous: BrowserTab?) {
        controller.didActivateTab(tab, previousActiveTab: previous)
        if let previous { controller.didDeselectTabs([previous]) }
        controller.didSelectTabs([tab])
        tab.owner?.refreshExtensionBar() // per-tab action state (badge, icon)
    }

    func tabChanged(_ tab: BrowserTab, _ change: TabChange) {
        var props: WKWebExtension.TabChangedProperties = []
        if change.contains(.title) { props.insert(.title) }
        if change.contains(.url) { props.insert(.URL) }
        if change.contains(.loading) { props.insert(.loading) }
        if !props.isEmpty { controller.didChangeTabProperties(props, for: tab) }
    }

    // MARK: Action bar

    func makeActionButtons(for window: BrowserWindowController) -> [NSView] {
        contexts.map { context in
            let action = context.action(for: window.activeTab)
            let size = CGSize(width: 16, height: 16)
            let image = action?.icon(for: size) ?? context.webExtension.icon(for: size)
                ?? NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: nil)!
            let button = NSButton(image: image, target: self, action: #selector(actionClicked(_:)))
            button.isBordered = false
            button.identifier = NSUserInterfaceItemIdentifier(context.uniqueIdentifier)
            button.toolTip = action?.label ?? context.webExtension.displayName
            if let badge = action?.badgeText, !badge.isEmpty {
                button.title = badge
                button.font = .systemFont(ofSize: 10, weight: .semibold)
                button.imagePosition = .imageLeading
            }
            button.isEnabled = action?.isEnabled ?? true
            return button
        }
    }

    @objc private func actionClicked(_ sender: NSButton) {
        guard let context = contexts.first(where: { $0.uniqueIdentifier == sender.identifier?.rawValue }) else { return }
        let window = sender.window?.windowController as? BrowserWindowController
        if let tab = window?.activeTab { context.userGesturePerformed(in: tab) }
        context.performAction(for: window?.activeTab)
    }

    // MARK: WKWebExtensionControllerDelegate

    func webExtensionController(_ controller: WKWebExtensionController,
                                openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        app.windows.filter { !$0.isPrivate }
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        guard let w = app.keyBrowserWindow, !w.isPrivate else { return app.primaryWindow }
        return w
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                openNewTabUsing configuration: WKWebExtension.TabConfiguration,
                                for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void) {
        let window = (configuration.window as? BrowserWindowController) ?? app.primaryWindow
            ?? { let w = app.openWindow(isPrivate: false); w.showWindow(nil); return w }()
        let tab = window.addTab(url: configuration.url, at: configuration.index,
                                activate: configuration.shouldBeActive, pinned: configuration.shouldBePinned)
        if !configuration.shouldBeActive, configuration.url != nil { window.materialize(tab) }
        completionHandler(tab, nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                openNewWindowUsing configuration: WKWebExtension.WindowConfiguration,
                                for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping ((any WKWebExtensionWindow)?, (any Error)?) -> Void) {
        let window = app.openWindow(isPrivate: configuration.shouldBePrivate)
        for (i, url) in configuration.tabURLs.enumerated() {
            window.addTab(url: url, activate: i == 0)
        }
        if configuration.frame != .zero, !configuration.frame.isNull, !configuration.frame.isInfinite {
            window.window?.setFrame(configuration.frame, display: false)
        }
        window.showWindow(nil)
        if !configuration.shouldBeFocused { app.primaryWindow?.window?.makeKeyAndOrderFront(nil) }
        completionHandler(window, nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                openOptionsPageFor extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping ((any Error)?) -> Void) {
        guard let url = extensionContext.optionsPageURL, let window = app.keyBrowserWindow ?? app.primaryWindow else {
            return completionHandler(nil)
        }
        window.openTab(url: url)
        completionHandler(nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                promptForPermissions permissions: Set<WKWebExtension.Permission>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void) {
        let list = permissions.map(\.rawValue).sorted().joined(separator: ", ")
        completionHandler(ask(extensionContext, "requests additional permissions:\n\(list)") ? permissions : [], nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                promptForPermissionToAccess urls: Set<URL>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<URL>, Date?) -> Void) {
        let list = urls.compactMap { $0.host() }.sorted().joined(separator: ", ")
        completionHandler(ask(extensionContext, "wants to access:\n\(list)") ? urls : [], nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void) {
        let list = matchPatterns.map(\.string).sorted().joined(separator: ", ")
        completionHandler(ask(extensionContext, "wants to access:\n\(list)") ? matchPatterns : [], nil)
    }

    private func ask(_ context: WKWebExtensionContext, _ text: String) -> Bool {
        if app.isEphemeralProfile { return true } // self tests grant everything
        let alert = NSAlert()
        alert.messageText = "“\(context.webExtension.displayName ?? "Extension")” \(text)"
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don’t Allow")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func webExtensionController(_ controller: WKWebExtensionController, didUpdate action: WKWebExtension.Action,
                                forExtensionContext context: WKWebExtensionContext) {
        app.windows.forEach { $0.refreshExtensionBar() }
    }

    func webExtensionController(_ controller: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action,
                                for context: WKWebExtensionContext,
                                completionHandler: @escaping ((any Error)?) -> Void) {
        guard let popover = action.popupPopover else { return completionHandler(nil) }
        let window = (action.associatedTab as? BrowserTab)?.owner ?? app.keyBrowserWindow
        if let anchor = window?.extensionButton(for: context) ?? window?.window?.contentView {
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        }
        onPopupPresented?(action, context)
        completionHandler(nil)
    }
}
