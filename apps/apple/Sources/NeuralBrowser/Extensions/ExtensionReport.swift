// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import ExtensionTranslator
import WebKit

/// `--extension-report`: loads every extension in the folder into a
/// non-persistent controller and prints what the WebKit API says about it.
@MainActor
enum ExtensionReport {
    static func run(directory: URL) {
        Task { @MainActor in
            let config = WKWebExtensionController.Configuration.nonPersistent()
            config.defaultWebsiteDataStore = .nonPersistent()
            let base = WKWebViewConfiguration()
            base.applicationNameForUserAgent = ExtensionManager.extensionUserAgentName
            config.webViewConfiguration = base
            let controller = WKWebExtensionController(configuration: config)
            var entries: [[String: Any]] = []
            for folder in ExtensionManager.extensionFolders(in: directory) {
                entries.append(await report(folder: folder, controller: controller))
            }
            let output: [String: Any] = [
                "directory": directory.path,
                "count": entries.count,
                "loadedCount": entries.filter { ($0["loaded"] as? Bool) == true }.count,
                "extensions": entries,
            ]
            writeJSON(output)
            exit(0)
        }
    }

    static func report(folder: URL, controller: WKWebExtensionController) async -> [String: Any] {
        var entry: [String: Any] = ["folder": folder.lastPathComponent]
        let ext: WKWebExtension
        if let record = Installer.record(in: folder) {
            entry["translatedWithRuleSet"] = record.ruleSetVersion
            entry["translatorChanges"] = record.translation.changes.map { "\($0.rule) ×\($0.count)" }
        }
        do {
            ext = try await WKWebExtension(resourceBaseURL: Installer.loadableFolder(for: folder) ?? folder)
        } catch {
            entry["loaded"] = false
            entry["errors"] = [ExtensionManager.describe(error)]
            return entry
        }
        entry.merge(describe(ext)) { a, _ in a }

        let context = WKWebExtensionContext(for: ext)
        context.uniqueIdentifier = ExtensionManager.identifier(for: folder)
        for p in ext.requestedPermissions { context.setPermissionStatus(.grantedExplicitly, for: p) }
        for m in ext.allRequestedMatchPatterns { context.setPermissionStatus(.grantedExplicitly, for: m) }
        do {
            try controller.load(context)
            entry["loaded"] = context.isLoaded
        } catch {
            entry["loaded"] = false
            entry["loadError"] = ExtensionManager.describe(error)
        }
        FileHandle.standardError.write(Data("report: \(folder.lastPathComponent)\n".utf8))
        if ext.hasBackgroundContent, context.isLoaded {
            // Some backgrounds never report back; give up after 20 s instead of hanging.
            let error: String?? = await withCheckedContinuation { c in
                var resumed = false
                func resume(_ v: String??) { if !resumed { resumed = true; c.resume(returning: v) } }
                context.loadBackgroundContent { e in
                    MainActor.assumeIsolated { resume(.some(e.map(ExtensionManager.describe))) }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 20) { resume(nil) }
            }
            switch error {
            case .none: entry["backgroundLoaded"] = false; entry["backgroundError"] = "no answer within 20 s"
            case .some(.none): entry["backgroundLoaded"] = true
            case .some(.some(let e)): entry["backgroundLoaded"] = false; entry["backgroundError"] = e
            }
        }
        entry["contextErrors"] = context.errors.map(ExtensionManager.describe)
        if context.isLoaded { try? controller.unload(context) }
        return entry
    }

    /// Top-level manifest keys WebKit's parser handles (from WebKit's manifest
    /// documentation and source; a heuristic, kept short on purpose). Keys outside
    /// this list are ignored by WebKit *without* an error, so we report them.
    static let knownManifestKeys: Set<String> = [
        "manifest_version", "name", "short_name", "version", "version_name", "description", "author",
        "homepage_url", "default_locale", "icons", "action", "browser_action", "page_action", "background",
        "content_scripts", "content_security_policy", "permissions", "optional_permissions",
        "host_permissions", "optional_host_permissions", "web_accessible_resources", "options_page",
        "options_ui", "chrome_url_overrides", "browser_url_overrides", "commands", "declarative_net_request",
        "externally_connectable", "browser_specific_settings", "applications", "minimum_chrome_version",
        "update_url", "key", "incognito", "offline_enabled", "$schema",
    ]

    /// Static facts about an extension, as parsed by WebKit.
    static func describe(_ ext: WKWebExtension) -> [String: Any] {
        let manifest = ext.manifest
        let action = (manifest["action"] ?? manifest["browser_action"] ?? manifest["page_action"]) as? [String: Any]

        // Permissions the manifest declares but WebKit silently dropped.
        let declared = ((manifest["permissions"] as? [String]) ?? []) + ((manifest["optional_permissions"] as? [String]) ?? [])
        let recognized = Set((ext.requestedPermissions.union(ext.optionalPermissions)).map(\.rawValue))
        let ignored = declared.filter { p in
            !recognized.contains(p) && (try? WKWebExtension.MatchPattern(string: p)) == nil
        }
        let unknownKeys = manifest.keys.filter { !knownManifestKeys.contains($0) }.sorted()

        return [
            "ignoredPermissions": Array(Set(ignored)).sorted(),
            "unsupportedManifestKeys": unknownKeys,
            "name": ext.displayName ?? "?",
            "version": ext.version ?? ext.displayVersion ?? "?",
            "manifestVersion": ext.manifestVersion,
            "errors": ext.errors.map(ExtensionManager.describe),
            "permissions": ext.requestedPermissions.map(\.rawValue).sorted(),
            "optionalPermissions": ext.optionalPermissions.map(\.rawValue).sorted(),
            "hostPatterns": ext.allRequestedMatchPatterns.map(\.string).sorted(),
            "hasBackgroundContent": ext.hasBackgroundContent,
            "hasPersistentBackground": ext.hasPersistentBackgroundContent,
            "hasContentScripts": ext.hasInjectedContent,
            "hasPopup": (action?["default_popup"] as? String).map { !$0.isEmpty } ?? false,
            "hasOptionsPage": ext.hasOptionsPage,
            "hasCommands": ext.hasCommands,
            "hasContentModificationRules": ext.hasContentModificationRules,
        ]
    }

    static func writeJSON(_ object: Any) {
        guard let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
