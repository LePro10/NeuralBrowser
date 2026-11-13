// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! Downloads EasyList and EasyPrivacy at run time (read-only, into a temporary
//! directory that is removed afterwards), converts them and prints statistics.
//! No list text is stored in the repository.
//!
//!     cargo run --release -p neural_core --example shield_real_lists [-- OUT_DIR]
//!
//! With `OUT_DIR` the generated chunks are also written there (e.g. for the Swift
//! WKContentRuleListStore check).

use neural_core::shield::{FilterListInput, DEFAULT_MAX_RULES_PER_CHUNK};
use std::process::Command;

const LISTS: &[(&str, &str)] = &[
    ("easylist", "https://easylist.to/easylist/easylist.txt"),
    (
        "easyprivacy",
        "https://easylist.to/easylist/easyprivacy.txt",
    ),
];

fn main() {
    let tmp = std::env::temp_dir().join(format!("shield-lists-{}", std::process::id()));
    std::fs::create_dir_all(&tmp).expect("temp dir");
    let mut inputs = Vec::new();
    for (id, url) in LISTS {
        let path = tmp.join(format!("{id}.txt"));
        let st = Command::new("curl")
            .args(["-fsSL", "--max-time", "120", "-o"])
            .arg(&path)
            .arg(url)
            .status()
            .expect("curl");
        assert!(st.success(), "download of {url} failed");
        let text = std::fs::read_to_string(&path).expect("read list");
        println!("{id}: {} bytes downloaded", text.len());
        inputs.push(FilterListInput {
            id: id.to_string(),
            text,
        });
    }
    let _ = std::fs::remove_dir_all(&tmp);

    let max = std::env::var("MAX_RULES")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(DEFAULT_MAX_RULES_PER_CHUNK);
    let out = neural_core::shield::convert_filter_lists(inputs, max);
    let c = out.expect("conversion");

    for l in &c.stats.lists {
        println!(
            "[{}] lines {} (comments/blank {}), network {}, cosmetic {}, unconvertible {}, {} ms",
            l.id,
            l.lines_total,
            l.comment_or_blank_lines,
            l.network_converted,
            l.cosmetic_converted,
            l.unconvertible,
            l.duration_ms
        );
        for r in &l.unconvertible_reasons {
            println!("    {:>6}  {}", r.count, r.reason);
        }
    }
    println!(
        "unique rules {}, exceptions per chunk {}, total {} ms, max/chunk {}",
        c.stats.total_unique_rules,
        c.stats.exception_rules_per_chunk,
        c.stats.total_duration_ms,
        max
    );
    let mut total = 0usize;
    for ch in &c.chunks {
        let v: serde_json::Value = serde_json::from_str(&ch.json).expect("valid JSON");
        let arr = v.as_array().expect("array");
        assert_eq!(arr.len() as u32, ch.rule_count);
        assert!(arr
            .iter()
            .all(|r| r.get("trigger").is_some() && r.get("action").is_some()));
        total += ch.json.len();
        println!(
            "chunk {}: {} rules, {:.2} MB JSON",
            ch.id,
            ch.rule_count,
            ch.json.len() as f64 / 1e6
        );
    }
    println!(
        "{} chunk(s), {:.2} MB JSON total, JSON valid with trigger/action",
        c.chunks.len(),
        total as f64 / 1e6
    );
    if let Some(dir) = std::env::args().nth(1) {
        std::fs::create_dir_all(&dir).expect("out dir");
        for ch in &c.chunks {
            std::fs::write(format!("{dir}/{}.json", ch.id), &ch.json).expect("write");
        }
    }
}
