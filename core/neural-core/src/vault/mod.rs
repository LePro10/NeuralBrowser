// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! Built-in Vaultwarden/Bitwarden client core (docs/SECURITY.md 4.7).
//!
//! # Sans-IO
//!
//! This module never opens a network connection. Every step is a pair: a `*_request`
//! method returns an [`HttpRequest`] (method, URL, headers, body) that the platform
//! shell sends (URLSession, normal system certificate checks), and a `handle_*` method
//! takes the [`HttpResponse`] (status, body). Order of a session:
//!
//! 1. [`Vault::new`] with the server address (`https://` only), e-mail and a device id
//!    that the shell keeps stable per installation (a UUID string).
//! 2. [`Vault::prelogin_request`] / [`Vault::handle_prelogin`]: KDF settings; values
//!    below the minimums of SECURITY.md 4.7 are refused unless `allow_weak_kdf`.
//! 3. [`Vault::login_request`] / [`Vault::handle_login`] -> [`LoginOutcome`]. On
//!    `TwoFactorRequired` call `login_request` again with a [`TwoFactorCode`];
//!    [`Vault::send_email_code_request`] asks the server to (re)send the e-mail code.
//! 4. [`Vault::sync_request`] / [`Vault::handle_sync`]: downloads and decrypts the vault.
//! 5. [`Vault::logins_for_url`], [`Vault::all_logins`], [`Vault::username`],
//!    [`Vault::password`]; [`Vault::add_login_request`] / [`Vault::handle_add_login`].
//! 6. [`Vault::lock`]: forgets the session, keys and decrypted data.
//!
//! # What is kept where
//!
//! * Stretched master key, user key, private key and organisation keys: rbw's locked
//!   buffers (`mlock`ed, zeroized on drop).
//! * Access token, decrypted names, usernames and URIs: heap, zeroized on lock/drop.
//! * Passwords stay encrypted in memory and are decrypted only inside
//!   [`Vault::password`] (MAC-checked during sync).
//! * The master password is copied into a locked buffer for key derivation and the
//!   argument string is zeroized. Nothing is written to disk.
//!
//! Strings handed to Swift (request bodies with the password hash, the `Authorization`
//! header, returned passwords) leave this module's control; UniFFI's transfer buffers
//! are not zeroized.
//!
//! # Limitations (first version)
//!
//! * No token refresh, nothing persisted: sign in once per app session; an expired
//!   access token makes sync/add fail with [`VaultError::Unauthorized`].
//! * Two-factor: authenticator app and e-mail code only; "remember this device" is off.
//!   No SSO, no key connector, no new-device e-mail verification of bitwarden.com.
//! * Only login items; matching is host-exact (see `matching`).
//! * New entries are encrypted with the user key directly (no per-item key).

mod crypto;
mod matching;
mod protocol;
#[rustfmt::skip]
mod rbw;
#[cfg(test)]
mod tests;

use std::collections::{BTreeMap, HashMap};
use std::sync::{Mutex, MutexGuard};

use serde::Serialize;
use zeroize::{Zeroize, Zeroizing};

use crate::shield::ReasonCount;
use crypto::{Failure, Kdf};
use protocol::{as_u32, Cipher, ConnectErrorRes, ConnectTokenRes, PreloginRes, SyncRes};
use rbw::locked;
use rbw::KdfType;

/// PBKDF2-SHA256 minimum (SECURITY.md 4.7, OWASP 2023).
pub const MIN_PBKDF2_ITERATIONS: u32 = 600_000;
/// Argon2id minimum memory in MiB (SECURITY.md 4.7).
pub const MIN_ARGON2_MEMORY_MIB: u32 = 19;
/// Argon2id minimum iterations (SECURITY.md 4.7).
pub const MIN_ARGON2_ITERATIONS: u32 = 2;
// Upper bounds as enforced by the Bitwarden server; a hostile server must not be able
// to make the client hang or allocate gigabytes.
const MAX_PBKDF2_ITERATIONS: u32 = 2_000_000;
const MAX_ARGON2_MEMORY_MIB: u32 = 1024;
const MAX_ARGON2_ITERATIONS: u32 = 10;
const MAX_ARGON2_PARALLELISM: u32 = 16;

/// `Bitwarden-Client-Name` header and OAuth `client_id`, as rbw uses them.
const CLIENT_NAME: &str = "cli";
/// `Bitwarden-Client-Version`; rbw sends this value for sync (Vaultwarden gates some
/// response fields on it).
const CLIENT_VERSION: &str = "2024.12.0";
/// Bitwarden `DeviceType.MacOsDesktop` (rbw sends 8, LinuxDesktop).
const DEVICE_TYPE: u32 = 7;
const DEVICE_NAME: &str = "NeuralBrowser";
const MAX_SERVER_MESSAGE: usize = 200;

// ---------------------------------------------------------------- public types

