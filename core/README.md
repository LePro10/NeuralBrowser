# NeuralBrowser core

Platform-independent Rust core (MPL-2.0). Crate `neural_core` (`core/neural-core`)
builds as `lib`, `staticlib` and `cdylib`; Swift bindings are generated with
UniFFI 0.32.2 (proc-macros, no UDL).

- `store`: SQLite (bundled, WAL, migrations via `PRAGMA user_version`): history,
  bookmarks/folders (UUID, `modified_ms`, tombstones for later sync), session,
  settings, address-bar suggestions (frecency, host-prefix boost).
- `input`: `resolve_input(text, search_template)` URL-or-search decision.
- `shield`: filter lists (ABP/uBO syntax) to Apple Content Blocker JSON for
  `WKContentRuleListStore`, split into chunks; see "Shield" below.
- `vault`: built-in Vaultwarden/Bitwarden client, sans-IO (builds HTTP requests,
  parses responses; crypto from rbw); see "Vault" below.
- `uniffi-bindgen` (`core/uniffi-bindgen`): workspace binary for binding generation.

## Dependencies

| Crate | Why |
|---|---|
| `uniffi` (+`cli` in the bindgen binary) | FFI scaffolding and Swift binding generation |
| `rusqlite` (`bundled`) | SQLite with FTS5; bundled so the version is the same on every platform |
| `thiserror` | Error enum derive |
| `uuid` (`v4`) | Stable record IDs for sync |
| `adblock` 0.13.5 (MPL-2.0, Brave adblock-rust; `default-features = false`, features `content-blocking`, `css-validation`) | Filter parser and Content-Blocker converter; see "Shield" |
| `serde_json` | Serialising converted rules / checking JSON |

## Build for Apple

    core/build-apple.sh

Output in `core/dist/apple/` (git-ignored): `libneural_core.a` (~13 MB; test program linked against it is 3.3 MB), `neural_core.swift`, `neural_coreFFI.h`,
`module.modulemap` (clang module `neural_coreFFI`). Only the host target
`aarch64-apple-darwin` is built (no rustup); add more triples to `TARGETS`
in the script when available.

## Using it from Swift (verified)

Plain compiler, in a directory containing your `main.swift`:

    D=/path/to/core/dist/apple
    swiftc -O main.swift $D/neural_core.swift -I $D -L $D -lneural_core -o app

`-I $D` finds `module.modulemap`, which makes `import`-less access to the C
symbols work (`neural_core.swift` does `#if canImport(neural_coreFFI)`).
No extra system libraries are needed (works with Swift language mode 5 and 6).

SwiftPM (verified in `apps/apple`, see its `Package.swift`): a C target
`CNeuralCore` (one empty .c file; `include/` holds symlinks to `neural_coreFFI.h`
and `module.modulemap`), a Swift target `NeuralCore` (symlink to
`neural_core.swift`, depends on CNeuralCore) and, on the executable target,
`linkerSettings: [.unsafeFlags([<abs path>/libneural_core.a, "-Xlinker", "-w"])]`.
`build-apple.sh` sets `MACOSX_DEPLOYMENT_TARGET=15.4`; the prebuilt Rust std objects
still report a newer macOS, hence `-w` (silences only ld warnings).

(Or a `.binaryTarget` XCFramework once `xcodebuild` is available; SwiftPM's
`unsafeFlags` are allowed for root packages only.) The module name inside themodulemap must stay `neural_coreFFI`; the C target must be named so the module
is called that, or edit the modulemap accordingly.

Minimal usage:

    let store = try Store.openInMemory()          // or Store.open(path:)
    try store.recordVisit(url: "https://example.com/", title: "Example", timestampMs: 1000)
    print(try store.recentHistory(limit: 10))

## Shield (ad-block rule conversion)

Module `shield` converts EasyList-style lists into Content Blocker JSON. Loading the
lists from the network and compiling them is the app's job.

    // Swift
    func convertFilterLists(lists: [FilterListInput], maxRulesPerChunk: UInt32) throws -> ShieldConversion
    func defaultMaxRulesPerChunk() -> UInt32                       // 100_000
    func siteExceptionRuleList(domains: [String]) throws -> String
    func appendSiteExceptions(chunkJson: String, domains: [String]) throws -> String
    // FilterListInput{id,text}; ShieldConversion{chunks:[RuleListChunk{id,json,ruleCount}], stats:ShieldStats}
    // ShieldStats{lists:[ListStats], exceptionRulesPerChunk, totalUniqueRules, totalDurationMs}
    // ListStats{id, linesTotal, commentOrBlankLines, networkConverted, cosmeticConverted,
    //           unconvertible, unconvertibleReasons:[ReasonCount{reason,count}], durationMs}

