// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! Which vault entries belong to a page (docs/SECURITY.md 4.3/4.7).
//!
//! Rules (deliberately stricter than Bitwarden's defaults):
//!
//! * The page must be `https://` with a host; otherwise nothing matches.
//! * Entry URIs must be `https://` too. A URI without scheme (`example.com/login`,
//!   common in hand-made entries) is read as `https://`. `http://`, `androidapp://`,
//!   `iosapp://` and everything else never match.
//! * Hosts must be equal after URL parsing (lower case, IDNA/punycode). No base-domain,
//!   no subdomain, no suffix logic: `example.com` matches neither `www.example.com`
//!   nor `example.com.evil.test`.
//! * Port: if the entry URI names a non-default port, the page must use that port;
//!   an entry without port (or with `:443`) matches any port of the host.
//! * Match type per URI (Bitwarden `UriMatchType`): 5 "never" never matches, 3 "exact"
//!   requires the whole normalised URL to be equal. 0 "base domain" (also the default
//!   when the field is null), 1 "host", 2 "starts with" and 4 "regex" are treated as
//!   host-exact for now (documented limitation).

use url::Url;

const MATCH_EXACT: u8 = 3;
const MATCH_NEVER: u8 = 5;

/// Parses a page URL; `None` unless it is `https://` with a host.
pub(crate) fn page_url(url: &str) -> Option<Url> {
    let u = Url::parse(url.trim()).ok()?;
    (u.scheme() == "https" && u.host().is_some()).then_some(u)
}

/// Parses an entry URI as stored in the vault; `None` if it can never match.
fn entry_url(uri: &str) -> Option<Url> {
    let uri = uri.trim();
    if uri.is_empty() {
        return None;
    }
    let u = if uri.contains("://") {
        Url::parse(uri).ok()?
    } else {
        Url::parse(&format!("https://{uri}")).ok()?
    };
    (u.scheme() == "https" && u.host().is_some()).then_some(u)
}

/// Whether one stored URI (with its match type) matches the page.
pub(crate) fn uri_matches(page: &Url, uri: &str, match_type: Option<u8>) -> bool {
    if match_type == Some(MATCH_NEVER) {
        return false;
    }
    let Some(entry) = entry_url(uri) else {
        return false;
    };
    if entry.host() != page.host() {
        return false;
    }
    if entry.port().is_some() && entry.port_or_known_default() != page.port_or_known_default() {
        return false;
    }
    if match_type == Some(MATCH_EXACT) {
        return entry.as_str() == page.as_str();
    }
    true
}

/// Validates a URL for a new entry: `https://` with a host. Returns the normalised form.
pub(crate) fn new_entry_url(url: &str) -> Option<String> {
    page_url(url).map(|u| u.to_string())
}