/// Errors of the vault. Messages never contain passwords, hashes, tokens, keys or
/// response bodies.
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum VaultError {
    /// Server address is not a usable `https://` URL.
    #[error("invalid server URL: {reason}")]
    InvalidServerUrl { reason: String },
    /// A caller-supplied value is invalid (e-mail, device id, code, URL, ...).
    #[error("invalid argument: {message}")]
    InvalidArgument { message: String },
    /// The server's KDF settings are below the minimums; retry `handle_prelogin` with
    /// `allow_weak_kdf = true` only after the user explicitly confirmed.
    #[error("the server's key derivation settings are below the minimum")]
    WeakKdf { settings: KdfSettings },
    /// Unknown KDF or values outside what any Bitwarden server allows.
    #[error("unsupported key derivation settings: {message}")]
    UnsupportedKdf { message: String },
    /// Methods called in the wrong order (e.g. login before prelogin).
    #[error("wrong order of calls: {message}")]
    WrongState { message: String },
    /// Needs a signed-in, unlocked vault.
    #[error("the vault is locked")]
    Locked,
    /// The server rejected the access token (HTTP 401); sign in again.
    #[error("the server rejected the session, sign in again")]
    Unauthorized,
    /// The server answered with an error status. `message` is the server's own short
    /// error text when it sent one (sanitised), never the request.
    #[error("server error (HTTP {status}): {message}")]
    Server { status: u16, message: String },
    /// The response could not be read (not JSON, required fields missing).
    #[error("unexpected server response: {message}")]
    InvalidResponse { message: String },
    /// Key derivation or a key check failed (e.g. the user key's MAC is wrong).
    #[error("cryptographic check failed: {message}")]
    Crypto { message: String },
    /// No login with this id in the unlocked vault.
    #[error("no login with this id")]
    NotFound,
    /// Internal invariant violated (poisoned lock).
    #[error("internal error: {message}")]
    Internal { message: String },
}

type Result<T, E = VaultError> = std::result::Result<T, E>;

/// One HTTP header.
#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct HttpHeader {
    pub name: String,
    pub value: String,
}

/// A request for the shell to send. `body` may contain the master password hash and
/// headers may contain the access token: do not log either.
#[derive(Clone, uniffi::Record)]
pub struct HttpRequest {
    /// `GET` or `POST`.
    pub method: String,
    /// Absolute `https://` URL.
    pub url: String,
    pub headers: Vec<HttpHeader>,
    pub body: Option<Vec<u8>>,
}

/// The server's answer as received by the shell (any status, full body).
#[derive(Clone, uniffi::Record)]
pub struct HttpResponse {
    pub status: u16,
    pub body: Vec<u8>,
}

/// Key derivation algorithm.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum KdfAlgorithm {
    Pbkdf2Sha256,
    Argon2id,
}

/// KDF settings reported by the server (not secret).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct KdfSettings {
    pub algorithm: KdfAlgorithm,
    pub iterations: u32,
    /// Argon2id only, in MiB.
    pub memory_mib: Option<u32>,
    /// Argon2id only.
    pub parallelism: Option<u32>,
    /// True if below the minimums and accepted only because of `allow_weak_kdf`.
    pub weak: bool,
}

/// Supported second factors.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum TwoFactorProvider {
    /// TOTP code from an authenticator app (Bitwarden provider 0).
    Authenticator,
    /// Code sent by e-mail (Bitwarden provider 1).
    Email,
}

/// A second-factor code entered by the user.
#[derive(Clone, uniffi::Record)]
pub struct TwoFactorCode {
    pub provider: TwoFactorProvider,
    pub code: String,
}

/// Result of [`Vault::handle_login`].
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum LoginOutcome {
    /// Signed in; keys and token are kept inside the core. Call sync next.
    Success,
    /// The server wants a second factor. `providers` are the ones this client supports
    /// (in this order: authenticator, e-mail); `unsupported_providers` names the others
    /// the account has (`duo`, `yubikey`, `webauthn`, ...). Empty `providers` means
    /// this account cannot sign in here.
    TwoFactorRequired {
        providers: Vec<TwoFactorProvider>,
        unsupported_providers: Vec<String>,
    },
    /// E-mail or master password wrong.
    InvalidCredentials,
    /// The second-factor code was rejected. Some servers answer a wrong code with
    /// `TwoFactorRequired` again instead.
    InvalidTwoFactorCode,
    /// Any other refusal (rate limit, blocked account, server down, ...).
    ServerError { status: u16, message: String },
}

/// A login entry without its password.
#[derive(Clone, PartialEq, Eq, uniffi::Record)]
pub struct LoginSummary {
    /// Server id of the item.
    pub id: String,
    pub name: String,
    pub username: Option<String>,
    /// The stored URI that matched (only from `logins_for_url`).
    pub matched_uri: Option<String>,
    /// True if the item belongs to an organisation.
    pub is_organization: bool,
}

/// Counts from [`Vault::handle_sync`] (never contents).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SyncSummary {
    /// Login items that are available.
    pub logins: u32,
    /// Login items (or malformed items) that could not be decrypted or verified.
    pub undecryptable: u32,
    /// Why, as counts per reason (e.g. "MAC check failed", "organization key unavailable").
    pub undecryptable_reasons: Vec<ReasonCount>,
    /// Items of other types (notes, cards, identities, SSH keys), not loaded.
    pub skipped_other_types: u32,
    /// Items in the trash, not loaded.
    pub skipped_deleted: u32,
}

