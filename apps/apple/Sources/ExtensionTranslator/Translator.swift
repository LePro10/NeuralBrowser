// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Result of one translation: which rules changed what, and what will probably not work.
public struct TranslationReport: Codable, Sendable, Equatable {
    public var ruleSetVersion: Int
    public var hits: [RuleHit]
    public var issues: [Compatibility.Issue]
    /// Generated files (relative to the patched folder).
    public var addedFiles: [String]
    public var warnings: [String]

    /// Hits of rules that actually changed something (not report-only rules).
    public var changes: [RuleHit] {
        hits.filter { hit in RuleSet.all.first { $0.id == hit.rule }?.mechanism != .report }
    }
}

/// Rewrites an extension so known WebKit gaps are bridged. Works on a copy:
/// `original` is never modified, `patched` is created from scratch.
public enum Translator {
    public static let preludeName = "nb-compat.js"
    static let wrapperName = "nb-sw-wrapper.js"

    public static func translate(original: URL, into patched: URL, limits: InstallLimits = InstallLimits()) throws -> TranslationReport {
        let fm = FileManager.default
        if fm.fileExists(atPath: patched.path) { try fm.removeItem(at: patched) }
        _ = try FileTree.copy(from: original, to: patched, limits: limits)

        let manifestURL = patched.appendingPathComponent("manifest.json")
        guard let manifestData = try? Data(contentsOf: manifestURL) else { throw InstallError.badManifest("manifest.json missing") }
        let parsed = try JSONC.parseObject(manifestData)
        let originalManifest = parsed.object
        var manifest = originalManifest
        var hits: [RuleHit] = []
        var added: [String] = []
        var warnings: [String] = []
        var manifestChanged = parsed.relaxed

        if parsed.relaxed {
            hits.append(RuleHit(rule: RuleSet.manifestComments.id, count: max(1, parsed.comments + parsed.trailingCommas),
                                details: ["manifest.json: \(parsed.comments) comment(s), \(parsed.trailingCommas) trailing comma(s)"]))
        }

        let files = try FileTree.files(in: patched)
        let sandboxPages = Set((((manifest["sandbox"] as? [String: Any])?["pages"] as? [String]) ?? []).map(normalize))
        let pages = files.filter { ($0.hasSuffix(".html") || $0.hasSuffix(".htm")) && !sandboxPages.contains($0) }
        let facts = ManifestFacts(manifest: manifest, hasPages: !pages.isEmpty)

        // Which global the prelude proxies: the name the extension's code uses more (see Prelude.swift).
        let mainWorld = Self.mainWorldScripts(manifest)
        var usage = (chrome: 0, browser: 0)
        for file in files where (file.hasSuffix(".js") || file.hasSuffix(".mjs")) && !mainWorld.contains(file) {
            if let data = try? Data(contentsOf: patched.appendingPathComponent(file)) {
                let u = TextRules.apiRootUsage(in: data)
                usage.chrome += u.chrome
                usage.browser += u.browser
            }
        }
        let proxyGlobal = usage.browser > usage.chrome ? "browser" : "chrome"
        let otherGlobal = proxyGlobal == "chrome" ? "browser" : "chrome"

        // Prelude: one generated file, loaded before the extension's code.
        let parts = Prelude.selectedParts(facts)
        if !parts.isEmpty {
            let prelude = unique(preludeName, in: "", existing: Set(files))
            try Data(Prelude.source(for: facts, proxyGlobal: proxyGlobal).utf8).write(to: patched.appendingPathComponent(prelude))
            added.append(prelude)
            for (part, details) in parts { hits.append(RuleHit(rule: part.rule.id, count: 1, details: details)) }

            // Background.
            if var background = manifest["background"] as? [String: Any] {
                if let sw = background["service_worker"] as? String {
                    let path = normalize(sw)
                    if files.contains(path) {
                        let dir = (path as NSString).deletingLastPathComponent
                        let wrapper = unique(wrapperName, in: dir, existing: Set(files + added))
                        let base = (path as NSString).lastPathComponent
                        let isModule = (background["type"] as? String) == "module"
                        let source = isModule
                            ? "// NeuralBrowser: compatibility prelude first, then the original service worker.\nimport \"/\(prelude)\";\nimport \"./\(base)\";\n"
                            : "// NeuralBrowser: compatibility prelude first, then the original service worker.\nimportScripts(\"/\(prelude)\", \"./\(base)\");\n"
                        try Data(source.utf8).write(to: patched.appendingPathComponent(wrapper))
                        added.append(wrapper)
                        background["service_worker"] = wrapper
                        hits.append(RuleHit(rule: RuleSet.backgroundPrelude.id, count: 1,
                                            details: ["service_worker \(path) → \(wrapper) (\(isModule ? "module import" : "importScripts"))"]))
                    } else {
                        warnings.append("background service worker \(sw) not found in package")
                    }
                } else if let scripts = background["scripts"] as? [String], !scripts.isEmpty {
                    background["scripts"] = [prelude] + scripts
                    hits.append(RuleHit(rule: RuleSet.backgroundPrelude.id, count: 1, details: ["background.scripts: prepended \(prelude)"]))
                }
                manifest["background"] = background
                manifestChanged = true
            }

            // Extension pages (popup, options, background page, …).
            var touched: [String] = []
            for page in pages {
                let url = patched.appendingPathComponent(page)
                guard let html = try? String(contentsOf: url, encoding: .utf8),
                      let out = insertPrelude(into: html, src: "/\(prelude)") else { continue }
                try Data(out.utf8).write(to: url)
                touched.append(page)
            }
            if !touched.isEmpty { hits.append(RuleHit(rule: RuleSet.pagePrelude.id, count: touched.count, details: touched)) }
        }

        // Text rules. ExecutionWorld constants: everywhere (also files injected with scripting.executeScript,
        // where the prelude does not run). browser → chrome: only where the prelude's proxy exists or the
        // code calls the API anyway; never in MAIN-world content scripts (page context).
        let aliasNamespaces = Set(parts.compactMap { part, _ in Self.aliasNamespace[part.rule.id] })
        var counts: [String: (count: Int, files: [String])] = [:]
        var textSkipped = 0
        for file in files where file.hasSuffix(".js") || file.hasSuffix(".mjs") {
            let url = patched.appendingPathComponent(file)
            guard var data = try? Data(contentsOf: url) else { continue }
            var changed = false
            let world = TextRules.replaceExecutionWorld(in: data)
            textSkipped += world.skipped
            if world.replaced > 0 {
                data = world.text; changed = true
                counts[RuleSet.executionWorldText.id, default: (0, [])].count += world.replaced
                counts[RuleSet.executionWorldText.id, default: (0, [])].files.append("\(file) (\(world.replaced))")
            }
            if !mainWorld.contains(file) {
                let alias = TextRules.alias(in: data, from: otherGlobal, to: proxyGlobal, namespaces: aliasNamespaces)
                textSkipped += alias.skipped
                if alias.replaced > 0 {
                    data = alias.text; changed = true
                    counts[RuleSet.browserAlias.id, default: (0, [])].count += alias.replaced
                    counts[RuleSet.browserAlias.id, default: (0, [])].files.append("\(file) (\(alias.replaced))")
                }
            }
            if changed { try data.write(to: url) }
        }
        for rule in [RuleSet.executionWorldText, RuleSet.browserAlias] {
            guard let c = counts[rule.id] else { continue }
            let note = rule.id == RuleSet.browserAlias.id
                ? ["\(otherGlobal).<namespace> → \(proxyGlobal).<namespace> (code names chrome \(usage.chrome)×, browser \(usage.browser)×)"] : []
            hits.append(RuleHit(rule: rule.id, count: c.count, details: note + c.files))
        }
        if textSkipped > 0 { warnings.append("text rules: \(textSkipped) match(es) left unchanged (ambiguous position or failed syntax check)") }

        // Report-only rules.
        let unknownKeys = manifest.keys.filter { !Compatibility.knownManifestKeys.contains($0) }.sorted()
        if !unknownKeys.isEmpty { hits.append(RuleHit(rule: RuleSet.unsupportedKeys.id, count: unknownKeys.count, details: unknownKeys)) }
        let issues = Compatibility.issues(for: originalManifest)
        let permIssues = issues.filter { $0.feature.hasPrefix("permission ") && $0.severity != .ignored }
        if !permIssues.isEmpty {
            hits.append(RuleHit(rule: RuleSet.unsupportedPermissions.id, count: permIssues.count,
                                details: permIssues.map { String($0.feature.dropFirst("permission ".count)) }))
        }

        try PermissionGuard.verify(original: originalManifest, patched: manifest, prelude: added.first)
        if manifestChanged {
            let out = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try out.write(to: manifestURL)
        }
        return TranslationReport(ruleSetVersion: RuleSet.version, hits: hits, issues: issues, addedFiles: added, warnings: warnings)
    }

