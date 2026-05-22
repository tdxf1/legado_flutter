# Findings — Wave 1A (Rust data/FFI/server tier)

**Scope**: core-storage (21 files) + core/bridge (api.rs / lib.rs / local_book.rs) + core/api-server (main + 7 routes + util/state/error/dto)
**Reviewed at**: 2026-05-19
**File count**: 35
**Lines reviewed**: ~12,560 (excluding `frb_generated.rs` per PRD)

## 统计

### 按严重度
| Severity | Count |
|---|---|
| P0 严重 | 2 |
| P1 主要 | 22 |
| P2 次要 | 19 |
| P3 nice-to-have | 11 |
| **合计** | **54** |

### 按维度
| 维度 | Count |
|---|---|
| A-架构 | 10 |
| B-正确性 | 16 |
| C-性能 | 9 |
| D-安全 | 5 |
| E-代码异味 | 14 |

### 按模块
| 模块 | P0 | P1 | P2 | P3 |
|---|---|---|---|---|
| core-storage/database | 0 | 2 | 2 | 1 |
| core-storage/source_dao | 0 | 3 | 2 | 2 |
| core-storage/chapter_dao | 0 | 2 | 1 | 0 |
| core-storage/backup_dao | 0 | 2 | 2 | 0 |
| core-storage/legado_aes | 1 | 1 | 1 | 0 |
| core-storage/legado_field_map | 0 | 2 | 1 | 0 |
| core-storage/cache_dao | 0 | 1 | 0 | 0 |
| core-storage/download_dao | 0 | 2 | 0 | 0 |
| core-storage/progress_dao | 0 | 0 | 0 | 1 |
| core-storage/rss_*_dao + rss_source_dao | 0 | 0 | 2 | 1 |
| core-storage/lib | 0 | 1 | 0 | 0 |
| bridge/api | 1 | 5 | 6 | 4 |
| bridge/local_book | 0 | 0 | 0 | 1 |
| api-server | 0 | 1 | 2 | 1 |

---

## Findings

### F-W1A-001 [P0 严重][D-安全][core-storage/legado_aes]

**File**: `core/core-storage/src/legado_aes.rs:33-131`

**问题**: 备份加密用 AES-128/ECB + MD5 派生 key，存在严重密码学缺陷且与外界凭据保护语义脱节。

**详细**: ECB 模式不抗模式分析（相同明文块产出相同密文块），MD5 已被证伪不应作 KDF；空密码时 key 退化为已知 MD5("") 等同明文。备份 zip 里 `servers.json` / `web_dav_password` 用此原语保护，本端口又把同一明文密码以"明文存到 `legado_local.json`"的方式写盘（`bridge/api.rs:1407-1429`）。即便算法选型是为兼容原 Legado `BackupAES.kt`，本端口对外也应明确告诉用户"该机制等同弱混淆，不可视为加密"。

**建议**: (1) 对外文档/UI 文案明确"备份密码不是加密强度保护，仅为 Legado 互兼容标记"；(2) 引入额外 AES-GCM + Argon2id 派生的"强加密备份" 选项，旧格式仅保留作 fallback 互兼容；(3) 严格审查所有"已加密"措辞避免误导用户。

**Resolution (BATCH-09, 2026-05-21，缩范围)**: legado_aes.rs 模块顶部 doc 加完整安全警告章节（"⚠ 弱混淆而非真加密"），罗列 ECB/MD5/PKCS7/空密码 4 个具体弱点；`encrypt_legado_aes` / `decrypt_legado_aes` 函数 doc 加 weak 标记 + 引用 finding；模块加 `static WEAK_CRYPTO_WARNED: Once`，首次调 encrypt/decrypt 时打印一次 `tracing::warn!` 提醒运维 / 开发者，避免日志污染。**未做** v2 强加密（AES-GCM + Argon2id）— audit 揭示 legado_aes 模块当前**未投产**（backup_dao 导出明文 JSON，未调 encrypt_legado_aes），零真实用户密文存量场景下提前做 v2 是 over-engineering，留 BATCH-09b 等真正接入加密备份功能时再做。

---

### F-W1A-002 [P0 严重][B-正确性][bridge/api]

**File**: `core/bridge/src/api.rs:933` (`block_on_explore` static runtime)

**问题**: `static RT: OnceLock<tokio::runtime::Runtime>` + `rt.block_on(...)` 在 FRB 同步 fn `explore` 内部直接阻塞。

**详细**: FRB 在 Dart 侧把 `pub fn explore(...)` 暴露为 sync 调用（funcId 同步派发），调用线程是 Dart UI / FRB worker。在该线程上 `block_on` 一个 multi-thread runtime 能走，但若 caller 自身已经在 tokio runtime 中（例如 future 化某个 dart-rust 包装），会触发 "Cannot start a runtime from within a runtime" panic。本仓库其它在线接口（`search_books_online`、`webdav_*`）都正确用 `pub async fn`，唯独 `explore` 走同步包装，成因可能是历史遗留。

**建议**: 把 `explore` 改成 `pub async fn`（与同模块 `search_books_online` 一致），删除 `block_on_explore` + `OnceLock<Runtime>`，让 FRB 走异步派发。

---

### F-W1A-003 [P1 主要][D-安全][core-storage/legado_aes]

**File**: `core/core-storage/src/legado_aes.rs:91-102`

**问题**: 加密路径使用未受保护的随机密文，缺少认证（无 HMAC / GCM tag），任何被篡改的密文在 PKCS7 padding 校验通过时会 silently 解出乱码。

**详细**: 注释里也承认"错密码也能'解出'看似合法的 PKCS7 字节流"。`try_decrypt_or_passthrough_array` 在解密失败时还做 `is_array()` fallback，攻击者只要让明文头是 `[`，就能绕过解密路径。配合 P0-001 弱算法，备份 zip 完整性几乎无保障。

**建议**: 短期：在解密成功后强制 JSON parse，失败即视为密文损坏；长期：见 P0-001 引入 AES-GCM。

**Resolution (BATCH-09, 2026-05-21)**: `try_decrypt_or_passthrough_array` 在 `decrypt_legado_aes` 解密成功后追加强制 JSON Array 校验：(1) `serde_json::from_str` 解析为 `Value`，失败即返回 Err；(2) 若解出非 Array，返回 Err 含具体类型名（Object/String/Number/...）。这把"PKCS7+UTF-8 双过但解出乱码"的攻击窗口完全关上 — servers.json 业务合约就是 Array，解出非 Array 必然密码错或密文损坏。+ 2 单测：`test_try_decrypt_rejects_non_array_after_successful_decrypt`（正确密码加密 Object，解出非 Array → Err）+ `test_try_decrypt_rejects_garbage_when_padding_passes`（9 个错密码全部 Err，不返回乱码字符串）。`decrypt_legado_aes` 本体保留低层比特互通能力不动。

---

### F-W1A-004 [P1 主要][B-正确性][core-storage/database]

**File**: `core/core-storage/src/database.rs:14-53` (`init_database`) + `lib.rs:73-82`

**问题**: WAL 启用后未触发 `wal_autocheckpoint` / `synchronous` 调优，断电时 WAL 内未 checkpoint 的提交可能丢失。

**详细**: `enable_wal=true` 走 `journal_mode=WAL` 但没设 `synchronous=NORMAL` 或 `FULL`，rusqlite 默认是 `NORMAL`，在 Android 设备崩溃 / 电池抽走场景下可能丢最近几条提交。`PRAGMA foreign_keys = ON` 在 `init_database` 设置但每次走 `get_connection` 重新打开连接时也要再设（apiserver 已用 `with_init` 处理，bridge 走 `get_connection` 也设了，OK），但 `core-storage/lib.rs::StorageManager` 的 `pragma_update("journal_mode","WAL")` 只对当前 conn 生效。

