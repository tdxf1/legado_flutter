# BATCH-08: SQL 列常量 + dao 死代码 + upsert 风格统一

**Stage**: P1
**Slug**: `dao-sql-dedup-and-cleanup`
**Effort**: M (≤500 行)
**Depends on**: BATCH-07 (事务 helper 已就位才好抽 SQL 常量)

## 1. 范围

把 source_dao 4 处硬编码 29 列 SELECT、3 处重复 books upsert SQL、add_bookmark INSERT-only 等 SQL 风格不一致问题集中收口；同时删除 chapter_dao.delete_by_book / progress_dao.delete 等 FK CASCADE 已兜底的死代码 + StorageManager 自身死代码；把 download_dao 的全局可变 `DOWNLOAD_ROOT` 改为构造参数；把 group bitmask round-trip 损失文档化；修一处 created_at*1000 当主键 id 的并发冲突；修 cache_dao.get 静默吞 SQL 错误。

## 2. 包含的 findings

- [F-W1A-006] source_dao 4 处硬编码 29 列 SELECT — `core/core-storage/src/source_dao.rs:118-185`
- [F-W1A-010] add_bookmark INSERT-only 与 chapter_dao upsert 风格不一致 — `core/core-storage/src/progress_dao.rs:117-145`
- [F-W1A-011] books upsert SQL 在 3 处重复 — `core/core-storage/src/backup_dao.rs:495-578`
- [F-W1A-013] group bitmask 多分组语义无法 round-trip — `core/core-storage/src/legado_field_map.rs:618-685`
- [F-W1A-014] StorageManager error type 用 boxed Error 与全 crate 不一致；StorageManager 实为死代码 — `core/core-storage/src/lib.rs:73-82`
- [F-W1A-015] cache_dao.get 用 unwrap_or_default 静默吞 SQL 错误 — `core/core-storage/src/cache_dao.rs:13-20`
- [F-W1A-016] download_dao 模块级 static DOWNLOAD_ROOT 全局可变状态 — `core/core-storage/src/download_dao.rs:9-21`
- [F-W1A-018] delete_book 多 dao 错误吞掉，留下孤儿 chapters/progress（实为死代码） — `core/bridge/src/api.rs:72-80`
- [F-W1A-054] legado_field_map 用 created_at*1000 当主键 id，并发导入冲突 — `core/core-storage/src/legado_field_map.rs:721`

## 3. 影响文件

- `core/core-storage/src/source_dao.rs` — 抽 `const BOOK_SOURCE_COLUMNS: &str = "id, name, url, ..."`，4 处 SELECT 用 `format!` 拼
- `core/core-storage/src/progress_dao.rs:117-145` — `add_bookmark` 改 `INSERT ... ON CONFLICT(id) DO UPDATE` 与 chapter_dao 一致
- `core/core-storage/src/upsert_sql.rs` (新增) — 抽 `BOOKS_UPSERT_SQL` / `BOOK_SOURCES_UPSERT_SQL` / `REPLACE_RULES_UPSERT_SQL` 公共常量；或者 `BookDao::upsert_in_tx(tx: &Transaction, ...)` 让 backup_dao 复用
- `core/core-storage/src/backup_dao.rs:495-578` — 改用公共常量 / dao_in_tx 接口
- `core/core-storage/src/legado_field_map.rs:618-685` — 文档明确"端口不支持单本书多分组，与原 Legado 互导有信息损失"；导出时优先用 `Book.custom_info_json` 中的 `originalGroupBitmask`
- `core/core-storage/src/lib.rs:73-82` — 把 StorageManager error type 统一成 `rusqlite::Error` 或 `core-storage::Error` enum；评估 StorageManager 是否仍需要——若只为单元测试用可移到 `#[cfg(test)]`；Default `path` 改成 `:memory:` 防误操作
- `core/core-storage/src/cache_dao.rs:13-20` — `get` 改成 `row.get::<_, String>(0)` 把 SqlResult 直接传上去，让 caller 决定 fallback
- `core/core-storage/src/legado_field_map.rs:721` — 用 `r.id` 字符串 hash 出 i64，或全局递增计数器
- `core/core-storage/src/download_dao.rs:9-21` — 删除 `static DOWNLOAD_ROOT`，改构造参数
- `core/bridge/src/api.rs:72-80` — 删除 `chapter_dao.delete_by_book` + `progress_dao.delete` 死代码（FK CASCADE 已兜底）

