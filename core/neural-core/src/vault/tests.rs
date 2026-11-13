// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! Vault tests without network: canned responses built with the same primitives,
//! key derivation checked against independently computed values.

use std::sync::OnceLock;

use serde_json::{json, Value};

use super::crypto::{self, Failure, Kdf};
use super::rbw::cipherstring::CipherString;
use super::rbw::{locked, KdfType};
use super::*;

const EMAIL: &str = "user@example.com";
const PASSWORD: &str = "correct horse battery staple";
const SERVER: &str = "https://vault.example.test/";

// Independent reference values, computed outside this code base:
//   Python 3 hashlib.pbkdf2_hmac (PBKDF2-SHA256), hmac (HKDF-Expand with one block:
//   HMAC(prk, info || 0x01)), OpenSSL 3.6 `openssl kdf ... ARGON2ID` (salt =
//   SHA-256(email), memcost 19456 KiB, iter 2, lanes 1), `openssl enc -aes-256-cbc`.
// Inputs: email "user@example.com", password "correct horse battery staple".
const PBKDF2_ENC: &str = "93ded3e35b9346cf64c4bdead65723856c45867ef3c3fb28696269fc2444394b";
const PBKDF2_MAC: &str = "29eaff41674c0bbb38f09f8fde3c77000e040ecc0e109479039c69b65acba1b7";
const PBKDF2_HASH: &str = "nfEypS52oCiXbQyehOT45BcIhAJYN/5ltdzSYVXHaWg=";
const ARGON2_ENC: &str = "e0c47cb712b02c4c00cf1722b89c34db3ac654f905962f56b30c97832c4ea38c";
const ARGON2_MAC: &str = "4e2eac968836c0efa19e085da9d966a4464c77857bd56fc321ebfe46b33a8e59";
const ARGON2_HASH: &str = "5zp6eaoTXbTOQzzXsw54VFXwnaQfzp1PWEp2KP96fxM=";
/// AES-256-CBC (openssl) + HMAC-SHA256 (Python) of "hunter2 secret" with the PBKDF2
/// enc/mac keys above, IV 00..0f.
const OPENSSL_CIPHERSTRING: &str =
    "2.AAECAwQFBgcICQoLDA0ODw==|jtOUlcIZ3Q2kN2/kNfU6bA==|7zDJsFxsuu2fJqlkjc0lGrJjSWK4+HQyy64+AJScHy0=";

fn hex(s: &str) -> Vec<u8> {
    (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap())
        .collect()
}

fn pbkdf2_kdf() -> Kdf {
    Kdf {
        kind: KdfType::Pbkdf2,
        iterations: 600_000,
        memory_mib: None,
        parallelism: None,
    }
}

fn argon2_kdf() -> Kdf {
    Kdf {
        kind: KdfType::Argon2id,
        iterations: 2,
        memory_mib: Some(19),
        parallelism: Some(1),
    }
}

fn resp(status: u16, body: Value) -> HttpResponse {
    HttpResponse {
        status,
        body: serde_json::to_vec(&body).unwrap(),
    }
}

fn form(req: &HttpRequest) -> Vec<(String, String)> {
    url::form_urlencoded::parse(req.body.as_ref().unwrap())
        .into_owned()
        .collect()
}

fn field(req: &HttpRequest, name: &str) -> Option<String> {
    form(req)
        .into_iter()
        .find(|(k, _)| k == name)
        .map(|(_, v)| v)
}

fn header_value(req: &HttpRequest, name: &str) -> Option<String> {
    req.headers
        .iter()
        .find(|h| h.name.eq_ignore_ascii_case(name))
        .map(|h| h.value.clone())
}

// ------------------------------------------------------------- key derivation

#[test]
fn pbkdf2_matches_independent_values() {
    let id = crypto::derive_identity(EMAIL, PASSWORD, &pbkdf2_kdf()).unwrap();
    assert_eq!(id.keys.enc_key(), hex(PBKDF2_ENC).as_slice());
    assert_eq!(id.keys.mac_key(), hex(PBKDF2_MAC).as_slice());
    assert_eq!(
        rbw::base64::encode(id.master_password_hash.hash()),
        PBKDF2_HASH
    );
    // E-mail is trimmed and lower-cased for the salt.
    let id2 = crypto::derive_identity(" User@Example.COM ", PASSWORD, &pbkdf2_kdf()).unwrap();
    assert_eq!(id2.keys.enc_key(), hex(PBKDF2_ENC).as_slice());
}

#[test]
fn argon2id_matches_independent_values() {
    let id = crypto::derive_identity(EMAIL, PASSWORD, &argon2_kdf()).unwrap();
    assert_eq!(id.keys.enc_key(), hex(ARGON2_ENC).as_slice());
    assert_eq!(id.keys.mac_key(), hex(ARGON2_MAC).as_slice());
    assert_eq!(
        rbw::base64::encode(id.master_password_hash.hash()),
        ARGON2_HASH
    );
    // Round trip: same input, same keys; other password, other keys.
    let again = crypto::derive_identity(EMAIL, PASSWORD, &argon2_kdf()).unwrap();
    assert_eq!(again.keys.enc_key(), id.keys.enc_key());
    let other = crypto::derive_identity(EMAIL, "other", &argon2_kdf()).unwrap();
    assert_ne!(other.keys.enc_key(), id.keys.enc_key());
}

