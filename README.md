# NeuralBrowser

A clean, fast, open-source browser. Small footprint first, AI as an optional layer on top.

> Status: early prototype. Nothing here is ready for daily use yet.

## Goals

- **Light**: uses the system web engine (WebKit first), sleeping tabs, visible memory use.
- **Clean**: vertical tabs, one command bar, nothing else in the way.
- **Extensible**: browser extensions where the platform allows it, plus userscripts and plugins.
- **Private by default**: no account, no telemetry, sync only to a server you host yourself.
- **AI is optional**: off by default and fully removable. When enabled, agents can drive the
  browser over MCP with per-site permissions.

## Layout

```
core/         Rust core shared by all platforms (storage, sync, content blocking, agent API)
apps/apple/   macOS (and later iOS) shell in Swift
docs/         Plan and background (German for now)
```

## Building

Requirements: macOS 15.4 or newer, Swift 6, Rust (stable).
Build steps are documented in `core/README.md` and `apps/apple/README.md`.

## License

[MPL-2.0](LICENSE)