impl std::fmt::Debug for HttpRequest {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let headers: Vec<String> = self
            .headers
            .iter()
            .map(|h| {
                let n = h.name.to_ascii_lowercase();
                if n == "authorization" || n == "auth-email" {
                    format!("{}: ***", h.name)
                } else {
                    format!("{}: {}", h.name, h.value)
                }
            })
            .collect();
        f.debug_struct("HttpRequest")
            .field("method", &self.method)
            .field("url", &self.url)
            .field("headers", &headers)
            .field("body", &self.body.as_ref().map(|_| "***"))
            .finish()
    }
}

impl std::fmt::Debug for HttpResponse {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("HttpResponse")
            .field("status", &self.status)
            .field("body", &format_args!("*** ({} bytes)", self.body.len()))
            .finish()
    }
}

impl std::fmt::Debug for TwoFactorCode {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("TwoFactorCode")
            .field("provider", &self.provider)
            .field("code", &"***")
            .finish()
    }
}

impl std::fmt::Debug for LoginSummary {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("LoginSummary")
            .field("id", &self.id)
            .field("name", &"***")
            .field("username", &self.username.as_ref().map(|_| "***"))
            .field("matched_uri", &self.matched_uri.as_ref().map(|_| "***"))
            .field("is_organization", &self.is_organization)
            .finish()
    }
}

// ---------------------------------------------------------------- internal state

/// Between `login_request` and a successful `handle_login`.
struct Pending {
    identity: rbw::identity::Identity,
    hash_b64: Zeroizing<String>,
    sent_two_factor: bool,
    sso_email_2fa_session_token: Option<Zeroizing<String>>,
}

struct Entry {
    id: String,
    org_id: Option<String>,
    /// Encrypted per-item key, if the item has one.
    item_key: Option<String>,
    name: Zeroizing<String>,
    username: Option<Zeroizing<String>>,
    /// Still encrypted; decrypted only in `password()`.
    password: Option<String>,
    uris: Vec<(Zeroizing<String>, Option<u8>)>,
}

struct Session {
    access_token: Zeroizing<String>,
    user_keys: locked::Keys,
    org_keys: HashMap<String, locked::Keys>,
    entries: BTreeMap<String, Entry>,
}

#[derive(Default)]
struct State {
    kdf: Option<Kdf>,
    pending: Option<Pending>,
    session: Option<Session>,
}

/// Client for one account on one Vaultwarden/Bitwarden server. Thread-safe; all
/// methods may be called from any thread (key derivation in `login_request` takes
/// up to a few seconds: call it off the main thread).
#[derive(uniffi::Object)]
pub struct Vault {
    base_url: String,
    api_url: String,
    identity_url: String,
    email: String,
    device_id: String,
    state: Mutex<State>,
}

impl std::fmt::Debug for Vault {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let unlocked = self
            .state
            .lock()
            .map(|s| s.session.is_some())
            .unwrap_or(false);
        f.debug_struct("Vault")
            .field("server", &self.base_url)
            .field("email", &"***")
            .field("unlocked", &unlocked)
            .finish_non_exhaustive()
    }
}

/// Normalises the server address: `https://` only, no credentials/query/fragment,
/// trailing slashes removed. Returns the base URL without trailing slash.
fn normalize_server_url(input: &str) -> Result<String> {
    let bad = |reason: &str| VaultError::InvalidServerUrl {
        reason: reason.to_string(),
    };
    let mut u = url::Url::parse(input.trim()).map_err(|_| bad("not a URL"))?;
    if u.scheme() != "https" {
        return Err(bad("only https:// is allowed"));
    }
    if u.host().is_none() {
        return Err(bad("missing host"));
    }
    if !u.username().is_empty() || u.password().is_some() {
        return Err(bad("must not contain credentials"));
    }
    if u.query().is_some() || u.fragment().is_some() {
        return Err(bad("must not contain a query or fragment"));
    }
    u.set_query(None);
    u.set_fragment(None);
    Ok(u.as_str().trim_end_matches('/').to_string())
}

fn invalid(message: &str) -> VaultError {
    VaultError::InvalidArgument {
        message: message.to_string(),
    }
}

fn wrong_state(message: &str) -> VaultError {
    VaultError::WrongState {
        message: message.to_string(),
    }
}

fn bad_response(message: &str) -> VaultError {
    VaultError::InvalidResponse {
        message: message.to_string(),
    }
}

fn header(name: &str, value: impl Into<String>) -> HttpHeader {
    HttpHeader {
        name: name.to_string(),
        value: value.into(),
    }
}

fn common_headers(content_type: Option<&str>) -> Vec<HttpHeader> {
    let mut h = vec![
        header("Accept", "application/json"),
        header("Bitwarden-Client-Name", CLIENT_NAME),
        header("Bitwarden-Client-Version", CLIENT_VERSION),
        header("Device-Type", DEVICE_TYPE.to_string()),
    ];
    if let Some(ct) = content_type {
        h.push(header("Content-Type", ct));
    }
    h
}