#[test]
fn derive_rejects_empty_and_oversized_password() {
    assert_eq!(
        crypto::derive_identity(EMAIL, "", &argon2_kdf()).err(),
        Some(crypto::DeriveError::PasswordEmpty)
    );
    let long = "x".repeat(5000);
    assert_eq!(
        crypto::derive_identity(EMAIL, &long, &argon2_kdf()).err(),
        Some(crypto::DeriveError::PasswordTooLong)
    );
}

// ------------------------------------------------------------- cipher strings

fn test_keys() -> locked::Keys {
    let mut b = hex(PBKDF2_ENC);
    b.extend(hex(PBKDF2_MAC));
    crypto::keys_from_bytes(&b)
}

#[test]
fn cipherstring_decrypts_independent_vector() {
    let pt = crypto::decrypt_text(OPENSSL_CIPHERSTRING, &test_keys(), None).unwrap();
    assert_eq!(pt.as_str(), "hunter2 secret");
}

#[test]
fn cipherstring_round_trip() {
    let keys = test_keys();
    for text in ["", "a", "päßwörd 🔑", &"x".repeat(1000)] {
        let cs = crypto::encrypt_text(text, &keys).unwrap();
        assert!(cs.starts_with("2."));
        assert_eq!(cs.split('|').count(), 3, "type 2 with MAC");
        assert_eq!(
            crypto::decrypt_text(&cs, &keys, None).unwrap().as_str(),
            text
        );
    }
    // Fresh IV every time.
    assert_ne!(
        crypto::encrypt_text("same", &keys).unwrap(),
        crypto::encrypt_text("same", &keys).unwrap()
    );
}

fn flip_base64_char(part: &str) -> String {
    let mut c: Vec<char> = part.chars().collect();
    c[2] = if c[2] == 'A' { 'B' } else { 'A' };
    c.into_iter().collect()
}

#[test]
fn tampered_cipherstring_is_rejected() {
    let keys = test_keys();
    let cs = crypto::encrypt_text("secret", &keys).unwrap();
    let parts: Vec<&str> = cs.trim_start_matches("2.").split('|').collect();
    let bad_mac = format!("2.{}|{}|{}", parts[0], parts[1], flip_base64_char(parts[2]));
    let bad_ct = format!("2.{}|{}|{}", parts[0], flip_base64_char(parts[1]), parts[2]);
    let bad_iv = format!("2.{}|{}|{}", flip_base64_char(parts[0]), parts[1], parts[2]);
    for s in [bad_mac, bad_ct, bad_iv] {
        assert_eq!(
            crypto::decrypt_text(&s, &keys, None).err(),
            Some(Failure::InvalidMac)
        );
    }
    // Wrong key.
    let mut other = hex(ARGON2_ENC);
    other.extend(hex(ARGON2_MAC));
    let other = crypto::keys_from_bytes(&other);
    assert_eq!(
        crypto::decrypt_text(&cs, &other, None).err(),
        Some(Failure::InvalidMac)
    );
}

#[test]
fn cipherstring_without_mac_is_rejected() {
    let keys = test_keys();
    let cs = crypto::encrypt_text("secret", &keys).unwrap();
    let no_mac = cs.rsplit_once('|').unwrap().0.to_string();
    assert_eq!(
        crypto::decrypt_text(&no_mac, &keys, None).err(),
        Some(Failure::MissingMac)
    );
    // Types 0 and 1 (AES-CBC without MAC / AES-128) are refused.
    let body = no_mac.trim_start_matches("2.");
    for ty in ["0", "1"] {
        let s = format!("{ty}.{body}");
        assert_eq!(
            crypto::decrypt_text(&s, &keys, None).err(),
            Some(Failure::MissingMac)
        );
    }
    // A symmetric key wrapped without MAC is refused too.
    assert_eq!(
        crypto::decrypt_key(&no_mac, &keys).err(),
        Some(Failure::MissingMac)
    );
}

#[test]
fn malformed_cipherstrings_do_not_panic() {
    let keys = test_keys();
    let short_mac = "2.AAECAwQFBgcICQoLDA0ODw==|jtOUlcIZ3Q2kN2/kNfU6bA==|AAAA";
    let short_iv = "2.AAEC|jtOUlcIZ3Q2kN2/kNfU6bA==|7zDJsFxsuu2fJqlkjc0lGrJjSWK4+HQyy64+AJScHy0=";
    let cases = [
        "",
        ".",
        "2",
        "2.",
        "!.abc",
        "x.abc",
        "22.abc",
        "9.abc",
        "2.a|b",
        "2.@@|@@|@@",
        "4.",
        "6.",
        short_mac,
        short_iv,
    ];
    for s in cases {
        assert!(crypto::decrypt_text(s, &keys, None).is_err(), "{s:?}");
        assert!(crypto::decrypt_key(s, &keys).is_err(), "{s:?}");
    }
    // A wrapped "key" that is too short must not reach rbw's fixed slicing.
    let short = crypto::encrypt_text("0123456789", &keys).unwrap();
    assert_eq!(
        crypto::decrypt_key(&short, &keys).err(),
        Some(Failure::WrongKeyLength)
    );
}

