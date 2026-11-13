// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! Ad-block filter lists (Adblock Plus / uBlock syntax) to Apple Content Blocker JSON.
//!
//! The conversion itself is done by Brave's `adblock` crate
//! (`adblock::content_blocking`). This module adds what WKWebView needs on top:
//!
//! * per-list statistics, including why lines could not be converted,
//! * splitting the result into several rule lists (WebKit limits the rules per list),
//! * a helper for per-site exceptions.
//!
//! # Chunking and exceptions
//!
//! `ignore-previous-rules` only cancels earlier rules **of the same compiled rule
//! list**; WebKit evaluates separate lists independently. The result of all input
//! lists is therefore ordered as `[blocking and hiding rules..., exception rules...,
//! first-party document exception]`, as in the `adblock` crate, and then split so that
//! *every chunk* carries a full copy of the exception rules after its own slice of
//! blocking rules. Because an exception rule only matches URLs it was written for,
//! copies that do not apply to a chunk's rules are harmless, and the behaviour of the
//! chunks together equals that of one unsplit list. The price: the exceptions count
//! against `max_rules_per_chunk` in every chunk.

use std::collections::{BTreeMap, HashSet};
use std::time::Instant;

use adblock::content_blocking::{
    ignore_previous_fp_documents, CbAction, CbRule, CbRuleCreationFailure, CbRuleEquivalent,
    CbTrigger, CbType,
};
use adblock::lists::{parse_filter, FilterParseError, ParseOptions, ParsedLine};

use crate::NeuralError;

/// Default rule limit per chunk. WebKit's hard limit is reported to be about 150,000
/// rules per list; stay well below it.
pub const DEFAULT_MAX_RULES_PER_CHUNK: u32 = 100_000;

/// One filter list as text.
#[derive(Debug, Clone, uniffi::Record)]
pub struct FilterListInput {
    /// Caller-chosen identifier, echoed in the statistics.
    pub id: String,
    /// Full list text (ABP/uBO syntax).
    pub text: String,
}

/// One JSON document for `WKContentRuleListStore.compileContentRuleList`.
#[derive(Debug, Clone, uniffi::Record)]
pub struct RuleListChunk {
    /// Stable-per-run identifier (`shield-000`, `shield-001`, ...).
    pub id: String,
    /// Content Blocker JSON array.
    pub json: String,
    /// Number of rules in `json` (including the copied exception rules).
    pub rule_count: u32,
}

/// Number of lines that failed for one reason.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ReasonCount {
    pub reason: String,
    pub count: u32,
}

/// Conversion statistics for one input list.
#[derive(Debug, Clone, uniffi::Record)]
pub struct ListStats {
    pub id: String,
    /// All lines of the list.
    pub lines_total: u32,
    /// Empty lines, comments and the `[Adblock ...]` header.
    pub comment_or_blank_lines: u32,
    /// Network filters (incl. `@@` exceptions) converted to at least one rule.
    pub network_converted: u32,
    /// Cosmetic filters (incl. `#@#` exceptions) converted.
    pub cosmetic_converted: u32,
    /// Lines that are syntax the list parser or the converter cannot handle.
    pub unconvertible: u32,
    /// `unconvertible` broken down by reason, sorted by count (descending).
    pub unconvertible_reasons: Vec<ReasonCount>,
    /// Wall-clock time spent parsing and converting this list.
    pub duration_ms: u64,
}

/// Statistics for a whole conversion.
#[derive(Debug, Clone, uniffi::Record)]
pub struct ShieldStats {
    pub lists: Vec<ListStats>,
    /// Exception rules copied into every chunk (incl. the first-party document rule).
    pub exception_rules_per_chunk: u32,
    /// Rules before chunking, without the per-chunk exception copies.
    pub total_unique_rules: u32,
    pub total_duration_ms: u64,
}

/// Result of [`convert_filter_lists`].
#[derive(Debug, Clone, uniffi::Record)]
pub struct ShieldConversion {
    pub chunks: Vec<RuleListChunk>,
    pub stats: ShieldStats,
}

