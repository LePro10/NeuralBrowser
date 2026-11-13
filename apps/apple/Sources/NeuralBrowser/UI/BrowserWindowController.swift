// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import WebKit

/// One browser window: sidebar with the tab list on the left, the active tab's
/// web view on the right, command bar and find bar as overlays.
@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate {
    unowned let app: AppDelegate
    let isPrivate: Bool
    private(set) var tabs: [BrowserTab] = []
    private(set) var activeTab: BrowserTab?

    private let sidebar = SidebarView()
    private let contentArea = NSView()
    private let webContainer = NSView()
    private let emptyLabel = NSTextField(labelWithString: "Press ⌘T to open a tab")
    private lazy var commandBar = CommandBarView()
    private lazy var findBar = FindBarView()
    private lazy var privateDataStore = WKWebsiteDataStore.nonPersistent()

    /// Hooks used by the smoke test.
    var onTabFinishedLoading: ((BrowserTab) -> Void)?
    var onTabFailed: ((BrowserTab, NSError) -> Void)?

    init(app: AppDelegate, isPrivate: Bool) {
        self.app = app
        self.isPrivate = isPrivate
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: true)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 600, height: 400)
        window.title = isPrivate ? "NeuralBrowser – Private" : "NeuralBrowser"
        super.init(window: window)
        window.delegate = self
        buildLayout(in: window)
        if !isPrivate, !window.setFrameUsingName("MainWindow") { window.center() }
        if !isPrivate { window.setFrameAutosaveName("MainWindow") } else { window.center() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func buildLayout(in window: NSWindow) {
        let root = NSView()
        window.contentView = root
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        contentArea.translatesAutoresizingMaskIntoConstraints = false
        webContainer.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.textColor = .tertiaryLabelColor
        root.addSubview(sidebar)
        root.addSubview(contentArea)
        contentArea.addSubview(webContainer)
        contentArea.addSubview(emptyLabel)

        let guide = window.contentLayoutGuide as? NSLayoutGuide
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 240),
            contentArea.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            contentArea.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentArea.topAnchor.constraint(equalTo: guide?.topAnchor ?? root.topAnchor),
            contentArea.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            webContainer.leadingAnchor.constraint(equalTo: contentArea.leadingAnchor),
            webContainer.trailingAnchor.constraint(equalTo: contentArea.trailingAnchor),
            webContainer.topAnchor.constraint(equalTo: contentArea.topAnchor),
            webContainer.bottomAnchor.constraint(equalTo: contentArea.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: contentArea.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: contentArea.centerYAnchor),
        ])

        sidebar.isPrivate = isPrivate
        sidebar.onSelect = { [weak self] i in self.map { if i < $0.tabs.count { $0.select($0.tabs[i]) } } }
        sidebar.onClose = { [weak self] i in self.map { if i < $0.tabs.count { $0.closeTab($0.tabs[i]) } } }
        sidebar.onNewTab = { [weak self] in self?.newTab(nil) }
        sidebar.onAddressClick = { [weak self] in self?.openLocation(nil) }
        sidebar.onBack = { [weak self] in self?.goBack(nil) }
        sidebar.onForward = { [weak self] in self?.goForward(nil) }
        sidebar.onReload = { [weak self] in self?.reload(nil) }
        refreshSidebar()
        refreshDownloads()
    }

    // MARK: Web views

    /// Many sites (and extensions, in their background) gate features on a Safari-like UA token.
    static let userAgentApplicationName = "Version/26.0 Safari/605.1.15"

    private func makeWebView(for url: URL?, configuration: WKWebViewConfiguration? = nil) -> WKWebView {
        let config: WKWebViewConfiguration
        if let configuration {
            config = configuration
        } else if let url, let ext = app.extensionManager?.extensionConfiguration(for: url), !isPrivate {
            config = ext // pages of an extension need that extension's configuration
        } else {
            config = WKWebViewConfiguration()
            config.websiteDataStore = isPrivate ? privateDataStore : app.websiteDataStore
            if !isPrivate, let controller = app.extensionManager?.controller {
                config.webExtensionController = controller
            }
            config.preferences.isElementFullscreenEnabled = true
            // Many sites gate features on a Safari-like UA token.
            config.applicationNameForUserAgent = app.options.tabUserAgentName ?? Self.userAgentApplicationName
        }
        let webView = WKWebView(frame: webContainer.bounds, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.isInspectable = true
        webView.autoresizingMask = [.width, .height]
        return webView
    }

    /// Ensures the tab has a web view (creating and loading it on first use).
    func materialize(_ tab: BrowserTab) {
        if tab.webView == nil {
            tab.attach(makeWebView(for: tab.url), load: true)
        }
        if tab === activeTab { showActiveWebView() }
    }

    private func showActiveWebView() {
        let current = activeTab?.webView
        for sub in webContainer.subviews where sub !== current { sub.removeFromSuperview() }
        if let current, current.superview !== webContainer {
            current.frame = webContainer.bounds
            webContainer.addSubview(current)
        }
        emptyLabel.isHidden = activeTab != nil
    }

    // MARK: Tab management

    @discardableResult
    func addTab(url: URL?, title: String = "", at index: Int? = nil, activate: Bool,
                id: String = UUID().uuidString, pinned: Bool = false) -> BrowserTab {
        let tab = BrowserTab(id: id, url: url, title: title, pinned: pinned)
        tab.owner = self
        tabs.insert(tab, at: min(index ?? tabs.count, tabs.count))
        refreshSidebar()
        if !isPrivate { app.extensionManager?.tabOpened(tab) }
        if activate { select(tab) }
        sessionChanged()
        return tab
    }

    /// Opens a URL in a new tab right after `parent` (or at the end).
    @discardableResult
    func openTab(url: URL, after parent: BrowserTab? = nil, activate: Bool = true) -> BrowserTab {
        let index = parent.flatMap { p in tabs.firstIndex(of: p).map { $0 + 1 } }
        let tab = addTab(url: url, at: index, activate: activate)
        if !activate { materialize(tab) } // background tabs opened by a click start loading now
        return tab
    }

    /// Opens a tab for `window.open` / target=_blank using WebKit's configuration.
    func openTab(configuration: WKWebViewConfiguration, after parent: BrowserTab?) -> BrowserTab? {
        let index = parent.flatMap { p in tabs.firstIndex(of: p).map { $0 + 1 } }
        let tab = addTab(url: nil, at: index, activate: false)
        tab.attach(makeWebView(for: nil, configuration: configuration), load: false)
        select(tab)
        return tab
    }

    func select(_ tab: BrowserTab) {
        guard tabs.contains(tab) else { return }
        let previous = activeTab
        let now = nowMs()
        previous?.lastActiveMs = now
        tab.lastActiveMs = now
        activeTab = tab
        materialize(tab)
        showActiveWebView()
        if let wv = tab.webView, window?.isKeyWindow == true || window?.isVisible == true {
            window?.makeFirstResponder(wv)
        }
        refreshSidebar()
        if previous !== tab, !isPrivate { app.extensionManager?.tabActivated(tab, previous: previous) }
        sessionChanged()
    }

    func closeTab(_ tab: BrowserTab) {
        guard let index = tabs.firstIndex(of: tab) else { return }
        if !isPrivate, let url = tab.url {
            app.rememberClosedTab(url: url, title: tab.title)
        }
        tabs.remove(at: index)
        tab.detachWebView()
        if !isPrivate { app.extensionManager?.tabClosed(tab, windowIsClosing: false) }
        if tab === activeTab {
            activeTab = nil
            if !tabs.isEmpty { select(tabs[min(index, tabs.count - 1)]) }
        }
        tab.owner = nil
        showActiveWebView()
        refreshSidebar()
        sessionChanged()
        if tabs.isEmpty { window?.performClose(nil) }
    }

    func restore(_ session: SessionState) {
        for state in session.tabs.sorted(by: { $0.position < $1.position }) {
            let tab = BrowserTab(id: state.id, url: URL(string: state.url), title: state.title,
                                 pinned: state.pinned, lastActiveMs: state.lastActiveMs)
            tab.owner = self
            tabs.append(tab)
            if !isPrivate { app.extensionManager?.tabOpened(tab) }
        }
        // Only the active tab loads now; the others stay asleep until clicked.
        let active = tabs.first { $0.id == session.activeTabId } ?? tabs.first
        if let active { select(active) } else { refreshSidebar() }
    }

    func sessionStates() -> [TabState] {
        tabs.enumerated().compactMap { i, t in
            guard let url = t.url?.absoluteString else { return nil }
            return TabState(id: t.id, url: url, title: t.title, pinned: t.pinned,
                            position: i, lastActiveMs: t.lastActiveMs)
        }
    }

    private func sessionChanged() {
        if !isPrivate { app.sessionDidChange() }
    }

    // MARK: Tab callbacks

    func tabDidChange(_ tab: BrowserTab, _ change: TabChange) {
        if let i = tabs.firstIndex(of: tab) { sidebar.reloadTab(at: i) }
        if tab === activeTab {
            if change.contains(.webView) { showActiveWebView() }
            if !change.isDisjoint(with: [.url, .loading, .navigationState]) { refreshAddress() }
        }
        if !isPrivate {
            app.extensionManager?.tabChanged(tab, change)
            if !change.isDisjoint(with: [.url, .title]) { sessionChanged() }
        }
    }

    func tabTitleDidChange(_ tab: BrowserTab) {
        guard !isPrivate, let url = tab.url, url.scheme?.hasPrefix("http") == true else { return }
        try? app.store.updateTitle(url: url.absoluteString, title: tab.title)
    }

    func tabDidCommit(_ tab: BrowserTab) {
        guard !isPrivate, let url = tab.url, url.scheme?.hasPrefix("http") == true else { return }
        try? app.store.recordVisit(url: url.absoluteString, title: tab.webView?.title ?? "", timestampMs: nowMs())
    }

    func tabDidFinishLoad(_ tab: BrowserTab) { onTabFinishedLoading?(tab) }

    func tabDidFailLoad(_ tab: BrowserTab, error: NSError) { onTabFailed?(tab, error) }

    // MARK: Sidebar

    private func refreshSidebar() {
        sidebar.setTabs(tabs, active: activeTab)
        refreshAddress()
    }

    private func refreshAddress() {
        let url = activeTab?.url
        let text = url.map { $0.host() ?? $0.absoluteString } ?? (isPrivate ? "Private" : "Search or enter address")
        sidebar.setAddress(text, secure: url?.scheme == "https",
                           canGoBack: activeTab?.webView?.canGoBack ?? false,
                           canGoForward: activeTab?.webView?.canGoForward ?? false,
                           loading: activeTab?.isLoading ?? false)
    }

    func refreshExtensionBar() {
        sidebar.setExtensionButtons(isPrivate ? [] : (app.extensionManager?.makeActionButtons(for: self) ?? []))
    }

    func refreshDownloads() {
        sidebar.setDownloads(app.downloads.items)
    }

    /// Button in the extension bar for a context (used to anchor popovers).
    func extensionButton(for context: WKWebExtensionContext) -> NSView? {
        sidebar.extensionButton(identifier: context.uniqueIdentifier)
    }

    // MARK: Actions (menu / keyboard, via responder chain)

    @objc func newTab(_ sender: Any?) {
        presentCommandBar(text: "", newTab: true)
    }

    @objc func openLocation(_ sender: Any?) {
        presentCommandBar(text: activeTab?.url?.absoluteString ?? "", newTab: activeTab == nil)
    }

    @objc func closeCurrentTab(_ sender: Any?) {
        if let activeTab { closeTab(activeTab) } else { window?.performClose(nil) }
    }

    @objc func reopenClosedTab(_ sender: Any?) {
        guard let closed = app.popClosedTab() else { return }
        openTab(url: closed.url)
    }

    @objc func reload(_ sender: Any?) {
        guard let tab = activeTab else { return }
        if let wv = tab.webView { wv.reload() } else { materialize(tab) }
    }

    @objc func goBack(_ sender: Any?) { activeTab?.webView?.goBack() }
    @objc func goForward(_ sender: Any?) { activeTab?.webView?.goForward() }

    @objc func selectTabByNumber(_ sender: NSMenuItem) {
        guard !tabs.isEmpty else { return }
        let n = sender.tag
        select(n >= 9 ? tabs[tabs.count - 1] : tabs[min(n - 1, tabs.count - 1)])
    }

    @objc func selectNextTab(_ sender: Any?) { cycleTab(by: 1) }
    @objc func selectPreviousTab(_ sender: Any?) { cycleTab(by: -1) }

    private func cycleTab(by delta: Int) {
        guard !tabs.isEmpty else { return }
        let i = activeTab.flatMap { tabs.firstIndex(of: $0) } ?? 0
        select(tabs[(i + delta + tabs.count) % tabs.count])
    }

    @objc func zoomIn(_ sender: Any?) { activeTab?.webView.map { $0.pageZoom = min($0.pageZoom + 0.1, 3) } }
    @objc func zoomOut(_ sender: Any?) { activeTab?.webView.map { $0.pageZoom = max($0.pageZoom - 0.1, 0.3) } }
    @objc func actualSize(_ sender: Any?) { activeTab?.webView?.pageZoom = 1 }

    @objc func findInPage(_ sender: Any?) {
        guard activeTab?.webView != nil else { return }
        findBar.onSearch = { [weak self] text, backwards in self?.find(text, backwards: backwards) }
        findBar.onClose = { [weak self] in
            if let wv = self?.activeTab?.webView { self?.window?.makeFirstResponder(wv) }
        }
        findBar.present(in: contentArea)
    }

    @objc func findNext(_ sender: Any?) { findAgain(backwards: false) }
    @objc func findPrevious(_ sender: Any?) { findAgain(backwards: true) }

    private func findAgain(backwards: Bool) {
        if findBar.superview == nil { return findInPage(nil) }
        find(findBar.query, backwards: backwards)
    }

    func find(_ text: String, backwards: Bool, completion: ((Bool) -> Void)? = nil) {
        guard let wv = activeTab?.webView, !text.isEmpty else {
            findBar.setResult(found: true)
            completion?(false)
            return
        }
        let config = WKFindConfiguration()
        config.backwards = backwards
        config.wraps = true
        wv.find(text, configuration: config) { [weak self] result in
            MainActor.assumeIsolated {
                self?.findBar.setResult(found: result.matchFound)
                completion?(result.matchFound)
            }
        }
    }

    // MARK: Command bar

    private func presentCommandBar(text: String, newTab: Bool) {
        commandBar.provider = { [weak self] query in self?.commandItems(for: query) ?? [] }
        commandBar.onSubmit = { [weak self] item, text, newTab in self?.submitCommand(item, text: text, newTab: newTab) }
        commandBar.present(in: window!.contentView!, text: text, newTab: newTab)
    }

    private func commandItems(for query: String) -> [CommandBarView.Item] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        var items: [CommandBarView.Item] = []
        let lower = q.lowercased()
        for tab in tabs where tab !== activeTab {
            if tab.displayTitle.lowercased().contains(lower) || (tab.url?.absoluteString.lowercased().contains(lower) ?? false) {
                items.append(.init(title: tab.displayTitle, subtitle: "Switch to tab", symbol: "square.on.square",
                                   target: .tab(tab)))
            }
            if items.count >= 3 { break }
        }
        if !isPrivate, let suggestions = try? app.store.suggest(query: q, limit: 8) {
            for s in suggestions {
                items.append(.init(title: s.title.isEmpty ? s.url : s.title, subtitle: s.url,
                                   symbol: s.kind == .bookmark ? "bookmark" : "clock",
                                   target: .url(s.url)))
            }
        }
        return items
    }

    private func submitCommand(_ item: CommandBarView.Item?, text: String, newTab: Bool) {
        let target: String
        switch item?.target {
        case .tab(let tab): select(tab); return
        case .url(let u): target = u
        case nil: target = app.store.resolveInput(text: text, searchTemplate: app.store.searchTemplate)
        }
        guard let url = URL(string: target) else { return }
        if newTab || activeTab == nil {
            addTab(url: url, activate: true)
        } else {
            activeTab?.navigate(to: url)
            if let wv = activeTab?.webView { window?.makeFirstResponder(wv) }
        }
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        app.windowDidBecomeKey(self)
    }

    func windowWillClose(_ notification: Notification) {
        app.windowWillClose(self)
        for tab in tabs {
            tab.detachWebView()
            if !isPrivate { app.extensionManager?.tabClosed(tab, windowIsClosing: true) }
        }
        tabs.removeAll()
        activeTab = nil
    }
}
