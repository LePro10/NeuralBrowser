// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Builds the compatibility prelude: one generated JavaScript file that runs before the
/// extension's own code in the background and in extension pages.
///
/// Why a proxy: WebKit's API namespace objects (`chrome.webNavigation`, `chrome.permissions`, …)
/// are wrappers that are created on demand and dropped by the garbage collector, and the
/// namespace properties of `chrome` cannot be replaced. A property added to a namespace object
/// therefore vanishes after a while (measured 13.11.2026: `chrome.webNavigation.x = …` was gone
/// after a GC). `globalThis.chrome` itself is writable, so the prelude replaces it with a proxy
/// that forwards everything to the real API and only fills members that are still missing at
/// the moment they are read. `globalThis.browser` must stay the real object (WebKit stops
/// delivering events when neither global is), so a text rule routes `browser.<ns>` to `chrome.<ns>`.
/// Missing namespaces (notifications, …) are added to the real API object itself, which lasts.
/// A future WebKit that implements a member wins automatically.
///
/// Nothing here adds a permission: stand-ins answer with neutral values, and the
/// permissions wrapper can only turn an "unknown permission" error into `false`.
public enum Prelude {
    /// One prelude part. `detail` decides from the manifest whether it is included.
    struct Part {
        let rule: RuleInfo
        let detail: (ManifestFacts) -> [String]   // empty = not included
        let js: (ManifestFacts) -> String
    }

    /// Namespaces we provide stand-ins for, and only when the manifest asks for them.
    static let stubbedNamespaces = ["notifications", "idle", "sidePanel", "offscreen", "fontSettings"]

