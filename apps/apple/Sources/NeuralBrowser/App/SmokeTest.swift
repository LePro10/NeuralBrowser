// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import WebKit

/// `--smoke-test URL [URL …]`: opens a real browser window (in-memory store unless --profile-dir,
/// non-persistent extension storage), loads all URLs, verifies extensions
/// (content script, background reply, popup) and prints a JSON report.
/// Exit code 0 on success, 1 on load error or timeout.
@MainActor
final class SmokeTest {
    unowned let app: AppDelegate
    let urls: [URL]
    private var window: BrowserWindowController!
    private var loadStart = Date()
    private var tabResults: [String: [String: Any]] = [:]
    private var report: [String: Any] = [:]
    private var done = false
    private var wakeTab: BrowserTab?
    private var wakeContinuation: CheckedContinuation<Void, Never>?

    init(app: AppDelegate, urls: [URL]) {
        self.app = app
        self.urls = urls
    }

    private func ms(since date: Date) -> Int { Int(Date().timeIntervalSince(date) * 1000) }

    func run() {
        let timeout = app.options.timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.finish(ok: false, error: "timeout after \(Int(timeout))s")
        }
        guard !urls.isEmpty else { return finish(ok: false, error: "no URL given") }
        Task { await start() }
    }

    private func start() async {
        let extDir = app.options.resolvedExtensionsDirectory
        if ExtensionManager.hasExtensions(in: extDir) {
            let manager = app.enableExtensions(persistent: false)
            let started = Date()
            let results = await manager.loadAll(from: extDir, autoGrant: true)
            report["extensionLoadMs"] = ms(since: started)
            report["extensions"] = results.map { r -> [String: Any] in
                [
                    "folder": r.folder.lastPathComponent,
                    "name": r.webExtension?.displayName ?? "?",
                    "loaded": r.error == nil && (r.context?.isLoaded ?? false),
                    "error": r.error ?? NSNull(),
                    "warnings": r.webExtension?.errors.map(ExtensionManager.describe) ?? [],
                ]
            }
        }

        window = app.openWindow(isPrivate: app.options.privateWindow)
        app.downloads.onChange = { [weak self] in self?.downloadsChanged() }
        window.onTabFinishedLoading = { [weak self] tab in self?.tabFinished(tab) }
        window.onTabFailed = { [weak self] tab, error in
            self?.finish(ok: false, error: "\(tab.url?.absoluteString ?? "?"): \(ExtensionManager.describe(error))")
        }
        window.showWindow(nil)
        NSApp.activate()
        report["windowShownSinceLaunchMs"] = ms(since: app.processStart)

        loadStart = Date()
        for (i, url) in urls.enumerated() {
            let tab = window.addTab(url: url, activate: i == 0)
            if i > 0 { window.materialize(tab) } // load every tab (needed for RAM measurements)
        }
        window.refreshExtensionBar()
    }

    private func tabFinished(_ tab: BrowserTab) {
        guard !done else { return }
        if tabResults[tab.id] != nil {
            if tab === wakeTab { wakeContinuation?.resume(); wakeContinuation = nil }
            return
        }
        var result: [String: Any] = [
            "url": tab.url?.absoluteString ?? "",
            "title": tab.webView?.title ?? "",
            "loadMs": ms(since: loadStart),
        ]
        if tab === window.tabs.first { result["sinceLaunchMs"] = ms(since: app.processStart) }
        tabResults[tab.id] = result
        checkAllLoaded()
    }

    /// A URL that turns into a download never finishes as a page; count finished downloads instead.
    private var finishedDownloads: Int {
        app.downloads.items.filter { $0.state != .running }.count
    }

    private func downloadsChanged() {
        checkAllLoaded()
    }

    private var afterLoadStarted = false

    private func checkAllLoaded() {
        guard !afterLoadStarted, tabResults.count + finishedDownloads >= urls.count else { return }
        afterLoadStarted = true
        Task { await afterLoad() }
    }

    private func afterLoad() async {
        guard let first = window.tabs.first else { return }
        if let manager = app.extensionManager, !manager.contexts.isEmpty {
            await probeExtensions(manager, tab: first)
        }
        if app.options.sleepTest, window.tabs.count > 1 {
            await testSleep()
        }
        // Find in page (same code path as ⌘F): one word that exists, one that does not.
        let word = (await evaluate("(document.body.innerText.match(/[A-Za-z]{5,}/) || [''])[0]", in: first.webView) as? String) ?? ""
        window.select(first)
        window.findInPage(nil)
        let hit = await withCheckedContinuation { c in window.find(word, backwards: false) { c.resume(returning: $0) } }
        let miss = await withCheckedContinuation { c in window.find("zqxjzqxj", backwards: false) { c.resume(returning: $0) } }
        report["findInPage"] = ["word": word, "found": hit, "nonsenseFound": miss]

        if let path = app.options.screenshotPath {
            await saveScreenshot(to: URL(fileURLWithPath: path))
        }
        finish(ok: true, error: nil)
    }

    /// Renders the window's views, then composites a WebKit snapshot of the page
    /// (web content lives in another process and is not captured by cacheDisplay).
    private func saveScreenshot(to url: URL) async {
        guard let content = window.window?.contentView,
              let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
        content.cacheDisplay(in: content.bounds, to: rep)
        let image = NSImage(size: content.bounds.size)
        image.addRepresentation(rep)
        if let webView = window.activeTab?.webView, let page = try? await webView.takeSnapshot(configuration: nil) {
            let frame = webView.convert(webView.bounds, to: content)
            image.lockFocus()
            page.draw(in: frame)
            image.unlockFocus()
        }
        if let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
            report["screenshot"] = url.path
        }
    }

    // MARK: Extension checks

    private func probeExtensions(_ manager: ExtensionManager, tab: BrowserTab) async {
        // Content scripts run in an isolated world but share the DOM, so the page can see their marks.
        let js = """
            ({ title: document.title,
               hello: document.documentElement.dataset.helloExtension || null,
               background: document.documentElement.dataset.helloBackground || null })
            """
        var probe: [String: Any] = [:]
        for _ in 0..<40 {
            probe = (await evaluate(js, in: tab.webView) as? [String: Any]) ?? [:]
            if probe["hello"] is String, probe["background"] is String { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        probe["contentScriptRan"] = probe["hello"] is String
        report["contentScript"] = probe

        // Popup: perform the action like a click would, wait for the delegate, read the popup's DOM.
        guard let context = manager.contexts.first(where: { $0.action(for: tab)?.presentsPopup == true }),
              let action = context.action(for: tab) else { return }
        var presented = false
        manager.onPopupPresented = { _, _ in presented = true }
        context.userGesturePerformed(in: tab)
        context.performAction(for: tab)
        for _ in 0..<40 where !presented { try? await Task.sleep(for: .milliseconds(100)) }
        var text: Any = NSNull()
        if presented {
            for _ in 0..<40 {
                if let t = await evaluate("document.getElementById('out')?.textContent || ''", in: action.popupWebView) as? String,
                   !t.isEmpty, t != "…" {
                    text = t
                    break
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        report["popup"] = ["extension": context.webExtension.displayName ?? "?", "presented": presented, "text": text]
        action.closePopup()
    }

    // MARK: Sleeping tabs

    private func testSleep() async {
        let background = Array(window.tabs.dropFirst())
        let target = background[0]
        _ = await evaluate("window.scrollTo(0, 400); window.scrollY", in: target.webView)
        var slept: [Bool] = []
        for tab in background {
            slept.append(await withCheckedContinuation { c in tab.sleep { c.resume(returning: $0) } })
        }
        let asleep = background.map(\.isAsleep)
        let start = Date()
        wakeTab = target
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            wakeContinuation = c
            window.select(target)
        }
        try? await Task.sleep(for: .milliseconds(300))
        let scrollY = await evaluate("window.scrollY", in: target.webView)
        report["sleepTest"] = [
            "slept": slept,
            "asleepAfter": asleep,
            "wakeReloadMs": ms(since: start),
            "restoredScrollY": scrollY ?? NSNull(),
            "titleAfterWake": target.title,
        ]
    }

    // MARK: Helpers

    private func evaluate(_ js: String, in webView: WKWebView?) async -> Any? {
        guard let webView else { return nil }
        return await withCheckedContinuation { c in
            webView.evaluateJavaScript(js) { value, _ in c.resume(returning: value) }
        }
    }

    private func finish(ok: Bool, error: String?) {
        guard !done else { return }
        if app.options.storeBench, report["storeBench"] == nil {
            Task { @MainActor in
                self.report["storeBench"] = await StoreBench.run(on: self.app.store)
                self.finish(ok: ok, error: error)
            }
            return
        }
        done = true
        report["ok"] = ok
        report["error"] = error ?? NSNull()
        report["pid"] = Int(getpid())
        report["tabs"] = (window?.tabs ?? []).compactMap { tabResults[$0.id] }
        report["privateWindow"] = window?.isPrivate ?? false
        if app.options.profileDirectory != nil, !(window?.isPrivate ?? true) {
            // Throw-away profile: also store the session so a later normal start can restore it.
            app.store.saveSession(tabs: window.sessionStates(), activeTabId: window.activeTab?.id)
        }
        app.store.flush()
        report["historyEntries"] = (try? app.store.recentHistory(limit: 1000).count) ?? 0
        report["downloads"] = app.downloads.items.map { item -> [String: Any] in
            let size = item.destination.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] }
            return ["file": item.destination?.path ?? item.filename, "state": "\(item.state)", "bytes": size ?? 0]
        }
        ExtensionReport.writeJSON(report)
        let hold = app.options.hold
        DispatchQueue.main.asyncAfter(deadline: .now() + hold) { exit(ok ? 0 : 1) }
    }
}
