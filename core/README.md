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
