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
    private(set) var store: BrowserStore = RustStore.inMemory()
    private(set) var extensionManager: ExtensionManager?
    let downloads = DownloadManager()
    private(set) var windows: [BrowserWindowController] = []
    private var closedTabs: [(url: URL, title: String)] = []
    private var sessionWork: DispatchWorkItem?
    private var sleeper: TabSleeper?
    private var smokeTest: SmokeTest?
    private var extensionScript: ExtensionScript?
    private var keyMonitor: Any?
    private var extensionsWindow: ExtensionsWindowController?

    init(options: LaunchOptions) {
        self.options = options
    }

    /// True when nothing may be written to the user's real profile (self tests, reports).
    /// A script in `--normal-mode` uses its own `--data-dir` like the normal app.
    var isEphemeralProfile: Bool {
        switch options.mode {
        case .normal: return false
        case .extensionScript: return !scriptUsesProfile
        default: return true
        }
    }

    /// `--ext-script --normal-mode --data-dir DIR`: the script drives the normal app on a throw-away profile.
    var scriptUsesProfile: Bool {
        guard case .extensionScript = options.mode else { return false }
        return options.scriptNormalMode && options.dataDirectory != nil
    }

    /// Self tests never wait for a person: JS dialogs and permission prompts are answered automatically.
    var answersPromptsAutomatically: Bool {
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
            // Self tests never touch the real profile: memory, or a throw-away --profile-dir.
            if let dir = options.profileDirectory {
                store = RustStore(databaseURL: dir.appendingPathComponent("browser.sqlite"))
            } else {
                store = RustStore.inMemory()
            }
            let test = SmokeTest(app: self, urls: urls)
            smokeTest = test
            test.run()
        case .extensionReport:
            NSApp.setActivationPolicy(.prohibited)
            ExtensionReport.run(directory: options.resolvedExtensionsDirectory)
        case .extensionScript(let file):
            NSApp.setActivationPolicy(.regular)
            NSApp.mainMenu = MainMenu.build()
            if options.scriptNormalMode, options.dataDirectory == nil {
                ExtensionReport.writeJSON(["ok": false, "error": "--normal-mode needs --data-dir (never the real profile)"])
                exit(2)
            }
            store = scriptUsesProfile
                ? RustStore(databaseURL: options.resolvedDataDirectory.appendingPathComponent("browser.sqlite"))
                : RustStore.inMemory()
            let script = ExtensionScript(app: self, file: file)
            extensionScript = script
            script.run()
        case .installExtensions(let paths):
            NSApp.setActivationPolicy(.prohibited)
            ExtensionCLI.install(paths, into: options.resolvedExtensionsDirectory)
        case .retranslateExtensions:
            NSApp.setActivationPolicy(.prohibited)
            ExtensionCLI.retranslateAll(in: options.resolvedExtensionsDirectory)
        }
    }

    private func startNormal() {
        NSApp.mainMenu = MainMenu.build()
        installKeyMonitor()
        downloads.onChange = { [weak self] in self?.windows.forEach { $0.refreshDownloads() } }
        let dataDir = options.resolvedDataDirectory
        store = RustStore(databaseURL: dataDir.appendingPathComponent("browser.sqlite"))

        // Creating the controller is cheap and must happen before the first tab, so an
        // extension installed later reaches existing tabs; loading happens after the window is up.
        let extDir = options.resolvedExtensionsDirectory
        enableExtensions(persistent: true)

        let window = openWindow(isPrivate: false)
        if let session = try? store.loadSession(), !session.tabs.isEmpty {
            window.restore(session)
        }
        NSLog("NeuralBrowser: profile %@, restored %d tab(s), %d history entries",
              dataDir.path, window.tabs.count, (try? store.recentHistory(limit: 100000).count) ?? 0)
        window.showWindow(nil)
        NSApp.activate()
        if window.tabs.isEmpty { window.newTab(nil) }

        sleeper = TabSleeper(app: self)
        sleeper?.start()

        if let manager = extensionManager, ExtensionManager.hasExtensions(in: extDir) {
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

    // MARK: Extensions

    @objc func installExtension(_ sender: Any?) {
        guard case .normal = options.mode, let manager = extensionManager else { return }
        ExtensionInstallFlow.run(manager: manager, extensionsDir: options.resolvedExtensionsDirectory) { [weak self] in
            self?.extensionsWindow?.reload()
        }
    }

    @objc func showExtensions(_ sender: Any?) {
        guard case .normal = options.mode, let manager = extensionManager else { return }
        let controller = extensionsWindow ?? ExtensionsWindowController(manager: manager,
                                                                        extensionsDir: options.resolvedExtensionsDirectory)
        extensionsWindow = controller
        controller.reload()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

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
        store.saveSession(tabs: window.sessionStates(), activeTabId: window.activeTab?.id)
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
