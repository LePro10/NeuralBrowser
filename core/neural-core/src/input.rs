// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! Decides whether address-bar text is a URL or a search query.

/// Schemes written without `//` that are always treated as URLs.
const OPAQUE_SCHEMES: &[&str] = &[
    "about:",
    "file:",
    "data:",
    "mailto:",
    "view-source:",
    "javascript:",
    "blob:",
    "tel:",
];

/// Percent-encodes `s` for use as a URL query component.
fn encode_query(s: &str) -> String {
    let mut out = String::with_capacity(s.len() * 3);
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(b as char)
            }
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

fn has_scheme_with_slashes(s: &str) -> bool {
    match s.find("://") {
        Some(i) if i > 0 => {
            let scheme = &s[..i];
            scheme.starts_with(|c: char| c.is_ascii_alphabetic())
                && scheme
                    .chars()
                    .all(|c| c.is_ascii_alphanumeric() || matches!(c, '+' | '-' | '.'))
        }
        _ => false,
    }
}

fn is_ipv4(host: &str) -> bool {
    let parts: Vec<&str> = host.split('.').collect();
    parts.len() == 4
        && parts.iter().all(|p| {
            !p.is_empty()
                && p.len() <= 3
                && p.bytes().all(|b| b.is_ascii_digit())
                && p.parse::<u16>().is_ok_and(|n| n <= 255)
        })
}

fn is_domain(host: &str) -> bool {
    let labels: Vec<&str> = host.split('.').collect();
    if labels.len() < 2 {
        return false;
    }
    let valid_label = |l: &&str| {
        !l.is_empty()
            && !l.starts_with('-')
            && !l.ends_with('-')
            && l.chars().all(|c| c.is_alphanumeric() || c == '-')
    };
    if !labels.iter().all(valid_label) {
        return false;
    }
    let tld = labels[labels.len() - 1];
    tld.starts_with("xn--") || (tld.chars().count() >= 2 && tld.chars().all(|c| c.is_alphabetic()))
}

fn valid_port(p: &str) -> bool {
    !p.is_empty()
        && p.len() <= 5
        && p.bytes().all(|b| b.is_ascii_digit())
        && p.parse::<u32>().is_ok_and(|n| n <= 65535)
}

/// Returns the scheme to add if `text` looks like a host (+port/path), else None.
fn host_scheme(text: &str) -> Option<&'static str> {
    let end = text.find(['/', '?', '#']).unwrap_or(text.len());
    let authority = &text[..end];
    let authority = authority.rsplit_once('@').map_or(authority, |(_, h)| h);
    let (host, port) = if let Some(rest) = authority.strip_prefix('[') {
        let (h, after) = rest.split_once(']')?;
        if h.is_empty()
            || !h.contains(':')
            || !h
                .chars()
                .all(|c| c.is_ascii_hexdigit() || c == ':' || c == '.')
        {
            return None;
        }
        match after {
            "" => (h, None),
            a => (h, Some(a.strip_prefix(':')?)),
        }
    } else {
        match authority.split_once(':') {
            Some((h, p)) => (h, Some(p)),
            None => (authority, None),
        }
    };
    if let Some(p) = port {
        if !valid_port(p) {
            return None;
        }
    }
    let lower = host.to_ascii_lowercase();
    if authority.starts_with('[')
        || is_ipv4(&lower)
        || lower == "localhost"
        || lower.ends_with(".localhost")
    {
        Some("http://")
    } else if is_domain(&lower) {
        Some("https://")
    } else {
        None
    }
}

