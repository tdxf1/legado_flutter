# Directory Structure

How the `core/` workspace is organized and which crate owns what.

## Crate Boundaries

Each crate has a narrow responsibility. Cross-crate imports are direction-only:

```
core-net  ◀── core-source ◀── bridge
                              │
core-parser ─────────────────▶│
                              │
core-storage ◀────────────────┴──── api-server
```

- `core-storage` does not depend on `core-source` / `core-parser` / `core-net`. It owns SQL only.
- `core-source` may depend on `core-net` for HTTP fetches but never on `core-storage`.
- `bridge` is the only crate allowed to depend on every other crate, because it is the FFI seam.
- `api-server` re-uses `core-storage` and `core-source` directly. It does not depend on `bridge`.

This boundary is enforced by `Cargo.toml` files only (no compiler-level enforcement), so when adding a new function check the existing direction before introducing the import.

## `core-storage/src/`

```
database.rs         init_database / get_connection / migrations (PRAGMA user_version up to v12)
models.rs           plain-data structs: Book, BookGroup, Bookmark, BookSource, ReplaceRule, ...
legado_aes.rs       AES-128/ECB+MD5 (Legado-compat, marked weak; see backup-aes guide)
legado_field_map.rs Legado JSON ↔ local model conversion (timestamp ms→s, bitmask→id, etc.)
backup_dao.rs       export/import zip; KNOWN_FILE_NAMES + MAX_ZIP_ENTRY_SIZE + MAX_ZIP_TOTAL_SIZE
*_dao.rs            21 DAOs: book / book_group / bookmark / cache / cache_stats / chapter / download
                    / progress / read_record / replace_rule / rss_article / rss_read_record /
                    rss_source / rss_star / rule_sub / source. Each owns its table.
```

All DAOs follow the same constructor: `pub fn new(conn: &Connection) -> Self`. There is no connection pool inside `core-storage`; `bridge` opens a fresh `Connection` per call.

## `core-source/src/`

```
legado/             Original Legado rule engine (search/explore/book-info/toc/content rules).
rss/                RSS parsing rules and HTTP fetches.
rule_engine.rs      Shared rule-engine entry point used by both legado and rss.
parser.rs           HTML / regex / JSONPath / xpath / @js extraction primitives.
types.rs            BookSearchResult, ExploreItem, ChapterListItem and friends.
utils.rs            URL normalize, charset detection delegations.
```

Everything in this crate is pure (no `Connection`, no `tokio` runtime ownership). `core-source` may build a `tokio::Runtime` only inside `bridge::api::explore` and similar sync FRB entry points. See `findings-rust-data.md::F-W1A-002`.

## `core-parser/src/`

```
epub.rs / txt.rs / umd.rs    Three local file format parsers. Each returns chapters as Vec<Chapter>.
cleaner.rs                   Whitespace + Unicode cleanup applied to chapter content.
types.rs                     ParsedBook, ParsedChapter.
```

Pure functions only. No IO except reading the file passed in by path.

## `core-net/src/`

```
client.rs       Thin reqwest wrapper. One client per call (no shared client cache).
cookie.rs       In-memory cookie jar with per-host save/load.
encoding.rs     charset_normalizer + encoding_rs detection used by core-source HTTP responses.
retry.rs        Simple exponential backoff with bounded retry count.
proxy.rs        SOCKS / HTTP proxy URL parsing.
downloader.rs   Stream-to-file with progress callback (used by bridge for chapter download).
webdav.rs       WebDAV PUT / GET / PROPFIND for backup upload/restore.
```

## `bridge/src/`

```
api.rs            ~2700 lines of pub fn exposed to Dart via flutter_rust_bridge. Each fn returns
                  Result<String, String> (JSON-encoded payload) or Result<(), String>.
local_book.rs    Local-file book import flow used by api::import_local_book.
transaction.rs   with_transaction(db_path, |tx| ...) helper for cross-DAO writes.
                  See `storage-and-database.md` for usage.
frb_generated.rs FRB-emitted bindings; never edit by hand. Regenerate via the project's FRB script.
```

## `api-server/src/`

```
main.rs       Axum router setup, dev-only token middleware (constant-time eq).
routes/       REST handlers grouped by resource.
state.rs      AppState with shared db path.
util.rs       Common JSON response helpers.
error.rs      Maps anyhow / String errors into HTTP status + JSON body.
```

This binary is only used during development. It is **not** shipped with the Flutter app and must not become a dependency of `bridge`.

## Adding a New File

Before adding a file, check whether the responsibility already lives in one of the existing crates. The most common mis-placement is putting HTTP retry logic in `core-source` (belongs in `core-net`) or putting JSON field translation in `bridge` (belongs in `core-storage::legado_field_map`).