**建议**: 显式 `PRAGMA synchronous=NORMAL`、`PRAGMA wal_autocheckpoint=1000`；并在文档里说明"WAL 设置是数据库属性而非连接属性，多 conn 共享同一文件时不必重复设"。

---

### F-W1A-005 [P1 主要][B-正确性][core-storage/database]

**File**: `core/core-storage/src/database.rs:455-494` (`migrate_database`)

**问题**: 迁移函数显式用 `execute_batch("BEGIN")` / `COMMIT` / `ROLLBACK`，不是 RAII；嵌套迁移调用 `migrate_v6` / `migrate_v8` 内部又 `create_tables` 时若发生 panic 会留下泄漏的事务句柄。

**详细**: `Connection::transaction()` 是 RAII（drop 即 rollback），但这里手写 BEGIN/COMMIT。若 `migrate_v11` 中间出错，外层 `result` 走 `ROLLBACK` 是 OK 的；但迁移过程中的某一步出错被 `?` 上抛后再被 outer match 捕获，期间 `migrate_v11` 内部已做的 ALTER TABLE 不会回退（DDL 在 SQLite 是事务性的，但 `BEGIN` + 多 ALTER 形成的 chained DDL 在某些 SQLite 版本里不能回滚 ALTER）。另外整个迁移占一个隐式 transaction 而无超时保护，DB 大时可能阻塞 UI 启动。

**建议**: 用 `conn.transaction()` 替换手写 BEGIN/COMMIT；在迁移前 log DB 大小并加 deferred-write 提示；考虑把"老版本一次迁多步"分批 commit，避免一次 transaction 包含上百条 ALTER。

---

### F-W1A-006 [P1 主要][C-性能 & A-架构][core-storage/source_dao]

**File**: `core/core-storage/src/source_dao.rs:118-185` (`get_by_id` / `get_enabled` / `get_all` / `get_by_url`)

**问题**: 4 个 SELECT 函数硬编码同一份 29-列字段 SQL，未复用 `BOOK_COLUMNS` 风格的常量；SOURCE_UPSERT_SQL 已抽常量，SELECT 没抽，列加减时极易漂移。

**详细**: 与 `book_dao.rs:20-25` `BOOK_COLUMNS` + `book_from_row` 列顺序单一来源的写法不一致。`book_source_from_row` 索引 0..28 与每条 SELECT 列顺序必须严格对齐——一旦改 schema 加列，4 个 SELECT 都要改，遗漏即 silently row.get() 索引越界。

**建议**: 抽 `const BOOK_SOURCE_COLUMNS: &str = "id, name, url, ..."`，4 个 SELECT 用 `format!` 拼，对齐 BookDao 风格。

**Resolution**: Resolved by BATCH-08（commit 待补）— 抽 `pub(crate) const BOOK_SOURCE_COLUMNS: &str = "..."` 在 `source_dao.rs:22`；4 处 SELECT (`get_by_id` / `get_enabled` / `get_all` / `get_by_url`) + `backup_dao::select_all_sources` 第 5 处都改用 `format!("SELECT {} FROM book_sources WHERE ...", BOOK_SOURCE_COLUMNS)`。

---

### F-W1A-007 [P1 主要][B-正确性][core-storage/source_dao]

**File**: `core/core-storage/src/source_dao.rs:69-78`

**问题**: `upsert` 内部 URL-去重逻辑（"URL 已存在则用旧 id"）只在 `upsert` 中做，`batch_insert` 同样有这段逻辑，但 `import_from_json` 走 `batch_insert`，外部 caller 直接调 `upsert` 时若没传 source.id 一致性 bug 会造成 ON CONFLICT(id) 走 UPDATE 而 url UNIQUE 失败。

**详细**: 当传入的 `source` 有 `id=A`，`url=U`，DB 已有 `id=B,url=U`，本逻辑把 effective_id 改成 B 后用 B 走 ON CONFLICT(id) DO UPDATE。语义上是把"指向 A 的请求"变成更新 B 行，调用方拿到 B 返回但还以为自己写的是 A，后续拿 A 查询会找不到。该 silently-rewrite-id 行为应当显式记录或在 API 层抛错让 caller 决策。

**建议**: 在 `upsert` 函数注释中明确"传入 id 与 DB 中 url 已存在的不同 id 冲突时返回 DB 中 id"；或者新增 `try_insert_strict` 严格走 ON CONFLICT 报错版本，让 caller 自己决定语义。

---

### F-W1A-008 [P1 主要][C-性能][core-storage/source_dao]

**File**: `core/core-storage/src/source_dao.rs:188-203` (`delete_batch`)

**问题**: `delete_batch` 在 for 循环里逐条 `execute("DELETE ... WHERE id = ?")`，无事务包裹，N 条 source 触发 N 个 fsync。

**详细**: 与同文件 `batch_insert` 用 `tx = self.conn.transaction()?` 风格不一致。删 50 个书源时会走 50 次磁盘 commit。

**建议**: 包一层 `self.conn.transaction()?`，或改成 `DELETE FROM book_sources WHERE id IN (?, ?, ...)` 单条 SQL（注意 SQLite IN 子句 999 限制，可分批）。

---

### F-W1A-009 [P1 主要][B-正确性][core-storage/chapter_dao]

**File**: `core/core-storage/src/chapter_dao.rs:115-160`

**问题**: `replace_by_book` / `replace_by_book_preserving_content` 拿 `&mut Connection` 开 `tx`，但调用方（如 `bridge/api.rs:1593-1597` `import_local_book`）在同一个 fn 里先用 `BookDao::new(&conn)` 写书再用 `ChapterDao::new(&mut conn)` 写章节——两步独立事务，第二步失败时 book 已写入但 chapters 还是旧数据。

**详细**: `import_local_book` 注释提到"必须先 upsert Book"是为了 FK 约束，但没把两步包成事务。api-server 已经用 `db_transaction` helper（`api-server/src/util.rs:101-131`）在 `bookshelf.rs:179-212` 把 chapter replace + book metadata update 包进同一 tx，但 bridge 端没有等价 helper。

**建议**: 在 `bridge/api.rs` 引入类似 `with_transaction(db_path, |tx| ...)` 的 helper 让 `import_local_book` 等多步 fn 走单事务；或者复用 `core-storage` 现有 transaction helper。

---

### F-W1A-010 [P1 主要][B-正确性][core-storage/chapter_dao]

**File**: `core/core-storage/src/chapter_dao.rs:34-72` (`upsert_using_conn`) + `progress_dao.rs:117-145`

**问题**: `chapters` upsert 用 `content = COALESCE(excluded.content, content)` 保留旧正文是合理设计，但 `progress_dao.add_bookmark` 用 INSERT-only（无 ON CONFLICT），同一 bookmark.id 重复添加会触发 PRIMARY KEY constraint failed 报错。

**详细**: bookmark 主键是 `id`（UUID），重复用同 UUID add 概率极低但调用方手写 id 时会踩坑；与同文件 ChapterDao 一致 upsert 风格不一致。

**建议**: `add_bookmark` 改成 `INSERT ... ON CONFLICT(id) DO UPDATE SET ...`；或文档明确"caller 必须保证 id 全局唯一"。

**Resolution**: Resolved by BATCH-08（commit 待补）— `add_bookmark` 改 upsert（`INSERT ... ON CONFLICT(id) DO UPDATE SET ...`）。抽 `pub(crate) const BOOKMARK_UPSERT_SQL` + `bookmark_upsert_params!` 宏在 `progress_dao.rs:11`，与 `backup_dao::upsert_bookmark` 共享单一来源。重复 id 现在 idempotent 覆盖（caller 通常用 sha256 派生 id，重复 = 同一 bookmark 二次添加）。

---