/// Rule limit used when the caller has no better value.
#[uniffi::export]
pub fn default_max_rules_per_chunk() -> u32 {
    DEFAULT_MAX_RULES_PER_CHUNK
}

fn failure_reason(f: &CbRuleCreationFailure) -> &'static str {
    use CbRuleCreationFailure::*;
    match f {
        NeedsDebugMode => "internal: needs debug mode",
        UnlessAndIfDomainTogetherUnsupported => "if-domain and unless-domain combined",
        NoSupportedNetworkOptions(_) => "only unsupported resource types",
        NetworkRedirectUnsupported => "redirect option",
        NetworkGenerichideUnsupported => "generichide option",
        NetworkBadFilterUnsupported => "badfilter option",
        NetworkCspUnsupported => "csp option",
        NetworkRemoveparamUnsupported => "removeparam option",
        FullRegexUnsupported => "regex not expressible",
        OptimizedRulesUnsupported => "optimized rule",
        CosmeticEntitiesUnsupported => "cosmetic entity (e.g. google.*)",
        CosmeticActionRulesNotSupported => "cosmetic :style() action",
        ScriptletInjectionsNotSupported => "scriptlet injection",
        RuleContainsNonASCII => "non-ASCII characters",
        FromNotSupported => "from=/to= domain alias",
        ProceduralCosmeticFiltersUnsupported => "procedural cosmetic filter",
    }
}

/// Short, low-cardinality reason text for a parse error (payload after `:`/`(` dropped).
fn parse_reason(kind: &str, e: &dyn std::fmt::Display) -> String {
    let msg = e.to_string();
    let head = msg.split([':', '(']).next().unwrap_or("").trim();
    format!("invalid {kind} filter: {head}")
}

fn is_comment(line: &str) -> bool {
    line.starts_with('!')
        || line.starts_with("[Adblock")
        || line.starts_with("[uBlock")
        || (line.starts_with('#') && line[1..].starts_with(char::is_whitespace))
}

/// Rules of one list, already serialised.
#[derive(Default)]
struct ListRules {
    /// Blocking / hiding rules in list order (network first, then cosmetic).
    plain: Vec<String>,
    /// `ignore-previous-rules` rules.
    exceptions: Vec<String>,
    any_network: bool,
}

fn push_rule(out: &mut ListRules, rule: &CbRule) -> Result<(), NeuralError> {
    let json = serde_json::to_string(rule).map_err(|e| NeuralError::Internal {
        message: format!("serialising rule: {e}"),
    })?;
    if matches!(rule.action.typ, CbType::IgnorePreviousRules) {
        out.exceptions.push(json);
    } else {
        out.plain.push(json);
    }
    Ok(())
}