    /// Namespaces whose members the prelude's chrome proxy patches (rule id → namespace).
    static let aliasNamespace: [String: String] = [
        RuleSet.executionWorld.id: "scripting",
        RuleSet.webNavigationEvents.id: "webNavigation",
        RuleSet.permissionsContains.id: "permissions",
        RuleSet.webRequestConstants.id: "webRequest",
    ]

    /// Content scripts that run in the page's own world (no extension APIs, never touched).
    static func mainWorldScripts(_ manifest: [String: Any]) -> Set<String> {
        let scripts = (manifest["content_scripts"] as? [[String: Any]]) ?? []
        return Set(scripts.filter { ($0["world"] as? String)?.uppercased() == "MAIN" }
            .flatMap { ($0["js"] as? [String]) ?? [] }.map(normalize))
    }

    /// Inserts `<script src>` as the first element of <head> (or after <html>/doctype). Nil if already present.
    static func insertPrelude(into html: String, src: String) -> String? {
        let tag = "<script src=\"\(src)\"></script>"
        if html.contains(tag) { return nil }
        for pattern in ["<head(\\s[^>]*)?>", "<html(\\s[^>]*)?>", "<!doctype[^>]*>"] {
            if let r = html.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                return html.replacingCharacters(in: r.upperBound..<r.upperBound, with: tag)
            }
        }
        return tag + html
    }

    /// Manifest paths may start with "/" or "./".
    static func normalize(_ path: String) -> String {
        var p = path
        while p.hasPrefix("./") { p.removeFirst(2) }
        while p.hasPrefix("/") { p.removeFirst() }
        return p
    }

    static func unique(_ name: String, in dir: String, existing: Set<String>) -> String {
        let join = { (n: String) in dir.isEmpty ? n : dir + "/" + n }
        var candidate = join(name)
        var n = 1
        while existing.contains(candidate) {
            candidate = join(name.replacingOccurrences(of: ".js", with: "-\(n).js"))
            n += 1
        }
        return candidate
    }
}

