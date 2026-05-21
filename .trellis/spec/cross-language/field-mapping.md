# Field Mapping

The Rust `core-storage::models` and the Legado Android backup JSON do not have the same field shapes. The translation layer is `core-storage::legado_field_map` — anything that crosses the Legado-compat boundary must go through it.

## Where the Mapping Lives

```
core/core-storage/src/legado_field_map.rs
```

This module is the single source of truth for:

- Timestamp conversions (Legado uses ms, local schema uses s).
- Group bitmask ↔ group id collapse.
- Word-count parsing (`"5.2M"`, `"10万"`, `"120K"` → `i32`).
- Field-set differences: Legado has 31 Book fields, local schema has 26. Spillover lives in `Book.custom_info_json` as a `_legado_backup` sub-object.
- URL-to-id resolution for `BookSource.origin` → local `source_id` (resolved by a `sources_url_to_id` HashMap supplied by `backup_dao::import_from_zip`).

When you find a translation rule in `bridge::api::*` or in a feature page, **move it to `legado_field_map`** instead. This module already has unit tests for every rule.

## Helpers Worth Reusing

| Helper | What it does |
|---|---|
| `ms_to_seconds_smart(ts: i64)` | If `>1e10` treat as ms, else as s. Defensive for mixed-source timestamps. |
| `legado_group_bitmask_to_id(mask: u64)` | `1<<n` Legado group → local self-incrementing id (lowest power-of-2 log2). |
| `parse_word_count(s: &str)` | Various formats → `i32`. Returns 0 on parse failure (backup-restore must stay lenient). |
| `legado_source_to_storage_source(json: &Value)` | Legado JSON `BookSource` → local `models::BookSource`. |
| `legado_book_to_storage_book(json: &Value, sources_url_to_id: &HashMap<String,String>)` | Legado JSON `Book` → local `models::Book`. Resolves `origin` to a `source_id`. |

Each has at least one unit test in `core-storage/src/legado_field_map.rs`. Add a test before changing any of these functions.

## Adding a New Mapping Rule

Checklist:

1. Add the conversion as a free function (not a method) in `legado_field_map.rs`.
2. Doc-comment must cite the Legado source-of-truth file (`Book.kt:42`, `BookGroup.kt:11`, etc. as found in the original Legado-MD3 repo). Keep the citation even if you can't verify the exact line — it documents which entity / field is the canonical reference.
3. Add a unit test covering at least one corner case (empty string, ms vs s timestamp, malformed JSON).
4. Update the `import_from_zip` / `export_to_zip` flow to call the new helper.

## Anti-Patterns

- **Inline `serde_json::Value::as_str().unwrap_or("")` chains** inside `bridge::api::*` for Legado payloads. Move them into `legado_field_map`.
- **Per-feature shape parsers in Flutter.** The Flutter side parses JSON returned by `bridge::api::*`, but those payloads are already local-shape (not Legado-shape). If a feature is reaching for Legado-specific keys, that's a sign the Rust side is leaking the wrong shape — fix it there.
- **Reading timestamps as `i64` without going through `ms_to_seconds_smart`.** Old code used raw casts and silently produced timestamps in 1970 when the source was ms.

## Schema Drift Audits

The roadmap captures known field-mapping discrepancies in `findings-rust-data.md`. Currently resolved drift items include word-count parsing, group bitmask, and timestamp mixing. New drift will be added as findings if discovered.

Before adding a feature that depends on a Legado field, grep the field name in `legado_field_map.rs` first. If it's already wired up, follow the pattern. If not, this is the right module to extend.
