// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import NeuralCore
import WebKit

/// Content blocking: downloads filter lists, lets the Rust core convert them to WebKit
/// rule JSON, compiles them with `WKContentRuleListStore` and attaches the result to tabs.
///
/// Per-site switch: the compiled lists are detached from a tab while its main document is
/// on a switched-off site (decided on every main-frame navigation). That is instant; baking
/// the exceptions into the lists (`appendSiteExceptions`) would mean recompiling every
/// chunk (seconds each) for one click.
@MainActor
final class Shield {
    struct Source {
        let id: String
        let url: URL
    }

    /// Downloaded at run time, never bundled (EasyList/EasyPrivacy: GPL-3.0 / CC BY-SA 3.0).
    static let defaultSources = [
        Source(id: "easylist", url: URL(string: "https://easylist.to/easylist/easylist.txt")!),
        Source(id: "easyprivacy", url: URL(string: "https://easylist.to/easylist/easyprivacy.txt")!),
    ]
    /// Both lists declare "Expires: 4 days".
    static let maxAge: TimeInterval = 4 * 24 * 3600

    private struct Manifest: Codable {
        var identifiers: [String]
        var updatedAt: Double
        var ruleCount: Int
    }

    private let directory: URL
    private let settings: BrowserStore?
    private let ruleStore: WKContentRuleListStore?
    private(set) var ruleLists: [WKContentRuleList] = []
    private(set) var ruleCount = 0
    private(set) var lastError: String?
    private(set) var disabledHosts: Set<String> = []
    private(set) var isEnabled = true
    private var updating = false
    private var timer: Timer?
    /// Controllers that currently carry `ruleLists`.
    private let attached = NSHashTable<WKUserContentController>.weakObjects()
    /// All web views that asked for rules, so new lists reach open tabs.
    private let webViews = NSHashTable<WKWebView>.weakObjects()

    /// `settings` nil: nothing is persisted (self tests).
    init(directory: URL, settings: BrowserStore?) {
        self.directory = directory
        self.settings = settings
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        ruleStore = WKContentRuleListStore(url: directory.appendingPathComponent("compiled", isDirectory: true))
        if let settings {
            isEnabled = ((try? settings.getSetting(key: SettingKey.shieldEnabled)) ?? nil) != "false"
            let hosts = ((try? settings.getSetting(key: SettingKey.shieldDisabledHosts)) ?? nil) ?? ""
            disabledHosts = Set(hosts.split(separator: "\n").map(String.init))
        }
    }

    private var manifestURL: URL { directory.appendingPathComponent("manifest.json") }

    // MARK: Loading and updating