/// Short, printable error text from an error body, or a generic one. `scrub` values
/// (e.g. the password hash) cause the message to be withheld.
fn server_message(body: &[u8], scrub: &[&str]) -> String {
    let parsed: protocol::ApiErrorRes = serde_json::from_slice(body).unwrap_or_default();
    let raw = parsed
        .error_model
        .and_then(|m| m.message)
        .or(parsed.message)
        .unwrap_or_default();
    if scrub.iter().any(|s| !s.is_empty() && raw.contains(s)) {
        return "(server message withheld)".to_string();
    }
    let clean: String = raw
        .chars()
        .filter(|c| !c.is_control())
        .take(MAX_SERVER_MESSAGE)
        .collect();
    if clean.trim().is_empty() {
        "request failed".to_string()
    } else {
        clean
    }
}

fn status_error(response: &HttpResponse) -> VaultError {
    if response.status == 401 {
        VaultError::Unauthorized
    } else {
        VaultError::Server {
            status: response.status,
            message: server_message(&response.body, &[]),
        }
    }
}

/// Checks prelogin values. `Ok(settings)` with `weak` set if only `allow_weak_kdf`
/// let them through.
fn check_kdf(res: &PreloginRes, allow_weak: bool) -> Result<(Kdf, KdfSettings)> {
    let unsupported = |m: &str| VaultError::UnsupportedKdf {
        message: m.to_string(),
    };
    let iterations = as_u32(&res.kdf_iterations).ok_or_else(|| unsupported("iterations"))?;
    let (kdf, settings) = match as_u32(&res.kdf) {
        Some(0) => {
            if iterations == 0 || iterations > MAX_PBKDF2_ITERATIONS {
                return Err(unsupported("PBKDF2 iterations out of range"));
            }
            let weak = iterations < MIN_PBKDF2_ITERATIONS;
            (
                Kdf {
                    kind: KdfType::Pbkdf2,
                    iterations,
                    memory_mib: None,
                    parallelism: None,
                },
                KdfSettings {
                    algorithm: KdfAlgorithm::Pbkdf2Sha256,
                    iterations,
                    memory_mib: None,
                    parallelism: None,
                    weak,
                },
            )
        }
        Some(1) => {
            let memory = as_u32(&res.kdf_memory).ok_or_else(|| unsupported("Argon2 memory"))?;
            let parallelism =
                as_u32(&res.kdf_parallelism).ok_or_else(|| unsupported("Argon2 parallelism"))?;
            if !(1..=MAX_ARGON2_ITERATIONS).contains(&iterations)
                || !(1..=MAX_ARGON2_MEMORY_MIB).contains(&memory)
                || !(1..=MAX_ARGON2_PARALLELISM).contains(&parallelism)
                || argon2::Params::new(memory * 1024, iterations, parallelism, Some(32)).is_err()
            {
                return Err(unsupported("Argon2id parameters out of range"));
            }
            let weak = memory < MIN_ARGON2_MEMORY_MIB || iterations < MIN_ARGON2_ITERATIONS;
            (
                Kdf {
                    kind: KdfType::Argon2id,
                    iterations,
                    memory_mib: Some(memory),
                    parallelism: Some(parallelism),
                },
                KdfSettings {
                    algorithm: KdfAlgorithm::Argon2id,
                    iterations,
                    memory_mib: Some(memory),
                    parallelism: Some(parallelism),
                    weak,
                },
            )
        }
        _ => return Err(unsupported("unknown KDF type")),
    };
    if settings.weak && !allow_weak {
        return Err(VaultError::WeakKdf { settings });
    }
    Ok((kdf, settings))
}

/// Decrypts one login cipher. Error = reason for the summary.
fn decrypt_entry(
    c: &Cipher,
    user_keys: &locked::Keys,
    org_keys: &HashMap<String, locked::Keys>,
) -> std::result::Result<Entry, &'static str> {
    let base = match &c.organization_id {
        Some(org) => org_keys.get(org).ok_or("organization key unavailable")?,
        None => user_keys,
    };
    let item_key = match &c.key {
        Some(k) => Some(crypto::decrypt_key(k, base).map_err(Failure::reason)?),
        None => None,
    };
    let text = |s: &str| crypto::decrypt_text(s, base, item_key.as_ref()).map_err(Failure::reason);
    let name = text(c.name.as_deref().ok_or("item without name")?)?;
    let login = c.login.as_ref();
    let username = match login.and_then(|l| l.username.as_deref()) {
        Some(u) => Some(text(u)?),
        None => None,
    };
    // Verify (MAC) and decrypt once; keep only the cipher string.
    let password = match login.and_then(|l| l.password.as_deref()) {
        Some(p) => {
            drop(text(p)?);
            Some(p.to_string())
        }
        None => None,
    };
    let mut uris = Vec::new();
    for u in login.and_then(|l| l.uris.as_ref()).into_iter().flatten() {
        if let Some(enc) = u.uri.as_deref() {
            uris.push((text(enc)?, u.match_type));
        }
    }
    Ok(Entry {
        id: c.id.clone(),
        org_id: c.organization_id.clone(),
        item_key: c.key.clone(),
        name,
        username,
        password,
        uris,
    })
}

fn summary(e: &Entry, matched_uri: Option<String>) -> LoginSummary {
    LoginSummary {
        id: e.id.clone(),
        name: e.name.to_string(),
        username: e.username.as_ref().map(|u| u.to_string()),
        matched_uri,
        is_organization: e.org_id.is_some(),
    }
}