    static let parts: [Part] = [
        Part(rule: RuleSet.executionWorld,
             detail: { $0.permissions.contains("scripting") ? ["scripting.ExecutionWorld"] : [] },
             js: { _ in """
                addMember("scripting", "ExecutionWorld", () => Object.freeze({ ISOLATED: "ISOLATED", MAIN: "MAIN" }),
                          "scripting-execution-world");
                """ }),
        Part(rule: RuleSet.webNavigationEvents,
             detail: { $0.permissions.contains("webNavigation") ? ["webNavigation"] : [] },
             js: { _ in """
                for (const name of ["onHistoryStateUpdated", "onReferenceFragmentUpdated", "onTabReplaced", "onCreatedNavigationTarget"])
                  addMember("webNavigation", name, inertEvent, "webnavigation-missing-events");
                """ }),
        Part(rule: RuleSet.permissionsContains,
             detail: { $0.hasBackgroundOrPages ? ["permissions.contains"] : [] },
             js: { _ in """
                wrapMember("permissions", "contains", (current) => {
                  const unknown = (e) => /not a valid permission|is not a valid|unknown permission/i.test(String(e && e.message || e));
                  return function contains(query, callback) {
                    const ns = current();
                    let result;
                    try {
                      result = ns.contains.apply(ns, arguments);
                    } catch (e) {
                      if (!unknown(e)) throw e;
                      used("permissions-contains-unknown");
                      return reply(callback, false);
                    }
                    if (result && typeof result.then === "function" && typeof callback !== "function")
                      return result.catch((e) => { if (unknown(e)) { used("permissions-contains-unknown"); return false; } throw e; });
                    return result;
                  };
                });
                """ }),
        Part(rule: RuleSet.namespaceStubs,
             detail: { facts in stubbedNamespaces.filter { facts.permissions.contains($0) } },
             js: { facts in
                 let wanted = stubbedNamespaces.filter { facts.permissions.contains($0) }
                 let list = wanted.map { "\"\($0)\"" }.joined(separator: ", ")
                 return """
                    const stubs = {
                      notifications: () => {
                        let next = 0;
                        return {
                          create(a, b, c) {
                            const id = typeof a === "string" && a ? a : "nb-notification-" + (++next);
                            return reply(typeof a === "string" ? c : b, id);
                          },
                          update: (id, o, cb) => reply(cb, false),
                          clear: (id, cb) => reply(cb, false),
                          getAll: (cb) => reply(cb, {}),
                          getPermissionLevel: (cb) => reply(cb, "denied"),
                          onClicked: inertEvent(), onClosed: inertEvent(), onButtonClicked: inertEvent(),
                          onShowSettings: inertEvent(), onPermissionLevelChanged: inertEvent(),
                          TemplateType: Object.freeze({ BASIC: "basic", IMAGE: "image", LIST: "list", PROGRESS: "progress" }),
                          PermissionLevel: Object.freeze({ GRANTED: "granted", DENIED: "denied" }),
                        };
                      },
                      idle: () => ({
                        queryState: (s, cb) => reply(cb, "active"),
                        setDetectionInterval: () => undefined,
                        getAutoLockDelay: (cb) => reply(cb, 0),
                        onStateChanged: inertEvent(),
                        IdleState: Object.freeze({ ACTIVE: "active", IDLE: "idle", LOCKED: "locked" }),
                      }),
                      sidePanel: () => ({
                        setOptions: (o, cb) => reply(cb, undefined),
                        getOptions: (o, cb) => reply(cb, { enabled: false }),
                        setPanelBehavior: (o, cb) => reply(cb, undefined),
                        getPanelBehavior: (cb) => reply(cb, { openPanelOnActionClick: false }),
                        open: (o, cb) => fail(cb, "sidePanel is not supported in this browser"),
                      }),
                      offscreen: () => ({
                        hasDocument: (cb) => reply(cb, false),
                        createDocument: (o, cb) => fail(cb, "offscreen documents are not supported in this browser"),
                        closeDocument: (cb) => reply(cb, undefined),
                        Reason: new Proxy({}, { get: (t, k) => typeof k === "string" ? k : undefined }),
                      }),
                      fontSettings: () => ({
                        getFontList: (cb) => reply(cb, []),
                        getFont: (d, cb) => reply(cb, { fontId: "", levelOfControl: "not_controllable" }),
                        setFont: (d, cb) => reply(cb, undefined), clearFont: (d, cb) => reply(cb, undefined),
                        getDefaultFontSize: (d, cb) => reply(cb, { pixelSize: 16, levelOfControl: "not_controllable" }),
                        onFontChanged: inertEvent(), onDefaultFontSizeChanged: inertEvent(),
                      }),
                    };
                    for (const name of [\(list)]) addNamespace(name, stubs[name], "missing-namespace-stubs");
                    """
             }),
        Part(rule: RuleSet.runtimeEvents,
             detail: { $0.hasBackgroundOrPages ? ["runtime"] : [] },
             js: { _ in """
                for (const name of ["onUpdateAvailable", "onSuspend", "onSuspendCanceled", "onRestartRequired"])
                  addMember("runtime", name, inertEvent, "runtime-missing-events");
                """ }),
        Part(rule: RuleSet.webRequestConstants,
             detail: { $0.permissions.contains("webRequest") ? ["webRequest"] : [] },
             js: { _ in """
                const H = "extraHeaders", B = "blocking", RQ = "requestHeaders", RS = "responseHeaders";
                const enums = {
                  OnBeforeRequestOptions: { BLOCKING: B, REQUEST_BODY: "requestBody", EXTRA_HEADERS: H },
                  OnBeforeSendHeadersOptions: { REQUEST_HEADERS: RQ, BLOCKING: B, EXTRA_HEADERS: H },
                  OnSendHeadersOptions: { REQUEST_HEADERS: RQ, EXTRA_HEADERS: H },
                  OnHeadersReceivedOptions: { BLOCKING: B, RESPONSE_HEADERS: RS, EXTRA_HEADERS: H },
                  OnAuthRequiredOptions: { RESPONSE_HEADERS: RS, BLOCKING: B, ASYNC_BLOCKING: "asyncBlocking", EXTRA_HEADERS: H },
                  OnResponseStartedOptions: { RESPONSE_HEADERS: RS, EXTRA_HEADERS: H },
                  OnBeforeRedirectOptions: { RESPONSE_HEADERS: RS, EXTRA_HEADERS: H },
                  OnCompletedOptions: { RESPONSE_HEADERS: RS, EXTRA_HEADERS: H },
                  OnErrorOccurredOptions: { EXTRA_HEADERS: H },
                  ResourceType: { MAIN_FRAME: "main_frame", SUB_FRAME: "sub_frame", STYLESHEET: "stylesheet", SCRIPT: "script",
                    IMAGE: "image", FONT: "font", OBJECT: "object", XMLHTTPREQUEST: "xmlhttprequest", PING: "ping",
                    CSP_REPORT: "csp_report", MEDIA: "media", WEBSOCKET: "websocket", WEBBUNDLE: "webbundle", OTHER: "other" },
                };
                for (const [k, v] of Object.entries(enums)) addMember("webRequest", k, () => Object.freeze(v), "webrequest-constants");
                """ }),
    ]

    /// Parts included for this manifest (rule id → details).
    static func selectedParts(_ facts: ManifestFacts) -> [(Part, [String])] {
        parts.compactMap { part in
            let d = part.detail(facts)
            return d.isEmpty ? nil : (part, d)
        }
    }

