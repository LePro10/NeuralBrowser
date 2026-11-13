// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! Checked entry points into the rbw cryptography (`super::rbw`).
//!
//! Nothing here implements cryptography. These functions only
//!
//! * check untrusted input before it reaches code in `rbw` that would panic
//!   (a panic aborts the app): MAC length (`GenericArray::from` panics on a wrong
//!   length), cipher string type character, key and buffer lengths of the
//!   fixed-size locked buffers (4096 bytes),
//! * enforce the rule "every symmetric cipher string carries a MAC": rbw accepts
//!   type 2 without MAC and only rejects types 0/1; here a missing MAC is an error,
//! * map rbw errors to coarse failure reasons that never carry data.

use zeroize::{Zeroize, Zeroizing};

use super::rbw::cipherstring::CipherString;
use super::rbw::error::Error as RbwError;
use super::rbw::identity::Identity;
use super::rbw::locked;
use super::rbw::KdfType;

/// Capacity of rbw's locked buffers.
const LOCKED_CAPACITY: usize = 4096;
/// A 64-byte key (32 enc + 32 mac) encrypted with AES-CBC/PKCS#7: 64 + 16 bytes.
const WRAPPED_KEY_LEN: usize = 80;
const KEY_LEN: usize = 64;

/// Why a cipher string could not be used. The text is safe to show and to count.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub(crate) enum Failure {
    Malformed,
    MissingMac,
    UnsupportedType,
    InvalidMac,
    DecryptFailed,
    InvalidUtf8,
    WrongKeyLength,
}

impl Failure {
    pub(crate) fn reason(self) -> &'static str {
        match self {
            Failure::Malformed => "malformed cipher string",
            Failure::MissingMac => "cipher string without MAC",
            Failure::UnsupportedType => "unsupported cipher string type",
            Failure::InvalidMac => "MAC check failed",
            Failure::DecryptFailed => "decryption failed",
            Failure::InvalidUtf8 => "decrypted text is not UTF-8",
            Failure::WrongKeyLength => "key has the wrong length",
        }
    }
}

fn map_rbw(e: RbwError) -> Failure {
    match e {
        RbwError::InvalidMac => Failure::InvalidMac,
        RbwError::TooOldCipherStringType { .. } => Failure::MissingMac,
        RbwError::UnimplementedCipherStringType { .. } => Failure::UnsupportedType,
        RbwError::InvalidCipherString { .. } | RbwError::InvalidBase64 { .. } => Failure::Malformed,
        _ => Failure::DecryptFailed,
    }
}

/// Parses a cipher string and checks it can be handed to rbw without panicking.
/// Symmetric strings must have a 16-byte IV and a 32-byte MAC.
pub(crate) fn parse(s: &str) -> Result<CipherString, Failure> {
    let (ty, _) = s.split_once('.').ok_or(Failure::Malformed)?;
    if ty.len() != 1 || !ty.as_bytes()[0].is_ascii_digit() {
        return Err(Failure::UnsupportedType);
    }
    let cs = CipherString::new(s).map_err(map_rbw)?;
    if let CipherString::Symmetric {
        iv,
        mac,
        ciphertext,
    } = &cs
    {
        let mac = mac.as_ref().ok_or(Failure::MissingMac)?;
        if mac.len() != 32 || iv.len() != 16 || ciphertext.is_empty() {
            return Err(Failure::Malformed);
        }
    }
    Ok(cs)
}

fn symmetric_len(cs: &CipherString) -> Result<usize, Failure> {
    match cs {
        CipherString::Symmetric { ciphertext, .. } => Ok(ciphertext.len()),
        CipherString::Asymmetric { .. } => Err(Failure::UnsupportedType),
    }
}

/// Decrypts a MAC-protected symmetric cipher string to text.
pub(crate) fn decrypt_text(
    s: &str,
    keys: &locked::Keys,
    entry_key: Option<&locked::Keys>,
) -> Result<Zeroizing<String>, Failure> {
    let cs = parse(s)?;
    symmetric_len(&cs)?;
    let bytes = cs.decrypt_symmetric(keys, entry_key).map_err(map_rbw)?;
    match String::from_utf8(bytes) {
        Ok(text) => Ok(Zeroizing::new(text)),
        Err(e) => {
            e.into_bytes().zeroize();
            Err(Failure::InvalidUtf8)
        }
    }
}

