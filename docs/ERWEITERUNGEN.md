# Extensions in NeuralBrowser

NeuralBrowser runs Chrome-style web extensions on Apple's WebKit (`WKWebExtension`,
macOS 15.4+). WebKit implements most of the WebExtensions API, but not all of it, and
some gaps stop popular extensions from starting at all. NeuralBrowser therefore
**translates** every extension when it is installed: general, documented rules
bridge the known gaps. Not every Chrome extension will ever run; this page says
honestly which ones we tested and what happened.

Measured on macOS 27.0.1 (arm64), NeuralBrowser prototype, rule set 2, 13 November 2026.
Details and raw observations (German): `docs/ERWEITERUNGS-TEST.md`.

## Tested extensions

Status: **works** (unchanged package) · **works after translation** · **partly** ·
**does not work** · **untested**. Packages come from the vendors' official GitHub
releases, never from the Chrome Web Store.

| Extension | Version | Source (GitHub release) | Status | Notes |
|---|---|---|---|---|
| uBlock Origin Lite | 2026.1110.1816 | `uBlockOrigin/uBOL-home`, chromium zip | works | Network blocking active ~10 s after first start (rules compile). Translation changes nothing it uses; same results as the unchanged package. |
| Dark Reader | 4.9.135 | `darkreader/darkreader`, chrome-mv3 zip | works | Pages turn dark (test page, Wikipedia). Font settings ignored. |
| JSONVue | 0.2.3 | `gildas-lormeau/JSONVue` @ `21f3086` | works | JSON shown as collapsible tree. |
| TWP – Translate Web Pages | 10.2.1.0 | `FilipePS/Traduzir-paginas-web`, Chromium MV2 crx | works | Page translated from the popup. One harmless background error left (`ftp://` pattern). |
| Vimium | 2.4.2 | `philc/vimium`, tag `v2.4.2` (source folder) | works after translation | Unchanged: does not load (comments in `manifest.json`), background dies (`webNavigation.onHistoryStateUpdated`). Translated: loads without errors, link hints (`f`) work. In-page (history API) navigations are not reported to it. |
| Violentmonkey (MV2 package) | 2.50.0 | `violentmonkey/violentmonkey`, `…-webext-…zip` | works after translation | Unchanged: background dies (`notifications`, `permissions.contains`). Translated: a test userscript was installed and ran on a page, popup lists it. No notifications are shown. |
| Violentmonkey (MV3 package) | 2.50.0 | same, `…-mv3-…zip` | does not work | Needs `userScripts`, which WebKit lacks. Use the MV2 package. |
| Bitwarden | 2026.10.2 | `bitwarden/clients`, `dist-chrome-…zip` | partly | Unchanged: autofill scripts never injected (`scripting.ExecutionWorld`). Translated: no background errors, autofill script injected, login form detected (email + password), popup shows the welcome and login page, self-hosted server URL dialog reachable. Not verified: unlocking, filling, saving (needs an account). In our session the background stopped answering a few seconds after start (also unchanged and with the old app build), see the German report. Biometrics/desktop app (native messaging) not available. |
| SponsorBlock | 6.1.7 | `ajayyy/SponsorBlock`, `ChromeExtension.zip` | partly | Popup and options work, same with and without translation. On YouTube (measured before the translator) buttons and segment bar appear; skipping itself was not observed. |
| Stylus | 2.4.18 | `openstyles/stylus`, chrome-mv3 zip | does not work | Translated: the manager page and popup open, but installing a test style failed and no style is applied (`apply.js`: `data.cfg` undefined; blocking `webRequest`, `idle` and the DNR-redirect install path are missing in WebKit). |
| Return YouTube Dislike | 4.1.7 | `Anarios/return-youtube-dislike`, chrome zip | does not work | Content script runs, API reachable, dislike count never shown. Cause unknown. |
| React Developer Tools, LanguageTool, Raindrop.io, Wappalyzer, 1Password | – | no official package outside the Chrome Web Store | untested | |

Count: unchanged packages 4 of 10 work, 1 partly. With the translator 6 of 10 work, 2 partly
(the Violentmonkey MV2 package counted for Violentmonkey).

## What cannot work, and why

- **User scripts under Manifest V3** (Violentmonkey, Tampermonkey, …): WebKit has no
  `userScripts` API. A translator cannot add it: running arbitrary page scripts needs
  support inside the browser engine. NeuralBrowser plans a built-in userscript runner instead.
- **Blocking or changing network requests with `webRequest`**: WebKit's `webRequest`
  only observes. Content blockers must use `declarativeNetRequest` (uBlock Origin Lite does).
