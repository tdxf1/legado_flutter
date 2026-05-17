//! Build-time guard for the hand-edited `frb_generated.rs`.
//!
//! `flutter_rust_bridge_codegen generate` has timed out repeatedly on this
//! repo (300s/600s, see CURRENT_STATUS.md FRB patch chapter), so a number of
//! wire functions were added by hand. If a future contributor re-runs the
//! codegen they will silently overwrite those patches and the runtime
//! dispatcher will hit `unreachable!()` when Dart calls one of the missing
//! funcIds.
//!
//! This script runs at compile time and fails the build if any of the
//! known-manual wire impls disappears from `src/frb_generated.rs`. It is
//! intentionally string-matching (not a real Rust parser) so it stays cheap
//! and survives codegen-format churn.

use std::fs;
use std::path::PathBuf;

const REQUIRED_WIRE_FN_FRAGMENTS: &[&str] = &[
    // funcId 42 — validate_source_rules
    "wire__crate__api__validate_source_rules_impl",
    // funcId 43 — validate_source_from_db
    "wire__crate__api__validate_source_from_db_impl",
    // funcId 44 — export_all_sources
    "wire__crate__api__export_all_sources_impl",
    // funcId 45 — get_replace_rules
    "wire__crate__api__get_replace_rules_impl",
    // funcId 46 — save_replace_rule
    "wire__crate__api__save_replace_rule_impl",
    // funcId 47 — delete_replace_rule
    "wire__crate__api__delete_replace_rule_impl",
    // funcId 48 — set_replace_rule_enabled
    "wire__crate__api__set_replace_rule_enabled_impl",
    // funcId 49 — replace_book_chapters_preserving_content
    "wire__crate__api__replace_book_chapters_preserving_content_impl",
    // funcId 50 — replace_book_chapters
    "wire__crate__api__replace_book_chapters_impl",
    // funcId 51 — diagnostic for raw rule_search JSON
    "wire__crate__api__get_source_rule_search_raw_impl",
    // funcId 52 — search_with_source_from_db v2 wrapper
    "wire__crate__api__search_with_source_from_db_v2_impl",
    // funcId 54 — batch source deletion
    "wire__crate__api__delete_sources_batch_impl",
    // funcId 55 — explore entries listing
    "wire__crate__api__get_explore_entries_impl",
    // funcId 56 — explore page fetch
    "wire__crate__api__explore_impl",
    // funcId 57 — apply_replace_rules (P1-7)
    "wire__crate__api__apply_replace_rules_impl",
];

const REQUIRED_DISPATCHER_FRAGMENTS: &[&str] = &[
    "42 =>",
    "43 =>",
    "44 =>",
    "45 =>",
    "46 =>",
    "47 =>",
    "48 =>",
    "49 =>",
    "50 =>",
    "51 =>",
    "52 =>",
    "54 =>",
    "55 =>",
    "56 =>",
    "57 =>",
];

fn main() {
    let manifest_dir = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap());
    let frb = manifest_dir.join("src/frb_generated.rs");

    println!("cargo:rerun-if-changed=src/frb_generated.rs");

    let content = match fs::read_to_string(&frb) {
        Ok(s) => s,
        Err(e) => {
            // Don't hard-fail on a missing file (e.g. pre-codegen skeleton).
            // Surface a warning so the next codegen run is conspicuous.
            println!(
                "cargo:warning=bridge build.rs: cannot read {}: {} (manual-patch guard skipped)",
                frb.display(),
                e
            );
            return;
        }
    };

    let mut missing = Vec::new();
    for needle in REQUIRED_WIRE_FN_FRAGMENTS {
        if !content.contains(needle) {
            missing.push(*needle);
        }
    }
    for needle in REQUIRED_DISPATCHER_FRAGMENTS {
        if !content.contains(needle) {
            missing.push(*needle);
        }
    }

    if !missing.is_empty() {
        // Hard error: a missing wire fn means runtime calls from Dart will
        // panic with `unreachable!()`. Better to fail the build now.
        for fragment in &missing {
            println!(
                "cargo:warning=bridge build.rs: missing manual wire fragment `{}`",
                fragment
            );
        }
        panic!(
            "frb_generated.rs is missing {} hand-edited wire/dispatch fragment(s). \
             A `flutter_rust_bridge_codegen generate` run probably overwrote the manual \
             patches. See CURRENT_STATUS.md (FRB patch chapter) and re-apply funcId \
             42-52 / 54-57 (53 is intentionally a hole; do not re-introduce).",
            missing.len()
        );
    }
}