### F-W1A-011 [P1 主要][C-性能 & A-架构][core-storage/backup_dao]

**File**: `core/core-storage/src/backup_dao.rs:495-578` + `book_dao.rs:101-167` + `bridge/api.rs:609-628`

**问题**: 同一份 `INSERT INTO books (... 27 列) VALUES (..) ON CONFLICT DO UPDATE SET ...` 的 SQL 在 3 处各写一遍（`book_dao.upsert`、`backup_dao.upsert_book`、`source_dao.upsert` 同型问题）。

**详细**: backup_dao 注释里说"避免依赖 BookDao，因为 BookDao 持有 &Connection 可能与事务嵌套冲突"——这是真问题，但代价是列改一处必改 3 处。schema 加 1 字段就漏一处即 silently 不写入 backup。

**建议**: 把 books / book_sources / replace_rules / bookmarks 的 upsert SQL 抽成 `core-storage::upsert_sql::*` 公共常量，或提供 `BookDao::upsert_in_tx(tx: &Transaction, ...)` 让 backup_dao 直接复用 dao 而不必持有 Connection。

**Resolution**: Resolved by BATCH-07b + BATCH-08（commit 待补）— BATCH-07b 已抽 `book_dao::BOOK_UPSERT_SQL` + `book_upsert_params!` 宏；BATCH-08 把它们提到 `pub(crate)`，让 `backup_dao::upsert_book` 直接复用同一份 SQL（删除 ~80 行重复 inline INSERT）。bookmark upsert 由 BATCH-08 同步抽 `BOOKMARK_UPSERT_SQL` 共享（见 F-W1A-010）。书源 upsert 由 BATCH-07 抽 `SOURCE_UPSERT_SQL` 已共享。

---

### F-W1A-012 [P1 主要][B-正确性][core-storage/backup_dao]

**File**: `core/core-storage/src/backup_dao.rs:187-203`

**问题**: 解 zip 时把整个 5 张表 JSON 一次性 `read_to_string` 到 HashMap，没限制单文件大小。

**详细**: 用户上传一个恶意构造的备份 zip（zip-bomb 或单文件几百 MB）会直接 OOM。原 import_backup_zip 走 FRB 同步 fn 调用，整个内存会算到 Dart UI process 里。

**建议**: 在 `read_to_string` 前先 check `entry.size()` (压缩前) 和 `entry.compressed_size()`，超过 50 MB 单文件 / 500 MB 总量就拒绝；或者改成流式解析（serde_json::from_reader）。

**Resolution (BATCH-09, 2026-05-21)**: `import_from_zip` 加双层 cap 防 zip-bomb：(1) `entry.size()` 预检 — central directory 字段做快速拒绝（攻击者可篡改但快路径有效）；(2) `Read::take(MAX_ZIP_ENTRY_SIZE + 1)` 实读 cap — 兜底 size 字段被篡改的场景，实际读出超 50MB 即拒；(3) accumulator `total_decompressed` 用 `saturating_add` 防溢出，超 500MB 总限即拒。两层缺一不可。常量公开 `MAX_ZIP_ENTRY_SIZE = 50 * 1024 * 1024` / `MAX_ZIP_TOTAL_SIZE = 500 * 1024 * 1024`。+ 2 单测：60MB 单 entry zip 应拒（验证单 cap）+ 5 个 KNOWN entry 各 2B 正常 zip 应过（验证 accumulator 不误触）。

---

### F-W1A-013 [P1 主要][A-架构][core-storage/legado_field_map]

**File**: `core/core-storage/src/legado_field_map.rs:618-685` (`storage_book_to_legado_json`)

**问题**: 反向映射 `group_id → bitmask` 只能 set 一位（`1 << (id-1)`），与原 Legado bitmask 多分组语义不兼容；导出再导入 round-trip 会丢失多分组信息。

**详细**: 评论里提到"原 Legado `BookGroup.groupId` 用 bitmask 表示一本书可在多个分组"，本端口 schema 简化成单分组（`Book.group_id` 整数 FK）。导入时用 `legado_group_bitmask_to_id` 取最低位，已经丢失多分组；导出时再往回拼 bitmask 也只能拼一位。`originalGroupBitmask` 存到 `_legado_backup` 是好的兜底，但只在导入路径走，自建分组的 book 导出时没有这个字段。

**建议**: 文档明确"端口不支持单本书多分组，与原 Legado 互导有信息损失"；在 `Book.custom_info_json` 里始终维护 `originalGroupBitmask`，导出时优先用它而不是简单的 `1 << (id-1)`。

---

### F-W1A-014 [P1 主要][B-正确性][core-storage/lib]

**File**: `core/core-storage/src/lib.rs:73-82`

**问题**: `StorageManager::new` 用 `Box<dyn std::error::Error>` 错误类型，与全 crate 其它地方用 `rusqlite::Error` / `String` 不一致；callers 拿到 boxed error 后无法 downcast 区分错误来源。

**详细**: `Default for DatabaseConfig` 里 `path: "legado.db"` 是相对路径，进程 cwd 不同（Android Service vs Activity 启动）落盘位置会不同。`StorageManager` 在 codebase 中实际上**几乎没人用**——bridge/api 全走 `core_storage::database::get_connection(&db_path)` 和 `init_database`；StorageManager 是死代码或半成品。

**建议**: (1) 把错误类型统一成 `rusqlite::Error` 或 `core-storage::Error` 枚举；(2) 评估 StorageManager 是否仍需要——若只为单元测试用可移到 `#[cfg(test)]`；(3) Default `path` 改成 `:memory:` 防误操作。

**Resolution**: Resolved by BATCH-08b（commit 待补）— 选项 (A) 整删：删除 `pub struct StorageManager` + `impl StorageManager`（7 个 dao() 出口）+ `pub struct DatabaseConfig` + `impl Default` + `pub fn init_database` 顶层 wrapper + `#[cfg(test)] mod tests`（含 2 个 WAL 测试）。审计确认外部 0 caller，error type 两个 `?` 站点本来就是 `rusqlite::Error`；wrapper 仅 2 处外部 caller 在 `bridge/tests/download_test.rs`，已替换为 `core_storage::database::init_database`。`lib.rs` 从 169 行缩到 60 行（-109 行）。

**Follow-up — 新 finding (F-W1A-055)**：审计副产物。`StorageManager::new` 是仓库内**唯一**调用 `pragma_update("journal_mode", "WAL")` 的代码路径；删除后**生产 `database::init_database` 不调用任何 journal_mode 相关 pragma**，意味着 production SQLite 跑的是默认 `journal_mode=delete` 而非 WAL。`database.rs:34-49` 的注释强烈暗示意图启用 WAL（BATCH-07b 加了 `synchronous=NORMAL` + `wal_autocheckpoint=1000`，这两个 pragma 仅在 WAL 模式下有意义）。建议：单独立批次评估是否应给 `database::init_database` 加 `pragma_update(None, "journal_mode", "WAL")`，并评估 production DB 文件迁移路径（首次启动时从 `journal_mode=delete` 切到 WAL 是单文件操作不需要外部迁移工具，但要测在已有 DB 上的安全性）。

**Resolution (BATCH-08c, 2026-05-20)**: F-W1A-055 已闭环。在 `database::init_database` 内 `Connection::open` 之后插入 `pragma_update_and_check(None, "journal_mode", "WAL", ...)`，配合既有 `synchronous=NORMAL` + `wal_autocheckpoint=1000` 形成 SQLite 官方推荐组合。启用成功 info!，失败 warn!，不阻塞启动。新增 2 个单测 `test_wal_enabled_on_fresh_init` + `test_wal_persists_across_reopens`（验证 db-level 持久化；下游 `get_connection` / 直调 `Connection::open` 的所有路径自动继承）。`core-storage --lib` 从 89 → 91 PASS。`bridge --lib --tests` 维持 16/16 + 8/8。

