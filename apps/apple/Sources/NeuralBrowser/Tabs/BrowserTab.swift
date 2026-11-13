// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import WebKit

struct TabChange: OptionSet {
    let rawValue: Int
    static let title = TabChange(rawValue: 1 << 0)
    static let url = TabChange(rawValue: 1 << 1)
    static let loading = TabChange(rawValue: 1 << 2)
    static let favicon = TabChange(rawValue: 1 << 3)
    static let webView = TabChange(rawValue: 1 << 4)
    static let navigationState = TabChange(rawValue: 1 << 5)
}

/// One tab. The `WKWebView` is created lazily (first time the tab is shown)
/// and released again when the tab goes to sleep; URL, title and scroll
/// position survive in this object.
@MainActor
final class BrowserTab: NSObject {
    let id: String
    private(set) var url: URL?
    private(set) var title: String
    var pinned: Bool
    var lastActiveMs: Int64
    private(set) var favicon: NSImage?
    private(set) var webView: WKWebView?
    private(set) var isLoading = false
    weak var owner: BrowserWindowController?

    /// Scroll position remembered while asleep, re-applied after reload.
    private(set) var restoreScrollY: Double?
    private var observations: [NSKeyValueObservation] = []

    init(id: String = UUID().uuidString, url: URL?, title: String = "", pinned: Bool = false,
         lastActiveMs: Int64 = nowMs()) {
        self.id = id
        self.url = url
        self.title = title
        self.pinned = pinned
        self.lastActiveMs = lastActiveMs
    }

    var isAsleep: Bool { webView == nil }

    var displayTitle: String {
        if !title.isEmpty { return title }
        if let host = url?.host(), !host.isEmpty { return host }
        return url?.absoluteString ?? "New Tab"
    }

    // MARK: Web view lifecycle

    /// Attaches a freshly created web view. When `load` is true the tab's URL is loaded.
    func attach(_ webView: WKWebView, load: Bool) {
        self.webView = webView
        webView.navigationDelegate = self
        webView.uiDelegate = self
        observations = [
            webView.observe(\.title, options: [.new]) { [weak self] wv, _ in
                MainActor.assumeIsolated { self?.webViewTitleChanged(wv.title) }
            },
            webView.observe(\.url, options: [.new]) { [weak self] wv, _ in
                MainActor.assumeIsolated { self?.webViewURLChanged(wv.url) }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] wv, _ in
                MainActor.assumeIsolated {
                    self?.isLoading = wv.isLoading
                    self?.notify(.loading)
                }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.notify(.navigationState) }
            },
        ]
        if load, let url { Self.load(url, in: webView) }
        notify(.webView)
    }

    static func load(_ url: URL, in webView: WKWebView) {
        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    /// Loads `url` in this tab, creating the web view if needed.
    func navigate(to url: URL) {
        self.url = url
        if let webView {
            Self.load(url, in: webView)
        } else {
            owner?.materialize(self)
        }
        notify(.url)
    }

    /// Releases the web view unless media or capture is active. Calls back with `true` if it slept.
    func sleep(completion: @escaping (Bool) -> Void) {
        guard let webView else { return completion(false) }
        if webView.cameraCaptureState != .none || webView.microphoneCaptureState != .none {
            return completion(false)
        }
        webView.requestMediaPlaybackState { [weak self] state in
            MainActor.assumeIsolated {
                guard let self, state != .playing, self.webView === webView else { return completion(false) }
                webView.evaluateJavaScript("window.scrollY") { value, _ in
                    MainActor.assumeIsolated {
                        self.restoreScrollY = (value as? NSNumber)?.doubleValue
                        self.detachWebView()
                        completion(true)
                    }
                }
            }
        }
    }

    func detachWebView() {
        guard let webView else { return }
        observations = []
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
        self.webView = nil
        isLoading = false
        notify([.webView, .loading])
    }

    // MARK: Observation

    private func webViewTitleChanged(_ newTitle: String?) {
        guard let newTitle, !newTitle.isEmpty, newTitle != title else { return }
        title = newTitle
        notify(.title)
        owner?.tabTitleDidChange(self)
    }

    private func webViewURLChanged(_ newURL: URL?) {
        guard let newURL, newURL != url else { return }
        url = newURL
        notify(.url)
    }

    private func notify(_ change: TabChange) {
        owner?.tabDidChange(self, change)
    }

    fileprivate func applyFavicon(_ image: NSImage?) {
        favicon = image
        notify(.favicon)
    }
}

// MARK: - Navigation

extension BrowserTab: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        if navigationAction.shouldPerformDownload {
            return decisionHandler(.download)
        }
        // Cmd-click opens a background tab.
        if navigationAction.navigationType == .linkActivated,
           navigationAction.modifierFlags.contains(.command),
           let target = navigationAction.request.url {
            owner?.openTab(url: target, after: self, activate: false)
            return decisionHandler(.cancel)
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.isForMainFrame, !navigationResponse.canShowMIMEType {
            return decisionHandler(.download)
        }
        if let http = navigationResponse.response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition"),
           disposition.lowercased().hasPrefix("attachment") {
            return decisionHandler(.download)
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        owner?.app.downloads.track(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        owner?.app.downloads.track(download)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if let u = webView.url { url = u }
        owner?.tabDidCommit(self)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let y = restoreScrollY {
            restoreScrollY = nil
            webView.evaluateJavaScript("window.scrollTo(0, \(y))", completionHandler: nil)
        }
        loadFavicon(webView)
        owner?.tabDidFinishLoad(self)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        reportFailure(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        reportFailure(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    private func reportFailure(_ error: Error) {
        let ns = error as NSError
        // Cancelled navigations and policy-driven interruptions (downloads) are not failures.
        if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorCancelled { return }
        if ns.domain == "WebKitErrorDomain", ns.code == 102 { return }
        owner?.tabDidFailLoad(self, error: ns)
    }

    private func loadFavicon(_ webView: WKWebView) {
        guard let pageURL = webView.url, pageURL.scheme?.hasPrefix("http") == true else { return }
        let js = "(() => { const l = document.querySelector(\"link[rel~='icon']\"); return l ? l.href : null })()"
        webView.evaluateJavaScript(js) { [weak self] value, _ in
            MainActor.assumeIsolated {
                let iconURL = (value as? String).flatMap(URL.init(string:))
                    ?? URL(string: "/favicon.ico", relativeTo: pageURL)?.absoluteURL
                guard let self, let iconURL else { return }
                let ephemeral = (self.owner?.isPrivate ?? true) || (self.owner?.app.isEphemeralProfile ?? true)
                FaviconLoader.shared.load(iconURL, ephemeral: ephemeral) { image in
                    self.applyFavicon(image)
                }
            }
        }
    }
}

// MARK: - UI (new windows, JS dialogs, file pickers)

extension BrowserTab: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // target=_blank and window.open: WebKit loads the request into the view we return.
        owner?.openTab(configuration: configuration, after: self)?.webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        owner?.closeTab(self)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) {
        if owner?.app.isEphemeralProfile ?? false { return completionHandler() } // self tests never block
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host() ?? "Page"
        alert.informativeText = message
        alert.runModal()
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) {
        if owner?.app.isEphemeralProfile ?? false { return completionHandler(true) }
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host() ?? "Page"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor (String?) -> Void) {
        if owner?.app.isEphemeralProfile ?? false { return completionHandler(defaultText) }
        let alert = NSAlert()
        alert.messageText = prompt
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil)
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        completionHandler(panel.runModal() == .OK ? panel.urls : nil)
    }
}
