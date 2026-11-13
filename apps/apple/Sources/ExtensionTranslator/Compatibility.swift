// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// What WebKit (macOS 27, WKWebExtension) supports, as measured with a probe extension
/// on 13.11.2026 (docs/ERWEITERUNGS-TEST.md). Used to tell the user, before enabling,
/// what will probably not work. A guess from the manifest, not a guarantee.
public enum Compatibility {
    public enum Severity: String, Codable, Sendable, Comparable {
        case broken     // the extension's main purpose probably fails
        case missing    // a feature is missing; the rest may work
        case stubbed    // the translator provides a harmless stand-in; the feature itself does nothing
        case ignored    // ignored without visible effect

        private var rank: Int { [.broken: 0, .missing: 1, .stubbed: 2, .ignored: 3][self]! }
        public static func < (a: Severity, b: Severity) -> Bool { a.rank < b.rank }
    }

    public struct Issue: Codable, Sendable, Equatable {
        public let severity: Severity
        public let feature: String
        public let text: String
    }

    /// Permissions WebKit drops or provides without function (probe: requested → typeof chrome.X).
    static let permissionNotes: [String: (Severity, String)] = [
        "userScripts": (.broken, "User scripts cannot run: WebKit has no userScripts API. Userscript managers built for Manifest V3 cannot work."),
        "webRequestBlocking": (.missing, "Blocking or changing network requests with webRequest is not available (WebKit's webRequest only observes)."),
        "nativeMessaging": (.missing, "Native messaging (talking to a companion app on this Mac) is not available yet."),
        "notifications": (.stubbed, "Notifications are never shown (stand-in API)."),
        "idle": (.stubbed, "Idle detection always reports \"active\" (stand-in API)."),
        "offscreen": (.stubbed, "Offscreen documents are not supported (stand-in API reports an error)."),
        "sidePanel": (.stubbed, "The side panel is not available (stand-in API)."),
        "fontSettings": (.stubbed, "Font settings are not available (stand-in API)."),
        "downloads": (.missing, "The downloads API is not available."),
        "bookmarks": (.missing, "The bookmarks API is not available."),
        "history": (.missing, "The history API is not available."),
        "sessions": (.missing, "The sessions API (recently closed tabs) is not available."),
        "search": (.missing, "The search API is not available."),
        "identity": (.missing, "Sign-in through the identity API is not available."),
        "privacy": (.missing, "The privacy API is not available."),
        "proxy": (.missing, "Proxy settings are not available."),
        "debugger": (.missing, "The debugger API is not available."),
        "devtools": (.missing, "Developer-tools panels are not available."),
        "tabGroups": (.missing, "Tab groups are not available."),
        "topSites": (.missing, "Top sites are not available."),
        "tts": (.missing, "Text-to-speech is not available."),
        "ttsEngine": (.missing, "Text-to-speech engines are not available."),
        "management": (.missing, "The management API is not available."),
        "pageCapture": (.missing, "Saving pages (pageCapture) is not available."),
        "browsingData": (.missing, "Clearing browsing data is not available."),
        "contentSettings": (.missing, "Per-site content settings are not available."),
        "readingList": (.missing, "The reading list API is not available."),
        "clipboardRead": (.missing, "Reading the clipboard via permission is not available."),
        "webRequestAuthProvider": (.missing, "Answering HTTP authentication requests is not available."),
        "geolocation": (.ignored, "The geolocation permission is ignored."),
        "favicon": (.ignored, "The favicon permission is ignored."),
        "power": (.missing, "Keeping the system awake is not available."),
        "gcm": (.missing, "Push messages (gcm) are not available."),
        "declarativeNetRequestFeedback": (.ignored, "Rule-match feedback may be limited."),
    ]

    /// Manifest keys with a known effect when ignored.
    static let keyNotes: [String: (Severity, String)] = [
        "devtools_page": (.missing, "Developer-tools pages are not available."),
        "side_panel": (.missing, "The side panel page is not shown."),
        "sandbox": (.missing, "Sandboxed pages are not supported; features using them may fail."),
        "storage": (.ignored, "Managed storage (policies) is not available."),
        "oauth2": (.missing, "Chrome account sign-in (oauth2) is not available."),
        "chrome_settings_overrides": (.missing, "Search engine or homepage overrides are not applied."),
        "update_url": (.ignored, "No automatic updates: reinstall to update."),
        "incognito": (.ignored, "Extensions are always off in private windows."),
        "minimum_chrome_version": (.ignored, "Ignored."),
        "key": (.ignored, "Ignored."),
        "file_browser_handlers": (.missing, "File handlers are not available."),
        "tts_engine": (.missing, "Text-to-speech engines are not available."),
        "input_components": (.missing, "Input methods are not available."),
    ]

    /// Top-level manifest keys WebKit's parser handles (WebKit docs/source; same list as the extension report).
    public static let knownManifestKeys: Set<String> = [
        "manifest_version", "name", "short_name", "version", "version_name", "description", "author",
        "homepage_url", "default_locale", "icons", "action", "browser_action", "page_action", "background",
        "content_scripts", "content_security_policy", "permissions", "optional_permissions",
        "host_permissions", "optional_host_permissions", "web_accessible_resources", "options_page",
        "options_ui", "chrome_url_overrides", "browser_url_overrides", "commands", "declarative_net_request",
        "externally_connectable", "browser_specific_settings", "applications", "$schema",
    ]

    /// Expected issues for a manifest, most severe first.
    public static func issues(for manifest: [String: Any]) -> [Issue] {
        var out: [Issue] = []
        let declared = (((manifest["permissions"] as? [Any]) ?? []) + ((manifest["optional_permissions"] as? [Any]) ?? []))
            .compactMap { $0 as? String }
        for p in Set(declared).sorted() {
            if let (s, t) = permissionNotes[p] { out.append(Issue(severity: s, feature: "permission \(p)", text: t)) }
            else if p.hasPrefix("system.") { out.append(Issue(severity: .missing, feature: "permission \(p)", text: "System information APIs are not available.")) }
        }
        let mv = manifest["manifest_version"] as? Int ?? 2
        if mv == 2, declared.contains("webRequest"), !declared.contains("webRequestBlocking") {
            out.append(Issue(severity: .ignored, feature: "permission webRequest", text: "webRequest only observes requests."))
        }
        for key in manifest.keys.sorted() where !knownManifestKeys.contains(key) {
            let (s, t) = keyNotes[key] ?? (.ignored, "Ignored by WebKit.")
            out.append(Issue(severity: s, feature: "manifest key \(key)", text: t))
        }
        if let background = manifest["background"] as? [String: Any], background["persistent"] as? Bool == true, mv == 3 {
            out.append(Issue(severity: .ignored, feature: "background.persistent", text: "Ignored in Manifest V3."))
        }
        return out.sorted { $0.severity == $1.severity ? $0.feature < $1.feature : $0.severity < $1.severity }
    }
}