Pure functions (no locks, no global state): call from a background thread. EasyList +
EasyPrivacy convert in ~80 ms (release).

**Why `adblock`:** the only maintained parser with a tested ABP-to-Content-Blocker
converter; MPL-2.0 like this project. Only `content-blocking` (the converter) and
`css-validation` (rejects selectors WebKit would refuse; one bad selector makes WebKit
reject a whole list) are enabled; its default features (`embedded-domain-resolver`,
`full-regex-handling`, `single-thread`) are off.
Size (release, `build-apple.sh`): `libneural_core.a` 13.2 MB -> 34.7 MB (+21.5 MB, the
archive carries all dependency objects; `css-validation` is 1.6 MB of that); the linked Swift
test program 3.30 MB -> 7.58 MB (+4.3 MB; `css-validation` is 0.27 MB of that).

**Chunking and exceptions.** WebKit limits rules per list (reported ~150,000), so output
is split with `maxRulesPerChunk` (default 100,000). `ignore-previous-rules` (used for
`@@` exceptions and the first-party-document rule) only cancels earlier rules of the
*same* compiled list. Hence the exceptions, which the converter orders after all other
rules, are copied to the end of every chunk (`exceptionRulesPerChunk`; they count
against the chunk size; error if the limit is not larger than that number). Chunks
together then behave like one list. Blocking with two real chunks runs in the app
(`apps/apple/scripts/shield-test.sh` checks blocking with a small list); that an exception
really reaches across chunks is still derived from the documented semantics only.

**Per-site off switch.** `siteExceptionRuleList` is one rule (`if-domain` `*host`,
`ignore-previous-rules`). Because of the same-list rule it does nothing as a separate
list: use `appendSiteExceptions` on each chunk before compiling, or simply do not attach
the lists to that site's web view. Domains must be ASCII (punycode).

**Limits.** Not convertible (counted in `unconvertibleReasons`): `$popup` and other
unknown options, `$redirect`, `$csp`, `$removeparam`, `$generichide`, regex filters using
unsupported features, cosmetic entities (`google.*`), `:style()`, scriptlets
(`+js()`), procedural cosmetic filters (`:has-text()` ...), non-ASCII rules. Cosmetic
exceptions (`#@#`) are approximated by the converter with an `unless-domain` hide rule
rather than a real exception. `$badfilter` only acts within its own list. Lists are
merged, so an exception in one list applies to rules from the others; chunk ids
(`shield-000`, ...) are not stable when list contents change.

**Measured** (EasyList + EasyPrivacy of 2026-11-13, `cargo run --release -p neural_core
--example shield_real_lists`, downloads at run time, nothing stored): 135,263 lines ->
106,147 network + 24,231 cosmetic filters converted, 3,835 not convertible, 130,520
unique rules, 2 chunks (100,000 + 31,924 rules, 14.2 MB JSON), 82 ms. A throw-away Swift
program compiled both chunks, the site rule and a chunk with the site rule appended with
`WKContentRuleListStore(url:)` (no app bundle needed): all accepted, ~2-4 s each.

## Vault (Vaultwarden/Bitwarden client)