// ------------------------------------------------------------- canned account

struct Account {
    user_key: Vec<u8>,
    org_key: Vec<u8>,
    item_key: Vec<u8>,
    private_key_cs: String,
    org_key_cs: String,
}

fn user_keys(a: &Account) -> locked::Keys {
    crypto::keys_from_bytes(&a.user_key)
}

/// One RSA key pair and fixed symmetric keys, shared by all tests.
fn account() -> &'static Account {
    static ACCOUNT: OnceLock<Account> = OnceLock::new();
    ACCOUNT.get_or_init(|| {
        use rsa::pkcs8::EncodePrivateKey;
        let mut rng = rand_08::thread_rng();
        let user_key: Vec<u8> = (0..64u8)
            .map(|i| i.wrapping_mul(7).wrapping_add(1))
            .collect();
        let org_key: Vec<u8> = (0..64u8)
            .map(|i| i.wrapping_mul(13).wrapping_add(5))
            .collect();
        let item_key: Vec<u8> = (0..64u8)
            .map(|i| i.wrapping_mul(29).wrapping_add(9))
            .collect();
        let private = rsa::RsaPrivateKey::new(&mut rng, 2048).unwrap();
        let der = private.to_pkcs8_der().unwrap();
        let uk = crypto::keys_from_bytes(&user_key);
        let private_key_cs = CipherString::encrypt_symmetric(&uk, der.as_bytes())
            .unwrap()
            .to_string();
        let ct = rsa::RsaPublicKey::from(&private)
            .encrypt(&mut rng, rsa::Oaep::new::<sha1::Sha1>(), &org_key)
            .unwrap();
        let org_key_cs = format!("4.{}", rbw::base64::encode(ct));
        Account {
            user_key,
            org_key,
            item_key,
            private_key_cs,
            org_key_cs,
        }
    })
}

fn enc(keys: &locked::Keys, text: &str) -> String {
    crypto::encrypt_text(text, keys).unwrap()
}

fn wrap(keys: &locked::Keys, raw: &[u8]) -> String {
    CipherString::encrypt_symmetric(keys, raw)
        .unwrap()
        .to_string()
}

fn login(
    id: &str,
    keys: &locked::Keys,
    name: &str,
    user: &str,
    pw: &str,
    uris: &[(&str, Value)],
) -> Value {
    json!({
        "id": id,
        "type": 1,
        "organizationId": null,
        "name": enc(keys, name),
        "login": {
            "username": enc(keys, user),
            "password": enc(keys, pw),
            "uris": uris.iter().map(|(u, m)| json!({"uri": enc(keys, u), "match": m})).collect::<Vec<_>>(),
        },
        "key": null,
        "deletedDate": null,
    })
}

fn sync_body(a: &Account) -> Value {
    let uk = user_keys(a);
    let ok = crypto::keys_from_bytes(&a.org_key);
    let ik = crypto::keys_from_bytes(&a.item_key);
    let wrong = crypto::keys_from_bytes(&[0x55; 64]);

    // Organisation item with its own item key (encrypted with the org key).
    let mut team = login(
        "o1",
        &ik,
        "Team",
        "team",
        "pw-o1",
        &[("https://example.com:8443/", Value::Null)],
    );
    team["organizationId"] = json!("org-1");
    team["key"] = json!(wrap(&ok, &a.item_key));

    let mut unknown_org = login(
        "o2",
        &ok,
        "Other org",
        "x",
        "y",
        &[("https://example.com", Value::Null)],
    );
    unknown_org["organizationId"] = json!("org-unknown");

    let mut no_mac = login(
        "bad2",
        &uk,
        "No MAC",
        "u",
        "p",
        &[("https://example.com", Value::Null)],
    );
    let name = no_mac["name"]
        .as_str()
        .unwrap()
        .rsplit_once('|')
        .unwrap()
        .0
        .to_string();
    no_mac["name"] = json!(name);

    let mut deleted = login(
        "del1",
        &uk,
        "Deleted",
        "u",
        "p",
        &[("https://example.com", Value::Null)],
    );
    deleted["deletedDate"] = json!("2026-01-01T00:00:00Z");

    json!({
        "profile": {
            "privateKey": a.private_key_cs,
            "organizations": [ { "id": "org-1", "key": a.org_key_cs } ],
        },
        "folders": [],
        "ciphers": [
            login("a1", &uk, "Example", "alice", "pw-a1", &[("https://example.com/login", Value::Null)]),
            login("a2", &uk, "Example 2", "bob", "pw-a2", &[("example.com", json!(1))]),
            team,
            login("n1", &uk, "Never", "n", "p", &[("https://example.com", json!(5))]),
            login("h1", &uk, "Plain http", "h", "p", &[("http://example.com", Value::Null)]),
            login("and1", &uk, "App", "a", "p", &[("androidapp://com.example", Value::Null)]),
            login("l1", &uk, "Lookalike suffix", "l", "p", &[("https://example.com.evil.test", Value::Null)]),
            login("l2", &uk, "Lookalike prefix", "l", "p", &[("https://evilexample.com", Value::Null)]),
            login("l3", &uk, "Subdomain", "l", "p", &[("https://sub.example.com", Value::Null)]),
            login("e1", &uk, "Exact", "e", "p", &[("https://exact.test/login", json!(3))]),
            login("bad1", &wrong, "Wrong key", "u", "p", &[("https://example.com", Value::Null)]),
            no_mac,
            unknown_org,
            deleted,
            { "id": "note1", "type": 2, "name": enc(&uk, "A note"), "secureNote": {"type": 0} },
            { "id": 5 },
        ],
    })
}