/// Turns address-bar `text` into a URL to load.
///
/// URLs get a scheme if missing (`https://` for domains, `http://` for
/// `localhost` and IP addresses). Anything else becomes a search using
/// `search_template`, where `%s` is replaced by the percent-encoded query.
/// Empty input yields `about:blank`.
#[uniffi::export]
pub fn resolve_input(text: String, search_template: String) -> String {
    let t = text.trim();
    if t.is_empty() {
        return "about:blank".to_string();
    }
    let lower = t.to_ascii_lowercase();
    if OPAQUE_SCHEMES.iter().any(|s| lower.starts_with(s)) || has_scheme_with_slashes(t) {
        return t.to_string();
    }
    if !t.chars().any(char::is_whitespace) {
        if let Some(scheme) = host_scheme(t) {
            return format!("{scheme}{t}");
        }
    }
    let q = encode_query(t);
    if search_template.contains("%s") {
        search_template.replace("%s", &q)
    } else {
        format!("{search_template}{q}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    const T: &str = "https://duckduckgo.com/?q=%s";
    fn r(s: &str) -> String {
        resolve_input(s.to_string(), T.to_string())
    }

    #[test]
    fn urls_with_scheme_kept() {
        assert_eq!(r("https://a.com/x?y=1"), "https://a.com/x?y=1");
        assert_eq!(r("http://localhost:3000"), "http://localhost:3000");
        assert_eq!(r("ftp://host/file"), "ftp://host/file");
        assert_eq!(r("  https://a.com  "), "https://a.com");
    }
    #[test]
    fn special_schemes() {
        assert_eq!(r("about:blank"), "about:blank");
        assert_eq!(r("ABOUT:config"), "ABOUT:config");
        assert_eq!(r("file:///tmp/a b.html"), "file:///tmp/a b.html");
        assert_eq!(r("mailto:a@b.c"), "mailto:a@b.c");
    }
    #[test]
    fn domains_get_https() {
        assert_eq!(r("example.com"), "https://example.com");
        assert_eq!(
            r("www.example.co.uk/path?x=1#f"),
            "https://www.example.co.uk/path?x=1#f"
        );
        assert_eq!(r("example.com:8080/x"), "https://example.com:8080/x");
        assert_eq!(r("user@example.com/x"), "https://user@example.com/x");
        assert_eq!(r("bücher.de"), "https://bücher.de");
    }
    #[test]
    fn local_and_ip_get_http() {
        assert_eq!(r("localhost"), "http://localhost");
        assert_eq!(r("localhost:3000"), "http://localhost:3000");
        assert_eq!(r("localhost:3000/a?b=c"), "http://localhost:3000/a?b=c");
        assert_eq!(r("127.0.0.1"), "http://127.0.0.1");
        assert_eq!(r("192.168.0.1:8080/x"), "http://192.168.0.1:8080/x");
        assert_eq!(r("[::1]:8080"), "http://[::1]:8080");
        assert_eq!(r("[2001:db8::1]/x"), "http://[2001:db8::1]/x");
        assert_eq!(r("app.localhost:3000"), "http://app.localhost:3000");
    }
    #[test]
    fn searches() {
        assert_eq!(r("hello world"), "https://duckduckgo.com/?q=hello%20world");
        assert_eq!(r("rust"), "https://duckduckgo.com/?q=rust");
        assert_eq!(r("a&b=c"), "https://duckduckgo.com/?q=a%26b%3Dc");
        assert_eq!(
            r("example.com is good"),
            "https://duckduckgo.com/?q=example.com%20is%20good"
        );
        assert_eq!(r("3.14"), "https://duckduckgo.com/?q=3.14");
        assert_eq!(r("256.1.1.1"), "https://duckduckgo.com/?q=256.1.1.1");
        assert_eq!(r("foo:bar"), "https://duckduckgo.com/?q=foo%3Abar");
        assert_eq!(
            r("localhost:99999"),
            "https://duckduckgo.com/?q=localhost%3A99999"
        );
        assert_eq!(r("äöü"), "https://duckduckgo.com/?q=%C3%A4%C3%B6%C3%BC");
        assert_eq!(r("-bad-.com x"), "https://duckduckgo.com/?q=-bad-.com%20x");
    }
    #[test]
    fn empty_and_template() {
        assert_eq!(r("   "), "about:blank");
        assert_eq!(
            resolve_input("a b".into(), "https://s/?q=%s&x=%s".into()),
            "https://s/?q=a%20b&x=a%20b"
        );
        assert_eq!(
            resolve_input("a b".into(), "https://s/?q=".into()),
            "https://s/?q=a%20b"
        );
    }
}
