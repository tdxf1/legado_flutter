# BATCH-08: SQL 列常量 + DAO 死代码 + upsert 风格统一

## Goal

集中收口 7 条 DAO 层局部 SQL 风格 / 死代码 / 小修问题，以提升一致性与可维护性。所有改动局限在 `core/core-storage/src/` + `core/bridge/src/api.rs`，无业务行为变化。继承 BATCH-07b 落地的 `BOOK_UPSERT_SQL` + `book_upsert_params!` 范式，把 backup_dao 的 books upsert 也接进来；同时清理 BATCH-18a 简化 `delete_book` 后留下的两个孤儿 dao fn。

## What I already know

### 来自 explore 审计（2026-05-20，本批次）

**1. F-W1A-006 — `source_dao.rs` 5 处 29 列 SELECT 字面重复**
- 重复点：`source_dao.rs:137 / 157 / 172 / 187`（4 处 `get_by_id` / `get_enabled` / `get_all` / `get_by_url`）+ `backup_dao.rs:444`（第 5 处独立）
- `book_dao.rs` 已抽 `BOOK_COLUMNS`、`rss_source_dao.rs` 已抽 `RSS_SOURCE_COLUMNS`，**`source_dao` 没有同款常量**
- grep `SOURCE_COLUMNS core/core-storage/src/source_dao.rs` → 0 命中

**2. F-W1A-010 — `add_bookmark` 裸 INSERT，与 `backup_dao::upsert_bookmark` 风格分裂**
- `progress_dao.rs:117-145` 的 `add_bookmark` 用 `INSERT INTO bookmarks(...)` 不带 `ON CONFLICT`
- `backup_dao.rs:683` 的 `upsert_bookmark` 同一张表却走 upsert（`ON CONFLICT(id) DO UPDATE SET ...`）
- 后果：导入备份会覆盖、主端口 add 重复 id 报 SQLite UNIQUE 违反

**3. F-W1A-011 — books upsert 还有 2 处生产代码重复**
- BATCH-07b 已抽 `book_dao.rs:33` 的 `BOOK_UPSERT_SQL` 常量 + `book_upsert_params!` 宏
- `backup_dao.rs:611-676` 的 `upsert_book(tx, b)` 仍是独立的 27 列 inline INSERT + ON CONFLICT，**未复用** `BOOK_UPSERT_SQL`
- test fixtures（`database.rs:1787 / 1871` 等）是 6-8 列 minimal insert，不算重复风险

**6. F-W1A-015 — `cache_dao.get` 静默吞 SQL 错误**
- `cache_dao.rs:13-19`：签名虽 `SqlResult<Option<String>>`，但 `row.get(0).unwrap_or_default()` 把 `rusqlite::Error`（列类型不匹配 / NULL → String 解码失败）替成 `""`
- caller 区分不出 "key 不存在" 和 "value 列读取失败"
- 1 行修复：`row.get(0).unwrap_or_default()` → `row.get::<_, String>(0)` + 对 `Option` 做 `transpose`

**7. F-W1A-016 — `download_dao` 模块级 `static DOWNLOAD_ROOT`**
- `download_dao.rs:9-21`：`RwLock<Option<PathBuf>>` 全局可变状态
- set 路径仅 1 处（`bridge/src/api.rs:722`，FRB 启动时一次 set）
- get 仅 1 处（`download_dao.rs:184` 的 `delete_with_files`）
- 不是 unsound，但 mutable global 不必要：set 只发生 1 次

**8. F-W1A-018 — `delete_book` 残留死 dao fn**
- `bridge/src/api.rs:71-79` 已经简化为单一 `book_dao.delete(&id)`（FK CASCADE 兜底）— BATCH-18a commit `c82713c` 落地
- `chapter_dao.rs:239` 的 `delete_by_book` + `progress_dao.rs:103` 的 `delete(book_id)` — 0 内外部 caller
- 主路径已闭环，剩两个孤儿 fn 可删

**9. F-W1A-054 — `created_at * 1000` 当 Legado PK，秒内冲突风险**
- `legado_field_map.rs:723`：`storage_replace_rule_to_legado_json` 反向序列化时用 `r.created_at * 1000` 当 Legado 的 `id` PK
- 同 1 秒内创建两条 ReplaceRule 导出后会拿同一个 i64 PK，导入 Legado 端 UNIQUE 违反
- 修复：用 `r.created_at * 1000 + (hash(r.id) as i64 & 0xFFFF)` 抖动 + doc-comment 说明