    /// The generated prelude source.
    /// `proxyGlobal` is "chrome" or "browser": the name the extension's code mostly uses.
    static func source(for facts: ManifestFacts, proxyGlobal: String = "chrome") -> String {
        let other = proxyGlobal == "chrome" ? "browser" : "chrome"
        let body = selectedParts(facts).map { part, _ in
            "  // Rule \(part.rule.id): \(part.rule.title)\n  try {\n" +
                part.js(facts).split(separator: "\n", omittingEmptySubsequences: false).map { "    " + $0 }.joined(separator: "\n") +
                "\n  } catch (e) { failed.push(\"\(part.rule.id): \" + e); }\n"
        }.joined(separator: "\n")
        return """
            // NeuralBrowser compatibility prelude, rule set \(RuleSet.version). Generated at install time; do not edit.
            // It runs before the extension's own code and only fills APIs WebKit is missing.
            // Rules: docs/ERWEITERUNGEN.md. Source: apps/apple/Sources/ExtensionTranslator/Prelude.swift.
            (function () {
              "use strict";
              const g = globalThis;
              // WebKit has no Symbol.dispose / Symbol.asyncDispose yet. Code transpiled for `using`
              // (Bitwarden: background, popup, inline menu) throws "Symbol.dispose is not defined".
              for (const name of ["dispose", "asyncDispose"]) {
                if (typeof Symbol[name] !== "symbol") {
                  try { Object.defineProperty(Symbol, name, { value: Symbol.for("Symbol." + name) }); } catch (e) {}
                }
              }
              // Extension pages carry a Chrome token in their user agent (ExtensionManager), but the
              // background service worker can start without it. Bitwarden then detects no browser at
              // all and its background crashes ("this.device.toString", popup spins forever).
              try {
                const ua = g.navigator && g.navigator.userAgent;
                if (typeof ua === "string" && g.location && g.location.protocol === "webkit-extension:" &&
                    ua.indexOf(" Chrome/") === -1) {
                  const fixed = ua.replace(/ Safari\\/[\\d.]+$/, "") + " Chrome/142.0.0.0 Safari/605.1.15";
                  Object.defineProperty(g.navigator, "userAgent", { get: () => fixed, configurable: true });
                }
              } catch (e) {}
              const applied = new Set(), failed = [];
              const used = (rule) => { applied.add(rule); };
              // Registries filled by the rules below: missing members, wrapped members, missing namespaces.
              const members = Object.create(null), wrappers = Object.create(null), namespaces = Object.create(null);
              const addMember = (ns, key, make, rule) => { (members[ns] || (members[ns] = Object.create(null)))[key] = { make, rule }; };
              const wrapMember = (ns, key, make) => { (wrappers[ns] || (wrappers[ns] = Object.create(null)))[key] = { make }; };
              const addNamespace = (name, make, rule) => { namespaces[name] = { make, rule }; };
              const inertEvent = () => {
                const listeners = new Set();
                return {
                  addListener: (f) => { listeners.add(f); },
                  removeListener: (f) => { listeners.delete(f); },
                  hasListener: (f) => listeners.has(f),
                  hasListeners: () => listeners.size > 0,
                };
              };
              const reply = (cb, value) => {
                if (typeof cb === "function") { setTimeout(() => cb(value), 0); return undefined; }
                return Promise.resolve(value);
              };
              let lastErrorTarget = null;
              const fail = (cb, message) => {
                if (typeof cb === "function") {
                  setTimeout(() => {
                    try { Object.defineProperty(lastErrorTarget.runtime, "lastError", { value: { message }, configurable: true }); } catch (e) {}
                    cb(undefined);
                  }, 0);
                  return undefined;
                }
                return Promise.reject(new Error(message));
              };

            \(body)
              // Functions handed out by a proxy are bound to the real namespace object (WebKit's
              // methods check their receiver); the bound copy is cached so identity stays stable.
              const boundCache = new WeakMap();
              const bindTo = (target, fn) => {
                let m = boundCache.get(target);
                if (!m) { m = new Map(); boundCache.set(target, m); }
                let b = m.get(fn);
                if (!b) { b = fn.bind(target); m.set(fn, b); }
                return b;
              };
              // A proxy with an empty target, so no proxy invariant can clash with WebKit's
              // non-configurable properties; every read goes to the current real object.
              const forward = (current, extra) => {
                const value = (k) => {
                  const real = current();
                  const v = real == null ? undefined : Reflect.get(real, k);
                  if (v === undefined && typeof k === "string" && extra) { const x = extra(k); if (x !== undefined) return x; }
                  return typeof v === "function" ? bindTo(real, v) : v;
                };
                const keys = (extraKeys) => {
                  const real = current();
                  const own = real == null ? [] : Reflect.ownKeys(real);
                  return [...new Set([...own, ...extraKeys().filter((k) => real == null || Reflect.get(real, k) === undefined)])];
                };
                return {
                  get: (t, k) => value(k),
                  has: (t, k) => { const real = current(); return (real != null && Reflect.has(real, k)) || value(k) !== undefined; },
                  set: (t, k, v) => { const real = current(); return real != null && Reflect.set(real, k, v); },
                  ownKeys: () => keys(() => []),
                  getOwnPropertyDescriptor: (t, k) => {
                    const v = value(k);
                    return v === undefined ? undefined : { value: v, writable: true, enumerable: true, configurable: true };
                  },
                  keys,
                };
              };
              // Missing namespaces go straight onto the real API object: it is the value of a global
              // and never collected, so they last, and chrome and browser (the same object) both see them.
              const proxyName = "\(proxyGlobal)", otherName = "\(other)";
              const root = (g[proxyName] && typeof g[proxyName] === "object") ? g[proxyName]
                : (g[otherName] && typeof g[otherName] === "object") ? g[otherName] : null;
              if (!root) return;
              lastErrorTarget = root;
              for (const name of Object.keys(namespaces)) {
                if (Reflect.get(root, name) !== undefined) continue;
                let value;
                const entry = namespaces[name];
                const get = () => { if (value === undefined) { value = entry.make(); used(entry.rule + ":" + name); } return value; };
                try { Object.defineProperty(root, name, { get, configurable: true, enumerable: false }); } catch (e) {}
                if (!(name in root)) failed.push("cannot add namespace " + name);
              }

              // Members of existing namespaces: only through a proxy that replaces ONE global (the name the
              // extension's code mostly uses). The other stays the real object on purpose: WebKit delivers
              // events (runtime.onMessage, webNavigation, …) only while one of the two globals is the real
              // object (measured: with both replaced, no listener in the service worker was ever called).
              // The text rule browser-alias-patched-namespaces routes the other name to the proxied one.
              if (Object.keys(members).length || Object.keys(wrappers).length) {
                const nsProxies = Object.create(null);
                const namespaceProxy = (name) => {
                  if (nsProxies[name]) return nsProxies[name];
                  const add = members[name] || {}, wrap = wrappers[name] || {};
                  const made = Object.create(null);
                  const current = () => Reflect.get(root, name);
                  // Stand-ins are made once, so listeners added to an inert event stay registered.
                  const once = (k, make) => { if (!(k in made)) made[k] = make(); return made[k]; };
                  const handler = forward(current, (k) => add[k] ? once(k, () => { used(add[k].rule); return add[k].make(); }) : undefined);
                  const baseGet = handler.get;
                  // A wrapped member replaces the real one while the real one exists; the wrapper
                  // reports itself as used only when it actually changes an answer.
                  handler.get = (t, k) => (typeof k === "string" && wrap[k] && typeof Reflect.get(current(), k) === "function")
                    ? once("wrap:" + k, () => wrap[k].make(current)) : baseGet(t, k);
                  const nsKeys = handler.keys;
                  delete handler.keys;
                  handler.ownKeys = () => nsKeys(() => Object.keys(add));
                  return (nsProxies[name] = new Proxy({}, handler));
                };
                const handler = forward(() => root, null);
                const baseGet = handler.get;
                handler.get = (t, k) => {
                  if (typeof k === "string" && (members[k] || wrappers[k])) {
                    const real = Reflect.get(root, k);
                    if (real && typeof real === "object") return namespaceProxy(k);
                  }
                  return baseGet(t, k);
                };
                const rootKeys = handler.keys;
                delete handler.keys;
                handler.ownKeys = () => rootKeys(() => []);
                const proxy = new Proxy({}, handler);
                const name = g[proxyName] === root ? proxyName : otherName;
                try { g[name] = proxy; } catch (e) {}
                if (g[name] !== proxy) { try { Object.defineProperty(g, name, { value: proxy, configurable: true, writable: true }); } catch (e) {} }
                if (g[name] !== proxy) failed.push("cannot replace globalThis." + name);
              }
              try {
                Object.defineProperty(g, "__neuralbrowserCompat", {
                  get: () => Object.freeze({ ruleSet: \(RuleSet.version), applied: [...applied], failed: [...failed] }),
                  configurable: true,
                });
              } catch (e) {}
            })();

            """
    }
}

/// What the translator needs to know about a manifest.
public struct ManifestFacts {
    public let manifestVersion: Int
    /// API permissions from `permissions` and `optional_permissions` (match patterns removed).
    public let permissions: Set<String>
    public let hasBackground: Bool
    public let hasPages: Bool

    var hasBackgroundOrPages: Bool { hasBackground || hasPages }

    public init(manifest: [String: Any], hasPages: Bool) {
        manifestVersion = manifest["manifest_version"] as? Int ?? 2
        let declared = ((manifest["permissions"] as? [Any]) ?? []) + ((manifest["optional_permissions"] as? [Any]) ?? [])
        permissions = Set(declared.compactMap { $0 as? String }.filter { !$0.contains(":") && !$0.contains("/") && $0 != "<all_urls>" })
        hasBackground = manifest["background"] is [String: Any]
        self.hasPages = hasPages
    }
}
