// Cryptography taken from rbw, the unofficial Bitwarden CLI.
//
//   Origin:   https://github.com/doy/rbw
//   Version:  1.15.0, commit 77464d4
//   License:  MIT, Copyright (c) 2021 Jesse Luehrs (full text: LICENSE in this
//             directory). This directory stays under MIT; the rest of the crate
//             is MPL-2.0.
//
// Files and their origin (src/ of rbw):
//
//   cipherstring.rs  <- src/cipherstring.rs
//   identity.rs      <- src/identity.rs
//   locked.rs        <- src/locked.rs
//   base64.rs        <- src/base64.rs
//   error.rs         <- src/error.rs (subset, see below)
//   mod.rs           (this file; `KdfType` from src/api.rs, `prelude` from src/prelude.rs)
//
// Edits, all needed to compile without rbw's other modules; the cryptographic
// code itself is unchanged:
//
//   1. A three-line provenance comment at the top of every copied file.
//   2. Paths: `crate::prelude` -> `super::prelude`, `crate::base64::`,
//      `crate::locked::` -> `super::...`, `crate::api::KdfType` -> `super::KdfType`.
//   3. error.rs: only the variants used by the four modules above are kept (same
//      names and messages); variants for networking, files, pinentry etc. removed.
//   4. `KdfType` (src/api.rs) is copied here without its serde impls.
//   5. Formatting is rbw's own (max_width 78); `cargo fmt` skips this module.
//   6. `#![allow(...)]` below for lints that the copied code triggers under this
//      crate's clippy settings.
//
// Callers in `vault` must not feed unchecked input into this code where it can
// panic (a panic aborts the app, release profile has `panic = "abort"`); see the
// checks in `vault::crypto`.

#![allow(dead_code, clippy::all)]

pub mod base64;
pub mod cipherstring;
pub mod error;
pub mod identity;
pub mod locked;

mod prelude {
    pub use super::error::{Error, Result};
}

#[derive(Debug, Copy, Clone, PartialEq, Eq)]
pub enum KdfType {
    Pbkdf2 = 0,
    Argon2id = 1,
}
