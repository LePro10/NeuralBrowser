// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import WebKit

/// `--smoke-test URL --vault-fill-test`: checks the fill guard and the fill/read scripts with
/// dummy values, without a vault or a server. The page is the one written by
/// scripts/vault-fill-test.sh (decoy fields, an iframe, React-like inputs, a second form).
/// Test pages are http://127.0.0.1, so the fill routine is called directly with the page's own
/// origin; the guard (which refuses http) is tested separately, including on that page.
@MainActor
enum VaultFillTest {
    private static let user = "dummy-user"
    private static let pass = "dummy-pass-1"

    static func run(on tab: BrowserTab) async -> (report: [String: Any], failures: [String]) {
        var checks: [[String: Any]] = []
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            checks.append(["name": name, "ok": ok, "detail": detail])
        }

        // Guard: "may we fill this tab?"
        let page = URL(string: "https://example.com/login")!
        func refused(_ url: String?, _ lookedUp: URL? = nil, secure: Bool = true) -> Bool {
            VaultFill.refusal(url: url.flatMap(URL.init(string:)), lookedUp: lookedUp, hasOnlySecureContent: secure) != nil
        }
        check("guard refuses http", refused("http://example.com/login"))
        check("guard refuses file URL", refused("file:///tmp/login.html"))
        check("guard refuses no page", refused(nil))
        check("guard refuses mixed content", refused("https://example.com/login", secure: false))
        check("guard refuses other host after lookup", refused("https://evil.example.com/login", page))
        check("guard refuses lookalike host", refused("https://example.com.evil.test/login", page))
        check("guard refuses other port", refused("https://example.com:8443/login", page))
        check("guard refuses http after https lookup", refused("http://example.com/login", page))
        check("guard allows same origin", !refused("https://EXAMPLE.com:443/other?x=1", page))

        guard let webView = tab.webView, let url = webView.url else {
            check("test page loaded", false, "no web view")
            return finish(checks)
        }
        check("guard refuses the http test page", VaultFill.refusal(url: url, lookedUp: nil,
                                                                    hasOnlySecureContent: webView.hasOnlySecureContent) != nil)

        // 1. Fill with nothing focused: first visible password field and its user name field.
        do {
            let r = try await VaultFill.fill(in: webView, expected: url, username: user, password: pass)
            check("fill reports user name and password filled", r.username && r.password, "\(r.username) \(r.password)")
            check("fill result carries no values", !String(describing: r).contains("dummy"))
        } catch {
            check("fill ran", false, "\(error)")
        }
        let s = await pageState(webView)
        check("visible password field filled", s["pw"] as? String == pass)
        check("user name field filled", s["user"] as? String == user)
        let decoys = s["decoys"] as? [String: String] ?? ["?": "missing"]
        check("hidden, disabled and read-only password fields untouched",
              decoys.values.allSatisfy(\.isEmpty), decoys.filter { !$0.value.isEmpty }.keys.sorted().joined(separator: ","))
        check("hidden text field and text field outside the form untouched",
              s["hiddenUser"] as? String == "" && s["outsideUser"] as? String == "")
        check("password field in iframe untouched", s["frame"] as? String == "", "\(s["frame"] ?? "nil")")
        check("second form untouched", s["user2"] as? String == "" && s["pw2"] as? String == "")
        let react = s["react"] as? [String: Any] ?? [:]
        check("React-like inputs noticed the input event", react["user"] as? String == user && react["pw"] as? String == pass,
              "\(react.keys.sorted())")
        check("change events fired", s["changes"] as? Int ?? 0 >= 2, "\(s["changes"] ?? "nil")")
        check("page world sees no helper globals", (s["newGlobals"] as? [String])?.isEmpty == true,
              "\(s["newGlobals"] ?? "nil")")

        // 2. Read back (Save Login…).
        let values = try? await VaultFill.read(in: webView, expected: url)
        check("read returns the field values", values?.username == user && values?.password == pass)

        // 3. The page re-checks its origin: a lookup for another site fills nothing.
        let other = try? await VaultFill.fill(in: webView, expected: URL(string: "https://example.com/")!,
                                             username: "x", password: "dummy-wrong-origin")
        let afterOther = await pageState(webView)
        check("fill refused inside the page for another origin",
              other?.password == false && other?.reason == "origin" && afterOther["pw"] as? String == pass)
        let readOther = try? await VaultFill.read(in: webView, expected: URL(string: "https://example.com/")!)
        check("read refused for another origin", readOther == nil)

        // 4. A focused visible password field wins over the first one.
        _ = try? await webView.evaluateJavaScript("document.getElementById('pw2').focus(); document.activeElement.id")
        let second = try? await VaultFill.fill(in: webView, expected: url, username: "dummy-user2", password: "dummy-pass-2")
        let s4 = await pageState(webView)
        check("focused password field preferred",
              second?.password == true && s4["pw2"] as? String == "dummy-pass-2" && s4["user2"] as? String == "dummy-user2"
                && s4["pw"] as? String == pass, "\(s4["pw2"] ?? "nil")")
        return finish(checks)
    }

    private static func finish(_ checks: [[String: Any]]) -> (report: [String: Any], failures: [String]) {
        let failed = checks.filter { $0["ok"] as? Bool != true }.map { "vault fill: \($0["name"] ?? "?")" }
        return (["checks": checks, "passed": checks.count - failed.count, "failed": failed.count], failed)
    }

    /// Field values as the page itself sees them (page world).
    private static func pageState(_ webView: WKWebView) async -> [String: Any] {
        let js = """
            (() => {
              const v = (id, doc) => { const el = (doc || document).getElementById(id); return el ? el.value : null; };
              const decoys = {};
              document.querySelectorAll('[data-decoy]').forEach((el) => { decoys[el.id] = el.value; });
              let frame = null;
              try { frame = v('fpw', document.querySelector('iframe').contentDocument); } catch (e) { frame = 'error ' + e; }
              const before = new Set(window.__globalsBefore || []);
              const newGlobals = Object.getOwnPropertyNames(window).filter((k) => !before.has(k) && k !== '__globalsBefore');
              return JSON.stringify({ pw: v('pw'), user: v('user'), hiddenUser: v('hiddenUser'), outsideUser: v('outsideUser'),
                user2: v('user2'), pw2: v('pw2'), frame, decoys, react: window.reactState, changes: window.changeCount,
                newGlobals });
            })()
            """
        guard let json = try? await webView.evaluateJavaScript(js) as? String,
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }
}