fn login_ok_body(a: &Account, identity: &super::rbw::identity::Identity) -> Value {
    // PascalCase "Key" as the official server sends it (alias check).
    json!({
        "access_token": "tok-123",
        "refresh_token": "refresh-456",
        "token_type": "Bearer",
        "expires_in": 3600,
        "Key": wrap(&identity.keys, &a.user_key),
    })
}

fn argon2_prelogin() -> HttpResponse {
    resp(
        200,
        json!({"kdf": 1, "kdfIterations": 2, "kdfMemory": 19, "kdfParallelism": 1}),
    )
}

/// Prelogin + login (no 2FA) + sync; returns the unlocked vault.
fn unlocked_vault() -> Vault {
    let a = account();
    let v = Vault::new(SERVER.into(), EMAIL.into(), "dev-1".into()).unwrap();
    v.handle_prelogin(argon2_prelogin(), false).unwrap();
    v.login_request(PASSWORD.into(), None).unwrap();
    let id = crypto::derive_identity(EMAIL, PASSWORD, &argon2_kdf()).unwrap();
    assert_eq!(
        v.handle_login(resp(200, login_ok_body(a, &id))).unwrap(),
        LoginOutcome::Success
    );
    v.handle_sync(resp(200, sync_body(a))).unwrap();
    v
}

fn ids(v: &[LoginSummary]) -> Vec<&str> {
    v.iter().map(|s| s.id.as_str()).collect()
}

// ------------------------------------------------------------- full flow