/// The translator must never widen what an extension may do. Checked after every translation.
enum PermissionGuard {
    static func verify(original: [String: Any], patched: [String: Any], prelude: String?) throws {
        let keys = Set(original.keys).union(patched.keys)
        for key in keys where key != "background" {
            guard NSDictionary(dictionary: [key: original[key] ?? NSNull()])
                .isEqual(to: [key: patched[key] ?? NSNull()]) else {
                throw InstallError.translation("manifest key \(key) changed")
            }
        }
        let a = (original["background"] as? [String: Any]) ?? [:]
        let b = (patched["background"] as? [String: Any]) ?? [:]
        for key in Set(a.keys).union(b.keys) where key != "service_worker" && key != "scripts" {
            guard NSDictionary(dictionary: [key: a[key] ?? NSNull()]).isEqual(to: [key: b[key] ?? NSNull()]) else {
                throw InstallError.translation("background.\(key) changed")
            }
        }
        if let old = a["scripts"] as? [String] {
            let new = b["scripts"] as? [String] ?? []
            guard new == old || (prelude != nil && new == [prelude!] + old) else { throw InstallError.translation("background.scripts changed") }
        }
        if let old = a["service_worker"] as? String, let new = b["service_worker"] as? String, old != new {
            guard new.hasSuffix(".js"), new.contains("nb-sw-wrapper") else { throw InstallError.translation("background.service_worker changed") }
        }
    }
}

/// Hooks for the offline self test.
public enum TranslatorTesting {
    public static func verifyPermissions(original: [String: Any], patched: [String: Any]) throws {
        try PermissionGuard.verify(original: original, patched: patched, prelude: nil)
    }
}