- **Native messaging** (talking to a companion app: 1Password, Bitwarden biometrics,
  KeePassXC): not implemented in NeuralBrowser yet.
- **Store-only extensions** (1Password, Raindrop.io, Wappalyzer, LanguageTool): we do
  not download from the Chrome Web Store, so they are untested.
- **APIs WebKit lacks entirely** (`downloads`, `bookmarks`, `history`, `sessions`,
  `identity`, `devtools`, `sidePanel`, `offscreen`, …): calls fail or, where the
  translator adds a stand-in, do nothing. The install dialog lists them per extension.

## How the translator works

Installing (File ▸ Install Extension…, a folder, `.zip` or `.crx`):

1. **Unpack safely** into `Extensions/<id>/original/`: no entry may leave the target
   folder (`..`, absolute paths, drive letters, backslashes), symlinks and special files
   are refused, sizes, file count and path depth are capped, CRC-32 is checked, nothing
   from the package is executed. `.crx` = zip with a header that is cut off.
2. **Translate** a copy into `Extensions/<id>/patched/`, which WebKit loads. The original
   stays untouched, so the extension can be re-translated whenever the rules change.
3. **Record** `install.json`: source, version, SHA-256 of the package, rule-set version,
   which rule changed what and how often.
4. **Show** permissions, websites, changes and expected gaps; enable only after the user agrees.

Rules are general (never "if extension X then …"). Each has an id, a reason and the
finding that motivated it (`Sources/ExtensionTranslator/Rules.swift`). Preferred means, in order:

| Mechanism | Used for | Why |
|---|---|---|
| **Prelude** – a generated script `nb-compat.js` loaded before the extension's own code (service worker via a tiny wrapper, `background.scripts` first entry, first `<script>` of every extension page) | Missing namespaces (`notifications`, `idle`, `offscreen`, `sidePanel`, `fontSettings`) as harmless stand-ins; missing members of existing namespaces (`scripting.ExecutionWorld`, `webNavigation.onHistoryStateUpdated` & co., `runtime.onUpdateAvailable` & co., `webRequest` enum constants); `permissions.contains()` answering `false` instead of throwing for unknown permissions | Feature-detects at run time, so a future WebKit that has the API wins automatically |
| **Manifest** | comments and trailing commas in `manifest.json`; adding the prelude | WebKit rejects JSON with comments; Chrome accepts it |
| **Text** (last resort, exact patterns only, outside strings/comments/regexes, syntax-checked with JavaScriptCore, every change counted) | `…scripting.ExecutionWorld.ISOLATED/MAIN` → `"ISOLATED"`/`"MAIN"` (also where no prelude runs, e.g. injected files); `browser.<patched namespace>` → `chrome.<…>` | see below |
| **Report** | permissions and manifest keys WebKit ignores | the user should know before enabling |

Two WebKit details shaped the prelude (both measured, see the German report):
WebKit's namespace objects (`chrome.webNavigation`, …) are recreated after garbage
collection, so a property added to them disappears after a while, and they cannot be
replaced on `chrome`. The prelude therefore replaces `globalThis.chrome` with a proxy that
forwards to the real API and fills only what is missing. `globalThis.browser` must stay
WebKit's own object: when both globals were replaced, WebKit stopped delivering events
(`runtime.onMessage`, `webNavigation.*`) to the extension. Because WebKit's `browser` and
`chrome` are the same object, the text rule `browser-alias-patched-namespaces` routes
`browser.permissions` (and the other patched namespaces) to `chrome.…`.

The translator **never widens permissions**: after every translation a guard compares the
manifest with the original; only the `background` entry may change, and only to load the
prelude. Stand-ins answer with neutral values (no notification is shown, idle is always
"active"); the `permissions.contains` wrapper can only turn an "unknown permission" error into `false`.

At run time, `globalThis.__neuralbrowserCompat` (in the background or an extension page)
lists which stand-ins the extension actually used.

## Contributing a rule

1. Find the gap with the test tool (`--ext-script`, see `apps/apple/README.md`) and write
   it down in `docs/ERWEITERUNGS-TEST.md` (what is missing, which extension, what breaks).
2. Prefer a prelude part (`Prelude.swift`: `addMember`, `wrapMember`, `addNamespace`) that
   only fills what is missing. Use a text rule only if the prelude cannot reach the code,
   and only for an exact, unambiguous pattern (`TextRules.swift`).
3. Add a `RuleInfo` in `Rules.swift` (id, title, mechanism, reason, finding) and bump
   `RuleSet.version`.
4. Add offline tests to `apps/apple/Tests/TranslatorSelfTest/main.swift` (normal case and
   a case where the rule must not apply), run `swift run -c release translator-selftest`.
5. Re-measure the affected extensions and update the table above.