fn convert_one(input: &FilterListInput) -> Result<(ListStats, ListRules), NeuralError> {
    let start = Instant::now();
    let opts = ParseOptions::default();
    let mut stats = ListStats {
        id: input.id.clone(),
        lines_total: 0,
        comment_or_blank_lines: 0,
        network_converted: 0,
        cosmetic_converted: 0,
        unconvertible: 0,
        unconvertible_reasons: Vec::new(),
        duration_ms: 0,
    };
    let mut reasons: BTreeMap<String, u32> = BTreeMap::new();
    let mut bump = |stats: &mut ListStats, reason: &str| {
        stats.unconvertible += 1;
        *reasons.entry(reason.to_string()).or_insert(0) += 1;
    };

    // Pass 1: parse. Debug mode is required by the converter (it needs the raw line).
    let mut network = Vec::new();
    let mut cosmetic = Vec::new();
    for line in input.text.lines() {
        stats.lines_total += 1;
        match parse_filter(line, true, opts) {
            Ok(ParsedLine::Network(f)) => network.push(f),
            Ok(ParsedLine::Cosmetic(f)) => cosmetic.push(f),
            Err(FilterParseError::Empty) => stats.comment_or_blank_lines += 1,
            Err(FilterParseError::Unsupported) if is_comment(line.trim()) => {
                stats.comment_or_blank_lines += 1
            }
            Err(FilterParseError::Unsupported) => bump(&mut stats, "unsupported syntax"),
            Err(FilterParseError::Network(e)) => bump(&mut stats, &parse_reason("network", &e)),
            Err(FilterParseError::Cosmetic(e)) => bump(&mut stats, &parse_reason("cosmetic", &e)),
            Err(FilterParseError::InvalidExpiresInterval) => {
                stats.comment_or_blank_lines += 1;
            }
        }
    }

    // `$badfilter` disables the identically-written filter in the same list.
    let bad_ids: HashSet<_> = network
        .iter()
        .filter(|f| f.is_badfilter())
        .map(|f| f.get_id())
        .collect();

    let mut rules = ListRules::default();
    for f in network {
        if f.is_badfilter() || bad_ids.contains(&f.get_id()) {
            bump(&mut stats, "disabled by $badfilter");
            continue;
        }
        match CbRuleEquivalent::try_from(f) {
            Ok(eq) => {
                stats.network_converted += 1;
                rules.any_network = true;
                for r in eq {
                    push_rule(&mut rules, &r)?;
                }
            }
            Err(e) => bump(&mut stats, failure_reason(&e)),
        }
    }
    for f in cosmetic {
        match CbRule::try_from(f) {
            Ok(r) => {
                stats.cosmetic_converted += 1;
                push_rule(&mut rules, &r)?;
            }
            Err(e) => bump(&mut stats, failure_reason(&e)),
        }
    }

    let mut v: Vec<_> = reasons
        .into_iter()
        .map(|(reason, count)| ReasonCount { reason, count })
        .collect();
    v.sort_by(|a, b| b.count.cmp(&a.count).then_with(|| a.reason.cmp(&b.reason)));
    stats.unconvertible_reasons = v;
    stats.duration_ms = start.elapsed().as_millis() as u64;
    Ok((stats, rules))
}

fn join_json(rules: &[&str]) -> String {
    let len: usize = rules.iter().map(|r| r.len() + 1).sum::<usize>() + 2;
    let mut s = String::with_capacity(len);
    s.push('[');
    for (i, r) in rules.iter().enumerate() {
        if i > 0 {
            s.push(',');
        }
        s.push_str(r);
    }
    s.push(']');
    s
}

/// Converts filter lists to Content Blocker JSON, split into chunks of at most
/// `max_rules_per_chunk` rules (see the module docs for how exceptions are kept
/// correct across chunks). Pass [`DEFAULT_MAX_RULES_PER_CHUNK`] if unsure.
///
/// Pure function: holds no locks and no global state, safe to call from a
/// background thread while the rest of the core is in use. Lists are combined as if
/// concatenated, so an exception in one list also applies to rules of another.
/// `$badfilter` only acts inside its own list.
///
/// Errors: `InvalidArgument` if `max_rules_per_chunk` is too small to hold the
/// exception rules plus at least one other rule.
#[uniffi::export]
pub fn convert_filter_lists(
    lists: Vec<FilterListInput>,
    max_rules_per_chunk: u32,
) -> Result<ShieldConversion, NeuralError> {
    let start = Instant::now();
    let mut stats = Vec::with_capacity(lists.len());
    let mut plain: Vec<String> = Vec::new();
    let mut exceptions: Vec<String> = Vec::new();
    let mut seen_exc: HashSet<String> = HashSet::new();
    let mut any_network = false;

    for input in &lists {
        let (s, rules) = convert_one(input)?;
        stats.push(s);
        any_network |= rules.any_network;
        plain.extend(rules.plain);
        for e in rules.exceptions {
            if seen_exc.contains(&e) {
                continue;
            }
            seen_exc.insert(e.clone());
            exceptions.push(e);
        }
    }
    if any_network {
        let fp = serde_json::to_string(&ignore_previous_fp_documents()).map_err(|e| {
            NeuralError::Internal {
                message: format!("serialising rule: {e}"),
            }
        })?;
        exceptions.push(fp);
    }

    let exc_len = exceptions.len();
    let max = max_rules_per_chunk as usize;
    if max <= exc_len {
        return Err(NeuralError::InvalidArgument {
            message: format!(
                "max_rules_per_chunk ({max}) must exceed the {exc_len} exception rules \
                 that every chunk carries"
            ),
        });
    }
    let capacity = max - exc_len;
    let exc_refs: Vec<&str> = exceptions.iter().map(String::as_str).collect();

    let mut chunks = Vec::new();
    for (i, slice) in plain.chunks(capacity).enumerate() {
        let mut refs: Vec<&str> = slice.iter().map(String::as_str).collect();
        refs.extend_from_slice(&exc_refs);
        chunks.push(RuleListChunk {
            id: format!("shield-{i:03}"),
            json: join_json(&refs),
            rule_count: refs.len() as u32,
        });
    }

    Ok(ShieldConversion {
        chunks,
        stats: ShieldStats {
            lists: stats,
            exception_rules_per_chunk: exc_len as u32,
            total_unique_rules: (plain.len() + exc_len) as u32,
            total_duration_ms: start.elapsed().as_millis() as u64,
        },
    })
}