#[test]
fn full_flow_with_two_factor() {
    let a = account();
    let v = Vault::new(SERVER.into(), " User@Example.com ".into(), "dev-1".into()).unwrap();
    assert_eq!(v.server_url(), "https://vault.example.test");
    assert_eq!(v.email(), EMAIL);
    assert!(!v.is_unlocked());

    // Prelogin.
    let req = v.prelogin_request();
    assert_eq!(req.method, "POST");
    assert_eq!(
        req.url,
        "https://vault.example.test/identity/accounts/prelogin"
    );
    assert_eq!(
        header_value(&req, "Content-Type").unwrap(),
        "application/json"
    );
    let body: Value = serde_json::from_slice(req.body.as_ref().unwrap()).unwrap();
    assert_eq!(body, json!({"email": EMAIL}));
    let kdf = v.handle_prelogin(argon2_prelogin(), false).unwrap();
    assert_eq!(kdf.algorithm, KdfAlgorithm::Argon2id);
    assert!(!kdf.weak);

    // Login, first without code.
    let req = v.login_request(PASSWORD.into(), None).unwrap();
    assert_eq!(req.url, "https://vault.example.test/identity/connect/token");
    assert!(header_value(&req, "Content-Type")
        .unwrap()
        .starts_with("application/x-www-form-urlencoded"));
    assert_eq!(
        header_value(&req, "Auth-Email").unwrap(),
        "dXNlckBleGFtcGxlLmNvbQ"
    );
    assert_eq!(header_value(&req, "Bitwarden-Client-Name").unwrap(), "cli");
    assert_eq!(header_value(&req, "Device-Type").unwrap(), "7");
    assert_eq!(field(&req, "grant_type").unwrap(), "password");
    assert_eq!(field(&req, "scope").unwrap(), "api offline_access");
    assert_eq!(field(&req, "client_id").unwrap(), "cli");
    assert_eq!(field(&req, "deviceType").unwrap(), "7");
    assert_eq!(field(&req, "deviceIdentifier").unwrap(), "dev-1");
    assert_eq!(field(&req, "username").unwrap(), EMAIL);
    // Independently computed Argon2id master password hash.
    assert_eq!(field(&req, "password").unwrap(), ARGON2_HASH);
    assert_eq!(field(&req, "twoFactorToken"), None);

    let two_factor = json!({
        "error": "invalid_grant",
        "error_description": "Two factor required.",
        "TwoFactorProviders": ["7", "1", "0", 5],
        "TwoFactorProviders2": {"0": null, "1": {"Email": "u***@example.com"}, "7": {}},
    });
    assert_eq!(
        v.handle_login(resp(400, two_factor)).unwrap(),
        LoginOutcome::TwoFactorRequired {
            providers: vec![TwoFactorProvider::Authenticator, TwoFactorProvider::Email],
            unsupported_providers: vec!["webauthn".into()],
        }
    );
    assert!(!v.is_unlocked());

    // Ask for the e-mail code.
    let req = v.send_email_code_request().unwrap();
    assert_eq!(
        req.url,
        "https://vault.example.test/api/two-factor/send-email-login"
    );
    let body: Value = serde_json::from_slice(req.body.as_ref().unwrap()).unwrap();
    assert_eq!(body["email"], EMAIL);
    assert_eq!(body["masterPasswordHash"], ARGON2_HASH);
    assert_eq!(body["deviceIdentifier"], "dev-1");
    v.handle_send_email_code(resp(200, json!({}))).unwrap();

    // Wrong code.
    let code = TwoFactorCode {
        provider: TwoFactorProvider::Email,
        code: " 123456 ".into(),
    };
    let req = v.login_request(PASSWORD.into(), Some(code)).unwrap();
    assert_eq!(field(&req, "twoFactorToken").unwrap(), "123456");
    assert_eq!(field(&req, "twoFactorProvider").unwrap(), "1");
    assert_eq!(field(&req, "twoFactorRemember").unwrap(), "0");
    let wrong = json!({
        "error": "invalid_grant",
        "error_description": "invalid_username_or_password",
        "ErrorModel": {"Message": "Two-step token is invalid. Try again."},
    });
    assert_eq!(
        v.handle_login(resp(400, wrong)).unwrap(),
        LoginOutcome::InvalidTwoFactorCode
    );

    // Right code.
    let code = TwoFactorCode {
        provider: TwoFactorProvider::Authenticator,
        code: "654321".into(),
    };
    let req = v.login_request(PASSWORD.into(), Some(code)).unwrap();
    assert_eq!(field(&req, "twoFactorProvider").unwrap(), "0");
    let id = crypto::derive_identity(EMAIL, PASSWORD, &argon2_kdf()).unwrap();
    assert_eq!(
        v.handle_login(resp(200, login_ok_body(a, &id))).unwrap(),
        LoginOutcome::Success
    );
    assert!(v.is_unlocked());

    // Sync.
    let req = v.sync_request().unwrap();
    assert_eq!(req.method, "GET");
    assert_eq!(
        req.url,
        "https://vault.example.test/api/sync?excludeDomains=true"
    );
    assert_eq!(
        header_value(&req, "Authorization").unwrap(),
        "Bearer tok-123"
    );
    let s = v.handle_sync(resp(200, sync_body(a))).unwrap();
    assert_eq!(s.logins, 10, "{s:?}");
    assert_eq!(s.undecryptable, 4, "{s:?}");
    assert_eq!(s.skipped_other_types, 1);
    assert_eq!(s.skipped_deleted, 1);
    let reasons: Vec<(String, u32)> = s
        .undecryptable_reasons
        .iter()
        .map(|r| (r.reason.clone(), r.count))
        .collect();
    assert_eq!(
        reasons,
        vec![
            ("MAC check failed".to_string(), 1),
            ("cipher string without MAC".to_string(), 1),
            ("malformed item".to_string(), 1),
            ("organization key unavailable".to_string(), 1),
        ]
    );

    // Lookups.
    let found = v
        .logins_for_url("https://example.com/login?next=/".into())
        .unwrap();
    assert_eq!(ids(&found), ["a1", "a2"]);
    assert_eq!(found[0].name, "Example");
    assert_eq!(found[0].username.as_deref(), Some("alice"));
    assert_eq!(
        found[0].matched_uri.as_deref(),
        Some("https://example.com/login")
    );
    assert_eq!(found[1].matched_uri.as_deref(), Some("example.com"));
    let found = v
        .logins_for_url("https://EXAMPLE.com:8443/x".into())
        .unwrap();
    assert_eq!(ids(&found), ["a1", "a2", "o1"]);
    assert!(found[2].is_organization);
    assert_eq!(v.password("a1".into()).unwrap().as_deref(), Some("pw-a1"));
    assert_eq!(v.password("o1".into()).unwrap().as_deref(), Some("pw-o1"));
    assert_eq!(v.username("o1".into()).unwrap().as_deref(), Some("team"));
    assert!(matches!(
        v.password("bad1".into()),
        Err(VaultError::NotFound)
    ));
    let all = v.all_logins().unwrap();
    assert_eq!(all.len(), 10);
    assert_eq!(all[0].name, "App");
    assert!(all.iter().all(|s| s.matched_uri.is_none()));

    // Add a login.
    let req = v
        .add_login_request(
            "New".into(),
            "https://new.example.test/login".into(),
            "carol".into(),
            "pw-new".into(),
        )
        .unwrap();
    assert_eq!(req.url, "https://vault.example.test/api/ciphers");
    assert_eq!(
        header_value(&req, "Authorization").unwrap(),
        "Bearer tok-123"
    );
    let mut body: Value = serde_json::from_slice(req.body.as_ref().unwrap()).unwrap();
    assert_eq!(body["type"], 1);
    assert_eq!(body["folderId"], Value::Null);
    let uk = user_keys(a);
    let name_cs = body["name"].as_str().unwrap();
    assert_eq!(
        crypto::decrypt_text(name_cs, &uk, None).unwrap().as_str(),
        "New"
    );
    let pw_cs = body["login"]["password"].as_str().unwrap();
    assert_eq!(
        crypto::decrypt_text(pw_cs, &uk, None).unwrap().as_str(),
        "pw-new"
    );
    assert!(!String::from_utf8_lossy(req.body.as_ref().unwrap()).contains("pw-new"));
    // The server echoes the item with an id.
    body["id"] = json!("new1");
    let added = v.handle_add_login(resp(200, body)).unwrap();
    assert_eq!(added.id, "new1");
    assert_eq!(
        ids(&v
            .logins_for_url("https://new.example.test/".into())
            .unwrap()),
        ["new1"]
    );
    assert_eq!(
        v.password("new1".into()).unwrap().as_deref(),
        Some("pw-new")
    );

    // Lock.
    v.lock();
    assert!(!v.is_unlocked());
    assert!(matches!(v.all_logins(), Err(VaultError::Locked)));
    assert!(matches!(
        v.logins_for_url("https://example.com".into()),
        Err(VaultError::Locked)
    ));
    assert!(matches!(v.password("a1".into()), Err(VaultError::Locked)));
    assert!(matches!(v.username("a1".into()), Err(VaultError::Locked)));
    assert!(matches!(v.sync_request(), Err(VaultError::Locked)));
    assert!(matches!(
        v.add_login_request("n".into(), "https://x.test".into(), "".into(), "".into()),
        Err(VaultError::Locked)
    ));
    assert!(matches!(
        v.send_email_code_request(),
        Err(VaultError::WrongState { .. })
    ));
}