**Follow-up — 新 finding (F-W1A-056)**：审计副产物。启用 WAL 后用户 db 目录会多 `legado.db-wal` + `legado.db-shm` sidecar 文件。`core/core-storage/src/backup_dao.rs` 当前只备份主 db 文件，如果备份发起时 WAL 未 checkpoint，-wal 内的未 commit 改动会丢失。修复方向：备份前先 `PRAGMA wal_checkpoint(TRUNCATE)` 把 -wal 数据强制 sync 回主 db，或备份 db + sidecar 三件套。Legado 写量小、autocheckpoint=1000 页（~4MB）频繁，实际丢失风险低，留独立批次审计。Status: Open。

**F-W1A-056 Resolution (BATCH-08d audit, 2026-05-20)**: **Dismissed — finding 基于错误前提**。BATCH-08d audit 推翻"备份会拷贝 db 文件"假设：`backup_dao::export_to_zip` 走 SQL `SELECT` → JSON → zip 路径，全程不接触文件系统层 db 文件。WAL sidecar 对 SQL 层透明：已 commit 数据由 SQLite 引擎自动合并到 SELECT 结果，未 commit 数据按 ACID 隔离语义本就不属于备份范围。Audit evidence：
- `backup_dao.rs:75-130` — `export_to_zip` 通过 `select_all_books / select_all_groups / select_all_bookmarks / select_all_replace_rules / select_all_sources` 走 SQL 读取
- `core/bridge/src/api.rs:1219` (`export_backup_zip`) + `:1275` (`webdav_upload_backup`) — 仅有 2 处 caller，都先 `open_db` 拿 `Connection` 再调 `export_to_zip(conn, ...)`
- 全仓 grep `fs::copy` / `sqlite3_backup_init` / `VACUUM INTO` / `wal_checkpoint` 调用：0 命中（仅 `local_book.rs:126` 的 `fs::copy` 用于复制用户上传的 epub/txt 与 db 备份无关）
- SQLite WAL doc 保证 SELECT 看到合并后的视图（https://sqlite.org/wal.html#concurrency）

**Follow-up — 新 finding (F-W1A-057)**：BATCH-08d 审计副产物，占位防止后续 binary backup 路径漏 checkpoint。当前 `backup_dao::export_to_zip` 走 SQL SELECT 路径与 WAL sidecar 无关（F-W1A-056 dismissed）。但若**未来**新增任何"二进制级"备份路径（`fs::copy` db 文件 / `VACUUM INTO` / `sqlite3_backup_init` / Dart 侧直接拷贝 `legado.db`），那条新路径**必须在备份前**调 `PRAGMA wal_checkpoint(TRUNCATE)` 把 -wal 数据 sync 回主 db，否则会丢失已 commit 但还未 checkpoint 回主 db 的事务。修复触发条件：仅在新增 binary backup 路径的 PR 内联解决，本 finding 单独不修复。Status: Open（占位）。

---

### F-W1A-015 [P1 主要][C-性能][core-storage/cache_dao]

**File**: `core/core-storage/src/cache_dao.rs:13-20`

**问题**: `get` 函数用 `row.get(0).unwrap_or_default()` 在 query map 里，column 类型错误时返回空串而不是错误。

**详细**: `unwrap_or_default()` 把 SqliteFailure 静默吞掉，调用方拿到空字符串以为"键不存在"。`legacy_cache.value` 是 `TEXT NOT NULL`，不会出 NULL，但若日后改 schema 引入 BLOB 字段会立刻 silently 失败。

**建议**: 改成 `row.get::<_, String>(0)` 把 SqlResult 直接传上去，让 caller 决定怎么 fallback。

**Resolution**: Resolved by BATCH-08（commit 待补）— `cache_dao::get` 改 `rows.next()?.map(|row| row.get::<_, String>(0)).transpose()`，错误传播让 caller 区分 "key 不存在" vs "value 列读取失败"。新增单测 `get_propagates_column_type_error_instead_of_swallowing` 验证。

---

### F-W1A-016 [P1 主要][C-性能 & A-架构][core-storage/download_dao]

**File**: `core/core-storage/src/download_dao.rs:9-21`

**问题**: 模块级 `static DOWNLOAD_ROOT: RwLock<Option<PathBuf>>` 是全局可变状态，多 db 实例 / 多进程共用一个。

**详细**: 测试时 set_download_root 设置后会泄漏到下一个测试；多个 Flutter isolate 共用一份配置。Bridge 层在 `download_and_save_chapter` 调 `set_download_root`（api.rs:721），但目录其实由 `db_path` 推断而来，没必要全局保存。

**建议**: 把 `download_root` 作为参数传到 `DownloadDao` 构造函数；删除 `static DOWNLOAD_ROOT`。

**Resolution**: Resolved by BATCH-08（commit 待补）— `static DOWNLOAD_ROOT: RwLock<Option<PathBuf>>` 改 `OnceLock<PathBuf>`（minimal diff，不动 caller）；`set_download_root` 重复 set 静默忽略（OnceLock 语义）；`get_download_root` 直接 `DOWNLOAD_ROOT.get().cloned()`。仍是模块级全局，但去掉 mutable RwLock 噪音；构造参数化方案的成本（10+ caller 改动）超出本批次范围，留待后续重构。

---

### F-W1A-017 [P1 主要][B-正确性][core-storage/download_dao]

**File**: `core/core-storage/src/download_dao.rs:164-183` (`create_task_with_chapters`)

**问题**: 手写 `BEGIN` / `COMMIT` / `ROLLBACK` 逻辑而不是 RAII transaction，且 `ROLLBACK` 用 `let _ = ` 忽略错误。

**详细**: `self.conn.execute("BEGIN", [])` 在嵌套调用时会报错（SQLite 不允许嵌套显式 transaction）。用 `Connection::transaction()` 是更稳的写法。`let _ = ROLLBACK` 在 commit 失败之外的 panic 路径不会触发，泄漏一个 open transaction。

**建议**: 改成 `let tx = self.conn.transaction()?; ... tx.commit()`；删除手写 BEGIN/COMMIT。

---

### F-W1A-018 [P1 主要][B-正确性][bridge/api]

**File**: `core/bridge/src/api.rs:72-80` (`delete_book`)

**问题**: `chapter_dao.delete_by_book` 与 `progress_dao.delete` 各用 `let _ = ...` 吞掉错误，只 propagate 最后一步 `book_dao.delete` 的错误。

**详细**: chapters / progress 删除失败但 book 行删除成功时 caller 拿到 Ok，留下孤儿 chapters / progress 数据。schema 上 chapters 有 `ON DELETE CASCADE`（database.rs:162）会兜底删除 chapters，但 `delete_by_book` 显式调用是冗余——不知道是否 caller 关闭了 foreign_keys pragma 兜底。progress 表也有 `ON DELETE CASCADE`，所以这两行**完全是死代码**。

**建议**: 直接删除 `chapter_dao.delete_by_book` 与 `progress_dao.delete`；让 SQLite FK CASCADE 处理。或者写注释说明"本地维护一致性，防 PRAGMA foreign_keys 被外层关掉"。

**Resolution**: Resolved by BATCH-18a + BATCH-08（commit 待补）— BATCH-18a (`c82713c`) 已把 `bridge::api::delete_book` 简化为单一 `book_dao.delete(&id)`，依赖 SQLite FK CASCADE 兜底；BATCH-08 删除残留的两个孤儿 dao fn（`chapter_dao::delete_by_book` + `progress_dao::delete(book_id)`），原位补 `//` 注释说明历史背景与未来重新引入的指引。`database.rs::test_progress_dao` 测试同步迁移到 `book_dao.delete` 触发 CASCADE 路径。

---

### F-W1A-019 [P1 主要][C-性能][bridge/api]