/// Normalises domains for `if-domain`: lower-case ASCII (punycode for IDNs), no
/// scheme/path/port; a leading `*.` or `.` is dropped (matching always includes
/// subdomains).
fn site_rule(domains: &[String]) -> Result<CbRule, NeuralError> {
    let mut list: Vec<String> = Vec::new();
    for d in domains {
        let n = d
            .trim()
            .trim_start_matches("*.")
            .trim_start_matches('.')
            .trim_end_matches('.')
            .to_ascii_lowercase();
        let ok = !n.is_empty()
            && n.split('.').all(|l| {
                !l.is_empty()
                    && !l.starts_with('-')
                    && !l.ends_with('-')
                    && l.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
            });
        if !ok {
            return Err(NeuralError::InvalidArgument {
                message: format!("not a plain ASCII host name: {d:?}"),
            });
        }
        list.push(format!("*{n}"));
    }
    list.sort();
    list.dedup();
    if list.is_empty() {
        return Err(NeuralError::InvalidArgument {
            message: "no domains given".into(),
        });
    }
    Ok(CbRule {
        trigger: CbTrigger {
            url_filter: ".*".into(),
            if_domain: Some(list),
            ..CbTrigger::default()
        },
        action: CbAction {
            typ: CbType::IgnorePreviousRules,
            selector: None,
        },
    })
}

/// JSON of a rule list with one rule that cancels all earlier rules on the given
/// domains (and their subdomains).
///
/// Caveat (WebKit semantics): `ignore-previous-rules` only affects rules in the
/// *same* compiled list, so this list alone does not disable other lists. To switch
/// the blocker off for a site, either use [`append_site_exceptions`] on every chunk
/// or do not attach the chunk lists to that site's web view.
#[uniffi::export]
pub fn site_exception_rule_list(domains: Vec<String>) -> Result<String, NeuralError> {
    let rule = site_rule(&domains)?;
    let json = serde_json::to_string(&[rule]).map_err(|e| NeuralError::Internal {
        message: e.to_string(),
    })?;
    Ok(json)
}