#[test]
fn pbkdf2_login_sends_independent_hash() {
    let v = Vault::new(SERVER.into(), EMAIL.into(), "dev-1".into()).unwrap();
    // Numbers as strings and PascalCase, as some servers send them.
    v.handle_prelogin(
        resp(200, json!({"Kdf": "0", "KdfIterations": "600000"})),
        false,
    )
    .unwrap();
    let req = v.login_request(PASSWORD.into(), None).unwrap();
    assert_eq!(field(&req, "password").unwrap(), PBKDF2_HASH);
}

#[test]
fn wrong_credentials_and_server_errors() {
    let v = Vault::new(SERVER.into(), EMAIL.into(), "dev-1".into()).unwrap();
    assert!(matches!(
        v.login_request(PASSWORD.into(), None),
        Err(VaultError::WrongState { .. })
    ));
    assert!(matches!(
        v.handle_login(resp(400, json!({}))),
        Err(VaultError::WrongState { .. })
    ));
    v.handle_prelogin(argon2_prelogin(), false).unwrap();
    v.login_request("wrong".into(), None).unwrap();
    let official = json!({
        "error": "invalid_grant",
        "error_description": "invalid_username_or_password",
        "ErrorModel": {"Message": "Username or password is incorrect. Try again"},
    });
    assert_eq!(
        v.handle_login(resp(400, official)).unwrap(),
        LoginOutcome::InvalidCredentials
    );
    let vaultwarden = json!({
        "error": "", "error_description": "",
        "ErrorModel": {"Message": "Username or password is incorrect. Try again", "Object": "error"},
    });
    assert_eq!(
        v.handle_login(resp(400, vaultwarden)).unwrap(),
        LoginOutcome::InvalidCredentials
    );

    let busy = json!({"ErrorModel": {"Message": "Too many requests.\nTry later"}});
    assert_eq!(
        v.handle_login(resp(429, busy)).unwrap(),
        LoginOutcome::ServerError {
            status: 429,
            message: "Too many requests.Try later".into()
        }
    );
    // A message echoing the password hash is withheld.
    let hash = crypto::derive_identity(EMAIL, "wrong", &argon2_kdf()).unwrap();
    let hash = rbw::base64::encode(hash.master_password_hash.hash());
    let echo = json!({"ErrorModel": {"Message": format!("bad hash {hash}")}});
    match v.handle_login(resp(500, echo)).unwrap() {
        LoginOutcome::ServerError { message, .. } => assert!(!message.contains(&hash)),
        other => panic!("{other:?}"),
    }
    // Not JSON at all.
    let html = HttpResponse {
        status: 502,
        body: b"<html>Bad Gateway</html>".to_vec(),
    };
    assert_eq!(
        v.handle_login(html).unwrap(),
        LoginOutcome::ServerError {
            status: 502,
            message: "request failed".into()
        }
    );
    // 200 but garbage / missing key: error, no secret in the message.
    let err = v
        .handle_login(resp(200, json!({"access_token": "tok-secret"})))
        .unwrap_err();
    assert!(!err.to_string().contains("tok-secret"));
    assert!(!v.is_unlocked());
}

#[test]
fn login_with_tampered_user_key_fails() {
    let a = account();
    let v = Vault::new(SERVER.into(), EMAIL.into(), "dev-1".into()).unwrap();
    v.handle_prelogin(argon2_prelogin(), false).unwrap();
    v.login_request(PASSWORD.into(), None).unwrap();
    let id = crypto::derive_identity(EMAIL, PASSWORD, &argon2_kdf()).unwrap();
    let mut body = login_ok_body(a, &id);
    let key = body["Key"].as_str().unwrap().to_string();
    let (rest, mac) = key.rsplit_once('|').unwrap();
    body["Key"] = json!(format!("{rest}|{}", flip_base64_char(mac)));
    assert!(matches!(
        v.handle_login(resp(200, body.clone())),
        Err(VaultError::Crypto { .. })
    ));
    // Key without MAC.
    body["Key"] = json!(rest);
    assert!(matches!(
        v.handle_login(resp(200, body)),
        Err(VaultError::Crypto { .. })
    ));
    assert!(!v.is_unlocked());
}