Module `vault` (docs/SECURITY.md 4.7): sign in, two-factor, sync, decrypt, look up
logins for a page, add a login. **Sans-IO:** the core never opens a connection. Each
step returns an `HttpRequest` that the shell sends with URLSession (normal certificate
checks) and takes the `HttpResponse` back. The cryptography is rbw 1.15.0 (MIT, commit
77464d4), copied nearly verbatim into `neural-core/src/vault/rbw/` (licence text and
the list of edits in that directory; `cargo fmt` skips it). `vault/crypto.rs` only adds
input checks in front of it (see "Hardening" below); nothing is self-made.

    // Swift (generated)
    class Vault {
        init(serverUrl: String, email: String, deviceId: String) throws
        func serverUrl() -> String                       // normalised, show it in full
        func email() -> String                           // trimmed, lower case
        func preloginRequest() -> HttpRequest
        func handlePrelogin(response: HttpResponse, allowWeakKdf: Bool) throws -> KdfSettings
        func loginRequest(masterPassword: String, twoFactor: TwoFactorCode?) throws -> HttpRequest
        func handleLogin(response: HttpResponse) throws -> LoginOutcome
        func sendEmailCodeRequest() throws -> HttpRequest
        func handleSendEmailCode(response: HttpResponse) throws
        func syncRequest() throws -> HttpRequest
        func handleSync(response: HttpResponse) throws -> SyncSummary
        func allLogins() throws -> [LoginSummary]
        func loginsForUrl(url: String) throws -> [LoginSummary]
        func username(id: String) throws -> String?
        func password(id: String) throws -> String?
        func addLoginRequest(name: String, url: String, username: String, password: String) throws -> HttpRequest
        func handleAddLogin(response: HttpResponse) throws -> LoginSummary
        func lock()
        func isUnlocked() -> Bool
    }
    struct HttpRequest  { method: String; url: String; headers: [HttpHeader]; body: Data? }
    struct HttpHeader   { name: String; value: String }
    struct HttpResponse { status: UInt16; body: Data }
    struct KdfSettings  { algorithm: KdfAlgorithm; iterations: UInt32; memoryMib: UInt32?;
                          parallelism: UInt32?; weak: Bool }
    enum KdfAlgorithm   { pbkdf2Sha256, argon2id }
    struct TwoFactorCode { provider: TwoFactorProvider; code: String }
    enum TwoFactorProvider { authenticator, email }
    enum LoginOutcome {
        success
        twoFactorRequired(providers: [TwoFactorProvider], unsupportedProviders: [String])
        invalidCredentials
        invalidTwoFactorCode
        serverError(status: UInt16, message: String)
    }
    struct LoginSummary { id: String; name: String; username: String?; matchedUri: String?;
                          isOrganization: Bool }
    struct SyncSummary  { logins: UInt32; undecryptable: UInt32; undecryptableReasons: [ReasonCount];
                          skippedOtherTypes: UInt32; skippedDeleted: UInt32 }
    enum VaultError: Error {
        InvalidServerUrl(reason), InvalidArgument(message), WeakKdf(settings: KdfSettings),
        UnsupportedKdf(message), WrongState(message), Locked, Unauthorized,
        Server(status, message), InvalidResponse(message), Crypto(message), NotFound,
        Internal(message)
    }

**Flow.** `Vault(serverUrl:email:deviceId:)` (device id: a UUID string kept per
installation, `[A-Za-z0-9-]`, max 128) -> `preloginRequest`/`handlePrelogin` ->
`loginRequest`/`handleLogin` (on `twoFactorRequired`: optionally
`sendEmailCodeRequest`, then `loginRequest` again with a `TwoFactorCode`) ->
`syncRequest`/`handleSync` -> lookups -> `lock()`. `loginRequest` derives the keys
(Argon2id/PBKDF2, up to seconds): call it off the main thread. All methods are
thread-safe. `password(id:)` decrypts on demand: call it only for a user action.

**Server address.** Only `https://` (also for localhost; no credentials, query or
fragment). Trailing slashes are removed; API = `<server>/api`, identity =
`<server>/identity` (Vaultwarden layout).

**Requests.** All carry `Accept: application/json`, `Bitwarden-Client-Name: cli`,
`Bitwarden-Client-Version: 2024.12.0`, `Device-Type: 7` (MacOsDesktop).
- `POST /identity/accounts/prelogin` JSON `{"email"}`.
- `POST /identity/connect/token`, form: `grant_type=password`,
  `scope=api offline_access`, `client_id=cli`, `deviceType=7`, `deviceIdentifier`,
  `deviceName=NeuralBrowser`, `devicePushToken=`, `username`, `password` (base64 master
  password hash); with a code also `twoFactorToken`, `twoFactorProvider` (0 app, 1
  e-mail), `twoFactorRemember=0`. Header `Auth-Email` = base64url(e-mail), no padding.
- `POST /api/two-factor/send-email-login` JSON `{email, masterPasswordHash,
  deviceIdentifier[, ssoEmail2faSessionToken]}`, header `Auth-Email`.