**File**: `core/bridge/src/api.rs:1066-1109` (`apply_replace_rules_impl`)

**问题**: 全局 `Mutex<ReplaceRulesCache>` 在每次 `apply_replace_rules` 调用都被 lock 一次，章节切换时 reader 端可能 burst 调用，主线程串行化。

**详细**: 注释里说"replace_all 在 lock 外跑"是好的，但 lock 内还有 `get_or_load_rules` 的 `||` 闭包会执行 SQL（DB io 在 mutex 内），第一次冷启动几十 ms 阻塞所有并行 reader。FRB Mode `Sync` 调用走 Dart UI worker，长时间 lock 会卡主线程。

**建议**: 把 `get_or_load_rules` 内的 SQL 调用移到 lock 外（先释放 lock 拿规则列表，再加锁更新缓存）；或者用 `parking_lot::RwLock` 让多读者并发。

**Resolution (BATCH-09, 2026-05-21)**: `apply_replace_rules_impl` 重构为三阶段 SQL-out-of-lock 模式：(1) Phase 1 —— 加锁 + `try_get_rules` 只读 probe，命中即返回 `Some(Arc)` 释放锁；(2) Phase 2 —— 锁外跑 SQL（`open_db` + `dao.get_enabled`）；(3) Phase 3 —— 重新加锁 + double-check（其它线程可能在 SQL 期间已填好同 generation 的 cache）→ 用别人的或 `store_rules` 存自己的 + `ensure_regex_generation` + 编译 regex。`ReplaceRulesCache` 加新方法 `try_get_rules`（只读 probe，不分配不写）+ `store_rules`（只写）；旧 `get_or_load_rules` 标 `#[cfg(test)]` 保留供 cache_concurrency_tests 复用。所有 16 个 bridge tests 通过，**关键 generation 隔离不变量** `unified_cache_keeps_generations_isolated` 仍过。生产路径 SQL 不再持锁，章节切换 burst 时 reader 主线程不再串行化。

---

### F-W1A-020 [P1 主要][D-安全][bridge/api]

**File**: `core/bridge/src/api.rs:1407-1429` (`set_backup_password`) + `1432-1447` (`get_backup_password`)

**问题**: 备份密码以**明文** JSON 写盘 (`legado_local.json`)，权限取决于上层 sandbox。

**详细**: Android app 内部目录虽然 sandboxed，但 root 设备 / `adb pull` / 备份导出时密码会泄漏。注释里说"原 Legado 也只加密导出 zip 内的字段，不加密本机 prefs"——参考实现的安全性不能成为本端口的理由。

**建议**: 用 Android Keystore 包裹一次（FRB 提供 native side hook 即可），iOS 用 Keychain；至少在文件名前缀加 `.protected_` 让用户感知到敏感性。

**Resolution**: BATCH-03b (2026-05-22) — 选 Dart 端 secure_storage 方案：复用 BATCH-03 已为 webdav_password 建好的 `flutter_secure_storage` 基础设施（Android Keystore-backed EncryptedSharedPreferences / iOS Keychain）。`webdav_config_page.dart` load 路径优先 `readSecret('backup_password')`，miss 时回退 `rust_api.getBackupPassword(...)` 读旧 `legado_local.json` 字段，有值则迁到 secure_storage + 调 `set_backup_password` 传空串清理（保留 .json 文件其他字段）。save 路径单行 `writeSecret('backup_password', _backupPwdCtl.text)`。Rust 端 `set_backup_password` (line 1452) + `get_backup_password` (line 1510) 加 deprecate doc 注释——**不**加 `#[deprecated]` attr（dart 端迁移路径仍要调）+ FRB funcId 71/72 binary contract 保留以备未来 backup zip 加密功能（如真接入）复用，避免 binding regen 风险。新增 `flutter_app/test/backup_password_secure_test.dart` 4 case 覆盖 secure_storage 命中 / 迁移路径 / 双空 / save 写入；改 `webdav_config_page_test.dart` 第三 case 断言从 setBackupPassword override 调用 → secure_storage fake debugStore 命中。凭据存储主题（F-W1A-020 + F-W2B-001 + F-W1A-023 等）整体闭环。task: 05-22-batch-03b-backup-password-secure。

---

### F-W1A-021 [P1 主要][B-正确性][bridge/api]

**File**: `core/bridge/src/api.rs:730-790` (`download_and_save_chapter`)

**问题**: 多次开 `open_db` 拿连接，无事务，章节 status update + recompute_download_task_status 两步 SQL 之间任何错误都会留下"已下载文件 + status=2 但 task progress 不一致"的脏数据。

**详细**: 函数内部 conn 至少打开 3 次（734、745、782），每次都从头连。再加上 `recompute_download_task_status` 自身有 4 个 SELECT/UPDATE，整链路 ~7 次独立 commit。中间任一 commit 失败，DB 就走样。

**建议**: 改成 `let mut conn = open_db(...)?; let tx = conn.transaction()?;` 一次性包；或仿 api-server 的 `db_transaction` helper 统一封装。

---

### F-W1A-022 [P1 主要][B-正确性][bridge/api]

**File**: `core/bridge/src/api.rs:733-741` (Empty error path) 

**问题**: `Err(core_source::ParserError::Empty)` 分支在 update_chapter_status 失败时直接 return Err 不再 recompute task status，可能让 task 卡在 status=1 永不结束。

**详细**: `match content` 三个分支里只有 `Ok(c)` 路径走完了完整的 update_chapter_status + recompute_download_task_status；`Empty` / 一般 Err 路径调了 update_chapter_status(status=3, ...) 也调了 recompute_download_task_status，但写法靠人眼对齐，下次改动很容易漏一处。

**建议**: 抽 helper `mark_chapter_failed(dao, task_id, chapter_id, error_message)` 把"update + recompute" 包到一处；三个分支都统一调它。

---

### F-W1A-023 [P1 主要][A-架构][api-server]

**File**: `core/api-server/src/main.rs:108-119`

**问题**: token 没设环境变量时打 warn 并生成临时 UUID，但**在日志里输出 token 明文** —— `tracing::warn!("...token for this run: {}", generated)`。

**详细**: 日志通常进 stdout/stderr，可能被运维系统/容器日志收集。攻击者能读日志即拿到 token。注释说"a local dev session is still ergonomic"，但 dev 体验不应以记录敏感凭据为代价。

**建议**: 记录 `token_set=true / token_set=false`，不打印实际值；在控制台单独以特殊路径（stderr 一行 + 提示用户复制）输出，且只输出一次（首次启动），后续不重复打。

**Resolution (BATCH-23, 2026-05-21)**: Resolved。`tracing::warn!` 改为只 log 前 8 char 作 fingerprint（`generated ephemeral token (fingerprint: {}…)` 格式），不进结构化日志的完整 token 走 `eprintln!` 一次性写到 stderr。op 仍能定位本次启动用了哪个 token，但 log aggregator / docker logs / journalctl 等 sink 不会落库完整 token。生产部署强烈建议设 `LEGADO_API_TOKEN` 显式提供，不依赖 ephemeral fallback。

---

### F-W1A-024 [P2 次要][E-代码异味][core-storage/database]

**File**: `core/core-storage/src/database.rs:587-686`

**问题**: 12 个 `migrate_v*` 函数大量重复 `ALTER TABLE ADD COLUMN` + `pragma_table_info` 列存在判定模式。

**详细**: v6/v8/v9/v11 都是同样的"列名+类型 + check existence"循环。读起来要逐函数 diff 才能看出"这一版加了哪几列"。

**建议**: 抽 helper `add_column_if_missing(conn, table, name, ddl_type)`；每个 migration 调几行。重复代码 ~150 行可压到 ~40 行。

---

### F-W1A-025 [P2 次要][E-代码异味][core-storage/database]

