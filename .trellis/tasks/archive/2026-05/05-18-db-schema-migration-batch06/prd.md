# DB Schema 迁移：补齐字段 + 新增 4 张表 (批次 6)

## Goal

把 Rust core-storage SQLite schema 提升到 v11，对齐原 Legado Room 缺失部分：
1. `books` 表加 5 字段：`dur_chapter_index` / `dur_chapter_pos` / `dur_chapter_title` / `dur_chapter_time` / `group_id`
2. `bookmarks` 表加 5 字段：`book_name` / `book_author` / `chapter_pos` / `chapter_name` / `book_text`
3. 新增 4 张表：`book_groups` / `read_records` / `cookies` / `rule_subs`
4. 不动 dict_rules / http_tts / txt_toc_rules / search_keywords / rss_*（这些等后续依赖批次再加，避免空表无人用）

本批是**纯 schema 层**——不接 Flutter UI，不动业务逻辑；为批次 7-12 提供数据基础。

## What I already know

- `core/core-storage/src/database.rs` 当前 v10，有完整迁移机制（v0→v10 链 + 事务保护 + 失败回滚）
- `migrate_v10` 是最新迁移（重塑 replace_rules.scope）
- 字段差异详见 `feature-gap-reader-bookshelf-source.md` §5
- 现有 dao：book_dao / chapter_dao / source_dao / progress_dao / replace_rule_dao / download_dao / cache_dao
- Rust struct 在 `models.rs`；需要在加字段时同步更新对应 struct + serde

## Decision

**v11 一次迁移搞定 4 张表 + 2 张表加字段**。原子事务，失败回滚。

新表设计原则：
- `book_groups`：原 Legado bitmask 设计太复杂；改成自增 ID 普通表，Book 加 `group_id` 外键。简化但不损失功能
- `read_records`：(device_id, book_name) 联合主键 → 改成自增 ID + 索引
- `cookies`：(domain, key) 联合主键，与原项目一致
- `rule_subs`：原 Legado RuleSub 表，UID 主键 + url + type 三字段够用

## Requirements

1. **`books` 表加 5 字段（v11 ALTER TABLE）**
   - `dur_chapter_index INTEGER DEFAULT 0` — 当前章节索引（书架"上次读"显示）
   - `dur_chapter_pos INTEGER DEFAULT 0` — 章内字符 offset
   - `dur_chapter_title TEXT` — 当前章节标题
   - `dur_chapter_time INTEGER DEFAULT 0` — 上次阅读时间戳
   - `group_id INTEGER DEFAULT 0` — 所属分组 id（0 = 未分组）

2. **`bookmarks` 表加 5 字段**
   - `book_name TEXT` — 跨书全书签清单页要显示书名
   - `book_author TEXT`
   - `chapter_pos INTEGER DEFAULT 0` — 字符级 offset
   - `chapter_name TEXT`
   - `book_text TEXT` — 书签上下文片段

3. **新表 `book_groups`**
   ```
   id INTEGER PRIMARY KEY AUTOINCREMENT
   name TEXT NOT NULL
   sort_order INTEGER DEFAULT 0
   cover TEXT
   show INTEGER DEFAULT 1
   book_sort INTEGER DEFAULT 0  -- 分组内排序模式
   created_at INTEGER NOT NULL
   updated_at INTEGER NOT NULL
   ```

4. **新表 `read_records`**
   ```
   id TEXT PRIMARY KEY (uuid)
   book_id TEXT NOT NULL  -- FK to books.id
   book_name TEXT NOT NULL  -- 冗余存便于跨书统计（书删了仍保留）
   read_time INTEGER NOT NULL DEFAULT 0  -- 累计秒数
   last_read_at INTEGER NOT NULL  -- 上次阅读时间戳
   created_at INTEGER NOT NULL
   updated_at INTEGER NOT NULL
   ```

5. **新表 `cookies`**
   ```
   id INTEGER PRIMARY KEY AUTOINCREMENT
   domain TEXT NOT NULL
   key TEXT NOT NULL
   value TEXT NOT NULL
   path TEXT,
   expires_at INTEGER  -- nullable，session cookie 为 null
   created_at INTEGER NOT NULL
   updated_at INTEGER NOT NULL
   UNIQUE(domain, key, path)
   ```