### 不在本批次（独立分支）

- **F-W1A-013** group bitmask round-trip：仅 `legado_field_map.rs:638-666` 补 doc-comment，本批次不做（彻底解需多对多表，超出范围）
- **F-W1A-014** StorageManager 死代码删除：拆 BATCH-08b 单独处理
  - 整个 `core/` 0 外部 caller（仅 `lib.rs:150 / 166` 自家 `#[cfg(test)]` 用）
  - 但删除涉及 7 个 `pub fn xxx_dao()` 出口 + WAL test 迁移到 `database.rs` + error type 从 `Box<dyn Error>` 统一
  - 表面变化重，独立成批方便回滚

## Open Questions

（已收敛）

## Requirements (evolving)

### MVP scope（7 条 finding）

1. **F-W1A-006 — `source_dao.rs` 抽 `BOOK_SOURCE_COLUMNS` 常量**
   - 在 `source_dao.rs` 头部加 `pub(crate) const BOOK_SOURCE_COLUMNS: &str = "id, name, url, source_type, ..."`（29 列，按现有 `book_source_from_row` 列顺序）
   - 4 处 SELECT (`get_by_id` / `get_enabled` / `get_all` / `get_by_url`) 改用 `format!("SELECT {} FROM book_sources WHERE ...", BOOK_SOURCE_COLUMNS)` 或 `concat!`
   - `backup_dao.rs:444` 第 5 处 SELECT 也复用同一个常量

2. **F-W1A-010 — `add_bookmark` 改 upsert（共享 SQL 常量）**
   - `add_bookmark` 改 `INSERT INTO bookmarks(...) ON CONFLICT(id) DO UPDATE SET ...`
   - 抽 `BOOKMARK_UPSERT_SQL` 常量 + `bookmark_upsert_params!` 宏（参考 BATCH-07b 对 books 的范式），与 `backup_dao::upsert_bookmark` 共享
   - 实施前 grep `add_bookmark` 调用方核实没有依赖"重复 id 报错"做正确性检查（至少 1 个 caller 必须是"add 时 caller 已保证 id 唯一"语义，否则改 upsert 会静默吞重复 — 当前预期：bookmark 的 id 由 caller 用 sha256(book_id|chapter_index|paragraph_index) 生成，重复 id = 同一 bookmark 的二次添加，应 idempotent）

3. **F-W1A-011 — backup_dao::upsert_book 复用 BOOK_UPSERT_SQL**
   - `book_dao.rs::BOOK_UPSERT_SQL` + `book_upsert_params!` 提到 `pub(crate)`（当前可能是 module-local）
   - `backup_dao::upsert_book(tx, b)` 改用同一份 SQL + params，或者直接调 `book_dao::upsert_in_tx(tx, &b)`（BATCH-07b 已抽出此 fn）
   - 优先方案：直接调 `book_dao::upsert_in_tx`（更彻底，零 SQL 重复），除非 backup_dao 的字段映射与 book_dao 有差异需要保留 inline

4. **F-W1A-015 — `cache_dao::get` 不再吞 SQL Error**
   - 1 行修：`Ok(rows.next()?.map(|row| row.get(0).unwrap_or_default()))` → `rows.next()?.map(|row| row.get::<_, String>(0)).transpose()`
   - 测试补：构造一个 NULL value 行 / 列类型不匹配行，确认 `get` 返回 Err 而非 `Ok(Some(""))`

5. **F-W1A-016 — `DOWNLOAD_ROOT` 改 OnceLock**
   - `static DOWNLOAD_ROOT: RwLock<Option<PathBuf>>` → `static DOWNLOAD_ROOT: OnceLock<PathBuf>`
   - `set_download_root` 改 `let _ = DOWNLOAD_ROOT.set(canonical);` + doc-comment "重复 set 静默忽略（OnceLock 语义）"
   - `get_download_root` → `DOWNLOAD_ROOT.get().cloned()`
   - 仅动 `download_dao.rs:9-21` 三个 fn，不动 caller

