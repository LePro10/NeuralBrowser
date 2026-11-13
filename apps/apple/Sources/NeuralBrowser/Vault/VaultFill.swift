// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import WebKit

/// Writing a login into a page and reading one back for saving (SECURITY.md 4.3/4.7).
/// Independent of the vault so the self test can run it with dummy values:
/// - `refusal(...)` is the guard "may we fill this tab?";
/// - `fill`/`read` run in their own content world, in the main frame only, take values
///   as arguments (never interpolated into the script) and re-check the page's origin
///   inside the page right before touching a field.
/// Nothing here runs on page load or submits a form; the page world gets no global,
/// no message handler and no return channel.
@MainActor
enum VaultFill {
    static let world = WKContentWorld.world(name: "NeuralBrowserVault")

    struct FillResult {
        var username: Bool
        var password: Bool
        /// Set when the page refused (e.g. "origin" after a navigation).
        var reason: String?
    }

    struct FormValues {
        var username: String
        var password: String
    }

    /// nil when filling (or reading for saving) is allowed, else a message for the user.
    /// `lookedUp`: the URL the logins were looked up for; the tab must still be on its origin.
    static func refusal(url: URL?, lookedUp: URL?, hasOnlySecureContent: Bool) -> String? {
        guard let url, let host = url.host(), !host.isEmpty else { return "This tab shows no web page." }
        guard url.scheme?.lowercased() == "https" else {
            return "Passwords are only filled on secure (https) pages. \(host) is not secure."
        }
        guard hasOnlySecureContent else {
            return "\(host) loads some content without encryption, so passwords are not filled there."
        }
        if let lookedUp, origin(of: lookedUp) != origin(of: url) {
            return "The tab moved to another site (\(host)) while choosing a login. Nothing was filled."
        }
        return nil
    }

    /// `scheme://host[:port]` as `location.origin` writes it (default port omitted).
    static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), let host = url.host()?.lowercased(), !host.isEmpty else { return nil }
        let shownHost = host.contains(":") ? "[\(host)]" : host
        let defaultPort = scheme == "https" ? 443 : scheme == "http" ? 80 : nil
        if let port = url.port, port != defaultPort { return "\(scheme)://\(shownHost):\(port)" }
        return "\(scheme)://\(shownHost)"
    }

    /// Fills the visible password field (and its user name field) of the main frame.
    /// The return value says only which fields were filled, never their values.
    static func fill(in webView: WKWebView, expected url: URL, username: String?, password: String) async throws -> FillResult {
        guard let origin = origin(of: url) else { return FillResult(username: false, password: false, reason: "origin") }
        let value = try await webView.callAsyncJavaScript(
            fillScript, arguments: ["expectedOrigin": origin, "username": username ?? "", "password": password],
            in: nil, contentWorld: world)
        let dict = value as? [String: Any] ?? [:]
        return FillResult(username: dict["username"] as? Bool ?? false,
                          password: dict["password"] as? Bool ?? false,
                          reason: dict["reason"] as? String)
    }

    /// Reads the current values of the visible password field and its user name field
    /// (for "Save Login…"). nil when there is no such field or the origin changed.
    static func read(in webView: WKWebView, expected url: URL) async throws -> FormValues? {
        guard let origin = origin(of: url) else { return nil }
        let value = try await webView.callAsyncJavaScript(
            readScript, arguments: ["expectedOrigin": origin], in: nil, contentWorld: world)
        guard let dict = value as? [String: Any], dict["found"] as? Bool == true,
              let password = dict["password"] as? String else { return nil }
        return FormValues(username: dict["username"] as? String ?? "", password: password)
    }

    // MARK: Scripts (function bodies for callAsyncJavaScript; arguments arrive as local constants)

    /// Finds the field pair: the focused visible password field, else the first visible one;
    /// the user name field is the nearest preceding visible text/email/tel input in the same
    /// form (document order when there is no form). Hidden means: display none, visibility
    /// hidden, opacity 0 (on the field or an ancestor), no size, off-page, disabled, read-only, inert.
    private static let pickFields = """
        const isVisible = (el) => {
          if (!el || el.disabled || el.readOnly || el.closest('[inert]')) return false;
          const r = el.getBoundingClientRect();
          if (r.width < 2 || r.height < 2) return false;
          if (r.right + window.scrollX <= 0 || r.bottom + window.scrollY <= 0) return false;
          for (let n = el; n && n.nodeType === 1; n = n.parentElement) {
            const s = getComputedStyle(n);
            if (s.display === 'none' || s.visibility === 'hidden' || s.visibility === 'collapse') return false;
            if (parseFloat(s.opacity) === 0) return false;
          }
          return true;
        };
        const passwords = Array.from(document.querySelectorAll('input'))
          .filter((el) => el.type === 'password' && isVisible(el));
        const active = document.activeElement;
        const pw = passwords.includes(active) ? active : (passwords[0] || null);
        let user = null;
        if (pw) {
          const scope = pw.form ? Array.from(pw.form.elements) : Array.from(document.querySelectorAll('input'));
          for (const el of scope) {
            if (el === pw) break;
            if (el.tagName === 'INPUT' && ['text', 'email', 'tel'].includes(el.type) && isVisible(el)) user = el;
          }
        }
        """

    private static let fillScript = """
        if (window !== window.top || location.origin !== expectedOrigin) {
          return { username: false, password: false, reason: 'origin' };
        }
        \(pickFields)
        if (!pw) return { username: false, password: false, reason: 'no field' };
        // The native setter of this (isolated) world: page code cannot intercept it, and
        // frameworks that track the value (React) see a change on the following events.
        const setValue = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
        const put = (el, v) => {
          setValue.call(el, v);
          el.dispatchEvent(new Event('input', { bubbles: true, composed: true }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
        };
        let filledUser = false;
        if (user && username.length > 0) { put(user, username); filledUser = true; }
        put(pw, password);
        return { username: filledUser, password: true };
        """

    private static let readScript = """
        if (window !== window.top || location.origin !== expectedOrigin) return { found: false };
        \(pickFields)
        if (!pw) return { found: false };
        return { found: true, username: user ? user.value : '', password: pw.value };
        """
}
