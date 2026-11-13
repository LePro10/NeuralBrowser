// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import ExtensionTranslator
import WebKit

/// `--ext-script STEPS.json`: drives a real browser window step by step to test
/// extensions (in-memory profile, everything granted, dialogs auto-answered).
/// Prints one JSON report with a result per step. Exit 0 = all steps ran.
///
/// Script: `{"steps": [ … ]}`. Each step is an object with one of these keys:
///   {"open": URL, "newTab": false, "wait": 1}   load in the active tab (or a new one)
///       URL may be `ext:FOLDER/path`, `ext:FOLDER/@options` or `ext:FOLDER/@popup`.
///   {"wait": 2}                                    sleep (seconds)
///   {"eval": "return document.title", "target": "tab", "until": true, "timeout": 10}
///       async JS function body in the page world; with `until` it is polled until truthy.
///       target: "tab" (default), "popup:FOLDER", "background:FOLDER" (SPI, may be unavailable)
///   {"shot": "/tmp/x.png", "target": "window"}     target: "window" (default), "tab", "popup:FOLDER"
///   {"popup": FOLDER}                              run the extension's action (performAction, like a click)
///   {"clickAction": FOLDER}                        real mouse click on the extension's sidebar button
///   {"install": "/path/pkg.zip"}                   File ▸ Install Extension… with "Install and Enable" chosen
///   {"closePopup": FOLDER}
///   {"extensionsWindow": "/tmp/x.png"}             open the Extensions window, save a picture, return each summary
///   {"loadBackground": FOLDER}                    start the background content (service worker) now
///   {"popupState": FOLDER}                         is the popover still shown? (closes are also logged as events)
///   {"keys": "f{Esc}"}                             real key events to the active web view
///   {"click": "css selector", "target": "tab"}     real mouse click at the element's center
///   {"selectTab": 0}
///   {"errors": true}                               WebKit's error list of every extension
/// With `--normal-mode --data-dir DIR` the script runs like the normal app on that (throw-away)
/// profile: persistent store, WebKit website data and extension storage, extensions loaded with the
/// grants stored in the profile. Run the same script twice on one DIR to test an app restart.
/// Top level `"assumeVisible": true` turns off WebKit's window-occlusion detection for tab and popup
/// web views (SPI, test only). Note: popups that stayed on a spinner and backgrounds that stopped
/// answering after a few seconds were not caused by a locked screen but by tracking prevention
/// deleting the background's service worker (see ExtensionManager.exemptFromTrackingPrevention).
@MainActor
final class ExtensionScript {
    unowned let app: AppDelegate
    let file: URL
    private var window: BrowserWindowController!
    private var results: [[String: Any]] = []
    private var report: [String: Any] = [:]
    private var done = false
    private var loadWaiters: [(tab: BrowserTab, c: CheckedContinuation<Bool, Never>)] = []
    private var popoverObserver: NSObjectProtocol?
    private var assumeVisible = false

    init(app: AppDelegate, file: URL) {
        self.app = app
        self.file = file
    }

