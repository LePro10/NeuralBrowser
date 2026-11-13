// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// How a rule changes an extension. Preferred order: prelude (adds what is missing,
/// at runtime, only if still missing), manifest (structural), text (last resort).
///
/// Prelude rules work through a proxy around `globalThis.chrome`/`browser` (see Prelude.swift):
/// WebKit's namespace objects are recreated after garbage collection, so properties added to
/// them directly do not last, and the namespace properties of `chrome` cannot be replaced.
public enum RuleMechanism: String, Codable, Sendable {
    case manifest   // rewrites manifest.json
    case prelude    // part of the generated compatibility script loaded before the extension's code
    case text       // exact, counted text replacement in the extension's JavaScript
    case report     // changes nothing, only tells the user
}

/// Static description of one rule. Every rule is general (no per-extension cases),
/// has a reason and points to the finding that motivated it.
public struct RuleInfo: Codable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let mechanism: RuleMechanism
    /// Why the rule exists, in one or two sentences.
    public let reason: String
    /// Where the gap was observed (docs/ERWEITERUNGS-TEST.md, table rows / section).
    public let finding: String
}

/// One application of a rule during a translation.
public struct RuleHit: Codable, Sendable, Equatable {
    public var rule: String
    public var count: Int
    /// Files touched (relative paths), or namespaces/keys for prelude and report rules.
    public var details: [String]
}

/// The rule set. Bump `version` whenever a rule is added or its output changes;
/// installed extensions record the version they were translated with.
public enum RuleSet {
    public static let version = 2

