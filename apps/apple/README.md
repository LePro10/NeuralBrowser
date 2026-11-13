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
| ⇧⌘P | Passwords window (Vaultwarden sign-in, list) |
| ⌘\\ | Fill login on the current https page |

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

The smoke test uses an in-memory store (or the `--profile-dir` you give it),
non-persistent extension storage and an in-memory website data store (cookies,
caches), so it never touches your real profile.
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
# --normal-mode --data-dir DIR: run the script like the normal app on that profile (persistent).
```

## Content blocking (Shield)

`Sources/NeuralBrowser/Shield/Shield.swift`. On a normal start the app downloads EasyList and
EasyPrivacy (never bundled) into `<data-dir>/Shield/`, lets the Rust core convert them
(`convertFilterLists`), compiles the chunks with `WKContentRuleListStore` and attaches them to
every tab, private windows included. Later starts load the compiled lists from disk; they are
rebuilt when older than 4 days. Measured 2026-11-13: 130,584 rules, 2 lists, download +
convert + compile 2.6 s in the background, 48 MB on disk.

View > "Block Ads and Trackers" (everywhere) and "… on This Site" (per site, including its
subdomains; reloads the page). The per-site switch detaches the lists from a tab while its main
document is on that site, decided on every main-frame navigation; nothing is recompiled.
Known gaps: a tab opened by `window.open` shares its opener's rule set until one of the two
navigates; no counter of blocked requests; no choice of lists yet.

    scripts/shield-test.sh        # local page, no network: on, site off, off -> on, on -> off, private
    $B --smoke-test URL --shield-download --eval 'JS'     # real lists in a temporary folder
    $B --smoke-test URL --shield-lists FILE --shield-off HOST --eval 'JS'

## Passwords (Vaultwarden)

`Sources/NeuralBrowser/Vault/`. A built-in client for a self-hosted Vaultwarden (or
Bitwarden-compatible) server, docs/SECURITY.md 4.3/4.7. The Rust core (`vault` module, see
core/README.md "Vault") does all cryptography and builds/parses every HTTP message;
`VaultService` only sends them (ephemeral `URLSession`: no cookies, no cache, 30 s timeout,
redirects only to the same https host) and keeps the session for the UI.

- **File ▸ Passwords… (⇧⌘P):** server address (`https://` only, shown in full), e-mail,
  master password; two-step login with an authenticator app or an e-mail code ("Send Code").
  If the server reports key derivation settings below the minimums (PBKDF2 < 600,000,
  Argon2id < 19 MiB / 2 iterations) an alert explains it and only "Sign In Anyway" retries.
  Signed in: server, account, number of logins, searchable list (name, user name, owner;
  never passwords), Sync, Lock.
- **Edit ▸ Fill Login (⌘\\):** only after this action, only on https pages without insecure
  content, logins matched by the exact host. Several matches: a menu to choose. The values
  are written by a script in its own content world (`VaultFill`), main frame only, passed as
  arguments; it picks the focused (else first) visible password field and the nearest visible
  text/e-mail/tel field before it in the same form, sets the values with the native setter
  and fires `input`/`change`. It re-checks the page origin right before writing, returns only
  "filled yes/no", never submits a form. Locked or signed out: opens the Passwords window.