    func run() {
        let timeout = app.options.timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.finish(ok: false, error: "timeout after \(Int(timeout))s")
        }
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let steps = json["steps"] as? [[String: Any]] else {
            return finish(ok: false, error: "cannot read script \(file.path)")
        }
        assumeVisible = json["assumeVisible"] as? Bool ?? false
        Task { await start(steps) }
    }

    private var manager: ExtensionManager? { app.extensionManager }

    private func start(_ steps: [[String: Any]]) async {
        let extDir = app.options.resolvedExtensionsDirectory
        if app.scriptUsesProfile {
            // Same order as AppDelegate.startNormal: controller first, window, then load what the
            // user enabled, with the grants stored in the profile (no autoGrant).
            report["mode"] = "normal"
            report["dataDir"] = app.options.resolvedDataDirectory.path
            let manager = app.enableExtensions(persistent: true)
            openWindow()
            let results = await manager.loadAll(from: extDir, autoGrant: false)
            window.refreshExtensionBar()
            report["extensions"] = results.map(Self.describe)
        } else {
            report["mode"] = "memory"
            if ExtensionManager.hasExtensions(in: extDir) {
                let manager = app.enableExtensions(persistent: false)
                let results = await manager.loadAll(from: extDir, autoGrant: true)
                report["extensions"] = results.map(Self.describe)
            }
            openWindow()
        }

        for (i, step) in steps.enumerated() {
            guard !done else { return }
            var result = await perform(step)
            result["step"] = i
            if let label = step["label"] { result["label"] = label }
            results.append(result)
        }
        report["finalErrors"] = extensionErrors()
        report["dataStores"] = dataStores()
        finish(ok: true, error: nil)
    }

    /// Which website data store tabs and extension pages really use, and whether WebKit's tracking
    /// prevention (ITP, read through an SPI getter) runs on it.
    private func dataStores() -> [String: Any] {
        func info(_ store: WKWebsiteDataStore?) -> Any {
            guard let store else { return NSNull() }
            let itp = NSSelectorFromString("_resourceLoadStatisticsEnabled")
            return ["persistent": store.isPersistent, "identifier": store.identifier?.uuidString ?? "default",
                    "isDefault": store === WKWebsiteDataStore.default(), "sameAsTabs": store === app.websiteDataStore,
                    "trackingPrevention": store.responds(to: itp) ? (store.value(forKey: "_resourceLoadStatisticsEnabled") ?? NSNull()) : "unknown"]
        }
        var out: [String: Any] = ["tabs": info(window.activeTab?.webView?.configuration.websiteDataStore)]
        out["cookiesAPI"] = info(manager?.controller.configuration.defaultWebsiteDataStore)
        // What WebKit really gives extension web views (background, popup), checked per extension.
        let pageStores = (manager?.contexts ?? []).compactMap { $0.webViewConfiguration?.websiteDataStore }
        out["extensionPages"] = info(pageStores.first)
        out["allExtensionsUseIt"] = pageStores.allSatisfy { $0 === app.websiteDataStore }
        return out
    }

    private static func describe(_ r: ExtensionManager.LoadResult) -> [String: Any] {
        [
            "folder": r.folder.lastPathComponent,
            "name": r.webExtension?.displayName ?? "?",
            "loaded": r.error == nil && (r.context?.isLoaded ?? false),
            "error": r.error ?? NSNull(),
            "warnings": r.webExtension?.errors.map(ExtensionManager.describe) ?? [],
            "baseURL": r.context?.baseURL.absoluteString ?? NSNull(),
        ]
    }

    private func openWindow() {
        window = app.openWindow(isPrivate: false)
        window.onTabFinishedLoading = { [weak self] tab in self?.tabFinished(tab) }
        window.onTabFailed = { [weak self] tab, error in
            self?.tabFinished(tab)
            self?.results.append(["event": "loadFailed", "url": tab.url?.absoluteString ?? "?",
                                  "error": ExtensionManager.describe(error)])
        }
        window.showWindow(nil)
        NSApp.activate()
        window.refreshExtensionBar()
    }

    // MARK: Steps

    private func forceVisible(_ webView: WKWebView?) {
        guard assumeVisible, let webView, webView.responds(to: NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")) else { return }
        webView.setValue(false, forKey: "windowOcclusionDetectionEnabled")
    }

    private func perform(_ step: [String: Any]) async -> [String: Any] {
        defer {
            // `popupWebView` is created on first access: only touch it when asked to, otherwise the
            // test itself would create and load the popup off-screen before the user's click.
            if assumeVisible {
                forceVisible(window.activeTab?.webView)
                for ctx in manager?.contexts ?? [] { forceVisible(ctx.action(for: window.activeTab)?.popupWebView) }
            }
        }
        if let target = step["open"] as? String { return await open(target, newTab: step["newTab"] as? Bool ?? false,
                                                                     wait: step["wait"] as? Double ?? 0.5) }
        if let seconds = step["wait"] as? Double {
            try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
            return ["wait": seconds]
        }
        if let js = step["eval"] as? String {
            return await evalStep(js, target: step["target"] as? String ?? "tab",
                                  until: step["until"] as? Bool ?? false, timeout: step["timeout"] as? Double ?? 10)
        }
        if let path = step["shot"] as? String { return await shot(path, target: step["target"] as? String ?? "window") }
        if let folder = step["popup"] as? String { return await openPopup(folder) }
        if let folder = step["clickAction"] as? String { return await clickAction(folder) }
        if let path = step["install"] as? String { return await install(path) }
        if let folder = step["closePopup"] as? String {
            context(folder).flatMap { $0.action(for: window.activeTab) }?.closePopup()
            return ["closePopup": folder]
        }
        if let path = step["extensionsWindow"] as? String { return extensionsWindow(png: path) }
        if let folder = step["loadBackground"] as? String {
            guard let ctx = context(folder) else { return ["loadBackground": folder, "error": "no such extension"] }
            let error: Error? = await withCheckedContinuation { c in ctx.loadBackgroundContent { c.resume(returning: $0) } }
            return ["loadBackground": folder, "error": error.map { ExtensionManager.describe($0) } ?? NSNull()]
        }
        if let folder = step["popupState"] as? String {
            let action = context(folder).flatMap { $0.action(for: window.activeTab) }
            let shown = action?.popupPopover?.isShown ?? false // popupPopover/-WebView are created on access
            return ["popupState": folder, "shown": shown,
                    "popupURL": (shown ? action?.popupWebView?.url?.absoluteString : nil) ?? NSNull()]
        }
        if let keys = step["keys"] as? String { return await sendKeys(keys) }
        if let selector = step["click"] as? String { return await click(selector) }
        if let index = step["selectTab"] as? Int {
            if index < window.tabs.count { window.select(window.tabs[index]) }
            return ["selectTab": index, "url": window.activeTab?.url?.absoluteString ?? ""]
        }
        if step["errors"] != nil { return ["errors": extensionErrors()] }
        return ["error": "unknown step \(step)"]
    }

    private func context(_ folder: String) -> WKWebExtensionContext? {
        manager?.contexts.first { $0.uniqueIdentifier == ExtensionManager.identifier(for: URL(fileURLWithPath: folder)) }
    }

    /// `ext:FOLDER/path` → the extension's base URL + path; `@options` / `@popup` are looked up.
    private func resolve(_ target: String) -> URL? {
        guard target.hasPrefix("ext:") else { return URL(string: target) }
        let rest = target.dropFirst(4)
        let folder = String(rest.prefix { $0 != "/" })
        let path = String(rest.dropFirst(folder.count + 1))
        guard let ctx = context(folder) else { return nil }
        switch path {
        case "@options": return ctx.optionsPageURL
        case "@popup":
            let manifest = ctx.webExtension.manifest
            let action = (manifest["action"] ?? manifest["browser_action"]) as? [String: Any]
            return (action?["default_popup"] as? String).flatMap { URL(string: $0, relativeTo: ctx.baseURL)?.absoluteURL }
        default: return URL(string: path, relativeTo: ctx.baseURL)?.absoluteURL
        }
    }

    private func open(_ target: String, newTab: Bool, wait: Double) async -> [String: Any] {
        guard let url = resolve(target) else { return ["open": target, "error": "cannot resolve"] }
        let start = Date()
        let finished: Bool = await withCheckedContinuation { c in
            let tab: BrowserTab
            if newTab || window.activeTab == nil {
                tab = window.openTab(url: url)
            } else {
                tab = window.activeTab!
                tab.navigate(to: url)
            }
            forceVisible(tab.webView)
            loadWaiters.append((tab, c))
            let waiterTab = tab
            DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in self?.resumeWaiters(for: waiterTab, ok: false) }
        }
        try? await Task.sleep(for: .milliseconds(Int(wait * 1000)))
        return ["open": url.absoluteString, "loaded": finished, "ms": Int(Date().timeIntervalSince(start) * 1000),
                "title": window.activeTab?.webView?.title ?? "", "finalURL": window.activeTab?.webView?.url?.absoluteString ?? ""]
    }

    private func tabFinished(_ tab: BrowserTab) { resumeWaiters(for: tab, ok: true) }

    private func resumeWaiters(for tab: BrowserTab, ok: Bool) {
        let matching = loadWaiters.filter { $0.tab === tab }
        loadWaiters.removeAll { $0.tab === tab }
        matching.forEach { $0.c.resume(returning: ok) }
    }

    private func webView(for target: String) -> WKWebView? {
        if target.hasPrefix("popup:") {
            return context(String(target.dropFirst(6)))?.action(for: window.activeTab)?.popupWebView
        }
        if target.hasPrefix("background:") {
            // WebKit SPI, used only by this test tool; nil if the selector is gone.
            guard let ctx = context(String(target.dropFirst(11))),
                  ctx.responds(to: NSSelectorFromString("_backgroundWebView")) else { return nil }
            return ctx.value(forKey: "_backgroundWebView") as? WKWebView
        }
        return window.activeTab?.webView
    }

    private func evalStep(_ js: String, target: String, until: Bool, timeout: Double) async -> [String: Any] {
        guard let webView = webView(for: target) else { return ["eval": js, "target": target, "error": "no web view"] }
        let deadline = Date().addingTimeInterval(timeout)
        var last: (Any?, String?) = (nil, nil)
        repeat {
            last = await callAsync(js, in: webView)
            if !until || Self.truthy(last.0) { break }
            try? await Task.sleep(for: .milliseconds(250))
        } while Date() < deadline
        var r: [String: Any] = ["eval": String(js.prefix(80)), "target": target,
                                "value": Self.jsonSafe(last.0)]
        if let error = last.1 { r["jsError"] = error }
        if until { r["satisfied"] = Self.truthy(last.0) }
        return r
    }

    /// Runs an async JS function body; gives up after 8 s (a page that never answers must not stall the run).
    private func callAsync(_ js: String, in webView: WKWebView, arguments: [String: Any] = [:]) async -> (Any?, String?) {
        await withCheckedContinuation { c in
            var resumed = false
            func resume(_ v: (Any?, String?)) { if !resumed { resumed = true; c.resume(returning: v) } }
            webView.callAsyncJavaScript(js, arguments: arguments, in: nil, in: .page) { result in
                switch result {
                case .success(let v): resume((v, nil))
                case .failure(let e): resume((nil, ExtensionManager.describe(e)))
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { resume((nil, "no answer within 8 s")) }
        }
    }

    static func truthy(_ v: Any?) -> Bool {
        switch v {
        case nil, is NSNull: return false
        case let b as Bool: return b
        case let n as NSNumber: return n.doubleValue != 0
        case let s as String: return !s.isEmpty
        default: return true
        }
    }

    static func jsonSafe(_ v: Any?) -> Any {
        guard let v, !(v is NSNull) else { return NSNull() }
        if JSONSerialization.isValidJSONObject([v]) { return v }
        return "\(v)"
    }

    private func openPopup(_ folder: String) async -> [String: Any] {
        guard let ctx = context(folder), let manager else { return ["popup": folder, "error": "extension not loaded"] }
        guard let tab = window.activeTab else { return ["popup": folder, "error": "no tab"] }
        window.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true) // a popover closes again in an inactive app
        var presented = false
        manager.onPopupPresented = { _, c in if c === ctx { presented = true } }
        ctx.userGesturePerformed(in: tab)
        let opened = Date()
        ctx.performAction(for: tab)
        for _ in 0..<200 where !presented { try? await Task.sleep(for: .milliseconds(100)) }
        let action = ctx.action(for: tab)
        forceVisible(action?.popupWebView)
        // Log when (and why) the popover closes, for the Bitwarden "closes after a second" bug.
        if let popover = action?.popupPopover {
            if let popoverObserver { NotificationCenter.default.removeObserver(popoverObserver) }
            popoverObserver = NotificationCenter.default.addObserver(forName: NSPopover.willCloseNotification, object: popover,
                                                                     queue: .main) { [weak self] note in
                let reason = (note.userInfo?[NSPopover.closeReasonUserInfoKey] as? NSPopover.CloseReason)?.rawValue ?? "?"
                MainActor.assumeIsolated {
                    self?.results.append(["event": "popoverWillClose", "popup": folder, "reason": reason,
                                          "afterMs": Int(Date().timeIntervalSince(opened) * 1000),
                                          "appActive": NSApp.isActive, "behavior": popover.behavior.rawValue,
                                          "stack": Thread.callStackSymbols.prefix(30).map { String($0.dropFirst(4)) }])
                }
            }
        }
        var loaded = false
        if presented, let wv = action?.popupWebView {
            for _ in 0..<50 { if !wv.isLoading { loaded = true; break }; try? await Task.sleep(for: .milliseconds(100)) }
        }
        return ["popup": folder, "presentsPopup": action?.presentsPopup ?? false, "presented": presented, "appActive": NSApp.isActive,
                "popupLoaded": loaded, "popupURL": action?.popupWebView?.url?.absoluteString ?? NSNull(),
                "popupSize": action?.popupWebView.map { "\(Int($0.frame.width))x\(Int($0.frame.height))" } ?? NSNull()]
    }

    /// A real mouse click on the extension's button in the sidebar, the way a user opens the popup.
    /// The mouse-up is queued first: NSButton tracks the click in its own event loop.
    private func clickAction(_ folder: String) async -> [String: Any] {
        guard let ctx = context(folder), let manager else { return ["clickAction": folder, "error": "extension not loaded"] }
        guard let nsWindow = window.window, let button = window.extensionButton(for: ctx) else {
            return ["clickAction": folder, "error": "no button in the sidebar"]
        }
        nsWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try? await Task.sleep(for: .milliseconds(200))
        var presented = false
        manager.onPopupPresented = { _, c in if c === ctx { presented = true } }
        let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: nsWindow.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        // What a real click at that point would hit (an overlapping view would swallow it).
        let hit = nsWindow.contentView?.superview?.hitTest(point) ?? nsWindow.contentView?.hitTest(point)
        let hitsButton = hit === button || hit?.isDescendant(of: button) == true
        guard let down = event(.leftMouseDown), let up = event(.leftMouseUp) else { return ["clickAction": folder, "error": "no event"] }
        NSApp.postEvent(up, atStart: false)
        nsWindow.sendEvent(down)
        for _ in 0..<100 where !presented { try? await Task.sleep(for: .milliseconds(100)) }
        let action = ctx.action(for: window.activeTab)
        forceVisible(action?.popupWebView)
        var loaded = false
        if presented, let wv = action?.popupWebView {
            for _ in 0..<50 { if !wv.isLoading { loaded = true; break }; try? await Task.sleep(for: .milliseconds(100)) }
        }
        return ["clickAction": folder, "hitsButton": hitsButton, "buttonEnabled": (button as? NSControl)?.isEnabled ?? false,
                "hasTarget": (button as? NSControl)?.target != nil, "hitView": hit.map { "\(type(of: $0))" } ?? NSNull(),
                "at": "\(Int(point.x)),\(Int(point.y))", "presented": presented, "popoverShown": action?.popupPopover?.isShown ?? false,
                "popupLoaded": loaded, "popupURL": action?.popupWebView?.url?.absoluteString ?? NSNull()]
    }

    /// File ▸ Install Extension… without the panel and with "Install and Enable" chosen:
    /// unpack + translate, move into the profile, remember the grant, load into the running app.
    private func install(_ path: String) async -> [String: Any] {
        guard let manager else { return ["install": path, "error": "extensions off"] }
        let dir = app.options.resolvedExtensionsDirectory
        let pending = dir.appendingPathComponent(".pending-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: pending) }
        let source = URL(fileURLWithPath: path)
        let result = await Task.detached { Result { try Installer.install(from: source, into: pending) } }.value
        do {
            let record = try result.get()
            try ExtensionInstallFlow.commit(record, from: pending, manager: manager, extensionsDir: dir)
            await manager.setEnabled(true, id: record.id, in: dir)
            return ["install": path, "id": record.id, "loaded": manager.context(id: record.id)?.isLoaded ?? false]
        } catch {
            return ["install": path, "error": "\(error)"]
        }
    }

    // MARK: Screenshots

    private func shot(_ path: String, target: String) async -> [String: Any] {
        let url = URL(fileURLWithPath: path)
        var image: NSImage?
        if target == "window" {
            image = await windowImage()
        } else if let wv = webView(for: target) {
            image = try? await wv.takeSnapshot(configuration: nil)
        }
        guard let image, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            return ["shot": path, "error": "no image"]
        }
        try? png.write(to: url)
        return ["shot": path, "size": "\(Int(image.size.width))x\(Int(image.size.height))"]
    }

    /// The management window and the text the install dialog shows, for a check without clicking.
    private func extensionsWindow(png path: String) -> [String: Any] {
        guard let manager else { return ["extensionsWindow": path, "error": "extensions off"] }
        let dir = app.options.resolvedExtensionsDirectory
        let controller = ExtensionsWindowController(manager: manager, extensionsDir: dir)
        controller.reload()
        controller.showWindow(nil)
        var result: [String: Any] = ["extensionsWindow": path]
        if let content = controller.window?.contentView, let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        result["summaries"] = ExtensionManager.extensionFolders(in: dir).compactMap { folder -> [String: String]? in
            Installer.record(in: folder).map { ["id": $0.id, "text": ExtensionSummary.text($0)] }
        }
        controller.close()
        return result
    }

    /// Window views via cacheDisplay plus WebKit snapshots of the page and an open popup.
    private func windowImage() async -> NSImage? {
        guard let content = window.window?.contentView,
              let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return nil }
        content.cacheDisplay(in: content.bounds, to: rep)
        let image = NSImage(size: content.bounds.size)
        image.addRepresentation(rep)
        if let webView = window.activeTab?.webView, let page = try? await webView.takeSnapshot(configuration: nil) {
            let frame = webView.convert(webView.bounds, to: content)
            image.lockFocus()
            page.draw(in: frame)
            image.unlockFocus()
        }
        return image
    }

    // MARK: Input

    private static let keyCodes: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
        "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
        "9": 25, "7": 26, "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40,
        "n": 45, "m": 46, "/": 44, "?": 44, ".": 47, ",": 43, " ": 49,
    ]

    private func sendKeys(_ text: String) async -> [String: Any] {
        guard let nsWindow = window.window, let wv = window.activeTab?.webView else { return ["keys": text, "error": "no web view"] }
        nsWindow.makeKeyAndOrderFront(nil)
        nsWindow.makeFirstResponder(wv)
        var tokens: [String] = []
        var rest = Substring(text)
        while let ch = rest.first {
            if ch == "{", let end = rest.firstIndex(of: "}") {
                tokens.append(String(rest[rest.index(after: rest.startIndex)..<end]))
                rest = rest[rest.index(after: end)...]
            } else {
                tokens.append(String(ch))
                rest = rest.dropFirst()
            }
        }
        for token in tokens {
            var chars = token
            var code: UInt16 = 0
            var flags: NSEvent.ModifierFlags = []
            switch token {
            case "Esc": chars = "\u{1b}"; code = 53
            case "Enter": chars = "\r"; code = 36
            case "Tab": chars = "\t"; code = 48
            default:
                let c = Character(token.lowercased())
                code = Self.keyCodes[c] ?? 0
                if token != token.lowercased() || token == "?" { flags.insert(.shift) }
            }
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                                            timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: nsWindow.windowNumber, context: nil, characters: chars,
                                            charactersIgnoringModifiers: chars.lowercased(), isARepeat: false, keyCode: code) {
                    nsWindow.sendEvent(e)
                }
            }
            try? await Task.sleep(for: .milliseconds(120))
        }
        return ["keys": text]
    }

    private func click(_ selector: String) async -> [String: Any] {
        guard let nsWindow = window.window, let wv = window.activeTab?.webView else { return ["click": selector, "error": "no web view"] }
        let js = """
            const el = document.querySelector(sel); if (!el) return null;
            el.scrollIntoView({block: 'center'}); const r = el.getBoundingClientRect();
            return [r.left + r.width / 2, r.top + r.height / 2];
            """
        nsWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let (value, err) = await callAsync(js, in: wv, arguments: ["sel": selector])
        guard let xy = value as? [Double], xy.count == 2 else { return ["click": selector, "error": err ?? "not found"] }
        let local = NSPoint(x: xy[0], y: wv.isFlipped ? xy[1] : wv.bounds.height - xy[1])
        let point = wv.convert(local, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let e = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                          timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: nsWindow.windowNumber, context: nil,
                                          eventNumber: 0, clickCount: 1, pressure: 1) {
                nsWindow.sendEvent(e)
            }
            try? await Task.sleep(for: .milliseconds(60))
        }
        return ["click": selector, "at": xy]
    }

    // MARK: Report

    private func extensionErrors() -> [String: Any] {
        var out: [String: Any] = [:]
        for ctx in manager?.contexts ?? [] {
            out[ctx.webExtension.displayName ?? ctx.uniqueIdentifier] = ctx.errors.map(ExtensionManager.describe)
        }
        return out
    }

    private func finish(ok: Bool, error: String?) {
        guard !done else { return }
        done = true
        report["ok"] = ok
        report["error"] = error ?? NSNull()
        report["steps"] = results
        ExtensionReport.writeJSON(report)
        DispatchQueue.main.asyncAfter(deadline: .now() + app.options.hold) { exit(ok ? 0 : 1) }
    }
}