    public static let manifestComments = RuleInfo(
        id: "manifest-comments", title: "Remove comments from manifest.json", mechanism: .manifest,
        reason: "Chrome accepts // and /* */ comments and trailing commas in manifest.json; WebKit rejects the whole extension (\"Unable to parse manifest\").",
        finding: "Vimium (table row 5, footnote 2)")
    public static let backgroundPrelude = RuleInfo(
        id: "background-prelude", title: "Load the compatibility prelude before the background code", mechanism: .manifest,
        reason: "Missing APIs must exist before the extension's background code runs. A service worker gets a small wrapper (importScripts or import) in its own folder; background scripts get the prelude prepended.",
        finding: "Section 3: missing APIs kill the background at start")
    public static let pagePrelude = RuleInfo(
        id: "page-prelude", title: "Load the compatibility prelude in extension pages", mechanism: .manifest,
        reason: "Popup, options and other extension pages use the same APIs as the background (Bitwarden's popup also reads chrome.scripting.ExecutionWorld). A <script src> as first element of <head> runs before every other script and passes the default CSP.",
        finding: "Bitwarden (row 1)")
    public static let contentPrelude = RuleInfo(
        id: "content-prelude", title: "Load the compatibility prelude before content scripts", mechanism: .manifest,
        reason: "Prepends the prelude to isolated-world content scripts, but only when a prelude rule targets content scripts. None does today: the content-script API surface (runtime, storage, i18n, dom, extension) matched Chrome in our tests. MAIN-world scripts are never touched.",
        finding: "Section 3 (probe of content-script namespaces, 13.11.2026)")
    public static let executionWorld = RuleInfo(
        id: "scripting-execution-world", title: "Provide chrome.scripting.ExecutionWorld", mechanism: .prelude,
        reason: "WebKit's scripting API accepts world: \"ISOLATED\"/\"MAIN\" but has no ExecutionWorld constant; code reading ExecutionWorld.ISOLATED throws and never injects its scripts. The prelude's chrome proxy answers scripting.ExecutionWorld while WebKit lacks it.",
        finding: "Bitwarden (row 1): autofill scripts never injected")
    public static let executionWorldText = RuleInfo(
        id: "scripting-execution-world-literal", title: "Replace ExecutionWorld.ISOLATED/MAIN with its string value", mechanism: .text,
        reason: "Backup for code that runs where the prelude is not loaded (for example files injected with scripting.executeScript). Only an exact member chain ending in scripting.ExecutionWorld.ISOLATED or .MAIN outside strings and comments is replaced, by the exact value Chrome has (\"ISOLATED\"/\"MAIN\"); files that fail a syntax check afterwards are left unchanged.",
        finding: "Bitwarden (row 1), minified as chrome.scripting.ExecutionWorld.ISOLATED")
    public static let browserAlias = RuleInfo(
        id: "browser-alias-patched-namespaces", title: "Route browser.* and chrome.* to the proxied name for patched namespaces", mechanism: .text,
        reason: "The prelude can replace only one of globalThis.chrome / globalThis.browser with its proxy (the name the code uses more); the other has to stay WebKit's own object, otherwise WebKit stops delivering events to the extension. In WebKit both names are the same object, so renaming e.g. `browser.permissions` → `chrome.permissions` (only for namespaces the prelude patches, only a free identifier, outside strings and comments, never in MAIN-world content scripts) changes nothing but routes the code through the fixes.",
        finding: "Violentmonkey (row 6) and Stylus (row 7) call browser.permissions.contains")
    public static let webNavigationEvents = RuleInfo(
        id: "webnavigation-missing-events", title: "Inert webNavigation events", mechanism: .prelude,
        reason: "WebKit lacks webNavigation.onHistoryStateUpdated, onReferenceFragmentUpdated, onTabReplaced and onCreatedNavigationTarget; addListener on undefined kills the background. The stand-in accepts listeners but never fires: in-page (history API) navigations are not reported.",
        finding: "Vimium (row 5), Stylus (row 7)")
    public static let permissionsContains = RuleInfo(
        id: "permissions-contains-unknown", title: "permissions.contains() answers false for unknown permissions", mechanism: .prelude,
        reason: "Chrome answers false for a permission it does not know or grant; WebKit throws \"not a valid permission\" synchronously, which kills the caller. The wrapper turns exactly that error into false and passes everything else through. It can only answer false, never grant anything.",
        finding: "Stylus (row 7), Violentmonkey (row 6)")
    public static let namespaceStubs = RuleInfo(
        id: "missing-namespace-stubs", title: "Harmless stand-ins for missing API namespaces", mechanism: .prelude,
        reason: "For namespaces the manifest requests but WebKit does not provide (notifications, idle, sidePanel, offscreen, fontSettings), a stand-in that never crashes: calls answer with neutral values (no notification is shown, idle state is \"active\", offscreen documents report as unsupported) and events never fire.",
        finding: "Violentmonkey (row 6, browser.notifications), Bitwarden, Vimium, Stylus (idle, offscreen)")
    public static let runtimeEvents = RuleInfo(
        id: "runtime-missing-events", title: "Inert runtime events", mechanism: .prelude,
        reason: "runtime.onUpdateAvailable, onSuspend, onSuspendCanceled and onRestartRequired are missing in WebKit. There are no automatic updates and no suspend notice, so a listener that never fires is accurate.",
        finding: "TWP (row 10): runtime.onUpdateAvailable")
    public static let webRequestConstants = RuleInfo(
        id: "webrequest-constants", title: "webRequest enum constants", mechanism: .prelude,
        reason: "WebKit has observe-only webRequest events but none of the enum objects (OnBeforeSendHeadersOptions, ResourceType, …); reading them throws. The constants carry Chrome's string values. Blocking still does not work.",
        finding: "Stylus (row 7): webRequest constants")
    public static let unsupportedKeys = RuleInfo(
        id: "unsupported-manifest-keys", title: "Report manifest keys WebKit ignores", mechanism: .report,
        reason: "WebKit ignores unknown manifest keys without an error. They are left in place (extensions read their own manifest) and listed for the user.",
        finding: "Section 3, extension report unsupportedManifestKeys")
    public static let unsupportedPermissions = RuleInfo(
        id: "unsupported-permissions", title: "Report permissions WebKit does not implement", mechanism: .report,
        reason: "WebKit silently drops permissions it does not know (userScripts, webRequestBlocking, downloads, …). The translator cannot add them; it tells the user what will not work.",
        finding: "Section 3 and 7 (userScripts, blocking webRequest)")

    /// Every rule, in the order they run.
    public static let all: [RuleInfo] = [
        manifestComments, backgroundPrelude, pagePrelude, contentPrelude,
        executionWorld, executionWorldText, browserAlias, webNavigationEvents, permissionsContains,
        namespaceStubs, runtimeEvents, webRequestConstants, unsupportedKeys, unsupportedPermissions,
    ]
}