/// Decrypts a wrapped 64-byte symmetric key (user key with the stretched master key,
/// per-item key with the user or organisation key) into locked memory.
pub(crate) fn decrypt_key(s: &str, keys: &locked::Keys) -> Result<locked::Keys, Failure> {
    let cs = parse(s)?;
    if symmetric_len(&cs)? != WRAPPED_KEY_LEN {
        return Err(Failure::WrongKeyLength);
    }
    // The locked buffer keeps the PKCS#7 padding after the 64 key bytes (rbw behaviour);
    // `Keys` only reads bytes 0..64.
    let v = cs.decrypt_locked_symmetric(keys).map_err(map_rbw)?;
    Ok(locked::Keys::new(v))
}

/// Decrypts the account's RSA private key (PKCS#8 DER) with the user key.
pub(crate) fn decrypt_private_key(
    s: &str,
    keys: &locked::Keys,
) -> Result<locked::PrivateKey, Failure> {
    let cs = parse(s)?;
    if symmetric_len(&cs)? > LOCKED_CAPACITY {
        return Err(Failure::WrongKeyLength);
    }
    let v = cs.decrypt_locked_symmetric(keys).map_err(map_rbw)?;
    Ok(locked::PrivateKey::new(v))
}

/// Decrypts an organisation key (RSA-OAEP, cipher string type 4 or 6).
///
/// Type 4 has no MAC: this is how Bitwarden shares organisation keys, and OAEP itself
/// rejects modified ciphertexts. It does not prove who encrypted the key (anyone with
/// the public key can, including the server) - a known weakness of the protocol,
/// recorded in docs/SECURITY.md 4.7.
pub(crate) fn decrypt_org_key(
    s: &str,
    private_key: &locked::PrivateKey,
) -> Result<locked::Keys, Failure> {
    let cs = parse(s)?;
    if !matches!(cs, CipherString::Asymmetric { .. }) {
        return Err(Failure::UnsupportedType);
    }
    let v = cs.decrypt_locked_asymmetric(private_key).map_err(map_rbw)?;
    if v.data().len() != KEY_LEN {
        return Err(Failure::WrongKeyLength);
    }
    Ok(locked::Keys::new(v))
}

/// Encrypts text with AES-256-CBC + HMAC-SHA256 (type 2) and returns the cipher string.
pub(crate) fn encrypt_text(plaintext: &str, keys: &locked::Keys) -> Result<String, Failure> {
    CipherString::encrypt_symmetric(keys, plaintext.as_bytes())
        .map(|cs| cs.to_string())
        .map_err(map_rbw)
}

/// KDF settings as accepted from prelogin (already range-checked).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Kdf {
    pub kind: KdfType,
    pub iterations: u32,
    /// Argon2id only, MiB.
    pub memory_mib: Option<u32>,
    /// Argon2id only.
    pub parallelism: Option<u32>,
}

/// Errors of [`derive_identity`].
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum DeriveError {
    PasswordEmpty,
    PasswordTooLong,
    Failed,
}

/// Derives the stretched master key and the master password hash (rbw `Identity`).
pub(crate) fn derive_identity(
    email: &str,
    password: &str,
    kdf: &Kdf,
) -> Result<Identity, DeriveError> {
    if password.is_empty() {
        return Err(DeriveError::PasswordEmpty);
    }
    if password.len() > LOCKED_CAPACITY {
        return Err(DeriveError::PasswordTooLong);
    }
    if kdf.kind == KdfType::Argon2id && (kdf.memory_mib.is_none() || kdf.parallelism.is_none()) {
        return Err(DeriveError::Failed);
    }
    let mut buf = locked::Vec::new();
    buf.extend(password.bytes());
    let password = locked::Password::new(buf);
    Identity::new(
        email,
        &password,
        kdf.kind,
        kdf.iterations,
        kdf.memory_mib,
        kdf.parallelism,
    )
    .map_err(|_| DeriveError::Failed)
}

/// Builds `Keys` from 64 raw bytes (tests and canned data only).
#[cfg(test)]
pub(crate) fn keys_from_bytes(bytes: &[u8]) -> locked::Keys {
    assert_eq!(bytes.len(), KEY_LEN);
    let mut v = locked::Vec::new();
    v.extend(bytes.iter().copied());
    locked::Keys::new(v)
}