6. **新表 `rule_subs`**
   ```
   id TEXT PRIMARY KEY (uuid)
   name TEXT NOT NULL
   url TEXT NOT NULL UNIQUE
   sub_type INTEGER DEFAULT 0  -- 0=书源 1=RSS 2=替换规则
   custom_order INTEGER DEFAULT 0
   created_at INTEGER NOT NULL
   updated_at INTEGER NOT NULL
   ```

7. **Models / DAO / serde**：更新 `models.rs` 中 Book / Bookmark struct 字段；新增 BookGroup / ReadRecord / Cookie / RuleSub struct（仅 struct，不实现 DAO，DAO 留依赖批次再加）

8. **不暴露给 FRB bridge**：本批不动 `bridge/src/api.rs`，纯 schema 层；批次 7+ 再按需加 API

## Acceptance Criteria

- [ ] `cargo test -p core-storage` 全绿（含现有 v0→v10 测试 + 新增 v10→v11 迁移测试）
- [ ] 迁移 v10→v11 测试用 in-memory DB：旧 books/bookmarks 数据保留 + 新字段为默认值；4 张新表存在
- [ ] 迁移失败回滚测试（事务覆盖）
- [ ] DB_VERSION 改成 11
- [ ] `models.rs` 更新 Book / Bookmark + 新增 4 个 struct，serde derive 完整
- [ ] cargo build 通过（含 bridge）
- [ ] flutter test 不受影响（仍 338 通过 — Flutter 端未消费新 schema）

## Definition of Done

- cargo test 全绿
- cargo clippy 无新增 warning
- cargo build --release（aarch64-linux-android）通过
- Flutter test 338 全绿
- commit + archive

## Technical Approach

### A. database.rs

1. 改 `DB_VERSION = 11`
2. `migrate_database` match 加 `11 => migrate_v11(conn)?`
3. 新增 `migrate_v11` 函数：6 个 ALTER + 4 个 CREATE TABLE，每条带"列已存在/表已存在 跳过"防御
4. `create_tables`（首装路径）也要加 4 张新表 + books/bookmarks 新字段 — 否则首装设备升级到 v11 后没新表

### B. models.rs

加 5 字段到 `Book`：
```rust
pub dur_chapter_index: i32,
pub dur_chapter_pos: i32,
pub dur_chapter_title: Option<String>,
pub dur_chapter_time: i64,
pub group_id: i64,
```

加 5 字段到 `Bookmark`：
```rust
pub book_name: Option<String>,
pub book_author: Option<String>,
pub chapter_pos: i32,
pub chapter_name: Option<String>,
pub book_text: Option<String>,
```

加 4 个新 struct（BookGroup / ReadRecord / Cookie / RuleSub），完整 derive（Debug / Clone / Serialize / Deserialize），字段与 schema 对齐。

### C. DAO 兼容

`book_dao.rs` / `bookmark.rs`（如有）的 Book/Bookmark 读写 SQL 必须读到新字段，否则 serde 反序列化会崩。改 SELECT 列表 + INSERT 占位符 + UPDATE 字段。

### D. 测试

`tests/migrate_v11_test.rs` 或在现有 test 里加：
1. 创建 v10 schema → 插入 1 本书 + 1 个书签 → 跑 migrate_v11 → 验证：
   - books.dur_chapter_index = 0
   - bookmarks.chapter_pos = 0
   - 4 张新表 SELECT * 不报错
2. 重复迁移幂等（pragma_table_info 检测列已存在跳过）

## Out of Scope

- DAO 实现 BookGroup / ReadRecord / Cookie / RuleSub — 留对应批次 7（书架分组）/ 阅读时长统计 / 书源登录 / 订阅源
- Flutter 端 schema 消费 — 同样留对应批次
- dict_rules / http_tts / txt_toc_rules / search_keywords / rss_* 表 — 等批次 16+ 实现 HTTP TTS / 字典 / RSS 时再加
- Bridge API 暴露 — 留批次 7+

## Notes

- ALTER TABLE 在 SQLite 只能 ADD COLUMN（不能 DROP/MODIFY）；本批全是 ADD，问题不大
- group_id INTEGER 用 0 表示"未分组"（与 book_groups 表 id=0 没冲突，AUTOINCREMENT 从 1 开始）
- 迁移中检查列是否已存在用 `pragma_table_info(books)` 类似 v10 的写法
