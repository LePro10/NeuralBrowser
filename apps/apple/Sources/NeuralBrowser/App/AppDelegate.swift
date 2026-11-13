// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import WebKit

/// Owns the store, the windows, the extension manager and app-wide state
/// (recently closed tabs, session saving, downloads, sleeping tabs).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let options: LaunchOptions
    let processStart = processStartDate()
    private(set) var store: BrowserStore = JSONBrowserStore(fileURL: nil)
    private(set) var extensionManager: ExtensionManager?
    let downloads = DownloadManager()
    private(set) var windows: [BrowserWindowController] = []
    private var closedTabs: [(url: URL, title: String)] = []
    private var sessionWork: DispatchWorkItem?
    private var sleeper: TabSleeper?
    private var smokeTest: SmokeTest?
    private var extensionScript: ExtensionScript?
    private var keyMonitor: Any?

    init(options: LaunchOptions) {
        self.options = options
    }

    /// True when nothing may be written to the user's real profile (self tests, reports).
    var isEphemeralProfile: Bool {
        if case .normal = options.mode { return false }
        return true
    }

    /// Cookies, caches and site storage of normal (non-private) tabs.
    /// Self tests: in memory only. `--data-dir`: a separate store per directory,
    /// so a throw-away profile never shares cookies with the real one.
    private(set) lazy var websiteDataStore: WKWebsiteDataStore = {
        if isEphemeralProfile { return .nonPersistent() }
        if let id = options.profileIdentifier { return WKWebsiteDataStore(forIdentifier: id) }
        return .default()
    }()

    var primaryWindow: BrowserWindowController? { windows.first { !$0.isPrivate } }

    var keyBrowserWindow: BrowserWindowController? {
        (NSApp.keyWindow?.windowController as? BrowserWindowController) ?? windows.last
    }

    // MARK: Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        switch options.mode {
        case .normal:
            NSApp.setActivationPolicy(.regular)
            startNormal()
        case .smokeTest(let urls):
            NSApp.setActivationPolicy(.regular)
            NSApp.mainMenu = MainMenu.build()
            store = JSONBrowserStore(fileURL: nil)
            let test = SmokeTest(app: self, urls: urls)
            smokeTest = test
            test.run()
        case .extensionReport:
            NSApp.setActivationPolicy(.prohibited)
            ExtensionReport.run(directory: options.resolvedExtensionsDirectory)
        case .extensionScript(let file):
            NSApp.setActivationPolicy(.regular)
            NSApp.mainMenu = MainMenu.build()
            store = JSONBrowserStore(fileURL: nil)
            let script = ExtensionScript(app: self, file: file)
            extensionScript = script
            script.run()
        }
    }

    private func startNormal() {
        NSApp.mainMenu = MainMenu.build()
        installKeyMonitor()
        downloads.onChange = { [weak self] in self?.windows.forEach { $0.refreshDownloads() } }
        let dataDir = options.resolvedDataDirectory
        store = JSONBrowserStore(fileURL: dataDir.appendingPathComponent("store.json"))

        // Creating the controller is cheap; loading extensions happens after the window is up.
        let extDir = options.resolvedExtensionsDirectory
        if ExtensionManager.hasExtensions(in: extDir) {
            enableExtensions(persistent: true)
        }

        let window = openWindow(isPrivate: false)
        if let session = try? store.loadSession(), !session.tabs.isEmpty {
            window.restore(session)
        }
        window.showWindow(nil)
        NSApp.activate()
        if window.tabs.isEmpty { window.newTab(nil) }

        sleeper = TabSleeper(app: self)
        sleeper?.start()

        if let manager = extensionManager {
            DispatchQueue.main.async {
                Task { @MainActor in
                    _ = await manager.loadAll(from: extDir, autoGrant: false)
                    self.windows.forEach { $0.refreshExtensionBar() }
                }
            }
        }
    }

    /// Creates the extension controller. Must happen before tabs create web views.
    @discardableResult
    func enableExtensions(persistent: Bool) -> ExtensionManager {
        if let extensionManager { return extensionManager }
        let manager = ExtensionManager(app: self, persistent: persistent)
        extensionManager = manager
        return manager
    }

    func applicationWillTerminate(_ notification: Notification) {
        saveSessionNow()
        store.flush()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if windows.isEmpty { newWindow(nil) }
        return true
    }

    // MARK: Windows

    @discardableResult
    func openWindow(isPrivate: Bool) -> BrowserWindowController {
        let controller = BrowserWindowController(app: self, isPrivate: isPrivate)
        windows.append(controller)
        if !isPrivate {
            extensionManager?.windowOpened(controller)
            controller.refreshExtensionBar()
        }
        return controller
    }

    func windowDidBecomeKey(_ controller: BrowserWindowController) {
        if !controller.isPrivate { extensionManager?.windowFocused(controller) }
    }

    func windowWillClose(_ controller: BrowserWindowController) {
        if controller === primaryWindow { saveSessionNow() }
        windows.removeAll { $0 === controller }
        if !controller.isPrivate { extensionManager?.windowClosed(controller) }
    }

    @objc func newWindow(_ sender: Any?) {
        let w = openWindow(isPrivate: false)
        w.showWindow(nil)
        w.newTab(nil)
    }

    @objc func newPrivateWindow(_ sender: Any?) {
        let w = openWindow(isPrivate: true)
        w.showWindow(nil)
        w.newTab(nil)
    }

    /// ⌘T with no window open.
    @objc func newTab(_ sender: Any?) { newWindow(sender) }

    // MARK: Session

    func sessionDidChange() {
        guard case .normal = options.mode else { return }
        sessionWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveSessionNow() }
        sessionWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    func saveSessionNow() {
        sessionWork?.cancel()
        guard case .normal = options.mode, let window = primaryWindow else { return }
        try? store.saveSession(tabs: window.sessionStates(), activeTabId: window.activeTab?.id)
    }

    // MARK: Recently closed

    func rememberClosedTab(url: URL, title: String) {
        closedTabs.append((url, title))
        if closedTabs.count > 25 { closedTabs.removeFirst() }
    }

    func popClosedTab() -> (url: URL, title: String)? { closedTabs.popLast() }

    // MARK: Keyboard

    private func installKeyMonitor() {
        // Ctrl+Tab never reaches the menu reliably (key-view loop, web content), so catch it here.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 48, event.modifierFlags.contains(.control) else { return event }
            MainActor.assumeIsolated {
                if event.modifierFlags.contains(.shift) {
                    self?.keyBrowserWindow?.selectPreviousTab(nil)
                } else {
                    self?.keyBrowserWindow?.selectNextTab(nil)
                }
            }
            return nil
        }
    }
}