#[test]
fn sync_and_add_error_statuses() {
    let v = unlocked_vault();
    assert!(matches!(
        v.handle_sync(resp(401, json!({}))),
        Err(VaultError::Unauthorized)
    ));
    assert!(matches!(
        v.handle_sync(resp(500, json!({"message": "boom"}))),
        Err(VaultError::Server { status: 500, .. })
    ));
    assert!(matches!(
        v.handle_sync(resp(200, json!({"nope": 1}))),
        Err(VaultError::InvalidResponse { .. })
    ));
    // Entries from the earlier sync are still there.
    assert_eq!(v.all_logins().unwrap().len(), 10);
    assert!(matches!(
        v.add_login_request("x".into(), "http://x.test".into(), "".into(), "".into()),
        Err(VaultError::InvalidArgument { .. })
    ));
    assert!(matches!(
        v.add_login_request(" ".into(), "https://x.test".into(), "".into(), "".into()),
        Err(VaultError::InvalidArgument { .. })
    ));
    assert!(matches!(
        v.handle_add_login(resp(401, json!({}))),
        Err(VaultError::Unauthorized)
    ));
    // Empty username/password are sent as null.
    let req = v
        .add_login_request("n".into(), "https://x.test".into(), "".into(), "".into())
        .unwrap();
    let body: Value = serde_json::from_slice(req.body.as_ref().unwrap()).unwrap();
    assert_eq!(body["login"]["username"], Value::Null);
    assert_eq!(body["login"]["password"], Value::Null);
}

// ------------------------------------------------------------- abuse cases

#[test]
fn server_url_must_be_https() {
    for bad in [
        "http://vault.example.test",
        "http://localhost:8000",
        "http://127.0.0.1",
        "ftp://vault.example.test",
        "vault.example.test",
        "https://",
        "https://user:pw@vault.example.test",
        "https://vault.example.test/?x=1",
        "https://vault.example.test/#a",
        "",
    ] {
        assert!(
            matches!(
                Vault::new(bad.into(), EMAIL.into(), "dev-1".into()),
                Err(VaultError::InvalidServerUrl { .. })
            ),
            "{bad}"
        );
    }
    let v = Vault::new(
        "https://Example.test/vw///".into(),
        EMAIL.into(),
        "d".into(),
    )
    .unwrap();
    assert_eq!(v.server_url(), "https://example.test/vw");
    assert_eq!(
        v.prelogin_request().url,
        "https://example.test/vw/identity/accounts/prelogin"
    );
    let v = Vault::new("https://localhost:8443".into(), EMAIL.into(), "d".into()).unwrap();
    assert_eq!(v.server_url(), "https://localhost:8443");
    // Bad e-mail / device ids.
    assert!(Vault::new(SERVER.into(), "nobody".into(), "d".into()).is_err());
    assert!(Vault::new(SERVER.into(), EMAIL.into(), "".into()).is_err());
    assert!(Vault::new(SERVER.into(), EMAIL.into(), "a b".into()).is_err());
}

#[test]
fn weak_kdf_is_rejected_unless_allowed() {
    let v = Vault::new(SERVER.into(), EMAIL.into(), "dev-1".into()).unwrap();
    let weak = [
        json!({"kdf": 0, "kdfIterations": 100_000}),
        json!({"kdf": 0, "kdfIterations": 599_999}),
        json!({"kdf": 1, "kdfIterations": 2, "kdfMemory": 16, "kdfParallelism": 1}),
        json!({"kdf": 1, "kdfIterations": 1, "kdfMemory": 64, "kdfParallelism": 4}),
    ];
    for body in weak {
        match v.handle_prelogin(resp(200, body.clone()), false) {
            Err(VaultError::WeakKdf { settings }) => assert!(settings.weak),
            other => panic!("{body}: {other:?}"),
        }
        // Not stored: login is still impossible.
        assert!(matches!(
            v.login_request(PASSWORD.into(), None),
            Err(VaultError::WrongState { .. })
        ));
        let s = v.handle_prelogin(resp(200, body), true).unwrap();
        assert!(s.weak);
    }
    let ok = v
        .handle_prelogin(
            resp(200, json!({"kdf": 0, "kdfIterations": 600_000})),
            false,
        )
        .unwrap();
    assert!(!ok.weak);
    // Out of any valid range, even with the override.
    for body in [
        json!({"kdf": 0, "kdfIterations": 0}),
        json!({"kdf": 0, "kdfIterations": 4_000_000_000u32}),
        json!({"kdf": 1, "kdfIterations": 3, "kdfMemory": 4096, "kdfParallelism": 1}),
        json!({"kdf": 1, "kdfIterations": 3, "kdfMemory": 64, "kdfParallelism": 0}),
        json!({"kdf": 1, "kdfIterations": 3, "kdfMemory": 64}),
        json!({"kdf": 1, "kdfIterations": 100, "kdfMemory": 64, "kdfParallelism": 1}),
        json!({"kdf": 2, "kdfIterations": 600_000}),
        json!({"kdf": "x", "kdfIterations": 600_000}),
    ] {
        assert!(
            matches!(
                v.handle_prelogin(resp(200, body.clone()), true),
                Err(VaultError::UnsupportedKdf { .. })
            ),
            "{body}"
        );
    }
}