**File**: `core/core-storage/src/database.rs:589-614` (`migrate_v6`)

**问题**: `migrate_v6` 调用 `create_tables(conn)?` 作为"schema baseline guard"，但当 db 已经 v6+ 就跑了一遍 IF NOT EXISTS——纯浪费。

**详细**: 防御性写法可以理解（注释 R65），但等价于"我不信任前面迁移做对了"，应该 fix 前面的迁移而不是每次都重 create。

**建议**: 删除 `migrate_v6/v8` 内部的 `create_tables` 调用；如担心测试 fixture 脏，改为只 create 缺失的某张特定表。

---

### F-W1A-026 [P2 次要][E-代码异味][core-storage/source_dao]

**File**: `core/core-storage/src/source_dao.rs:611-797`

**问题**: `denormalize_rule_keys` 与 `normalize_rule_keys` 维护两份完全镜像的字段映射列表（25 对），无单一来源。

**详细**: 注释里也提到"Keep this list in sync with `core-source legado::import::normalize_rule_keys`"——三处维护一份字段表。

**建议**: 抽 `const FIELD_MAPPING: &[(&str, &str)] = &[...]`，正向 / 反向用同一份；并在 core-source 端引用（pub use 或者 `core_storage::FIELD_MAPPING`）避免漂移。

---

### F-W1A-027 [P2 次要][E-代码异味][core-storage/source_dao]

**File**: `core/core-storage/src/source_dao.rs:481-551` (`deser_flexible_header` / `deser_flexible_i64`)

**问题**: 两个 deserialize_with helper 包装得很复杂，读起来像 boilerplate。

**详细**: 实际是把"字符串/对象/数组/null 都接受"的兼容反序列化器手写出来。`serde_with` crate 提供 `OneOrMany`、`PickFirst` 等已成熟方案，用 derive 即可。

**建议**: 引入 `serde_with`；新代码用 derive 简化。如果不愿引入新依赖，至少把这两个函数移到 `mod compat;` 单独文件减小本文件长度。

---

### F-W1A-028 [P2 次要][B-正确性][core-storage/chapter_dao]

**File**: `core/core-storage/src/chapter_dao.rs:185-201` (`get_by_url`)

**问题**: `get_by_url` 没限定 `book_id`，跨书的相同 URL 会返回不确定的某一行。

**详细**: chapters 表 schema 没有 `UNIQUE(book_id, url)`，理论上两本书可以共享同一 chapter URL（比如静态站章节复用）。`get_by_url` 名义上是按 URL 查，调用方期望返回唯一行——目前调用方不明确，可能是诊断用，但仍有歧义。

**建议**: 改名为 `find_first_by_url` 强调"返回首个匹配"；或者添加 `book_id` 参数。

---

### F-W1A-029 [P2 次要][C-性能][core-storage/backup_dao]

**File**: `core/core-storage/src/backup_dao.rs:740-758` (export 路径里 7 个 sub-Map / Object 转换)

**问题**: 5 个 `Vec<Value>` 各自 `to_string_pretty`，每条 record 都过 serde_json + Pretty printer，几千本书时 CPU 占用明显。

**详细**: 尤其 `bookSource.json` 一份 5 MB 级 JSON，pretty 打印慢且无意义（用户不会手编辑）。

**建议**: 改用 `to_string`（无缩进），文件大小和 CPU 都减半；如果用户有 diff 需求另开 export-pretty fn。

---

### F-W1A-030 [P2 次要][E-代码异味][core-storage/backup_dao]

**File**: `core/core-storage/src/backup_dao.rs:236-247`

**问题**: 加载已有 sources 的代码块用 `rows.flatten()` 把 SqlResult error 静默吞掉。

**详细**: `query_map` 的结果是 `MappedRows<F>`，`flatten()` 用在 `Result<Result<T,E>>` 把外层 Err 也丢掉，等同于 `for r in rows.flatten()` 跳过任何返回错误的行。SQL 错误（schema 损坏 / 锁竞争）会 silently skip 然后用部分数据继续，破坏映射表完整性。

**建议**: `for r in rows.collect::<SqlResult<Vec<_>>>()? { ... }`，错误传播上去。

**Resolution (BATCH-23, 2026-05-21)**: Resolved。两处 `for r in rows.flatten()` 改为 `for r in rows { let r = r.map_err(|e| format!("读 ... 行失败: {}", e))?; ... }` 显式 `?` 向上传播。错误从 silent skip 变为可观测，caller 链上层能 surface 给用户。注：原 finding 报 L236-247，实际 BATCH-08 后行号变成 L257 (sources) + L327 (books)。

---

### F-W1A-031 [P2 次要][B-正确性][core-storage/legado_aes]

**File**: `core/core-storage/src/legado_aes.rs:74-86`

**问题**: `pkcs7_unpad` 对 padding 字节的校验非 constant-time，理论上有 padding-oracle 攻击面。

**详细**: 但本端口在 ECB 模式下已经没有 padding-oracle 概念（ECB 不需要 IV/MAC，攻击者可以直接换块），所以非 ct 校验影响极小。仍属"密码学 best practice 缺失"。

**建议**: 主要靠 P0-001 整体方案改进；本节单独修没意义。

---

### F-W1A-032 [P2 次要][A-架构][bridge/api]

**File**: `core/bridge/src/api.rs:240-250` (`get_source_for_download`) + `2301-2368` (`storage_to_source_book_source`)

**问题**: storage::BookSource → core_source::types::BookSource 转换函数在 bridge/api.rs 与 api-server/util.rs 各有一份，几乎完全重复。

**详细**: 两份代码都做同样的"5 个 rule_xxx 字段从 String 反序列化为 Object"，列名、错误消息略有差异。改一处 schema 就要同时改两处。

**建议**: 把 `storage_to_core_source` 移到 `core_storage` crate 顶层（或独立 `core-bridge-types` crate），bridge/api-server 共用。

---

### F-W1A-033 [P2 次要][C-性能][bridge/api]

**File**: `core/bridge/src/api.rs:43-50` (`get_all_books`) + 几乎所有 `get_*` 类 fn

**问题**: 每次调用都重新 `open_db` 打开 SQLite 连接，没有 connection pool。

**详细**: api-server 端有 r2d2 pool（state.rs:13-19），但 bridge 端每个 fn 都 fresh open。短期高频调用（reader 翻页 + apply_replace_rules + get_chapter_content）会有 conn open 开销，特别是首次的 `PRAGMA foreign_keys = ON`。

**建议**: 在 bridge crate 引入类似 `static POOL: OnceLock<r2d2::Pool>`，按 db_path 缓存；或者复用 api-server 的 SqlitePool 抽到 core-storage。

---

### F-W1A-034 [P2 次要][E-代码异味][bridge/api]

**File**: `core/bridge/src/api.rs:1-2595` 

**问题**: 单文件 2595 行，承担书架 / 章节 / 进度 / 书签 / 在线搜索 / 下载 / 备份 / WebDAV / 本地书 / 阅读时长 / 缓存 / RSS / 订阅 14 个域。

**详细**: 文件级耦合度已经高得离谱，新加 fn 都不知道塞哪个 section。FRB 要求 fn 是 pub 顶层，不是非要全堆一文件。

**建议**: 拆 `api/` 子模块（每个域一个文件），用 `pub use` 重新导出到 lib.rs；FRB codegen 应能跨多文件扫描 pub fn。或者至少切到 `api_books.rs`、`api_search.rs`、`api_rss.rs` 等 6-8 个文件。

---

### F-W1A-035 [P2 次要][D-安全][bridge/api]

**File**: `core/bridge/src/api.rs:1466-1602` (`import_local_book`)

**问题**: `documents_dir` 与 `file_path` 都是 caller 传入的字符串，没做"file_path 必须在 documents_dir 内"或"必须是绝对路径"的校验。

