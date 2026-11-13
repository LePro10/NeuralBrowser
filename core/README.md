# NeuralBrowser core

Platform-independent Rust core (MPL-2.0). Crate `neural_core` (`core/neural-core`)
builds as `lib`, `staticlib` and `cdylib`; Swift bindings are generated with
UniFFI 0.32.2 (proc-macros, no UDL).

- `store`: SQLite (bundled, WAL, migrations via `PRAGMA user_version`): history,
  bookmarks/folders (UUID, `modified_ms`, tombstones for later sync), session,
  settings, address-bar suggestions (frecency, host-prefix boost).
- `input`: `resolve_input(text, search_template)` URL-or-search decision.
- `uniffi-bindgen` (`core/uniffi-bindgen`): workspace binary for binding generation.

## Dependencies

| Crate | Why |
|---|---|
| `uniffi` (+`cli` in the bindgen binary) | FFI scaffolding and Swift binding generation |
| `rusqlite` (`bundled`) | SQLite with FTS5; bundled so the version is the same on every platform |
| `thiserror` | Error enum derive |
| `uuid` (`v4`) | Stable record IDs for sync |

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

SwiftPM (layout NOT yet verified, only the swiftc path above is): put the files in a package like this and it links the same way.

    Sources/CNeuralCore/include/{neural_coreFFI.h, module.modulemap}   // C target (needs one empty .c file)
    Sources/NeuralCore/neural_core.swift                               // Swift target depending on CNeuralCore
    // plus, for  executable target:
    linkerSettings: [.unsafeFlags(["-L", "<abs path>/core/dist/apple", "-lneural_core"])]

(Or a `.binaryTarget` XCFramework once `xcodebuild` is available; SwiftPM's
`unsafeFlags` are allowed for root packages only.) The module name inside themodulemap must stay `neural_coreFFI`; the C target must be named so the module
is called that, or edit the modulemap accordingly.

Minimal usage:

    let store = try Store.openInMemory()          // or Store.open(path:)
    try store.recordVisit(url: "https://example.com/", title: "Example", timestampMs: 1000)
    print(try store.recentHistory(limit: 10))

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
