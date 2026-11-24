// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import WebKit

/// Small polyfills injected into every page before its own scripts run.
///
/// WebKit (macOS 27) has no `Symbol.dispose` / `Symbol.asyncDispose` yet. Bundled
/// code that was transpiled for explicit resource management (`using`), e.g. the
/// Bitwarden/Vaultwarden web vault, fails with "Symbol.dispose is not defined".
/// Defining the well-known symbols is enough for such transpiled code.
enum PagePolyfills {
    static let marker = "/*neuralbrowser-polyfills*/"

    static let source = """
    \(marker)
    (function () {
      try {
        for (const name of ["dispose", "asyncDispose"]) {
          if (typeof Symbol[name] !== "symbol") {
            Object.defineProperty(Symbol, name, {
              value: Symbol.for("Symbol." + name),
              writable: false, enumerable: false, configurable: false
            });
          }
        }
      } catch (_) {}
      // Last few uncaught errors, for diagnosing extension pages from the app.
      if (location.protocol === "webkit-extension:") {
        const keep = (m) => { (window.__nbErrors = window.__nbErrors || []).push(String(m).slice(0, 300));
                              window.__nbErrors.splice(0, window.__nbErrors.length - 5); };
        addEventListener("error", (e) => keep(e.message + " @" + (e.filename || "") + ":" + (e.lineno || "")));
        addEventListener("unhandledrejection", (e) => keep("rejection: " + (e.reason && (e.reason.stack || e.reason))));
      }
    })();
    """

    /// Adds the polyfills once per content controller (configurations can be shared).
    static func install(in controller: WKUserContentController) {
        guard !controller.userScripts.contains(where: { $0.source.hasPrefix(marker) }) else { return }
        controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false, in: .page))
    }
}