**详细**: caller 通常是 Flutter file picker（受 Android Storage Access Framework 限制），但若 attacker 让 app 以 hijacked URL 调用此函数，理论可以读应用沙箱外文件复制到 `local_books/`。`copy_to_local_books_dir` 内部用 `fs::copy(src, &dest_path)`——src 来自 caller，没限制。

**建议**: 在 import_local_book 入口做：(1) `file_path` 必须是绝对路径；(2) canonicalize 后必须在用户期望的几个目录前缀下；(3) 拒绝 symlink。

---

### F-W1A-036 [P2 次要][E-代码异味][bridge/api]

**File**: `core/bridge/src/api.rs:472-552` (`search_with_source_from_db_v2`) vs `533-553` (`search_with_source_from_db`)

**问题**: 两个 search fn 几乎相同，仅返回包装格式不同。

**详细**: v2 用 `[{ok, error, source_name, search_url}]` 包装，旧版返回扁平 results 数组。FRB 暴露两份 fn 让 Dart 侧不知道用哪个。

**建议**: 选定一个语义保留，删除另一个；如果都要保留，给 v1 加 `#[deprecated]`。

---

### F-W1A-037 [P2 次要][B-正确性][bridge/api]

**File**: `core/bridge/src/api.rs:1416-1417`

**问题**: 读 `legado_local.json` 时 `serde_json::from_str(&text).ok().and_then(...).unwrap_or_default()` 完全静默 schema 损坏。

**详细**: 用户手编辑了 JSON 出错 / 文件被截断时会全部丢失（包括以前设的密码），但不通知用户。set_backup_password 之后会写一份新 JSON 也会把所有其它字段丢掉。

**建议**: 文件损坏时 log warn + 保留原文件备份（`legado_local.json.bak`）；至少不要 silently overwrite。

**Resolution (BATCH-23, 2026-05-21)**: Resolved。`set_backup_password` 在 JSON 解析失败 / 顶层非 object 时，把损坏内容写到 `legado_local.json.<unix_ts>.bak` 副本（timestamp 后缀防覆盖既存 .bak），同时 `tracing::warn!` 记录损坏原因；然后才用空 Map 重置（行为等价，但有备份兜底用户可手工恢复）。`get_backup_password` 不写文件，加 `tracing::warn!` log 让 op 知道配置已损坏。注：原 finding 报 L1416-1417，实际位于 set_backup_password (L1373-1395)。

---

### F-W1A-038 [P2 次要][A-架构][api-server]

**File**: `core/api-server/src/main.rs:20-29` (`is_loopback`) + `state.rs:50-63`

**问题**: `is_loopback` 与 `allowed_origin_hosts` 各自硬编码 IPv4/IPv6 loopback 字面量，逻辑重复且不完全一致（main.rs 含 "[::1]" 字面量、state.rs 也含 "[::1]"，但 origin parse 出来的 host 不会带方括号）。

**详细**: `url::Url::host_str()` 对 `http://[::1]/` 返回 `::1`（不带括号），所以 state.rs:54 的 `"[::1]"` 永远匹配不上。是否生效不影响功能（127.0.0.1 / localhost 的逻辑覆盖了大部分场景），但代码读起来不准确。

**建议**: 删除 state.rs 中 `"[::1]"` 字面量；或者抽 helper `IpAddr::is_loopback`-based check。

---

### F-W1A-039 [P3 nice-to-have][A-架构][core-storage/database]

**File**: `core/core-storage/src/database.rs:1-1077` (整个文件 2300 行)

**问题**: 单文件 2300 行，DDL 字符串 + 12 个 migration + 测试堆在一起。

**建议**: 拆 `database/schema.rs`（DDL 常量）、`database/migrate.rs`（migrate_v* fn）、`database/init.rs`（init_database / get_connection）。

---

### F-W1A-040 [P3 nice-to-have][E-代码异味][core-storage/source_dao]

**File**: `core/core-storage/src/source_dao.rs:704-706`

**问题**: `clean_legado_url(url)` 只做 `trim`，函数名暗示更复杂的清理逻辑。

**建议**: 内联，删掉函数；或者实现真正的 URL 解析校验。

**Resolution (BATCH-23, 2026-05-21)**: Resolved。`clean_legado_url` 删除，caller 内联为 `url.trim().to_string()`。注：原 finding 报 L704-706，实际 BATCH-08 后行号变成 L724/L729-731。

---

### F-W1A-041 [P3 nice-to-have][E-代码异味][core-storage/progress_dao]

**File**: `core/core-storage/src/progress_dao.rs:94-100` (`add_read_time`)

**问题**: 函数名 `add_read_time` 与字段单位不一致——参数 `additional_ms` 暗示毫秒，但 `read_record_dao::add_time` 用秒。两个 DAO 单位混用。

**详细**: `BookProgress.read_time` 注释为"累计阅读时长（毫秒）"（models.rs:137），`ReadRecord.read_time` 注释为"累计阅读时长（秒）"。两个时长字段语义重叠（同一本书的"读多久"），单位还不同。

**建议**: 统一成秒，删除其中一个；或者重命名 `BookProgress.read_time_ms` 让单位显式。

---

### F-W1A-042 [P3 nice-to-have][E-代码异味][core-storage/rss_*_dao]

**File**: `core/core-storage/src/rss_article_dao.rs:64` + `rss_star_dao.rs:34-38`

**问题**: rss_article_dao.upsert_batch 用 `unchecked_transaction()` 跳过 rusqlite 内部状态检查，理由不充分。

**详细**: `unchecked_transaction()` 文档说"caller must ensure no other transaction is open"。本场景下 conn 是 `&Connection` 不是 `&mut`，意图是想在不持有可变借用的情况下开 transaction——但这违背了 rusqlite 的 lifetime 设计。如果 caller 在外层已经开了 transaction（如 backup_dao 做整体导入），unchecked_transaction 会嵌套出错。

**建议**: 改成接受 `&mut Connection`；或者提供 `_in_tx` 变体让 caller 传入 &Transaction，rusqlite 推荐做法。

---

### F-W1A-043 [P3 nice-to-have][E-代码异味][bridge/api]

**File**: `core/bridge/src/api.rs:923-936` (`block_on_explore`)

**问题**: 见 P0-002，函数本身是 anti-pattern。即使 P0 修复后该函数应该删除。

**建议**: 删除整个 helper。

---

### F-W1A-044 [P3 nice-to-have][E-代码异味][bridge/api]

**File**: `core/bridge/src/api.rs:1173-1242` (ReplaceRulesCache 内部结构)

**问题**: cache 字段 `regex_entries: HashMap<(String, String), Option<Regex>>` key 包含 pattern 字符串，但 pattern 已经在 rule.pattern 里。`(rule_id, pattern)` 元组完全是为防"caller 改了 pattern 没改 generation"——而 generation 已经覆盖此场景，pattern 字段冗余。

**建议**: key 改成 `String`（rule_id），简化 `get_or_compile_regex` 签名。

---

### F-W1A-045 [P3 nice-to-have][A-架构][bridge/api]

**File**: `core/bridge/src/api.rs:1308-1339` (`webdav_upload_backup`)

**问题**: 用 `tempfile` 写到磁盘再读回内存上传，多余 IO；可以直接 `Vec<u8>` 内存中 export。

**详细**: 备份 zip 通常 < 50 MB，全内存可接受。注释里说"NamedTempFile 自动清理"是好处理但不必要——直接 `Vec<u8>` PUT 更简单。

**建议**: `core_storage::backup_dao::export_to_zip_bytes(&conn) -> Result<Vec<u8>>` 单独 fn。

---

### F-W1A-046 [P3 nice-to-have][E-代码异味][bridge/api]