- `GET /api/sync?excludeDomains=true`, `POST /api/ciphers` (type 1, no folder, no
  organisation, name/username/password/URI encrypted with the user key), both with
  `Authorization: Bearer <token>`.

**KDF minimums.** PBKDF2 >= 600,000 rounds; Argon2id >= 19 MiB and >= 2 iterations.
Below: `VaultError.WeakKdf(settings)`, nothing stored; call `handlePrelogin` again with
`allowWeakKdf: true` only after the user explicitly confirmed (`settings.weak` stays
true). Values no Bitwarden server allows (PBKDF2 > 2,000,000, Argon2 memory > 1024 MiB,
iterations > 10, parallelism 0 or > 16, unknown KDF) fail with `UnsupportedKdf` always.

**Login outcomes.** Classification as in rbw `classify_login_error`, plus the official
server's "Two-step token is invalid" text. A wrong code after `twoFactorRequired` gives
`invalidTwoFactorCode` (some servers may answer `twoFactorRequired` again). Providers
other than app/e-mail (Duo, YubiKey, WebAuthn, ...) are listed in
`unsupportedProviders`. `serverError.message` is the server's own short error text
(control characters removed, max 200 chars, withheld if it contains the password
hash), never the request or the whole body. On success the user key is decrypted and
MAC-checked immediately; a wrong MAC is `VaultError.Crypto`.

**Sync.** Private key (user key) -> organisation keys (RSA-OAEP) -> every login item
(item key if present). Every symmetric cipher string must carry a 32-byte MAC that is
verified before decryption (rbw itself would accept type 2 without MAC). Undecryptable
items are counted per reason ("MAC check failed", "cipher string without MAC",
"organization key unavailable", "malformed item", ...); the rest stays usable. Notes,
cards, identities, SSH keys and trashed items are skipped (counted).

**Matching** (`loginsForUrl`): page must be `https://` with a host, else `[]`. Entry
URIs must be `https://` (a URI without scheme is read as `https://`); `http://`,
`androidapp://` etc. never match. Hosts must be equal after URL parsing (lower case,
punycode): no subdomains, no base-domain logic, so `example.com` matches neither
`www.example.com`, `sub.example.com`, `example.com.evil.test` nor `evilexample.com`.
Port: an entry with an explicit non-default port only matches that port, otherwise any
port. Match types: "never" never matches, "exact" needs the whole normalised URL;
"base domain" (the Bitwarden default), "host", "starts with" and "regex" are all
treated as host-exact. Order: name (case-insensitive), username, id.

