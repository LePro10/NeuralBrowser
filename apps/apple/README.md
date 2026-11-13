# NeuralBrowser – macOS shell

Native AppKit shell around the system WebKit (WKWebView): vertical tabs in a
sidebar, one command bar, web extensions via `WKWebExtension` (macOS 15.4+).
No third-party dependencies. License: MPL-2.0.

## Build and run

Requires only the Command Line Tools (Swift 6, no Xcode).

```sh
cd apps/apple
swift build -c release          # compile
scripts/bundle.sh               # -> build/NeuralBrowser.app (Info.plist, ad-hoc signature)
scripts/run.sh                  # open the app (builds it if missing)
scripts/run.sh --data-dir /tmp/nb-profile   # run with a throw-away profile
```

Data lives in `~/Library/Application Support/NeuralBrowser/` (`store.json`,
`Extensions/`). Override with `--data-dir DIR` and `--extensions-dir DIR`.

Settings (no UI yet, stored in `store.json` → `settings`):
`search.template` (default `https://duckduckgo.com/?q=%s`),
`tabs.sleepAfterMinutes` (default `15`, `0` = never).

## Keyboard

| Keys | Action |
|---|---|
| ⌘L / click the address pill | Command bar for the current tab |
| ⌘T | Command bar, opens a new tab |
| ⌘W, ⇧⌘T | Close tab, reopen closed tab |
| ⌘1…⌘8, ⌘9 | Tab n, last tab |
| ⌃Tab, ⌃⇧Tab | Next / previous tab |
| ⌘[ ⌘] ⌘R | Back, forward, reload |
| ⌘F, ⌘G, ⇧⌘G | Find in page |
| ⌘N, ⇧⌘N | New window, new private window |

Command bar: type, ↑/↓ to pick a suggestion (open tabs, history, bookmarks),
Enter opens it; otherwise the text is resolved as URL or search.

## Self tests (no UI interaction)

```sh
B=build/NeuralBrowser.app/Contents/MacOS/NeuralBrowser

# Load pages, print title + timings as JSON. Exit 0 = ok, 1 = load error/timeout.
$B --smoke-test https://example.com
# With the test extension: proves content script, background reply and popup ran.
$B --smoke-test https://example.com --extensions-dir TestExtensions
# More checks: sleeping tabs, private window, window screenshot, keep alive for RAM tools.
$B --smoke-test URL1 URL2 URL3 --sleep-test --screenshot /tmp/nb.png --hold 15
$B --smoke-test https://example.com --private

# What WebKit thinks of every extension in a folder (errors, ignored permissions, …).
$B --extension-report --extensions-dir ~/Library/Application\ Support/NeuralBrowser/Extensions
```

The smoke test uses an in-memory store, non-persistent extension storage and
an in-memory website data store (cookies, caches), so it never touches your profile.
`--data-dir DIR` also gets its own WebKit data store and extension storage.

Scripted extension tests (`--ext-script`, same in-memory profile, every
permission granted, JS dialogs auto-answered). Steps are documented at the top
of `App/ExtensionScript.swift`; the report is JSON with one result per step:

```sh
cat > /tmp/dr.json <<'EOF'
{"steps":[
 {"open":"https://en.wikipedia.org/wiki/WebKit","wait":4},
 {"eval":"return getComputedStyle(document.body).backgroundColor"},
 {"popup":"darkreader"}, {"shot":"/tmp/popup.png","target":"popup:darkreader"},
 {"open":"ext:darkreader/@options","newTab":true}, {"shot":"/tmp/options.png"},
 {"keys":"f{Esc}"}, {"click":"a"}, {"errors":true}
]}
EOF
$B --ext-script /tmp/dr.json --extensions-dir /tmp/exts --timeout 120
# Test knobs: --extension-ua NAME / --tab-ua NAME replace the UA application name.
```

## Extensions

Put unpacked extensions (folder with `manifest.json`) into
`~/Library/Application Support/NeuralBrowser/Extensions/<name>/`. On first load
the app asks once whether to allow the extension and its permissions; the answer
is remembered. Extension icons appear at the bottom of the sidebar; a click runs
the action (popup shown as popover). Extensions are off in private windows.

Notes from testing:
- No entitlement and no developer account are needed: the ad-hoc signature
  from `bundle.sh` (or even the linker signature of `swift build`) is enough.
  A completely unsigned binary is killed by the kernel on Apple Silicon.
- WebKit silently ignores unknown permissions and manifest keys; the
  extension report lists them as `ignoredPermissions` / `unsupportedManifestKeys`.
- Extension web views (background, popup, options) carry a Chrome token in the
  user agent: the Chrome packages we load branch on it (Bitwarden crashes without
  any browser token and spins at 100 % CPU waiting for its Safari app with a
  Safari token). Full results: `docs/ERWEITERUNGS-TEST.md`.
- Folders under `~/Documents`, `~/Desktop`, `~/Downloads` trigger a macOS
  privacy prompt when the app is started from Finder/`open`.

## Layout

```
Sources/NeuralBrowser/
  App/         main.swift, AppDelegate, MainMenu, LaunchOptions, SmokeTest
  Store/       BrowserStore (protocol = Rust core API), JSONBrowserStore, InputResolver
  Tabs/        BrowserTab (lazy WKWebView, navigation/UI delegates), TabSleeper, FaviconLoader
  UI/          BrowserWindowController, SidebarView, CommandBarView
  Features/    FindBarView, DownloadManager
  Extensions/  ExtensionManager (controller + delegate), ExtensionAdapters
               (WKWebExtensionTab/Window), ExtensionReport
TestExtensions/hello/   MV3 test extension (content script, service worker, popup)
scripts/                bundle.sh, run.sh
```

`BrowserStore` mirrors the Rust core's API; `JSONBrowserStore` is the stand-in
until the UniFFI bindings exist.
