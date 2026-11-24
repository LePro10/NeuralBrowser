// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import ExtensionTranslator
import WebKit

/// Loads web extensions through WKWebExtensionController and forwards tab/window events to it.
/// Installed extensions live in `<Extensions>/<id>/` (`original/`, `patched/`, `install.json`,
/// see ExtensionTranslator.Installer); WebKit loads `patched/`. A plain unpacked folder with a
/// manifest.json directly inside still loads as it is.
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
    /// Per extension: number of popup requests and answers (a watchdog acts only on its own click).
    private var popupAttempt: [String: Int] = [:]
    private var popupClosedAt: [String: Date] = [:]
    private var popupCloseObservers: [String: NSObjectProtocol] = [:]
    var onPopupPresented: ((WKWebExtension.Action, WKWebExtensionContext) -> Void)?

    init(app: AppDelegate, persistent: Bool) {
        self.app = app
        controller = WKWebExtensionController(configuration: Self.configuration(app: app, persistent: persistent))
        super.init()
        controller.delegate = self
    }

    /// Extension storage: in memory for self tests, per profile for `--data-dir`, else WebKit's default.
    /// Website data and cookies of extension pages: the store of normal tabs.
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
        // Extension pages (background, popup, options) use the tabs' store, like Chrome. Left at its
        // default, the base configuration put them into WebKit's default store even in self tests and
        // `--data-dir` profiles. A separate store is not an option: WebKit then never delivers
        // runtime messages to the background service worker (measured: `sendMessage` from content
        // script and popup resolves with `undefined`, `onMessage` never fires).
        base.websiteDataStore = app.websiteDataStore
        // The Bitwarden popup needs Symbol.dispose too; without it the popup page throws on start,
        // renders nothing and WebKit shows an empty popover of size zero.
        PagePolyfills.install(in: base.userContentController)
        config.webViewConfiguration = base
        return config
    }

    static let extensionUserAgentName = "Chrome/142.0.0.0 Safari/605.1.15"

    // MARK: Discovery and loading

    /// Top-level extension folders (installed or plain unpacked); hidden staging folders are skipped.
    static func extensionFolders(in dir: URL) -> [URL] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                                      options: [.skipsHiddenFiles]) else { return [] }
        return items
            .filter { Installer.loadableFolder(for: $0) != nil }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func hasExtensions(in dir: URL) -> Bool { !extensionFolders(in: dir).isEmpty }

    static func identifier(for folder: URL) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-."))
        let name = String(folder.lastPathComponent.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        return "org.neuralbrowser.extension.\(name)"
    }

    /// Self tests (`autoGrant`) load everything; the normal app skips extensions the user switched off.
    func loadAll(from dir: URL, autoGrant: Bool) async -> [LoadResult] {
        var results: [LoadResult] = []
        for folder in Self.extensionFolders(in: dir) where autoGrant || isEnabled(id: folder.lastPathComponent) {
            // Translated with older rules: translate again, so fixes reach installed extensions.
            if let record = Installer.record(in: folder), record.ruleSetVersion < RuleSet.version {
                do {
                    _ = try Installer.retranslate(folder)
                    NSLog("NeuralBrowser: %@ translated again with rules v%d", folder.lastPathComponent, RuleSet.version)
                } catch {
                    NSLog("NeuralBrowser: %@ could not be translated again: %@", folder.lastPathComponent, "\(error)")
                }
            }
            results.append(await load(folder: folder, autoGrant: autoGrant))
        }
        return results
    }

    func load(folder: URL, autoGrant: Bool) async -> LoadResult {
        var result = LoadResult(folder: folder)
        do {
            guard let base = Installer.loadableFolder(for: folder) else { throw InstallError.notFound("manifest.json in \(folder.path)") }
            let ext = try await WKWebExtension(resourceBaseURL: base)
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
            await exemptFromTrackingPrevention(context)
            try controller.load(context)
            contexts.append(context)
            // Errors of the background etc. land in the console, so broken extensions are visible.
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self, weak context] in
                // TEMP diagnostics: NB_DEBUG_CLICK=1 clicks the extension's button once.
                if ProcessInfo.processInfo.environment["NB_DEBUG_CLICK"] != nil, let self, let context,
                   let button = (self.app.keyBrowserWindow ?? self.app.primaryWindow)?.extensionButton(for: context) as? NSButton {
                    button.performClick(nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak context] in
                        context?.action(for: nil)?.closePopup()
                        context?.action(for: (self.app.keyBrowserWindow ?? self.app.primaryWindow)?.activeTab)?.closePopup()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { button.performClick(nil) }
                    }
                }
                guard let context, !context.errors.isEmpty else { return }
                NSLog("NeuralBrowser: extension %@ errors: %@", context.uniqueIdentifier,
                      context.errors.map { "\($0.localizedDescription)" }.joined(separator: " | "))
            }
        } catch {
            result.error = Self.describe(error)
        }
        return result
    }

    /// WebKit's tracking prevention (ITP) treats the extension's origin (`webkit-extension://<uuid>`)
    /// like a website the user never interacted with and deletes its script-written storage. That
    /// includes the background service worker's registration: WebKit terminates the worker seconds
    /// after start (`deleteAndRestrictWebsiteDataForRegistrableDomains` → `SWServerRegistration::clear`
    /// → `terminateWorker`) and never restarts it, so popups wait forever (Bitwarden: spinner) and
    /// content scripts get no answer. Recording a user interaction for the origin before it loads
    /// keeps ITP away from it while ITP keeps protecting web pages. WebKit SPI
    /// (`-[WKWebsiteDataStore _logUserInteraction:completionHandler:]`), there is no public API;
    /// repeated on every load and action click, so the interaction never expires.
    @discardableResult
    func exemptFromTrackingPrevention(_ context: WKWebExtensionContext) async -> Bool {
        let store = app.websiteDataStore
        let selector = NSSelectorFromString("_logUserInteraction:completionHandler:")
        guard store.responds(to: selector), let method = class_getInstanceMethod(type(of: store), selector) else {
            NSLog("NeuralBrowser: WebKit SPI _logUserInteraction missing; tracking prevention may stop extension backgrounds")
            return false
        }
        typealias LogInteraction = @convention(c) (AnyObject, Selector, NSURL, @escaping @convention(block) () -> Void) -> Void
        let call = unsafeBitCast(method_getImplementation(method), to: LogInteraction.self)
        let url = context.baseURL as NSURL
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            call(store, selector, url) { c.resume() }
        }
        return true
    }

    // MARK: Installed extensions (enable, disable, remove, re-translate)

    func context(id: String) -> WKWebExtensionContext? {
        contexts.first { $0.uniqueIdentifier == Self.identifier(for: URL(fileURLWithPath: id)) }
    }

    func isEnabled(id: String) -> Bool {
        ((try? app.store.getSetting(key: SettingKey.extensionEnabled(id))) ?? nil) != "false"
    }

    /// Switches an extension on (loads it; asks for its permissions if never asked) or off (unloads it).
    func setEnabled(_ enabled: Bool, id: String, in dir: URL) async {
        try? app.store.setSetting(key: SettingKey.extensionEnabled(id), value: enabled ? "true" : "false")
        if enabled {
            if context(id: id) == nil { _ = await load(folder: dir.appendingPathComponent(id), autoGrant: false) }
        } else {
            unload(id: id)
        }
        app.windows.forEach { $0.refreshExtensionBar() }
    }

    func unload(id: String) {
        guard let ctx = context(id: id) else { return }
        try? controller.unload(ctx)
        contexts.removeAll { $0 === ctx }
        app.windows.forEach { $0.refreshExtensionBar() }
    }

    /// Records the user's decision from the install dialog, so loading does not ask again.
    func rememberGrant(id: String, granted: Bool) {
        try? app.store.setSetting(key: SettingKey.extensionGrant(Self.identifier(for: URL(fileURLWithPath: id))),
                                  value: granted ? "granted" : "denied")
        try? app.store.setSetting(key: SettingKey.extensionEnabled(id), value: granted ? "true" : "false")
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
        if app.answersPromptsAutomatically { // scripted run on a throw-away profile: "Allow"
            try? app.store.setSetting(key: key, value: "granted")
            return true
        }
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
            // A bare 16 pt icon is easy to miss; the whole 28 x 24 pt area takes the click.
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
            button.heightAnchor.constraint(equalToConstant: 24).isActive = true
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
        NSLog("NeuralBrowser: extension button clicked (%@)", sender.identifier?.rawValue ?? "-")
        guard let context = contexts.first(where: { $0.uniqueIdentifier == sender.identifier?.rawValue }) else {
            NSLog("NeuralBrowser: no extension context for the clicked button")
            return
        }
        let id = context.uniqueIdentifier
        // The click that closes an open popup (a popover closes on mouse-down outside of it)
        // must not open it again right away.
        if let closed = popupClosedAt[id], Date().timeIntervalSince(closed) < 0.4 {
            NSLog("NeuralBrowser: click ignored, popup closed just before")
            return
        }
        let window = sender.window?.windowController as? BrowserWindowController
        let tab = window?.activeTab
        if let tab { context.userGesturePerformed(in: tab) }
        Task { await exemptFromTrackingPrevention(context) } // a real interaction; also renews it
        popupAttempt[id] = (popupAttempt[id] ?? 0) + 1
        let attempt = popupAttempt[id]
        context.performAction(for: tab)
        NSLog("NeuralBrowser: performAction done, tab %d, presentsPopup %d, enabled %d",
              tab == nil ? 0 : 1, context.action(for: tab)?.presentsPopup == true ? 1 : 0,
              context.action(for: tab)?.isEnabled == true ? 1 : 0)
        guard context.action(for: tab)?.presentsPopup == true else { return }
        // WebKit shows a popup only when its page finishes loading after the click, and ignores
        // clicks while it believes a popup is open or on its way. A popup page that failed to load,
        // or was loaded before the click, therefore never appears and blocks every later click
        // (the system's WebKit does not reset that state in `closePopup`). Loading the page again
        // makes WebKit present it; if even that fails, show what there is.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self, weak context, weak tab] in
            guard let self, let context, self.popupAttempt[id] == attempt,
                  let action = context.action(for: tab) else { return }
            let webView = action.popupWebView
            NSLog("NeuralBrowser: extension %@: popup not presented 1.5 s after the click (loading %d, url %@), reloading it",
                  id, webView?.isLoading == true ? 1 : 0, webView?.url?.absoluteString ?? "-")
            if webView?.isLoading != true { webView?.reload() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self, weak context] in
                guard let self, let context, self.popupAttempt[id] == attempt else { return }
                NSLog("NeuralBrowser: extension %@: popup still not presented, showing it anyway", id)
                self.showPopup(of: action, for: context)
            }
        }
    }

    /// Shows the action's popover at its sidebar button. False when there is nothing to show it on.
    @discardableResult
    private func showPopup(of action: WKWebExtension.Action, for context: WKWebExtensionContext) -> Bool {
        let id = context.uniqueIdentifier
        popupAttempt[id] = (popupAttempt[id] ?? 0) + 1 // answered: stops the watchdog of the click
        let window = (action.associatedTab as? BrowserTab)?.owner ?? app.keyBrowserWindow
        guard let popover = action.popupPopover,
              let anchor = window?.extensionButton(for: context) ?? window?.window?.contentView,
              anchor.window != nil else { return false }
        if let old = popupCloseObservers[id] { NotificationCenter.default.removeObserver(old) }
        popupCloseObservers[id] = NotificationCenter.default.addObserver(
            forName: NSPopover.willCloseNotification, object: popover, queue: .main
        ) { [weak self] _ in
            NSLog("NeuralBrowser: extension %@: popover closing", id)
            MainActor.assumeIsolated { self?.popupClosedAt[id] = Date() }
        }
        // No white flash while the popup page loads: let the popover's own background show through.
        if let webView = action.popupWebView {
            webView.setValue(false, forKey: "drawsBackground")
            webView.underPageBackgroundColor = .clear
        }
        // A page that has not laid out yet reports size zero, which gives a tiny empty bubble.
        // Chrome's popup limits are 25...800 x 25...600; Bitwarden is designed for 380 x 600.
        if popover.contentSize.width < 50 || popover.contentSize.height < 50 {
            NSLog("NeuralBrowser: extension %@: popup size %@ too small, using 380 x 600",
                  id, NSStringFromSize(popover.contentSize))
            popover.contentSize = NSSize(width: 380, height: 600)
        }
        if !popover.isShown { popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY) }
        NSLog("NeuralBrowser: extension %@: popover shown %d, size %@, behavior %d", id, popover.isShown ? 1 : 0,
              NSStringFromSize(popover.contentSize), popover.behavior.rawValue)
        if let webView = action.popupWebView {
            webView.isInspectable = true
            let probe = """
            JSON.stringify({ready: document.readyState, href: location.href,
              body: document.body ? document.body.innerHTML.length : -1,
              w: document.documentElement.scrollWidth, h: document.documentElement.scrollHeight,
              dispose: typeof Symbol.dispose, err: window.__nbErrors || null,
              pending: performance.getEntriesByType('resource').filter(e => !e.responseEnd).map(e => e.name)})
            """
            for delay in [0.5, 3.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak webView, weak popover] in
                    webView?.evaluateJavaScript(probe) { result, error in
                        NSLog("NeuralBrowser: popup probe +%.1fs (shown %d): %@ %@", delay, popover?.isShown == true ? 1 : 0,
                              String(describing: result ?? "-"), error.map { String(describing: $0) } ?? "")
                    }
                }
            }
            let wasmProbe = """
            const out = {res: performance.getEntriesByType('resource').map(e => e.name.split('/').pop() + ':' + Math.round(e.duration))};
            try {
              const r = await fetch('/1e47f304764bbc07f639.module.wasm');
              out.wasmType = r.headers.get('content-type'); out.wasmStatus = r.status;
              const buf = await r.arrayBuffer(); out.wasmBytes = buf.byteLength;
              const m = await WebAssembly.compile(buf); out.wasmCompile = 'ok ' + WebAssembly.Module.imports(m).length;
            } catch (e) { out.wasmError = String(e); }
            try { out.bg = await Promise.race([chrome.runtime.sendMessage({command: 'nb-ping'}).then(v => 'answered ' + v, e => 'error ' + e),
                                               new Promise(r => setTimeout(() => r('timeout'), 2000))]); } catch (e) { out.bg = 'throw ' + e; }
            out.html = document.body.innerHTML.slice(0, 200);
            return JSON.stringify(out);
            """
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak webView] in
                webView?.callAsyncJavaScript(wasmProbe, arguments: [:], in: nil, in: .page) { result in
                    NSLog("NeuralBrowser: popup wasm probe: %@", String(describing: result))
                }
            }
        }
        return true
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
        if app.answersPromptsAutomatically { return true } // self tests grant everything
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
        guard showPopup(of: action, for: context) else {
            // Tell WebKit, otherwise it believes the popup is open and ignores every later click.
            NSLog("NeuralBrowser: extension %@: no place to show the popup", context.uniqueIdentifier)
            return completionHandler(NSError(domain: "NeuralBrowser", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "No window to present the popup in",
            ]))
        }
        onPopupPresented?(action, context)
        completionHandler(nil)
    }
}