/// Deterministic order: name (case-insensitive), username, id.
fn sort_summaries(v: &mut [LoginSummary]) {
    v.sort_by(|a, b| {
        a.name
            .to_lowercase()
            .cmp(&b.name.to_lowercase())
            .then_with(|| a.username.cmp(&b.username))
            .then_with(|| a.id.cmp(&b.id))
    });
}

#[derive(Serialize)]
struct SendEmailLoginReq<'a> {
    email: &'a str,
    #[serde(rename = "masterPasswordHash")]
    master_password_hash: &'a str,
    #[serde(rename = "deviceIdentifier")]
    device_identifier: &'a str,
    #[serde(
        rename = "ssoEmail2faSessionToken",
        skip_serializing_if = "Option::is_none"
    )]
    sso_email_2fa_session_token: Option<&'a str>,
}

impl Vault {
    fn state(&self) -> Result<MutexGuard<'_, State>> {
        self.state.lock().map_err(|_| VaultError::Internal {
            message: "vault lock poisoned".into(),
        })
    }

    fn with_session<T>(&self, f: impl FnOnce(&Session) -> Result<T>) -> Result<T> {
        let st = self.state()?;
        let session = st.session.as_ref().ok_or(VaultError::Locked)?;
        f(session)
    }

    fn auth_email(&self) -> String {
        rbw::base64::encode_url_safe_no_pad(&self.email)
    }
}