**File**: `core/bridge/src/api.rs:5`

**问题**: `use regex::Regex;` 在 module-level 导入，但只在 `ReplaceRulesCache` 里用。

**建议**: 把 `use regex::Regex;` 缩到 `mod replace_rules;` 子模块（如果按 P2-034 拆文件）。

---

### F-W1A-047 [P3 nice-to-have][A-架构][api-server]

**File**: `core/api-server/src/dto.rs:1`

**问题**: 文件只有一行注释 "DTOs will be added as endpoints are implemented." — 6 个月没动过的 placeholder。

**建议**: 删除整个 dto.rs；DTOs 已经分散在每个 routes/* 文件里定义。

**Resolution (BATCH-23, 2026-05-21)**: Resolved。整文件删除（grep `mod dto|use.*dto` 在 api-server 下 0 命中确认 orphan）。

---

### F-W1A-048 [P3 nice-to-have][E-代码异味][bridge/local_book]

**File**: `core/bridge/src/local_book.rs:33-34`

**问题**: 两个 `pub(crate) const` 命名 `LOCAL_SOURCE_ID` / `LOCAL_BOOK_URL_KEY` 字面量重复 — `loc_book` 既是 url scheme 又是 source.url 字段。

**详细**: 注释中也说"源 url=loc_book，但 source_id 列存 'local'"——两个值各取所长易混淆。

**建议**: 加文档清晰区分；或者把 source_id 也改成 "loc_book" 让两个字面量一致。

---

### F-W1A-049 [P2 次要][C-性能][core-storage/rss_*_dao]

**File**: `core/core-storage/src/rss_article_dao.rs:95-130` (`list_by_origin_sort`)

**问题**: limit/offset 用 `format!` 拼到 SQL 字符串，未参数化。

**详细**: `limit: i64` 是 caller 传入的可控数字，理论上没注入风险（i64 to_string 不可能产生 SQL 关键字）。但 SQLite 推荐用 `?` 绑定保持一致；当前写法会让 prepared statement cache 命中率降低（每个不同 limit 都生成新 SQL）。

**建议**: 用 `LIMIT ? OFFSET ?` 绑定参数。

---

### F-W1A-050 [P2 次要][A-架构][core-storage/rss_source_dao]

**File**: `core/core-storage/src/rss_source_dao.rs:296-298`

**问题**: 注释里说"`OptionalExtension` 引用保住"，但代码确实没 import OptionalExtension（其它 DAO 也没用到）—— 注释保留 dead reference。

**建议**: 删除注释；如果 DAO 改用 `query_row(...).optional()`，再加回 import。

---

### F-W1A-051 [P2 次要][B-正确性][core-storage/legado_field_map]

**File**: `core/core-storage/src/legado_field_map.rs:118-127` (`ms_to_seconds_smart`)

**问题**: `> 10_000_000_000` 阈值在 2286 年才被超过——长期 OK，但是用 `.abs()` 处理负时间戳无意义（chrono 不会返回负时间戳除非时钟错乱）。

**详细**: 不严重，但启发式算法在边界数据下行为难预测。如果备份格式版本演进到 7 万年代以后……（笑）

**建议**: 文档明确"调用方应已知字段单位，本函数仅作 best-effort 兜底"；并 cap 在 `i64::MAX / 1000` 范围内。

---

### F-W1A-052 [P2 次要][D-安全][api-server]

**File**: `core/api-server/src/main.rs:46-57` (`origin_allowed`)

**问题**: 如果 `LEGADO_HOST=0.0.0.0`（绑定所有接口），所有 Origin host 都会变成"同源"。

**详细**: state.rs:53 的 match 把 `"0.0.0.0"` 也算 loopback，于是 allowed_origin_hosts 加上 `127.0.0.1/localhost/::1`。但本身 `0.0.0.0` 作为 host 字符串永远不可能等于浏览器 Origin 里的实际 IP。所以场景比看起来安全：用户访问 `http://server-ip:8787` 时 Origin 是 `server-ip`，不在 allowed 列表里——但用户浏览器又能连上，这时会 403。需要测试此场景。

**建议**: 当 bind_host=0.0.0.0 时，文档明确"必须额外配置 LEGADO_ALLOWED_ORIGINS 环境变量"；否则 LAN 内浏览器访问会被 403 误伤。

---

### F-W1A-053 [P3 nice-to-have][A-架构][core-storage/source_dao]

**File**: `core/core-storage/src/source_dao.rs:282-353` (`import_from_json` 双格式探测)

**问题**: 双格式探测先尝试内部格式 deserialize 再 fall back 到 Legado 格式——失败时构造的错误信息缺乏上下文（用户不知道哪个格式失败）。

**建议**: 失败时返回一个组合错误：`"内部格式: ..., Legado 格式: ..."`。

---

### F-W1A-054 [P1 主要][A-架构][core-storage/legado_field_map]

**File**: `core/core-storage/src/legado_field_map.rs:721` (`storage_replace_rule_to_legado_json`)

**问题**: 把 `r.created_at * 1000` 当 Legado 主键 `id`，多条规则 created_at 相同（同时批量导入）时主键冲突。

**详细**: 原 Legado ReplaceRule.id 在 schema 上不是 created_at，是独立的自增 id。本端口反向映射时直接用 created_at*1000 充当 id 实属应急措施，导出数组里多个 id 重复时原 Legado 导入会冲突（取决于其 import 是否容忍）。

**建议**: 用 `r.id` 字符串 hash 出一个 i64，或者用一个全局递增计数器。

**Resolution**: Resolved by BATCH-08（commit 待补）— `storage_replace_rule_to_legado_json` 改 `r.created_at * 1000 + (hash_id_u16(&r.id) as i64)`：高 48 位是 ms 时间戳，低 16 位是 UUID hash 抖动。同 ms 多条规则导出后 PK 不再冲突（< 1/65536 概率）。新增 `hash_id_u16` helper（基于 std `DefaultHasher`，无外部 dep）+ `pk_jitter_avoids_same_ms_collision` / `pk_is_stable_for_same_id` 单测验证。

---

## 审查覆盖度自评

我**仔细读完**的文件：`database.rs`（核心 schema/迁移）、`book_dao.rs`、`source_dao.rs`、`chapter_dao.rs`、`backup_dao.rs`（前 700 行 + import 路径）、`legado_aes.rs`、`legado_field_map.rs`（前半）、`bridge/api.rs`（全 2595 行重点 sweep）、`bridge/local_book.rs`、`api-server/main.rs / state.rs / util.rs / error.rs`、`api-server/routes/{bookshelf, reader, search, sources, sse, replace_rules, explore, mod, health}.rs`。

我**只略读**的文件：`rss_article_dao.rs` / `rss_star_dao.rs` / `rss_source_dao.rs` / `rss_read_record_dao.rs` / `rule_sub_dao.rs`（结构和 dao 风格高度一致，不展开找细节）、`book_group_dao.rs`、`progress_dao.rs`、`replace_rule_dao.rs`、`download_dao.rs`、`models.rs`、`cache_dao.rs`、`cache_stats_dao.rs`、`legado_field_map.rs`（后半 storage→legado 反向映射段）。

我**完全跳过**的文件：`bridge/frb_generated.rs`（PRD out-of-scope）。

**未尽事项**：未对 `backup_dao.rs:300-1010`（test 段为主）、`legado_field_map.rs` 反向映射函数做最细致字段对照——这部分主要是逐字段拷贝的死代码，找问题的边际收益低。所有 RSS DAO 都按"复合主键 + ON CONFLICT 模式 + INSERT OR REPLACE 收藏"模板，与已审 dao 重复度高，发现的问题集中在 P3 风格层面。如发现 P0/P1 缺漏，建议优先重审 `backup_dao.rs:300-1010` 与 `legado_field_map.rs:550-963`。
