// Copied from rbw 1.15.0 (https://github.com/doy/rbw, commit 77464d4), src/error.rs.
// Copyright (c) 2021 Jesse Luehrs, MIT license (see LICENSE in this directory).
// Edits are listed in mod.rs (subset of variants only).

#[derive(thiserror::Error, Debug)]
pub enum Error {
    #[error("failed to create block mode decryptor")]
    CreateBlockMode { source: aes::cipher::InvalidLength },

    #[error("failed to create block mode decryptor")]
    CreateHmac { source: aes::cipher::InvalidLength },

    #[error("failed to decrypt")]
    Decrypt { source: block_padding::UnpadError },

    #[error("failed to expand with hkdf")]
    HkdfExpand,

    #[error("invalid base64")]
    InvalidBase64 { source: base64::DecodeError },

    #[error("invalid cipherstring: {reason}")]
    InvalidCipherString { reason: String },

    #[error("invalid mac")]
    InvalidMac,

    #[error("invalid padding")]
    Padding,

    #[error("pbkdf2 requires at least 1 iteration (got 0)")]
    Pbkdf2ZeroIterations,

    #[error("failed to run pbkdf2")]
    Pbkdf2,

    #[error("failed to run argon2")]
    Argon2,

    #[error("failed to decrypt")]
    Rsa { source: rsa::errors::Error },

    #[error("failed to decrypt")]
    RsaPkcs8 { source: rsa::pkcs8::Error },

    #[error("cipherstring type {ty} too old\n\nPlease rotate your account encryption key (https://bitwarden.com/help/article/account-encryption-key/) and try again.")]
    TooOldCipherStringType { ty: String },

    #[error("unimplemented cipherstring type: {ty}")]
    UnimplementedCipherStringType { ty: String },
}

pub type Result<T> = std::result::Result<T, Error>;