    /// Normal start: use the lists compiled earlier (fast), refresh in the background when old.
    func start() {
        Task { @MainActor in
            let age = await loadCompiled()
            if age == nil || age! > Self.maxAge { await update() }
            // Long-running app: look once in a while whether the lists expired.
            timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let m = self.readManifest() else { return }
                    if Date().timeIntervalSince1970 - m.updatedAt > Self.maxAge { await self.update() }
                }
            }
        }
    }

    private func readManifest() -> Manifest? {
        guard let data = try? Data(contentsOf: manifestURL) else { return nil }
        return try? JSONDecoder().decode(Manifest.self, from: data)
    }

    /// Returns the age of the compiled lists in seconds, nil when there are none.
    private func loadCompiled() async -> TimeInterval? {
        guard let ruleStore, let manifest = readManifest(), !manifest.identifiers.isEmpty else { return nil }
        var lists: [WKContentRuleList] = []
        for id in manifest.identifiers {
            guard let list = try? await ruleStore.contentRuleList(forIdentifier: id) else { return nil }
            lists.append(list)
        }
        install(lists, ruleCount: manifest.ruleCount)
        NSLog("NeuralBrowser: shield: %d rules in %d list(s) from the last build", manifest.ruleCount, lists.count)
        return Date().timeIntervalSince1970 - manifest.updatedAt
    }

    /// Downloads the lists and rebuilds the rules. A list that cannot be downloaded
    /// falls back to its last downloaded copy.
    func update() async {
        let sources = Self.defaultSources
        guard !updating else { return }
        updating = true
        defer { updating = false }
        var inputs: [FilterListInput] = []
        let session = URLSession(configuration: .ephemeral)
        for source in sources {
            let cache = directory.appendingPathComponent("\(source.id).txt")
            var text: String?
            if let (data, response) = try? await session.data(from: source.url),
               (response as? HTTPURLResponse)?.statusCode == 200,
               let body = String(data: data, encoding: .utf8), body.count > 1000 {
                text = body
                try? data.write(to: cache, options: .atomic)
            } else {
                NSLog("NeuralBrowser: shield: download of %@ failed, using the cached copy", source.id)
                text = try? String(contentsOf: cache, encoding: .utf8)
            }
            if let text { inputs.append(FilterListInput(id: source.id, text: text)) }
        }
        guard !inputs.isEmpty else {
            lastError = "no filter list available"
            NSLog("NeuralBrowser: shield: no filter list available")
            return
        }
        await build(from: inputs)
    }

    /// Converts (background thread) and compiles the lists, then swaps them into all tabs.
    func build(from inputs: [FilterListInput]) async {
        guard let ruleStore else { return }
        let started = Date()
        let conversion: ShieldConversion
        do {
            conversion = try await Task.detached(priority: .utility) {
                try convertFilterLists(lists: inputs, maxRulesPerChunk: defaultMaxRulesPerChunk())
            }.value
        } catch {
            lastError = "convert: \(error)"
            NSLog("NeuralBrowser: shield: conversion failed: %@", "\(error)")
            return
        }
        // A new identifier per build: a half-finished build never mixes with the old lists.
        let generation = String(Int(Date().timeIntervalSince1970))
        var lists: [WKContentRuleList] = []
        var ids: [String] = []
        for (i, chunk) in conversion.chunks.enumerated() where chunk.ruleCount > 0 {
            let id = "shield-\(generation)-\(i)"
            do {
                guard let list = try await ruleStore.compileContentRuleList(
                    forIdentifier: id, encodedContentRuleList: chunk.json) else { continue }
                lists.append(list)
                ids.append(id)
            } catch {
                lastError = "compile: \(error.localizedDescription)"
                NSLog("NeuralBrowser: shield: compiling %@ failed: %@", id, "\(error)")
                for done in ids { try? await ruleStore.removeContentRuleList(forIdentifier: done) }
                return
            }
        }
        let old = readManifest()?.identifiers ?? []
        let count = Int(conversion.stats.totalUniqueRules)
        let manifest = Manifest(identifiers: ids, updatedAt: Date().timeIntervalSince1970, ruleCount: count)
        try? JSONEncoder().encode(manifest).write(to: manifestURL, options: .atomic)
        install(lists, ruleCount: count)
        lastError = nil
        for id in old where !ids.contains(id) { try? await ruleStore.removeContentRuleList(forIdentifier: id) }
        NSLog("NeuralBrowser: shield: %d rules in %d list(s), built in %.1f s",
              count, lists.count, Date().timeIntervalSince(started))
    }

    private func install(_ lists: [WKContentRuleList], ruleCount: Int) {
        for controller in attached.allObjects {
            ruleLists.forEach { controller.remove($0) }
        }
        attached.removeAllObjects()
        ruleLists = lists
        self.ruleCount = ruleCount
        // Open tabs get the rules now; they act on the requests made from here on.
        for webView in webViews.allObjects { apply(to: webView, url: webView.url) }
    }

    // MARK: Attaching

    /// Attaches or detaches the rules for a main document at `url`.
    /// Call before a web view's first load and on every main-frame navigation.
    func apply(to webView: WKWebView, url: URL?) {
        webViews.add(webView)
        let controller = webView.configuration.userContentController
        let wanted = !ruleLists.isEmpty && isActive(for: url)
        if wanted, !attached.contains(controller) {
            ruleLists.forEach { controller.add($0) }
            attached.add(controller)
        } else if !wanted, attached.contains(controller) {
            ruleLists.forEach { controller.remove($0) }
            attached.remove(controller)
        }
    }

    // MARK: Switches

    /// Web pages only: extension pages, files and internal pages are never filtered.
    static func siteKey(for url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var host = url.host()?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    func isSiteDisabled(_ url: URL?) -> Bool {
        guard let host = Self.siteKey(for: url) else { return false }
        return disabledHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    func isActive(for url: URL?) -> Bool {
        isEnabled && Self.siteKey(for: url) != nil && !isSiteDisabled(url)
    }

    /// Switches blocking off (or on again) for the site of `url` and its subdomains.
    func setSiteDisabled(_ disabled: Bool, for url: URL?) {
        guard let host = Self.siteKey(for: url) else { return }
        if disabled {
            disabledHosts.insert(host)
        } else {
            disabledHosts = disabledHosts.filter { !(host == $0 || host.hasSuffix("." + $0)) }
        }
        try? settings?.setSetting(key: SettingKey.shieldDisabledHosts,
                                  value: disabledHosts.sorted().joined(separator: "\n"))
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        try? settings?.setSetting(key: SettingKey.shieldEnabled, value: enabled ? "true" : "false")
        for webView in webViews.allObjects { apply(to: webView, url: webView.url) }
    }

    /// Self tests: remove the throw-away directory.
    func removeFiles() {
        try? FileManager.default.removeItem(at: directory)
    }
}