**Where secrets live.** Stretched master key, user key, RSA private key and
organisation keys: rbw's `locked::Vec` (4 KiB buffer, `mlock`ed via `region`,
zeroized on drop). Master password argument: copied into a locked buffer for the
KDF, the string is zeroized. Access token and decrypted names, usernames, URIs:
heap, `zeroize` on `lock()`/drop. Passwords stay encrypted in memory (MAC-checked
during sync) and are decrypted only inside `password(id:)`. `lock()` drops all of it
(also after a poisoned mutex); KDF settings are kept, sign in again to unlock.
Rust-side `Debug` of `Vault`, `HttpRequest`, `HttpResponse`, `TwoFactorCode`,
`LoginSummary` prints `***`. **Swift side:** values crossing the FFI (request bodies
and headers with hash/token, returned passwords, UniFFI buffers) are outside the
core's control and are not zeroized; do not `print`/log `HttpRequest`, `HttpResponse`
or `TwoFactorCode` in Swift (Swift's default description shows all fields).

**Hardening in front of rbw** (`vault/crypto.rs`): a panic would abort the app
(`panic = "abort"`), so untrusted input is checked before it reaches rbw code that
would panic: MAC must be exactly 32 bytes and IV 16 (rbw converts the MAC with a
length-asserting `into()`), the type character must be a digit, wrapped 64-byte keys
must be exactly 80 bytes of ciphertext (rbw slices `[0..64]`), the private key must
fit the 4 KiB locked buffer, decrypted organisation keys must be 64 bytes, the
password must be 1..4096 bytes, Argon2 parameters are validated before rbw's
`Params::new(...).unwrap()`.

**Limitations (first version).**
- No token refresh and nothing persisted: sign in once per app session; when the
  access token expires, sync/add fail with `Unauthorized` -> sign in again.
- Two-factor: authenticator app and e-mail code only; no Duo/YubiKey/WebAuthn/FIDO2,
  no "remember this device", no SSO/key connector, no bitwarden.com new-device e-mail
  verification. bitwarden.com cloud: identity lives on a separate host there; not
  specially supported.
- Only login items; no folders, notes, TOTP, custom fields, password history, edit or
  delete. New items are encrypted with the user key directly (no per-item key, which
  newer official clients add).
- Base-domain/starts-with/regex matching not implemented (host-exact instead).
- Unverified against a live server (no network in tests): `Device-Type 7` with
  `client_id=cli`, `Bitwarden-Client-Version` on login, the `send-email-login` body
  (`masterPasswordHash` is what Vaultwarden and the official server expect; rbw only
  sends the SSO token), and the exact error texts for a wrong second factor.

**Tests** (`cargo test -p neural_core vault`, 22 tests, no network): PBKDF2 and
Argon2id keys/hash against values computed independently (Python `hashlib`/`hmac`,
OpenSSL 3.6 `kdf ARGON2ID`), an OpenSSL-made cipher string, round trip, tampered
MAC/IV/ciphertext, type 0/1 and MAC-less strings, malformed strings without panic,
full flow prelogin -> 2FA -> wrong code -> login -> sync (personal, organisation with
item key, wrong key, no MAC, unknown org, trash, note, malformed) -> lookups -> add ->
lock, plus abuse cases (http server, weak KDF, lookalike hosts, non-https pages,
`Debug` output, nothing readable after `lock()`). Dev builds compile the KDF/RSA crates
with `opt-level = 3` (root `Cargo.toml`), otherwise 600,000 PBKDF2 rounds take minutes.

**Dependencies** (same crates and versions as rbw 1.15.0):

| Crate | Why |
|---|---|
| `aes`, `cbc`, `block-padding` | AES-256-CBC with PKCS#7 (cipher strings type 2) |
| `hmac`, `sha2` | HMAC-SHA256 MAC of cipher strings; SHA-256 for PBKDF2/HKDF/Argon2 salt |
| `pbkdf2`, `argon2`, `hkdf` | Master key derivation and stretching (Bitwarden KDFs) |
| `rsa`, `pkcs8`, `sha1` | Organisation keys: RSA-OAEP-SHA1 with the PKCS#8 private key. `rsa` has RUSTSEC-2023-0071 (Marvin timing), see SECURITY.md 4.7 |
| `rand` | Random IVs for new cipher strings (OS-seeded `ThreadRng`) |
| `zeroize` | Wiping keys, token and decrypted data |
| `region`, `arrayvec` | rbw's locked memory: fixed 4 KiB buffers, `mlock`ed (works on macOS) |
| `base64` | Cipher string and hash encoding |
| `serde` (+derive) | Request/response JSON shapes (`serde_json` was already used) |
| `url` | WHATWG URL parsing for the server address and host matching (lookalike-safe); `idna`/`percent-encoding` were already in the tree. Also its `form_urlencoded` for the token request |
| `rand` 0.8 (dev only) | RSA-encrypting a canned organisation key in tests (`rsa` needs rand_core 0.6) |

Not used: reqwest/tokio/hyper/rustls (sans-IO). `cargo audit`/`cargo deny` are not
installed here; run them before release (SECURITY.md rule 9).

**Size** (release, `build-apple.sh`): `libneural_core.a` 34.7 MB -> 43.4 MB (+8.7 MB;
the archive carries all dependency objects). The linked app (`apps/apple`,
`swift build -c release`) is 6.4 MB after the change (not measured before).

## Notes

- `list_bookmarks(None)` returns all live bookmarks; `Some(id)` only that folder.
- `clear_history(0)` clears everything; otherwise entries with last visit >= `since_ms`.
- Suggestion ranking on very common terms uses a bounded candidate set (3000
  most recent matches + host-prefix + FTS matches); 100k rows: worst case ~6 ms
  (`cargo test --release bench_suggest_100k -- --nocapture`).
- Release profile uses `panic = "abort"`, which is compatible with UniFFI
  (panics across the FFI would abort instead of becoming errors).

## Checks

    cargo test && cargo clippy --all-targets -- -D warnings && cargo fmt --check