## 4. 修复方向

- F-W1A-006：抽 `BOOK_SOURCE_COLUMNS` 常量；4 处 SELECT 用 `format!`，与 `book_dao::BOOK_COLUMNS` 风格对齐。
- F-W1A-010：`add_bookmark` 改 `INSERT ... ON CONFLICT(id) DO UPDATE SET ...`；或文档明确"caller 必须保证 id 全局唯一"。
- F-W1A-011：抽 upsert SQL 公共常量；或新增 `BookDao::upsert_in_tx(tx, ...)` 接口让 backup_dao 直接复用 dao 而不必持有 Connection。
- F-W1A-013：在 `Book.custom_info_json` 始终维护 `originalGroupBitmask`，导出时优先使用；并文档化数据损失。
- F-W1A-016：`download_root` 作为构造参数传到 `DownloadDao`；删除 `static DOWNLOAD_ROOT`。
- F-W1A-018：直接删除 `chapter_dao.delete_by_book` 与 `progress_dao.delete` 死代码；让 SQLite FK CASCADE 处理。
- F-W1A-014：把 StorageManager error type 统一；评估其是否仍需要；Default path 改 `:memory:`。
- F-W1A-015：cache_dao.get 改返回 SqlResult（不再 unwrap_or_default 吞错）。
- F-W1A-054：用 `r.id` 字符串 hash 出 i64，或用全局递增计数器。

## 5. 测试策略

- Rust unit test：source_dao 4 个 SELECT 用同一份列常量，schema 加列后 round-trip 不漂移
- Rust unit test：add_bookmark 重复 id 不报错
- Rust unit test：删除 chapter_dao.delete_by_book 后 delete_book 仍能清干净 chapters / progress（FK CASCADE 兜底）
- Rust unit test：legado_field_map 多条同 created_at 规则导出后不冲突

## 6. 验收

- [ ] master finding F-W1A-006/010/011/013/014/015/016/018/054 全部消解
- [ ] grep `INSERT INTO books` 全代码库仅 1 处定义
- [ ] DownloadDao 不再持有全局可变状态

## 7. implement.jsonl 草稿

```jsonl
{"file": ".trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings-rust-data.md", "reason": "本批次涉及的 wave 1A findings"}
{"file": "core/core-storage/src/source_dao.rs", "reason": "4 处 SELECT 抽列常量"}
{"file": "core/core-storage/src/book_dao.rs", "reason": "已有 BOOK_COLUMNS 风格参考"}
{"file": "core/core-storage/src/backup_dao.rs", "reason": "books upsert 重复 SQL"}
{"file": "core/core-storage/src/progress_dao.rs", "reason": "add_bookmark INSERT-only"}
{"file": "core/core-storage/src/legado_field_map.rs", "reason": "group bitmask + created_at*1000"}
{"file": "core/core-storage/src/download_dao.rs", "reason": "static DOWNLOAD_ROOT"}
{"file": "core/bridge/src/api.rs", "reason": "delete_book 死代码"}
{"file": "core/core-storage/src/chapter_dao.rs", "reason": "delete_by_book 是否真的死代码"}
{"file": ".trellis/spec/backend/database-guidelines.md", "reason": "SQL 列常量 + upsert 风格 spec"}
```

## 8. check.jsonl 草稿

```jsonl
{"file": ".trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings.md", "reason": "master report 主题：重复 SQL / 重复实现 / 死代码"}
{"file": ".trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings-rust-data.md", "reason": "Wave 1A 详细 findings"}
{"file": ".trellis/tasks/05-20-fix-roadmap/plan/batches/BATCH-08-dao-sql-dedup-and-cleanup.md", "reason": "本批次自身验收清单"}
{"file": ".trellis/spec/backend/database-guidelines.md", "reason": "spec 是否落地"}
```