6. **F-W1A-018 — 删除残留死 dao fn**
   - 实施前用 `grep -rn 'delete_by_book' core/` 确认仅有 `chapter_dao.rs:239` 定义点 + `cache_stats_dao.rs:9-10` 注释，0 caller
   - 实施前用 `grep -rn 'progress_dao\.delete\|ProgressDao.*\.delete\(' core/` 确认 `progress_dao.rs:103` 的 `delete(book_id)` 0 caller
   - 删 `chapter_dao::delete_by_book` + `progress_dao::delete(book_id)`，保留它们的同名/相似但活的兄弟 fn（`delete_bookmark` / `delete_by_id` 等）

7. **F-W1A-054 — created_at*1000 PK 抖动**
   - `legado_field_map.rs:723`：`r.created_at * 1000` → `r.created_at * 1000 + (hash_id_u16(&r.id) as i64)`
   - 用 `std::collections::hash_map::DefaultHasher`（无外部 dep）写一个 `fn hash_id_u16(id: &str) -> u16`：hash → cast u16，最低 16 bit 抖动
   - 同步在该字段处加 doc-comment 说明"Legado 端 PK 是 i64 ms 时间戳；本端口 ReplaceRule 真实主键是 String UUID。导出时把 UUID hash 抖动 16 bit 进 PK 低位，避免同 1ms 创建的多条规则导出后 PK 冲突。极端情况下 hash 冲突仍可能（但 65536 内冲突概率极低，可接受）。"

### 测试策略

- 现有测试套件全 PASS：`cargo test -p core-storage --lib` (85/85 baseline) + `cargo test -p bridge --lib` (16/16 baseline)
- 新增（仅测改动行为）：
  - `add_bookmark` 重复 id 不报错（upsert 行为）
  - `cache_dao::get` 列类型不匹配返回 Err
  - `legado_field_map::storage_replace_rule_to_legado_json` 同 created_at 多条规则导出后 id 字段不冲突

### 不在范围内

- F-W1A-013（group bitmask）：本批次不动，后续顺手补 doc 或 BATCH-08b 处理
- F-W1A-014（StorageManager 整删）：拆 BATCH-08b 单独处理

## Acceptance Criteria (final)

- [ ] master finding F-W1A-006 / 010 / 011 / 015 / 016 / 018 / 054 全部消解
- [ ] grep `INSERT INTO books \(` 在 `core/core-storage/src/` 生产代码（非 test fixtures，区分依据：完整 27 列 INSERT 算生产，6-8 列 minimal INSERT 算 fixture）下仅 1 处定义
- [ ] grep `SELECT id, name, url, source_type` 在 `core/` 下仅 1 处（`source_dao.rs::BOOK_SOURCE_COLUMNS` 定义本身）
- [ ] grep `RwLock<Option<PathBuf>>` / `static DOWNLOAD_ROOT.*RwLock` 在 `download_dao.rs` 0 命中
- [ ] grep `delete_by_book` 在 `core/` 下 0 命中（除 commit message / git history）
- [ ] grep `pub fn delete\(.*book_id` 在 `progress_dao.rs` 0 命中
- [ ] `add_bookmark` 重复 id 不再抛 UNIQUE 违反（新增单测验证）
- [ ] `cache_dao::get` 不再 `unwrap_or_default()`（grep 0 命中）
- [ ] `cargo check --workspace` 在 `core/` 下全绿
- [ ] `cargo test -p core-storage --lib` + `cargo test -p bridge --lib` 全 PASS

## Definition of Done

- 所有 7 条 finding 逐条对账（PRD ADR-lite 段落）
- 改动局部、无业务行为变化（`add_bookmark` 行为变化为 idempotent，已确认 caller 语义无依赖）
- `cargo check --workspace` + 测试 PASS
- master report 同步标 "Resolved by BATCH-08"

## Decision (ADR-lite)

**Context**: BATCH-08 路线图原文 9 条 finding。explore 审计确认：F-W1A-014 StorageManager 零外部 caller（可整删，但 7 个 public dao() 出口 + WAL test 迁移 + error type 统一表面变化重）；F-W1A-013 group bitmask 多对多重构超出范围。

**Decision**:
- **本批次执行 7 条**：F-W1A-006 / 010 / 011 / 015 / 016 / 018 / 054
- **F-W1A-013** 跳过（待后续轻量批次或 BATCH-08b 顺手补 doc-comment）
- **F-W1A-014** 拆 BATCH-08b 独立处理
- **F-W1A-016 DOWNLOAD_ROOT**：选 OnceLock（最小 diff，不动 caller）
- **F-W1A-010 add_bookmark**：改 upsert（共享 BOOKMARK_UPSERT_SQL 常量），grep caller 确认无"重复 id 报错"语义依赖

