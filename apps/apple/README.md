# NeuralBrowser – macOS shell

Native AppKit shell around the system WebKit (WKWebView): vertical tabs in a
sidebar, one command bar, web extensions via `WKWebExtension` (macOS 15.4+).
No third-party dependencies. License: MPL-2.0.

## Build and run

Requires only the Command Line Tools (Swift 6, no Xcode) and a Rust toolchain
(cargo) for the core.

```sh
cd apps/apple
scripts/bundle.sh               # builds the Rust core if needed, then the app
                                # -> build/NeuralBrowser.app (Info.plist, ad-hoc signature)
scripts/run.sh                  # open the app (builds it if missing)
scripts/run.sh --data-dir /tmp/nb-profile   # run with a throw-away profile
```

The Rust core (`../../core`) is linked as a static library. `bundle.sh` runs
`core/build-apple.sh` when `core/dist/apple/libneural_core.a` is missing or a
Rust source/Cargo file is newer. A plain `swift build` needs that output to
exist already (run `core/build-apple.sh` once). Package layout: `CNeuralCore`
(C target; header and module map are symlinks into `core/dist/apple/`),
`NeuralCore` (generated UniFFI Swift bindings, symlink) and the app target;
the linker gets `core/dist/apple/libneural_core.a` via `unsafeFlags`
(allowed for root packages). Nothing generated is checked in.

Data lives in `~/Library/Application Support/NeuralBrowser/` (`browser.sqlite`
+ WAL files, `Extensions/`). Override with `--data-dir DIR` and `--extensions-dir DIR`.

Settings (no UI yet, stored in the `settings` table of `browser.sqlite`):
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
# Throw-away profile instead of memory (history + session land in DIR/browser.sqlite;
# start the app later with --data-dir DIR to see them restored).
$B --smoke-test https://example.com https://example.org --profile-dir /tmp/nb-prof
# Time store calls (suggest, saveSession) on a seeded store; adds "storeBench" to the report.
$B --smoke-test https://example.com --store-bench --timeout 90

# With the test extension: proves content script, background reply and popup ran.
$B --smoke-test https://example.com --extensions-dir TestExtensions
# More checks: sleeping tabs, private window, window screenshot, keep alive for RAM tools.
$B --smoke-test URL1 URL2 URL3 --sleep-test --screenshot /tmp/nb.png --hold 15
$B --smoke-test https://example.com --private

# What WebKit thinks of every extension in a folder (errors, ignored permissions, …).
$B --extension-report --extensions-dir ~/Library/Application\ Support/NeuralBrowser/Extensions
```

The smoke test uses an in-memory store (or the `--profile-dir` you give it) and
non-persistent extension storage, so it never touches your real profile.

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
- Folders under `~/Documents`, `~/Desktop`, `~/Downloads` trigger a macOS
  privacy prompt when the app is started from Finder/`open`.

## Layout

```
Sources/CNeuralCore/   C target: header + module map (symlinks), empty shim.c
Sources/NeuralCore/    generated UniFFI bindings (symlink)
Sources/NeuralBrowser/
  App/         main.swift, AppDelegate, MainMenu, LaunchOptions, SmokeTest
  Store/       BrowserStore (protocol over the Rust core API), RustStore (SQLite via UniFFI)
  Tabs/        BrowserTab (lazy WKWebView, navigation/UI delegates), TabSleeper, FaviconLoader
  UI/          BrowserWindowController, SidebarView, CommandBarView
  Features/    FindBarView, DownloadManager
  Extensions/  ExtensionManager (controller + delegate), ExtensionAdapters
               (WKWebExtensionTab/Window), ExtensionReport
TestExtensions/hello/   MV3 test extension (content script, service worker, popup)
scripts/                bundle.sh, run.sh
```

`BrowserStore` uses the core's value types directly. `RustStore` queues the frequent
writes (visits, titles, session) on a background queue and computes suggestions off
the main thread; core errors are logged (`NSLog`) and never crash the app. If the
database cannot be opened, the app falls back to an in-memory store. Private
windows never call the store. Old `store.json` files are not migrated.
