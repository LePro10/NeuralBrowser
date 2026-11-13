// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! Wire format of the Bitwarden/Vaultwarden API as far as the vault uses it.
//!
//! Field names follow rbw 1.15.0 `src/api.rs` (PascalCase with camelCase alias, since
//! Vaultwarden and the official server answer in different cases). Parsing is lenient
//! where real servers differ (numbers sent as strings, unknown two-factor providers),
//! strict where it matters (types of the fields that are used).

use serde::Deserialize;
use serde_json::Value;

/// Response of `POST /identity/accounts/prelogin`.
#[derive(Deserialize)]
pub(crate) struct PreloginRes {
    #[serde(rename = "Kdf", alias = "kdf")]
    pub kdf: Value,
    #[serde(rename = "KdfIterations", alias = "kdfIterations")]
    pub kdf_iterations: Value,
    #[serde(rename = "KdfMemory", alias = "kdfMemory", default)]
    pub kdf_memory: Value,
    #[serde(rename = "KdfParallelism", alias = "kdfParallelism", default)]
    pub kdf_parallelism: Value,
}

/// Successful response of `POST /identity/connect/token`.
#[derive(Deserialize)]
pub(crate) struct ConnectTokenRes {
    pub access_token: String,
    #[serde(rename = "Key", alias = "key", default)]
    pub key: Option<String>,
}

/// Error response of `POST /identity/connect/token`.
#[derive(Deserialize, Default)]
pub(crate) struct ConnectErrorRes {
    #[serde(default)]
    pub error: Option<String>,
    #[serde(default)]
    pub error_description: Option<String>,
    #[serde(rename = "ErrorModel", alias = "errorModel", default)]
    pub error_model: Option<ErrorModel>,
    #[serde(rename = "TwoFactorProviders", alias = "twoFactorProviders", default)]
    pub two_factor_providers: Option<Vec<Value>>,
    #[serde(
        rename = "SsoEmail2faSessionToken",
        alias = "ssoEmail2faSessionToken",
        default
    )]
    pub sso_email_2fa_session_token: Option<String>,
}

#[derive(Deserialize, Default)]
pub(crate) struct ErrorModel {
    #[serde(rename = "Message", alias = "message", default)]
    pub message: Option<String>,
}

/// Generic error body of the API (`{"message": ...}` or `{"ErrorModel": {...}}`).
#[derive(Deserialize, Default)]
pub(crate) struct ApiErrorRes {
    #[serde(rename = "Message", alias = "message", default)]
    pub message: Option<String>,
    #[serde(rename = "ErrorModel", alias = "errorModel", default)]
    pub error_model: Option<ErrorModel>,
}

/// Response of `GET /api/sync`. Ciphers stay raw so that one malformed entry does not
/// fail the whole sync.
#[derive(Deserialize)]
pub(crate) struct SyncRes {
    #[serde(rename = "Ciphers", alias = "ciphers", default)]
    pub ciphers: Vec<Value>,
    #[serde(rename = "Profile", alias = "profile")]
    pub profile: SyncProfile,
}

#[derive(Deserialize)]
pub(crate) struct SyncProfile {
    #[serde(rename = "PrivateKey", alias = "privateKey", default)]
    pub private_key: Option<String>,
    #[serde(rename = "Organizations", alias = "organizations", default)]
    pub organizations: Vec<SyncOrganization>,
}

#[derive(Deserialize)]
pub(crate) struct SyncOrganization {
    #[serde(rename = "Id", alias = "id")]
    pub id: String,
    #[serde(rename = "Key", alias = "key", default)]
    pub key: Option<String>,
}

/// One cipher (vault item) from sync or from the add-cipher response.
#[derive(Deserialize)]
pub(crate) struct Cipher {
    #[serde(rename = "Id", alias = "id")]
    pub id: String,
    #[serde(rename = "Type", alias = "type")]
    pub ty: u32,
    #[serde(rename = "OrganizationId", alias = "organizationId", default)]
    pub organization_id: Option<String>,
    #[serde(rename = "Name", alias = "name", default)]
    pub name: Option<String>,
    #[serde(rename = "Login", alias = "login", default)]
    pub login: Option<CipherLogin>,
    #[serde(rename = "Key", alias = "key", default)]
    pub key: Option<String>,
    #[serde(rename = "DeletedDate", alias = "deletedDate", default)]
    pub deleted_date: Option<String>,
}

#[derive(Deserialize)]
pub(crate) struct CipherLogin {
    #[serde(rename = "Username", alias = "username", default)]
    pub username: Option<String>,
    #[serde(rename = "Password", alias = "password", default)]
    pub password: Option<String>,
    #[serde(rename = "Uris", alias = "uris", default)]
    pub uris: Option<Vec<CipherLoginUri>>,
}

#[derive(Deserialize)]
pub(crate) struct CipherLoginUri {
    #[serde(rename = "Uri", alias = "uri", default)]
    pub uri: Option<String>,
    #[serde(rename = "Match", alias = "match", default)]
    pub match_type: Option<u8>,
}

/// Cipher type "login" (1 = login, 2 = secure note, 3 = card, 4 = identity, 5 = SSH key).
pub(crate) const CIPHER_TYPE_LOGIN: u32 = 1;

/// Reads a number that some servers send as a JSON string.
pub(crate) fn as_u32(v: &Value) -> Option<u32> {
    match v {
        Value::Number(n) => n.as_u64().and_then(|n| u32::try_from(n).ok()),
        Value::String(s) => s.trim().parse().ok(),
        _ => None,
    }
}

/// Two-factor provider ids of the Bitwarden server (`TwoFactorProviderType`).
pub(crate) fn provider_name(id: u32) -> String {
    match id {
        0 => "authenticator".into(),
        1 => "email".into(),
        2 => "duo".into(),
        3 => "yubikey".into(),
        4 => "u2f".into(),
        5 => "remember".into(),
        6 => "organization_duo".into(),
        7 => "webauthn".into(),
        n => format!("unknown({n})"),
    }
}