**Consequences**:
- 7 条 finding 闭环
- 风险点：`add_bookmark` 行为变化（重复 id 报错 → 静默覆盖），需 grep caller 核实；`cache_dao::get` 错误传播变化（caller 看到 `Err(rusqlite::Error)` 而非 `Ok(Some(""))`），但 caller 都已经在 `?` 链上，应该无 breakage
- BATCH-08b 待后续启动（StorageManager 整删 + WAL test 迁移）



## Technical Notes

### 修复方向（每条）

**F-W1A-006**：抽 `pub(crate) const BOOK_SOURCE_COLUMNS: &str = "id, name, url, ..."` 在 `source_dao.rs` 头部；4 处 SELECT 改 `format!("SELECT {} FROM book_sources WHERE ...", BOOK_SOURCE_COLUMNS)` 或 `concat!`；`backup_dao.rs:444` 也复用同一个常量（用 `pub(crate)` 让跨文件可见）。与 `book_dao.rs::BOOK_COLUMNS` 风格对齐。

**F-W1A-010**：`add_bookmark` 改 `INSERT INTO bookmarks(...) VALUES(...) ON CONFLICT(id) DO UPDATE SET ...`，与 `backup_dao::upsert_bookmark` 共享 SQL 常量 + `bookmark_upsert_params!` 宏（参考 BATCH-07b 对 books 的玩法）。

**F-W1A-011**：把 `book_dao.rs::BOOK_UPSERT_SQL` 与 `book_upsert_params!` 提到 `pub(crate)`（当前是 module-local），让 `backup_dao::upsert_book` 复用。注意 `book_dao::upsert_in_tx` 已经是 BATCH-07b 抽好的 fn，能否直接 `book_dao.upsert_in_tx(tx, &b)` 替代 backup_dao 的 inline SQL？需读 backup_dao 现状判断。

**F-W1A-015**：1 行修。`Ok(rows.next()?.map(|row| row.get(0).unwrap_or_default()))` 改为 `rows.next()?.map(|row| row.get::<_, String>(0)).transpose()`。

**F-W1A-016**：`static DOWNLOAD_ROOT: RwLock<Option<PathBuf>>` 改 `static DOWNLOAD_ROOT: OnceLock<PathBuf>`；`set_download_root` 改 `set` 一次（重复 set 用 `OnceLock::set` 的 Result 行为，或 silent ignore）；`get_download_root` 直接 `DOWNLOAD_ROOT.get()`。或更彻底：把 `download_root: Option<PathBuf>` 挂到 `DownloadDao` 实例上，构造时传入。
- 需要决定：OnceLock vs 实例字段。前者 minimal diff，后者更彻底但要改 ~10 处 caller（每个 `DownloadDao::new(&conn)` 调用点都要传 root）

**F-W1A-018**：grep 所有 `chapter_dao.delete_by_book` / `progress_dao.delete(` caller，确认 0 处后直接删 fn。预期 0 caller。

**F-W1A-054**：`r.created_at * 1000 + (hash(&r.id) as i64 & 0xFFFF)`（用 std `DefaultHasher` 或 `seahash` workspace dep），把 r.id（uuid String）的 hash 抖动 16 bit。同步在该字段处加 doc-comment 说明 PK 冲突边界。

### 风险点

- 抽列常量后，4 处 SELECT 的列顺序必须与 `book_source_from_row`（已存在）严格一致，否则 row.get(0) 拿错列。需要先读这个 from_row 确认列顺序。
- `add_bookmark` 改 upsert 后，行为变化：原来报错 → 现在静默覆盖。caller 是否依赖"重复 id 报错"做正确性检查？grep `add_bookmark` 调用方核实。
- `OnceLock` 行为：set 第二次会失败（rust 标准库语义）。BATCH-08 内不存在第二次 set，但 spec 化要明确。

## Research References

- 本任务 explore audit（in-context）
- BATCH-07b commit `43fc8cc` — `BOOK_UPSERT_SQL` + `book_upsert_params!` 已落地
- BATCH-18a commit `c82713c` — `delete_book` 已简化，留下两个孤儿 dao fn