/// Appends the per-site exception rule to the end of an existing chunk JSON, which is
/// the only position where it cancels all other rules of that chunk. An empty
/// `domains` returns the input unchanged.
#[uniffi::export]
pub fn append_site_exceptions(
    chunk_json: String,
    domains: Vec<String>,
) -> Result<String, NeuralError> {
    if domains.is_empty() {
        return Ok(chunk_json);
    }
    let rule = site_rule(&domains)?;
    let rule = serde_json::to_string(&rule).map_err(|e| NeuralError::Internal {
        message: e.to_string(),
    })?;
    let body = chunk_json.trim_end();
    let Some(open) = body.strip_suffix(']') else {
        return Err(NeuralError::InvalidArgument {
            message: "chunk_json is not a JSON array".into(),
        });
    };
    let sep = if open.trim_end().ends_with('[') {
        ""
    } else {
        ","
    };
    Ok(format!("{open}{sep}{rule}]"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;

    const LIST: &str = "[Adblock Plus 2.0]\n\
! a comment\n\
\n\
||ads.example.com^\n\
||tracker.example.net^$third-party\n\
||cdn.example.org/banner$domain=news.example.com\n\
@@||ads.example.com/ok.js^\n\
##.ad-banner\n\
example.com##.sponsored\n\
example.com#@#.sponsored\n\
||x.example^$redirect=noopt.js\n\
example.com##+js(abort-on-property-read, foo)\n\
||bad.example^$nosuchoption\n";

    fn input(id: &str, text: &str) -> FilterListInput {
        FilterListInput {
            id: id.into(),
            text: text.into(),
        }
    }

    fn rules(json: &str) -> Vec<Value> {
        serde_json::from_str::<Value>(json)
            .unwrap()
            .as_array()
            .unwrap()
            .clone()
    }

    fn action(r: &Value) -> &str {
        r["action"]["type"].as_str().unwrap()
    }

    #[test]
    fn converts_and_counts() {
        let c = convert_filter_lists(vec![input("t", LIST)], 1000).unwrap();
        let s = &c.stats.lists[0];
        assert_eq!(s.id, "t");
        assert_eq!(s.lines_total, 13);
        assert_eq!(s.comment_or_blank_lines, 3);
        assert_eq!(s.network_converted, 4);
        assert_eq!(s.cosmetic_converted, 3);
        assert_eq!(s.unconvertible, 3, "{:?}", s.unconvertible_reasons);
        assert!(s
            .unconvertible_reasons
            .iter()
            .any(|r| r.reason == "redirect option" && r.count == 1));
        assert!(s
            .unconvertible_reasons
            .iter()
            .any(|r| r.reason == "scriptlet injection"));
        assert_eq!(c.chunks.len(), 1);
    }

    #[test]
    fn json_has_expected_shape_and_order() {
        let c = convert_filter_lists(vec![input("t", LIST)], 1000).unwrap();
        let r = rules(&c.chunks[0].json);
        assert_eq!(r.len() as u32, c.chunks[0].rule_count);
        for rule in &r {
            assert!(rule["trigger"]["url-filter"].is_string());
            assert!(rule["action"]["type"].is_string());
        }
        // Domain option became if-domain.
        assert!(r.iter().any(|x| x["trigger"]["if-domain"]
            .as_array()
            .is_some_and(|d| d.iter().any(|v| v == "*news.example.com"))));
        // Cosmetic rule keeps its selector.
        assert!(r
            .iter()
            .any(|x| action(x) == "css-display-none" && x["action"]["selector"] == ".ad-banner"));
        // All ignore-previous-rules come after every other rule.
        let first_ignore = r.iter().position(|x| action(x) == "ignore-previous-rules");
        let last_other = r.iter().rposition(|x| action(x) != "ignore-previous-rules");
        assert!(first_ignore.unwrap() > last_other.unwrap());
        // `@@` and the first-party document rule. The converter maps `#@#` to a
        // css-display-none rule with `unless-domain`, not to an exception.
        assert_eq!(c.stats.exception_rules_per_chunk, 2);
    }

    #[test]
    fn chunking_copies_exceptions_into_every_chunk() {
        let mut text = String::from("@@||allowed.example^\n");
        for i in 0..50 {
            text.push_str(&format!("||ads{i}.example^\n"));
        }
        let c = convert_filter_lists(vec![input("t", &text)], 12).unwrap();
        // 2 exceptions (@@ + fp document) -> 10 plain rules per chunk.
        assert_eq!(c.stats.exception_rules_per_chunk, 2);
        assert_eq!(c.chunks.len(), 5);
        let mut blocks = 0;
        for ch in &c.chunks {
            let r = rules(&ch.json);
            assert!(r.len() <= 12);
            assert_eq!(r.len() as u32, ch.rule_count);
            let n = r.len();
            assert_eq!(action(&r[n - 1]), "ignore-previous-rules");
            assert_eq!(action(&r[n - 2]), "ignore-previous-rules");
            assert!(r[..n - 2].iter().all(|x| action(x) == "block"));
            blocks += n - 2;
        }
        assert_eq!(blocks, 50);
        // Same blocks in the same order as unsplit.
        let whole = convert_filter_lists(vec![input("t", &text)], 1000).unwrap();
        let joined: Vec<Value> = c
            .chunks
            .iter()
            .flat_map(|ch| {
                let r = rules(&ch.json);
                r[..r.len() - 2].to_vec()
            })
            .collect();
        assert_eq!(joined, rules(&whole.chunks[0].json)[..50].to_vec());
    }

    #[test]
    fn exception_in_other_list_applies_and_dedupes() {
        let a = input("a", "||ads.example^\n@@||ok.example^\n");
        let b = input("b", "||t.example^\n@@||ok.example^\n");
        let c = convert_filter_lists(vec![a, b], 100).unwrap();
        assert_eq!(c.stats.lists.len(), 2);
        assert_eq!(c.stats.exception_rules_per_chunk, 2);
        assert_eq!(rules(&c.chunks[0].json).len(), 4);
    }

    #[test]
    fn too_small_chunk_is_rejected_and_empty_input_yields_no_chunks() {
        let l = input("t", "||a.example^\n@@||b.example^\n");
        assert!(matches!(
            convert_filter_lists(vec![l], 2),
            Err(NeuralError::InvalidArgument { .. })
        ));
        let c = convert_filter_lists(vec![input("e", "! only a comment\n")], 10).unwrap();
        assert!(c.chunks.is_empty());
        assert_eq!(c.stats.lists[0].comment_or_blank_lines, 1);
    }

    #[test]
    fn badfilter_removes_target() {
        let c = convert_filter_lists(
            vec![input(
                "t",
                "||a.example^\n||a.example^$badfilter\n||b.example^\n",
            )],
            100,
        )
        .unwrap();
        assert_eq!(c.stats.lists[0].network_converted, 1);
        assert_eq!(rules(&c.chunks[0].json).len(), 2); // block + fp document
    }

    #[test]
    fn site_exception_rules() {
        let j = site_exception_rule_list(vec!["Example.COM".into(), "*.foo.org".into()]).unwrap();
        let r = rules(&j);
        assert_eq!(r.len(), 1);
        assert_eq!(action(&r[0]), "ignore-previous-rules");
        assert_eq!(r[0]["trigger"]["url-filter"], ".*");
        assert_eq!(
            r[0]["trigger"]["if-domain"],
            serde_json::json!(["*example.com", "*foo.org"])
        );
        assert!(site_exception_rule_list(vec![]).is_err());
        assert!(site_exception_rule_list(vec!["a b".into()]).is_err());
        assert!(site_exception_rule_list(vec!["https://a.com/x".into()]).is_err());

        let c = convert_filter_lists(vec![input("t", "||a.example^\n")], 100).unwrap();
        let j = append_site_exceptions(c.chunks[0].json.clone(), vec!["a.com".into()]).unwrap();
        let r = rules(&j);
        assert_eq!(r.len(), 3);
        assert_eq!(r[2]["trigger"]["if-domain"][0], "*a.com");
        assert_eq!(
            append_site_exceptions("[]".into(), vec!["a.com".into()])
                .map(|s| rules(&s).len())
                .unwrap(),
            1
        );
        assert!(append_site_exceptions("{}".into(), vec!["a.com".into()]).is_err());
    }
}