- **Edit ▸ Save Login…:** reads the visible password field and its user name field (same
  rules), then a sheet in the shell (site, name, user name, password as dots with "Show
  password"); only "Save" sends it. If the site already has an entry with that user name,
  nothing is saved.
- **Locking:** after 15 minutes without use, when the screens sleep or lock, on system
  sleep, on fast user switching, with "Lock" and on quit. Unlocking means signing in again.

**What is stored where.** Settings table of `browser.sqlite`: `vault.server`, `vault.email`
and `vault.deviceId` (a random UUID sent as device identifier). Nothing else: the master
password is passed from the field to the core and never kept; keys, token and decrypted
entries live only in the core's memory until lock/quit. Errors (step, HTTP status, the
server's short message as returned by the core) appear in the window and as one
`NeuralBrowser vault: …` line in the system log, never with request or response content.

**Limits (first version).** Sign in once per app session (no token refresh, nothing
persisted, no Keychain yet); two-step login only with authenticator app or e-mail code (no
passkeys/FIDO2/WebAuthn, YubiKey, Duo, "remember this device"); exact-host matching (no
subdomains, no base domain); no update or deletion of existing entries; the list has no site
column (the core reports URIs only for page lookups); fields inside shadow DOM or in frames are
never filled. **Not yet tested against a real server** (the self tests use no network).

    scripts/vault-fill-test.sh    # local page, dummy values: guard, decoys, iframe, React-like inputs (25 checks)
    $B --smoke-test URL --vault-fill-test

## Extensions

File ▸ Install Extension… takes a folder with `manifest.json`, a `.zip` or a
`.crx`. The package is unpacked safely (no path may leave the target folder, no
symlinks, size and file-count limits, CRC check, nothing from the package is
executed) and translated: known WebKit gaps are bridged by general rules (a
generated prelude script, a few counted text replacements; permissions are never
widened). Before anything is enabled a dialog shows the permissions, the
websites, what the translator changed and what will probably not work.
File ▸ Extensions… lists installed extensions (on/off, details, re-translate,
remove). Rules and the list of tested extensions: `docs/ERWEITERUNGEN.md`;
code: `Sources/ExtensionTranslator/`.

Layout of an installed extension: `Extensions/<id>/original/` (the package,
unchanged), `patched/` (what WebKit loads) and `install.json` (source, version,
SHA-256 of the package, rule-set version, which rules changed what and how often).
A plain unpacked folder with `manifest.json` directly inside still loads as it is
(untranslated). On first load the app asks once whether to allow an extension
that was not installed through the dialog; the answer is remembered. Extension
icons appear at the bottom of the sidebar; a click runs the action (popup shown
as popover). Extensions are off in private windows.

Along the user's path (started via LaunchServices like from Finder, persistent throw-away
profile, package installed like File ▸ Install Extension…, local login page, real click on the
sidebar button, app restart, wait, click again). Each round checks the popup text and a message
content script → background (hello: "pong"; Bitwarden: background injects its autofill script,
which then reports the login fields):

```sh
scripts/ext-normal-test.sh ~/Downloads/bitwarden-chrome-2026.10.2.zip bitwarden-password-manager "Log in" 3
scripts/ext-normal-test.sh TestExtensions/hello hello-neuralbrowser "Active tab" 1
# --ext-script can do the same by hand: --normal-mode --data-dir DIR, steps "install" and "clickAction".
```

Extension pages (background, popup, options) use the tabs' website data store. WebKit's tracking
prevention (ITP) would treat an extension origin as a site without user interaction, delete its
storage including the service-worker registration and so stop the background seconds after start
(WebKit does not restart it; popups wait forever, content scripts get no answer). The app records a
user interaction for the extension origin before loading it and on every action click (SPI
`_logUserInteraction:completionHandler:`, no public API); ITP stays on for web pages. A separate
store for extension pages does not work: WebKit then never delivers runtime messages to the
background service worker. The smoke test fails when the test extension's background does not
answer its content script.

```sh
# Install / re-translate without UI (JSON on stdout), offline tests of installer and rules:
$B --install-extension pkg.zip other.crx some-folder --extensions-dir /tmp/exts
$B --retranslate-extensions --extensions-dir /tmp/exts
swift run -c release translator-selftest          # exit 0 = all passed
```

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
Sources/CNeuralCore/   C target: header + module map (symlinks), empty shim.c
Sources/NeuralCore/    generated UniFFI bindings (symlink)
Sources/NeuralBrowser/
  App/         main.swift, AppDelegate, MainMenu, LaunchOptions, SmokeTest
  Store/       BrowserStore (protocol over the Rust core API), RustStore (SQLite via UniFFI)
  Tabs/        BrowserTab (lazy WKWebView, navigation/UI delegates), TabSleeper, FaviconLoader
  UI/          BrowserWindowController, SidebarView, CommandBarView
  Features/    FindBarView, DownloadManager
  Vault/       VaultService (sign-in, sync, lookups, auto-lock), VaultWindow (Passwords),
               VaultFill (guard + fill/read scripts), VaultActions (menu actions, save sheet),
               VaultFillTest (--vault-fill-test)
  Extensions/  ExtensionManager (controller + delegate), ExtensionAdapters
               (WKWebExtensionTab/Window), ExtensionReport, ExtensionsWindow
               (install dialog, management window, --install-extension)
Sources/ExtensionTranslator/  Installer, ZipArchive (safe unpacking), Translator,
               Rules, Prelude (generated compatibility script), TextRules, JSONC,
               Compatibility (what will not work); Foundation only
Tests/TranslatorSelfTest/     offline tests incl. malicious archives
TestExtensions/hello/   MV3 test extension (content script, service worker, popup)
scripts/                bundle.sh (APP=… builds elsewhere), run.sh, ext-normal-test.sh,
                        shield-test.sh, vault-fill-test.sh
```

`BrowserStore` uses the core's value types directly. `RustStore` queues the frequent
writes (visits, titles, session) on a background queue and computes suggestions off
the main thread; core errors are logged (`NSLog`) and never crash the app. If the
database cannot be opened, the app falls back to an in-memory store. Private
windows never call the store. Old `store.json` files are not migrated.