#[test]
fn lookalike_hosts_do_not_match() {
    let v = unlocked_vault();
    // Entries for example.com never show on lookalike pages ...
    assert_eq!(
        ids(&v
            .logins_for_url("https://example.com.evil.test/".into())
            .unwrap()),
        ["l1"]
    );
    assert_eq!(
        ids(&v.logins_for_url("https://evilexample.com/".into()).unwrap()),
        ["l2"]
    );
    assert_eq!(
        ids(&v.logins_for_url("https://sub.example.com/".into()).unwrap()),
        ["l3"]
    );
    assert!(v
        .logins_for_url("https://www.example.com/".into())
        .unwrap()
        .is_empty());
    assert!(v
        .logins_for_url("https://example.co/".into())
        .unwrap()
        .is_empty());
    assert!(v
        .logins_for_url("https://example.com@evil.test/".into())
        .unwrap()
        .is_empty());
    // ... and lookalike entries never show on example.com.
    let found = v.logins_for_url("https://example.com/".into()).unwrap();
    assert_eq!(ids(&found), ["a1", "a2"]);
}

#[test]
fn only_https_pages_get_logins() {
    let v = unlocked_vault();
    for page in [
        "http://example.com/login",
        "ftp://example.com",
        "file:///etc/passwd",
        "javascript:alert(1)",
        "data:text/html,example.com",
        "about:blank",
        "example.com",
        "",
    ] {
        assert!(v.logins_for_url(page.into()).unwrap().is_empty(), "{page}");
    }
    // The http:// and androidapp:// entries never match, "never" never matches.
    let found = v.logins_for_url("https://example.com/".into()).unwrap();
    assert!(!ids(&found)
        .iter()
        .any(|id| ["h1", "and1", "n1"].contains(id)));
}

#[test]
fn exact_match_type() {
    let v = unlocked_vault();
    assert_eq!(
        ids(&v.logins_for_url("https://exact.test/login".into()).unwrap()),
        ["e1"]
    );
    assert!(v
        .logins_for_url("https://exact.test/other".into())
        .unwrap()
        .is_empty());
}

#[test]
fn debug_output_shows_no_secrets() {
    let v = unlocked_vault();
    let dbg = format!("{v:?}");
    assert!(!dbg.contains("tok-123") && !dbg.contains(EMAIL), "{dbg}");

    let fresh = Vault::new(SERVER.into(), EMAIL.into(), "dev-1".into()).unwrap();
    fresh.handle_prelogin(argon2_prelogin(), false).unwrap();
    let req = fresh.login_request(PASSWORD.into(), None).unwrap();
    let dbg = format!("{req:?}");
    let hash_urlenc = ARGON2_HASH
        .replace('/', "%2F")
        .replace('+', "%2B")
        .replace('=', "%3D");
    for secret in [
        ARGON2_HASH,
        hash_urlenc.as_str(),
        "dXNlckBleGFtcGxlLmNvbQ",
        PASSWORD,
    ] {
        assert!(!dbg.contains(secret), "{dbg}");
    }
    let dbg = format!("{:?}", v.sync_request().unwrap());
    assert!(!dbg.contains("tok-123"), "{dbg}");

    let code = TwoFactorCode {
        provider: TwoFactorProvider::Authenticator,
        code: "987654".into(),
    };
    assert!(!format!("{code:?}").contains("987654"));
    let summary = &v.logins_for_url("https://example.com/".into()).unwrap()[0];
    let dbg = format!("{summary:?}");
    assert!(!dbg.contains("alice") && !dbg.contains("Example"), "{dbg}");
    let r = resp(200, json!({"access_token": "tok-999"}));
    assert!(!format!("{r:?}").contains("tok-999"));
}

#[test]
fn lock_forgets_everything() {
    let v = unlocked_vault();
    assert!(v.is_unlocked());
    v.lock();
    v.lock(); // idempotent
    assert!(!v.is_unlocked());
    assert!(matches!(v.password("a1".into()), Err(VaultError::Locked)));
    assert!(matches!(
        v.handle_sync(resp(200, sync_body(account()))),
        Err(VaultError::Locked)
    ));
    // Signing in again works (KDF settings are kept).
    v.login_request(PASSWORD.into(), None).unwrap();
}

#[test]
fn two_factor_code_is_validated() {
    let v = Vault::new(SERVER.into(), EMAIL.into(), "dev-1".into()).unwrap();
    v.handle_prelogin(argon2_prelogin(), false).unwrap();
    for bad in ["", "   ", "12\n34", &"1".repeat(65)] {
        let code = TwoFactorCode {
            provider: TwoFactorProvider::Authenticator,
            code: bad.into(),
        };
        assert!(matches!(
            v.login_request(PASSWORD.into(), Some(code)),
            Err(VaultError::InvalidArgument { .. })
        ));
    }
    assert!(matches!(
        v.login_request(String::new(), None),
        Err(VaultError::InvalidArgument { .. })
    ));
}