#[uniffi::export]
impl Vault {
    /// Creates a client. `server_url` must be `https://` (also for localhost); the API
    /// lives at `<server>/api`, the identity service at `<server>/identity`
    /// (Vaultwarden layout; bitwarden.com's web vault address works the same way).
    /// `device_id`: stable per installation, 1-128 characters `[A-Za-z0-9-]`.
    #[uniffi::constructor]
    pub fn new(server_url: String, email: String, device_id: String) -> Result<Self> {
        let base_url = normalize_server_url(&server_url)?;
        let email = email.trim().to_lowercase();
        if email.len() > 254 || email.chars().any(char::is_control) || !email.contains('@') {
            return Err(invalid("e-mail address"));
        }
        if device_id.is_empty()
            || device_id.len() > 128
            || !device_id
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || c == '-')
        {
            return Err(invalid("device id"));
        }
        Ok(Self {
            api_url: format!("{base_url}/api"),
            identity_url: format!("{base_url}/identity"),
            base_url,
            email,
            device_id,
            state: Mutex::new(State::default()),
        })
    }

    /// The normalised server address (show it in full on the sign-in screen).
    pub fn server_url(&self) -> String {
        self.base_url.clone()
    }

    /// The e-mail address as used for the account (trimmed, lower case).
    pub fn email(&self) -> String {
        self.email.clone()
    }

    /// `POST <server>/identity/accounts/prelogin` asking for the account's KDF settings.
    pub fn prelogin_request(&self) -> HttpRequest {
        let body =
            serde_json::to_vec(&serde_json::json!({ "email": self.email })).unwrap_or_default();
        HttpRequest {
            method: "POST".into(),
            url: format!("{}/accounts/prelogin", self.identity_url),
            headers: common_headers(Some("application/json")),
            body: Some(body),
        }
    }

    /// Reads and checks the KDF settings. Below the minimums (PBKDF2 < 600,000;
    /// Argon2id < 19 MiB or < 2 iterations) this fails with `WeakKdf` unless
    /// `allow_weak_kdf` is true (only after the user confirmed). Values no Bitwarden
    /// server allows fail with `UnsupportedKdf` regardless.
    pub fn handle_prelogin(
        &self,
        response: HttpResponse,
        allow_weak_kdf: bool,
    ) -> Result<KdfSettings> {
        // Any earlier settings are void, also if this response is refused.
        let mut st = self.state()?;
        st.kdf = None;
        st.pending = None;
        if response.status != 200 {
            return Err(status_error(&response));
        }
        let res: PreloginRes = serde_json::from_slice(&response.body)
            .map_err(|_| bad_response("prelogin response could not be read"))?;
        let (kdf, settings) = check_kdf(&res, allow_weak_kdf)?;
        st.kdf = Some(kdf);
        Ok(settings)
    }

    /// Derives the keys from the master password (slow: PBKDF2/Argon2id) and builds
    /// `POST <server>/identity/connect/token`. With `two_factor`, the code is sent
    /// along (call again after `LoginOutcome::TwoFactorRequired`). The password string
    /// is zeroized; it is never stored.
    pub fn login_request(
        &self,
        master_password: String,
        two_factor: Option<TwoFactorCode>,
    ) -> Result<HttpRequest> {
        let master_password = Zeroizing::new(master_password);
        let two_factor = two_factor.map(|mut t| {
            let code = Zeroizing::new(t.code.trim().to_string());
            t.code.zeroize();
            (t.provider, code)
        });
        if let Some((_, code)) = &two_factor {
            if code.is_empty() || code.len() > 64 || code.chars().any(char::is_control) {
                return Err(invalid("two-factor code"));
            }
        }
        let kdf = self
            .state()?
            .kdf
            .ok_or_else(|| wrong_state("call handle_prelogin first"))?;
        let identity =
            crypto::derive_identity(&self.email, &master_password, &kdf).map_err(|e| match e {
                crypto::DeriveError::PasswordEmpty => invalid("master password is empty"),
                crypto::DeriveError::PasswordTooLong => invalid("master password is too long"),
                crypto::DeriveError::Failed => VaultError::Crypto {
                    message: "key derivation failed".into(),
                },
            })?;
        drop(master_password);
        let hash_b64 = Zeroizing::new(rbw::base64::encode(identity.master_password_hash.hash()));

        let device_type = DEVICE_TYPE.to_string();
        let mut form = url::form_urlencoded::Serializer::new(String::new());
        form.append_pair("grant_type", "password")
            .append_pair("scope", "api offline_access")
            .append_pair("client_id", CLIENT_NAME)
            .append_pair("deviceType", &device_type)
            .append_pair("deviceIdentifier", &self.device_id)
            .append_pair("deviceName", DEVICE_NAME)
            .append_pair("devicePushToken", "")
            .append_pair("username", &self.email)
            .append_pair("password", &hash_b64);
        if let Some((provider, code)) = &two_factor {
            let id = match provider {
                TwoFactorProvider::Authenticator => "0",
                TwoFactorProvider::Email => "1",
            };
            form.append_pair("twoFactorToken", code)
                .append_pair("twoFactorProvider", id)
                .append_pair("twoFactorRemember", "0");
        }
        let body = Zeroizing::new(form.finish());

        let mut headers = common_headers(Some("application/x-www-form-urlencoded; charset=utf-8"));
        headers.push(header("Auth-Email", self.auth_email()));

        let mut st = self.state()?;
        let sso_email_2fa_session_token = st
            .pending
            .take()
            .and_then(|p| p.sso_email_2fa_session_token);
        st.pending = Some(Pending {
            identity,
            hash_b64,
            sent_two_factor: two_factor.is_some(),
            sso_email_2fa_session_token,
        });
        Ok(HttpRequest {
            method: "POST".into(),
            url: format!("{}/connect/token", self.identity_url),
            headers,
            body: Some(body.as_bytes().to_vec()),
        })
    }

    /// Interprets the token response. On success the user key is decrypted and checked
    /// (MAC) right away; token and keys stay in the core. The response body is zeroized.
    pub fn handle_login(&self, response: HttpResponse) -> Result<LoginOutcome> {
        let status = response.status;
        let body = Zeroizing::new(response.body);
        let mut st = self.state()?;
        let pending = st
            .pending
            .as_mut()
            .ok_or_else(|| wrong_state("call login_request first"))?;

        if status == 200 {
            let res: ConnectTokenRes = serde_json::from_slice(&body)
                .map_err(|_| bad_response("login response could not be read"))?;
            let access_token = Zeroizing::new(res.access_token);
            let key = res.key.ok_or_else(|| {
                bad_response("no user key (accounts without master password are not supported)")
            })?;
            let user_keys = crypto::decrypt_key(&key, &pending.identity.keys).map_err(|f| {
                VaultError::Crypto {
                    message: format!("user key: {}", f.reason()),
                }
            })?;
            st.pending = None;
            st.session = Some(Session {
                access_token,
                user_keys,
                org_keys: HashMap::new(),
                entries: BTreeMap::new(),
            });
            return Ok(LoginOutcome::Success);
        }

        let err: ConnectErrorRes = serde_json::from_slice(&body).unwrap_or_default();
        if let Some(list) = err.two_factor_providers.as_ref().filter(|l| !l.is_empty()) {
            let mut providers = Vec::new();
            let mut unsupported = Vec::new();
            let mut ids: Vec<u32> = list.iter().filter_map(as_u32).collect();
            ids.sort_unstable();
            ids.dedup();
            for id in ids {
                match id {
                    0 => providers.push(TwoFactorProvider::Authenticator),
                    1 => providers.push(TwoFactorProvider::Email),
                    5 => {} // "remember this device" token, not a real provider
                    n => unsupported.push(protocol::provider_name(n)),
                }
            }
            pending.sso_email_2fa_session_token =
                err.sso_email_2fa_session_token.map(Zeroizing::new);
            return Ok(LoginOutcome::TwoFactorRequired {
                providers,
                unsupported_providers: unsupported,
            });
        }

        let message = err
            .error_model
            .as_ref()
            .and_then(|m| m.message.clone())
            .unwrap_or_default();
        let error = err.error.as_deref().unwrap_or("");
        let desc = err.error_description.as_deref().unwrap_or("");
        // Classification after rbw `classify_login_error` plus the official server's
        // two-step message.
        let totp_message = message == "TOTP code is not a number"
            || message.starts_with("Invalid TOTP code")
            || message.starts_with("Two-step token is invalid");
        let wrong_password = (error == "invalid_grant" && desc == "invalid_username_or_password")
            || message == "Username or password is incorrect. Try again";
        if totp_message || (wrong_password && pending.sent_two_factor) {
            return Ok(LoginOutcome::InvalidTwoFactorCode);
        }
        if wrong_password {
            return Ok(LoginOutcome::InvalidCredentials);
        }
        let scrub = [pending.hash_b64.as_str()];
        Ok(LoginOutcome::ServerError {
            status,
            message: server_message(&body, &scrub),
        })
    }

    /// `POST <server>/api/two-factor/send-email-login`: asks the server to send (again)
    /// the e-mail code. Valid after `login_request` (it reuses the derived password
    /// hash, which the server checks). Vaultwarden also sends the code by itself when
    /// e-mail is the account's two-factor method.
    pub fn send_email_code_request(&self) -> Result<HttpRequest> {
        let st = self.state()?;
        let pending = st
            .pending
            .as_ref()
            .ok_or_else(|| wrong_state("call login_request first"))?;
        let req = SendEmailLoginReq {
            email: &self.email,
            master_password_hash: &pending.hash_b64,
            device_identifier: &self.device_id,
            sso_email_2fa_session_token: pending
                .sso_email_2fa_session_token
                .as_ref()
                .map(|t| t.as_str()),
        };
        let body = serde_json::to_vec(&req).map_err(|_| VaultError::Internal {
            message: "could not encode request".into(),
        })?;
        let mut headers = common_headers(Some("application/json"));
        headers.push(header("Auth-Email", self.auth_email()));
        Ok(HttpRequest {
            method: "POST".into(),
            url: format!("{}/two-factor/send-email-login", self.api_url),
            headers,
            body: Some(body),
        })
    }

    /// Checks the answer to `send_email_code_request` (HTTP 200 = sent).
    pub fn handle_send_email_code(&self, response: HttpResponse) -> Result<()> {
        if response.status == 200 {
            Ok(())
        } else {
            Err(status_error(&response))
        }
    }

    /// `GET <server>/api/sync?excludeDomains=true` with the session's bearer token.
    pub fn sync_request(&self) -> Result<HttpRequest> {
        self.with_session(|s| {
            let mut headers = common_headers(None);
            headers.push(header(
                "Authorization",
                format!("Bearer {}", s.access_token.as_str()),
            ));
            Ok(HttpRequest {
                method: "GET".into(),
                url: format!("{}/sync?excludeDomains=true", self.api_url),
                headers,
                body: None,
            })
        })
    }

    /// Decrypts the vault: private key and organisation keys, then every login item.
    /// Every symmetric cipher string is MAC-checked before decryption; strings without
    /// MAC are refused. Replaces all previously loaded entries.
    pub fn handle_sync(&self, response: HttpResponse) -> Result<SyncSummary> {
        if response.status != 200 {
            return Err(status_error(&response));
        }
        let res: SyncRes = serde_json::from_slice(&response.body)
            .map_err(|_| bad_response("sync response could not be read"))?;
        let mut st = self.state()?;
        let session = st.session.as_mut().ok_or(VaultError::Locked)?;

        let private_key = res
            .profile
            .private_key
            .as_deref()
            .and_then(|pk| crypto::decrypt_private_key(pk, &session.user_keys).ok());
        let mut org_keys = HashMap::new();
        if let Some(pk) = &private_key {
            for org in &res.profile.organizations {
                if let Some(k) = org.key.as_deref() {
                    if let Ok(keys) = crypto::decrypt_org_key(k, pk) {
                        org_keys.insert(org.id.clone(), keys);
                    }
                }
            }
        }
        drop(private_key);

        let mut entries = BTreeMap::new();
        let mut reasons: BTreeMap<&'static str, u32> = BTreeMap::new();
        let mut summary = SyncSummary {
            logins: 0,
            undecryptable: 0,
            undecryptable_reasons: Vec::new(),
            skipped_other_types: 0,
            skipped_deleted: 0,
        };
        for raw in res.ciphers {
            let cipher: Cipher = match serde_json::from_value(raw) {
                Ok(c) => c,
                Err(_) => {
                    summary.undecryptable += 1;
                    *reasons.entry("malformed item").or_default() += 1;
                    continue;
                }
            };
            if cipher.deleted_date.is_some() {
                summary.skipped_deleted += 1;
                continue;
            }
            if cipher.ty != protocol::CIPHER_TYPE_LOGIN {
                summary.skipped_other_types += 1;
                continue;
            }
            match decrypt_entry(&cipher, &session.user_keys, &org_keys) {
                Ok(e) => {
                    summary.logins += 1;
                    entries.insert(e.id.clone(), e);
                }
                Err(reason) => {
                    summary.undecryptable += 1;
                    *reasons.entry(reason).or_default() += 1;
                }
            }
        }
        summary.undecryptable_reasons = reasons
            .into_iter()
            .map(|(reason, count)| ReasonCount {
                reason: reason.to_string(),
                count,
            })
            .collect();
        session.org_keys = org_keys;
        session.entries = entries;
        Ok(summary)
    }

    /// All loaded logins, sorted by name, username, id.
    pub fn all_logins(&self) -> Result<Vec<LoginSummary>> {
        self.with_session(|s| {
            let mut v: Vec<_> = s.entries.values().map(|e| summary(e, None)).collect();
            sort_summaries(&mut v);
            Ok(v)
        })
    }

    /// Logins for a page. Only `https://` pages; host-exact matching (see module docs
    /// of `matching`). Non-https pages get an empty list, not an error.
    pub fn logins_for_url(&self, url: String) -> Result<Vec<LoginSummary>> {
        self.with_session(|s| {
            let Some(page) = matching::page_url(&url) else {
                return Ok(Vec::new());
            };
            let mut v: Vec<_> = s
                .entries
                .values()
                .filter_map(|e| {
                    e.uris
                        .iter()
                        .find(|(uri, m)| matching::uri_matches(&page, uri, *m))
                        .map(|(uri, _)| summary(e, Some(uri.to_string())))
                })
                .collect();
            sort_summaries(&mut v);
            Ok(v)
        })
    }

    /// The username of a login (`None` if the item has none).
    pub fn username(&self, id: String) -> Result<Option<String>> {
        self.with_session(|s| {
            let e = s.entries.get(&id).ok_or(VaultError::NotFound)?;
            Ok(e.username.as_ref().map(|u| u.to_string()))
        })
    }

    /// Decrypts and returns the password of a login (`None` if the item has none).
    /// Call only for a user action (fill, copy, reveal).
    pub fn password(&self, id: String) -> Result<Option<String>> {
        self.with_session(|s| {
            let e = s.entries.get(&id).ok_or(VaultError::NotFound)?;
            let Some(enc) = e.password.as_deref() else {
                return Ok(None);
            };
            let crypto_err = |f: Failure| VaultError::Crypto {
                message: f.reason().to_string(),
            };
            let base = match &e.org_id {
                Some(org) => s.org_keys.get(org).ok_or(VaultError::Crypto {
                    message: "organization key unavailable".into(),
                })?,
                None => &s.user_keys,
            };
            let item_key = match &e.item_key {
                Some(k) => Some(crypto::decrypt_key(k, base).map_err(crypto_err)?),
                None => None,
            };
            let pw = crypto::decrypt_text(enc, base, item_key.as_ref()).map_err(crypto_err)?;
            Ok(Some(pw.to_string()))
        })
    }

    /// `POST <server>/api/ciphers`: a new login in the personal vault (no folder),
    /// name, username, password and URI encrypted with the user key. `url` must be
    /// `https://`. Empty `username`/`password` are sent as absent.
    pub fn add_login_request(
        &self,
        name: String,
        url: String,
        username: String,
        password: String,
    ) -> Result<HttpRequest> {
        let username = Zeroizing::new(username);
        let password = Zeroizing::new(password);
        let name = Zeroizing::new(name);
        if name.trim().is_empty() {
            return Err(invalid("name is empty"));
        }
        let uri = matching::new_entry_url(&url).ok_or_else(|| invalid("URL must be https://"))?;
        self.with_session(|s| {
            let enc = |t: &str| {
                crypto::encrypt_text(t, &s.user_keys).map_err(|f| VaultError::Crypto {
                    message: f.reason().to_string(),
                })
            };
            let opt = |t: &str| -> Result<Option<String>> {
                if t.is_empty() {
                    Ok(None)
                } else {
                    enc(t).map(Some)
                }
            };
            let body = serde_json::json!({
                "type": protocol::CIPHER_TYPE_LOGIN,
                "folderId": null,
                "organizationId": null,
                "name": enc(&name)?,
                "notes": null,
                "favorite": false,
                "reprompt": 0,
                "login": {
                    "username": opt(&username)?,
                    "password": opt(&password)?,
                    "totp": null,
                    "uris": [ { "uri": enc(&uri)?, "match": null } ],
                },
            });
            let mut headers = common_headers(Some("application/json"));
            headers.push(header(
                "Authorization",
                format!("Bearer {}", s.access_token.as_str()),
            ));
            Ok(HttpRequest {
                method: "POST".into(),
                url: format!("{}/ciphers", self.api_url),
                headers,
                body: Some(serde_json::to_vec(&body).unwrap_or_default()),
            })
        })
    }

    /// Reads the created item from the server's answer, verifies and decrypts it and
    /// adds it to the loaded entries.
    pub fn handle_add_login(&self, response: HttpResponse) -> Result<LoginSummary> {
        if response.status != 200 {
            return Err(status_error(&response));
        }
        let cipher: Cipher = serde_json::from_slice(&response.body)
            .map_err(|_| bad_response("created item could not be read"))?;
        if cipher.ty != protocol::CIPHER_TYPE_LOGIN {
            return Err(bad_response("created item is not a login"));
        }
        let mut st = self.state()?;
        let session = st.session.as_mut().ok_or(VaultError::Locked)?;
        let entry =
            decrypt_entry(&cipher, &session.user_keys, &session.org_keys).map_err(|reason| {
                VaultError::Crypto {
                    message: reason.to_string(),
                }
            })?;
        let s = summary(&entry, None);
        session.entries.insert(entry.id.clone(), entry);
        Ok(s)
    }

    /// Forgets the session: access token, all keys (locked memory is zeroized) and all
    /// decrypted data. The KDF settings stay; sign in again with `login_request`.
    pub fn lock(&self) {
        // Also after a panic elsewhere (poisoned mutex): secrets must go.
        let mut st = self.state.lock().unwrap_or_else(|e| e.into_inner());
        st.pending = None;
        st.session = None;
    }

    /// True between a successful `handle_login` and `lock`.
    pub fn is_unlocked(&self) -> bool {
        self.state().map(|s| s.session.is_some()).unwrap_or(false)
    }
}
