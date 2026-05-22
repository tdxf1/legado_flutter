//! # 书籍 DAO (Data Access Object)
//!
//! 提供书籍相关的数据库操作。
//! 对应原 Legado 的 Book 实体操作 (data/entities/Book.kt)
//!
//! 批次 6 (v11): SELECT/INSERT/UPDATE 列表新增 5 字段
//! `dur_chapter_index / dur_chapter_pos / dur_chapter_title /
//!  dur_chapter_time / group_id`，对齐 schema v11。
//! 列顺序固定常量 [`BOOK_COLUMNS`] 保证 SELECT/INSERT/UPDATE 同步。

use super::models::Book;
use chrono::Utc;
use rusqlite::{params, Connection, Result as SqlResult};
use tracing::{debug, info};
use uuid::Uuid;

/// books 表读取列顺序的单一来源。
/// SELECT/INSERT/UPDATE 都基于此常量构建，避免列错位。
/// 顺序与 [`book_from_row`] 内 `row.get(N)` 索引必须一致。
const BOOK_COLUMNS: &str = "id, source_id, source_name, name, author, cover_url, chapter_count, \
    latest_chapter_title, intro, kind, book_url, toc_url, last_check_time, last_check_count, \
    total_word_count, can_update, order_time, latest_chapter_time, \
    custom_cover_path, custom_info_json, \
    dur_chapter_index, dur_chapter_pos, dur_chapter_title, dur_chapter_time, group_id, \
    created_at, updated_at";

/// books 表 upsert 的 SQL 模板（27 列 INSERT + ON CONFLICT(id) DO UPDATE）。
///
/// 抽常量是因为 [`BookDao::upsert`] 与 [`BookDao::upsert_in_tx`] 用同一
/// 份 SQL — DAO 里两条 `&self` / 跨事务变体必须保持列顺序绝对一致。批
/// 次 69 (BATCH-07b) 抽出后，新增列只需改一处。绑定参数顺序由
/// [`bind_book_params`] 单一来源管理。
///
/// 跨文件复用：批次 08 (BATCH-08 / F-W1A-011) 提到 `pub(crate)`，让
/// `backup_dao::upsert_book` 复用同一份 SQL，不再维护重复 inline INSERT。
pub(crate) const BOOK_UPSERT_SQL: &str = "INSERT INTO books (
        id, source_id, source_name, name, author, cover_url, chapter_count,
        latest_chapter_title, intro, kind, book_url, toc_url, last_check_time, last_check_count,
        total_word_count, can_update, order_time, latest_chapter_time,
        custom_cover_path, custom_info_json,
        dur_chapter_index, dur_chapter_pos, dur_chapter_title, dur_chapter_time, group_id,
        created_at, updated_at
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(id) DO UPDATE SET
        source_id = excluded.source_id,
        source_name = excluded.source_name,
        name = excluded.name,
        author = excluded.author,
        cover_url = excluded.cover_url,
        chapter_count = excluded.chapter_count,
        latest_chapter_title = excluded.latest_chapter_title,
        intro = excluded.intro,
        kind = excluded.kind,
        book_url = excluded.book_url,
        toc_url = excluded.toc_url,
        last_check_time = excluded.last_check_time,
        last_check_count = excluded.last_check_count,
        total_word_count = excluded.total_word_count,
        can_update = excluded.can_update,
        order_time = excluded.order_time,
        latest_chapter_time = excluded.latest_chapter_time,
        custom_cover_path = excluded.custom_cover_path,
        custom_info_json = excluded.custom_info_json,
        dur_chapter_index = excluded.dur_chapter_index,
        dur_chapter_pos = excluded.dur_chapter_pos,
        dur_chapter_title = excluded.dur_chapter_title,
        dur_chapter_time = excluded.dur_chapter_time,
        group_id = excluded.group_id,
        updated_at = excluded.updated_at";

/// 把一本 [`Book`] 的 27 个字段按 [`BOOK_UPSERT_SQL`] 占位符顺序绑定为
/// `params!(...)`。与上面 SQL 常量配对的"单一来源"，避免 `upsert` 与
/// `upsert_in_tx` 两处写两份 `params![...]` 在加列时漏改一处。宏内部
/// 调 [`rusqlite::params!`]，因此返回值是 rusqlite 期望的 `impl Params`
/// 类型，对 `Connection::execute` / `Transaction::execute` 都可用。
///
/// 跨文件复用：批次 08 (BATCH-08 / F-W1A-011) 通过 `pub(crate) use` 把
/// 该宏暴露给 `backup_dao::upsert_book` 复用。
macro_rules! book_upsert_params {
    ($book:expr) => {
        rusqlite::params![
            $book.id,
            $book.source_id,
            $book.source_name,
            $book.name,
            $book.author,
            $book.cover_url,
            $book.chapter_count,
            $book.latest_chapter_title,
            $book.intro,
            $book.kind,
            $book.book_url,
            $book.toc_url,
            $book.last_check_time,
            $book.last_check_count,
            $book.total_word_count,
            $book.can_update as i32,
            $book.order_time,
            $book.latest_chapter_time,
            $book.custom_cover_path,
            $book.custom_info_json,
            $book.dur_chapter_index,
            $book.dur_chapter_pos,
            $book.dur_chapter_title,
            $book.dur_chapter_time,
            $book.group_id,
            $book.created_at,
            $book.updated_at,
        ]
    };
}

// 跨文件复用：批次 08 (BATCH-08 / F-W1A-011)，让 backup_dao 复用本宏。
pub(crate) use book_upsert_params;

/// 书架排序方式。
///
/// 批次 8 (2026-05): 对齐原 Legado `BookSourceSort.kt` 枚举。Bridge 层
/// 入参用 `i32`（避免 FRB 跨语言 enum 序列化负担），DAO 层用本 enum
/// 把语义集中：sql 拼接只有这一处出口，新增排序方式只需改这里。
///
/// 越界值（< 0 或 > 5）走 [`BookSort::Default`]，保持向后兼容。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BookSort {
    /// `rowid ASC`，等价批次 7 之前默认行为（按插入顺序）。
    Default = 0,
    /// `name COLLATE NOCASE ASC`。
    Name = 1,
    /// `author COLLATE NOCASE ASC`，author 为 NULL 时排在末尾。
    Author = 2,
    /// `order_time DESC`（最近加入书架的在前）。
    TimeAdd = 3,
    /// `dur_chapter_time DESC`（最近阅读的在前）。批次 6 字段。
    DurTime = 4,
    /// `chapter_count DESC`（章节多的在前）。
    ChapterCount = 5,
}

impl BookSort {
    /// 把 bridge 层来的 i32 解析成 enum；越界值回 [`BookSort::Default`]。
    pub fn from_i32(value: i32) -> Self {
        match value {
            1 => Self::Name,
            2 => Self::Author,
            3 => Self::TimeAdd,
            4 => Self::DurTime,
            5 => Self::ChapterCount,
            _ => Self::Default,
        }
    }

    /// 返回对应的 SQL `ORDER BY` 子句（不含 `ORDER BY` 关键字，仅排序表达式）。
    /// 调用方负责拼到 `format!("... ORDER BY {} ...", BOOK_COLUMNS, sort.order_by_clause())`。
    fn order_by_clause(self) -> &'static str {
        match self {
            // 与 sqlite 隐式 rowid ASC 一致；显式写出避免后续维护时被
            // "看上去没排序" 的 SELECT 误删。
            Self::Default => "rowid ASC",
            Self::Name => "name COLLATE NOCASE ASC",
            // author 可空：NULL 放到最后符合用户直觉（"未知作者" 的书排在已
            // 知作者之后），同时保持 NOCASE 大小写无关排序。
            Self::Author => "author IS NULL, author COLLATE NOCASE ASC",
            Self::TimeAdd => "order_time DESC",
            Self::DurTime => "dur_chapter_time DESC",
            Self::ChapterCount => "chapter_count DESC",
        }
    }
}

/// 书籍 DAO
pub struct BookDao<'a> {
    conn: &'a Connection,
}

impl<'a> BookDao<'a> {
    /// 创建新的 BookDao
    pub fn new(conn: &'a Connection) -> Self {
        Self { conn }
    }

    /// 插入或更新书籍
    pub fn upsert(&self, book: &Book) -> SqlResult<()> {
        debug!(
            "插入/更新书籍: {} - {}",
            book.name,
            book.author.as_deref().unwrap_or("")
        );

        // 27 列 → 27 个占位符。批次 6 (v11) 在 v10 基础上新增 5 个 dur_*/group_id 字段。
        // SQL 文本由共享常量 [`BOOK_UPSERT_SQL`] 提供，与
        // [`BookDao::upsert_in_tx`] 保持单一来源（批次 69 / BATCH-07b）。
        self.conn.execute(BOOK_UPSERT_SQL, book_upsert_params!(book))?;

        Ok(())
    }

    /// `&Transaction` 版的 upsert：caller 在外层事务内复用同一份 SQL，
    /// 让 [`crate::api::import_local_book`] 等多 DAO 多步写入跑单事务，
    /// 中间错误时整批 rollback。
    ///
    /// `&self` 版与 `_in_tx` 版共用 [`BOOK_UPSERT_SQL`] 与
    /// [`book_upsert_params!`] 宏，列顺序 / 参数顺序绝对一致。`upsert`
    /// 自身因 `&Connection` 不能 Deref 成 `&Transaction`，无法 forward
    /// 到 in_tx；两条路径分别 `execute` 同一常量是当前最简方案。
    pub fn upsert_in_tx(tx: &rusqlite::Transaction<'_>, book: &Book) -> SqlResult<()> {
        debug!(
            "(in_tx) 插入/更新书籍: {} - {}",
            book.name,
            book.author.as_deref().unwrap_or("")
        );
        tx.execute(BOOK_UPSERT_SQL, book_upsert_params!(book))?;
        Ok(())
    }

    /// 根据 ID 获取书籍
    pub fn get_by_id(&self, id: &str) -> SqlResult<Option<Book>> {
        let sql = format!("SELECT {} FROM books WHERE id = ?", BOOK_COLUMNS);
        let mut stmt = self.conn.prepare(&sql)?;

        let mut rows = stmt.query(params![id])?;

        if let Some(row) = rows.next()? {
            Ok(Some(book_from_row(row)?))
        } else {
            Ok(None)
        }
    }

    /// 获取所有书籍（按排序时间倒序）
    ///
    /// 批次 8 之前固定 `order_time DESC`；为保持向后兼容（内部其它调用
    /// 仍依赖该顺序，例如搜索结果在没有排序需求时也走 [`get_all`]），
    /// 这里继续用 `TimeAdd`，由批次 8 新增的 [`get_all_sorted`] 接受
    /// 显式 [`BookSort`]。bridge 层应优先用 [`get_all_sorted`]。
    pub fn get_all(&self) -> SqlResult<Vec<Book>> {
        self.get_all_sorted(BookSort::TimeAdd)
    }

    /// 批次 8 (2026-05): 按指定 [`BookSort`] 列出全部书。
    /// 调用方拿到 i32 后用 [`BookSort::from_i32`] 解析，越界值会回
    /// [`BookSort::Default`]，不会触发错误路径。
    pub fn get_all_sorted(&self, sort: BookSort) -> SqlResult<Vec<Book>> {
        let sql = format!(
            "SELECT {} FROM books ORDER BY {}",
            BOOK_COLUMNS,
            sort.order_by_clause()
        );
        let mut stmt = self.conn.prepare(&sql)?;
        let rows = stmt.query_map([], book_from_row)?;
        rows.collect()
    }

    /// 根据书源 ID 获取书籍
    pub fn get_by_source(&self, source_id: &str) -> SqlResult<Vec<Book>> {
        let sql = format!(
            "SELECT {} FROM books WHERE source_id = ? ORDER BY order_time DESC",
            BOOK_COLUMNS
        );
        let mut stmt = self.conn.prepare(&sql)?;

        let rows = stmt.query_map(params![source_id], book_from_row)?;
        rows.collect()
    }

    /// 删除书籍
    pub fn delete(&self, id: &str) -> SqlResult<()> {
        info!("删除书籍: {}", id);
        self.conn
            .execute("DELETE FROM books WHERE id = ?", params![id])?;
        // 章节会因外键级联删除
        Ok(())
    }

    /// 搜索书籍
    pub fn search(&self, keyword: &str) -> SqlResult<Vec<Book>> {
        let sql = format!(
            "SELECT {} FROM books \
             WHERE name LIKE ? OR author LIKE ? \
             ORDER BY order_time DESC",
            BOOK_COLUMNS
        );
        let mut stmt = self.conn.prepare(&sql)?;

        let pattern = format!("%{}%", keyword);
        let rows = stmt.query_map(params![pattern, pattern], book_from_row)?;
        rows.collect()
    }

    /// 按分组列出书籍。
    ///
    /// 批次 7 (2026-05): 配合书架顶栏 TabBar 切换分组。
    /// - `group_id == -1` → 列出所有书（"全部" Tab，等价 [`get_all`]）
    /// - `group_id == 0`  → "未分组" Tab，列出 `WHERE group_id = 0`
    /// - `group_id >= 1`  → 具体某个用户分组，列出 `WHERE group_id = ?`
    ///
    /// 旧实现固定 `order_time DESC`；批次 8 起委托给 [`list_by_group_sorted`]
    /// 并用 [`BookSort::TimeAdd`] 保持原行为。新代码请直接调
    /// [`list_by_group_sorted`] 并传 [`BookSort`]。
    pub fn list_by_group(&self, group_id: i64) -> SqlResult<Vec<Book>> {
        self.list_by_group_sorted(group_id, BookSort::TimeAdd)
    }

    /// 批次 8 (2026-05): 按分组 + 排序方式列出书籍。
    ///
    /// `sort` 由 bridge 层从 i32 解析得来（[`BookSort::from_i32`]），越界
    /// 安全。`group_id` 语义同 [`list_by_group`]。
    pub fn list_by_group_sorted(
        &self,
        group_id: i64,
        sort: BookSort,
    ) -> SqlResult<Vec<Book>> {
        if group_id == -1 {
            return self.get_all_sorted(sort);
        }
        let sql = format!(
            "SELECT {} FROM books WHERE group_id = ? ORDER BY {}",
            BOOK_COLUMNS,
            sort.order_by_clause()
        );
        let mut stmt = self.conn.prepare(&sql)?;
        let rows = stmt.query_map(params![group_id], book_from_row)?;
        rows.collect()
    }

    /// 把一本书移到指定分组（`group_id = 0` 表示移回"未分组"）。
    /// 同时刷新 `updated_at`，让书架排序能感知到"刚移过来"。
    pub fn set_group(&self, book_id: &str, group_id: i64) -> SqlResult<()> {
        info!("移动书籍到分组: book_id={}, group_id={}", book_id, group_id);
        let now = Utc::now().timestamp();
        self.conn.execute(
            "UPDATE books SET group_id = ?, updated_at = ? WHERE id = ?",
            params![group_id, now, book_id],
        )?;
        Ok(())
    }

    /// BATCH-27d: 切换书的「允许更新」状态（canUpdate）。canUpdate=false
    /// 后批量目录刷新（27b update_toc）会跳过此本，对齐 27b spec
    /// 「Dart 端 filter 契约」`!isLocal && canUpdate` 过滤。
    pub fn set_can_update(&self, book_id: &str, can_update: bool) -> SqlResult<()> {
        info!(
            "切换书 canUpdate: book_id={}, can_update={}",
            book_id, can_update
        );
        let now = Utc::now().timestamp();
        self.conn.execute(
            "UPDATE books SET can_update = ?, updated_at = ? WHERE id = ?",
            params![can_update as i32, now, book_id],
        )?;
        Ok(())
    }

    // 注：清缓存语义复用 BATCH-26a `CacheStatsDao::clear_book_cache(book_id)
    // -> Result<i64>`（cache_stats_dao.rs L98），不在 BookDao 重新加。
    // 27d Dart 端走 `clearBookCache(dbPath, bookId)` FRB（funcId 80）。

    /// 创建新书籍（便捷函数）
    pub fn create(
        &self,
        source_id: &str,
        source_name: Option<&str>,
        name: &str,
        author: Option<&str>,
    ) -> SqlResult<Book> {
        let now = Utc::now().timestamp();
        let book = Book {
            id: Uuid::new_v4().to_string(),
            source_id: source_id.to_string(),
            source_name: source_name.map(|s| s.to_string()),
            name: name.to_string(),
            author: author.map(|s| s.to_string()),
            cover_url: None,
            chapter_count: 0,
            latest_chapter_title: None,
            intro: None,
            kind: None,
            book_url: None,
            toc_url: None,
            last_check_time: None,
            last_check_count: 0,
            total_word_count: 0,
            can_update: true,
            order_time: now,
            latest_chapter_time: None,
            custom_cover_path: None,
            custom_info_json: None,
            dur_chapter_index: 0,
            dur_chapter_pos: 0,
            dur_chapter_title: None,
            dur_chapter_time: 0,
            group_id: 0,
            created_at: now,
            updated_at: now,
        };

        self.upsert(&book)?;
        Ok(book)
    }
}

/// 从数据库行转换到 Book 结构体。
/// 列顺序与 [`BOOK_COLUMNS`] 严格对齐 — 改一处必须同步另一处。
fn book_from_row(row: &rusqlite::Row) -> SqlResult<Book> {
    Ok(Book {
        id: row.get(0)?,
        source_id: row.get(1)?,
        source_name: row.get(2)?,
        name: row.get(3)?,
        author: row.get(4)?,
        cover_url: row.get(5)?,
        chapter_count: row.get(6)?,
        latest_chapter_title: row.get(7)?,
        intro: row.get(8)?,
        kind: row.get(9)?,
        book_url: row.get(10)?,
        toc_url: row.get(11)?,
        last_check_time: row.get(12)?,
        last_check_count: row.get(13)?,
        total_word_count: row.get(14)?,
        can_update: row.get::<_, i32>(15)? != 0,
        order_time: row.get(16)?,
        latest_chapter_time: row.get(17)?,
        custom_cover_path: row.get(18)?,
        custom_info_json: row.get(19)?,
        dur_chapter_index: row.get(20)?,
        dur_chapter_pos: row.get(21)?,
        dur_chapter_title: row.get(22)?,
        dur_chapter_time: row.get(23)?,
        group_id: row.get(24)?,
        created_at: row.get(25)?,
        updated_at: row.get(26)?,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    fn setup() -> (TempDir, Connection) {
        let dir = TempDir::new().unwrap();
        let db_path = dir.path().join("test.db");
        let conn = crate::database::init_database(db_path.to_str().unwrap()).unwrap();
        conn.execute(
            "INSERT INTO book_sources (id, name, url, created_at, updated_at) \
             VALUES ('s1', 'Source', 'https://e', 1, 1)",
            [],
        )
        .unwrap();
        (dir, conn)
    }

    fn book_with_group(id: &str, group_id: i64, order_time: i64) -> Book {
        Book {
            id: id.to_string(),
            source_id: "s1".to_string(),
            source_name: Some("Source".to_string()),
            name: format!("Book {id}"),
            author: None,
            cover_url: None,
            chapter_count: 0,
            latest_chapter_title: None,
            intro: None,
            kind: None,
            book_url: None,
            toc_url: None,
            last_check_time: None,
            last_check_count: 0,
            total_word_count: 0,
            can_update: true,
            order_time,
            latest_chapter_time: None,
            custom_cover_path: None,
            custom_info_json: None,
            dur_chapter_index: 0,
            dur_chapter_pos: 0,
            dur_chapter_title: None,
            dur_chapter_time: 0,
            group_id,
            created_at: 1,
            updated_at: 1,
        }
    }

    #[test]
    fn test_list_by_group_filters_correctly() {
        let (_dir, conn) = setup();
        let dao = BookDao::new(&conn);
        // 3 本未分组 + 2 本到分组 1 + 1 本到分组 2
        dao.upsert(&book_with_group("u1", 0, 1)).unwrap();
        dao.upsert(&book_with_group("u2", 0, 2)).unwrap();
        dao.upsert(&book_with_group("u3", 0, 3)).unwrap();
        dao.upsert(&book_with_group("g1a", 1, 4)).unwrap();
        dao.upsert(&book_with_group("g1b", 1, 5)).unwrap();
        dao.upsert(&book_with_group("g2a", 2, 6)).unwrap();

        // group_id == -1：全部，order_time DESC
        let all = dao.list_by_group(-1).unwrap();
        assert_eq!(all.len(), 6);
        assert_eq!(all[0].id, "g2a"); // order_time=6 最新

        // group_id == 0：未分组
        let ungrouped = dao.list_by_group(0).unwrap();
        assert_eq!(ungrouped.len(), 3);
        assert!(ungrouped.iter().all(|b| b.group_id == 0));

        // group_id == 1：分组 1
        let g1 = dao.list_by_group(1).unwrap();
        assert_eq!(g1.len(), 2);
        assert!(g1.iter().all(|b| b.group_id == 1));

        // group_id == 99：空分组
        let empty = dao.list_by_group(99).unwrap();
        assert!(empty.is_empty());
    }

    #[test]
    fn test_set_group_moves_book() {
        let (_dir, conn) = setup();
        let dao = BookDao::new(&conn);
        dao.upsert(&book_with_group("b1", 0, 1)).unwrap();

        dao.set_group("b1", 5).unwrap();
        let b = dao.get_by_id("b1").unwrap().unwrap();
        assert_eq!(b.group_id, 5);

        // 再移回未分组
        dao.set_group("b1", 0).unwrap();
        let b2 = dao.get_by_id("b1").unwrap().unwrap();
        assert_eq!(b2.group_id, 0);
    }

    /// BATCH-27d: set_can_update 切换 canUpdate 字段（默认 true → false →
    /// true round-trip）+ updated_at 也被刷新。
    #[test]
    fn test_set_can_update_toggles_flag() {
        let (_dir, conn) = setup();
        let dao = BookDao::new(&conn);
        dao.upsert(&book_with_group("b1", 0, 1)).unwrap();
        let initial = dao.get_by_id("b1").unwrap().unwrap();
        assert_eq!(initial.can_update, true, "default canUpdate=true");

        dao.set_can_update("b1", false).unwrap();
        let after_false = dao.get_by_id("b1").unwrap().unwrap();
        assert_eq!(after_false.can_update, false);
        assert!(after_false.updated_at >= initial.updated_at);

        dao.set_can_update("b1", true).unwrap();
        let after_true = dao.get_by_id("b1").unwrap().unwrap();
        assert_eq!(after_true.can_update, true);
    }

    /// BATCH-27d: set_can_update 对不存在的 book_id 返回 Ok（execute 影响 0
    /// 行不算错误），与 set_group 同款行为约定。
    #[test]
    fn test_set_can_update_unknown_id_no_op() {
        let (_dir, conn) = setup();
        let dao = BookDao::new(&conn);
        // 未 upsert 任何书
        let r = dao.set_can_update("nonexistent", false);
        assert!(r.is_ok());
    }

    // ==========================================================
    // 批次 8 (2026-05): BookSort 排序单测
    // ==========================================================

    /// 5 本字段都不同的书，跨多个排序维度断言顺序。把书插入顺序
    /// 与所有排序键都解耦（rowid 不等于 name 不等于 order_time），
    /// 这样某个 ORDER BY 写错时一定会 fail，避免"因为 rowid 顺序
    /// 巧合等于 name 顺序"导致测试假绿。
    fn sortable_book(
        id: &str,
        name: &str,
        author: Option<&str>,
        order_time: i64,
        dur_chapter_time: i64,
        chapter_count: i32,
    ) -> Book {
        Book {
            id: id.to_string(),
            source_id: "s1".to_string(),
            source_name: Some("Source".to_string()),
            name: name.to_string(),
            author: author.map(|s| s.to_string()),
            cover_url: None,
            chapter_count,
            latest_chapter_title: None,
            intro: None,
            kind: None,
            book_url: None,
            toc_url: None,
            last_check_time: None,
            last_check_count: 0,
            total_word_count: 0,
            can_update: true,
            order_time,
            latest_chapter_time: None,
            custom_cover_path: None,
            custom_info_json: None,
            dur_chapter_index: 0,
            dur_chapter_pos: 0,
            dur_chapter_title: None,
            dur_chapter_time,
            group_id: 0,
            created_at: 1,
            updated_at: 1,
        }
    }

    fn seed_sortable(conn: &Connection) -> &'static [&'static str] {
        let dao = BookDao::new(conn);
        // 字段交错：rowid (插入序) 1..5 = b1..b5
        // name:           "Charlie","alpha","Delta","bravo","echo"
        // author:         Some("Z"),None,Some("a"),Some("M"),Some("B")
        // order_time:     100, 500, 300, 200, 400
        // dur_chapter_time: 5,   1,   3,   2,   4
        // chapter_count:  10,  50,  30,  20,  40
        dao.upsert(&sortable_book("b1", "Charlie", Some("Z"), 100, 5, 10))
            .unwrap();
        dao.upsert(&sortable_book("b2", "alpha", None, 500, 1, 50))
            .unwrap();
        dao.upsert(&sortable_book("b3", "Delta", Some("a"), 300, 3, 30))
            .unwrap();
        dao.upsert(&sortable_book("b4", "bravo", Some("M"), 200, 2, 20))
            .unwrap();
        dao.upsert(&sortable_book("b5", "echo", Some("B"), 400, 4, 40))
            .unwrap();
        &["b1", "b2", "b3", "b4", "b5"]
    }

    #[test]
    fn test_book_sort_from_i32_clamps_out_of_range() {
        // 越界 / 负值 / 任意脏值都回退到 Default，保持向后兼容
        assert_eq!(BookSort::from_i32(-1), BookSort::Default);
        assert_eq!(BookSort::from_i32(0), BookSort::Default);
        assert_eq!(BookSort::from_i32(1), BookSort::Name);
        assert_eq!(BookSort::from_i32(2), BookSort::Author);
        assert_eq!(BookSort::from_i32(3), BookSort::TimeAdd);
        assert_eq!(BookSort::from_i32(4), BookSort::DurTime);
        assert_eq!(BookSort::from_i32(5), BookSort::ChapterCount);
        assert_eq!(BookSort::from_i32(6), BookSort::Default);
        assert_eq!(BookSort::from_i32(99), BookSort::Default);
        assert_eq!(BookSort::from_i32(i32::MAX), BookSort::Default);
        assert_eq!(BookSort::from_i32(i32::MIN), BookSort::Default);
    }

    #[test]
    fn test_get_all_sorted_by_name_and_author() {
        let (_dir, conn) = setup();
        seed_sortable(&conn);
        let dao = BookDao::new(&conn);

        // Name ASC，COLLATE NOCASE：alpha < bravo < Charlie < Delta < echo
        let by_name = dao.get_all_sorted(BookSort::Name).unwrap();
        let names: Vec<&str> = by_name.iter().map(|b| b.name.as_str()).collect();
        assert_eq!(names, vec!["alpha", "bravo", "Charlie", "Delta", "echo"]);

        // Author NOCASE ASC，None 排末尾：a, B, M, Z, [None]
        // 对应 id: b3, b5, b4, b1, b2
        let by_author = dao.get_all_sorted(BookSort::Author).unwrap();
        let ids: Vec<&str> = by_author.iter().map(|b| b.id.as_str()).collect();
        assert_eq!(ids, vec!["b3", "b5", "b4", "b1", "b2"]);
    }

    #[test]
    fn test_get_all_sorted_by_time_and_chapter_count() {
        let (_dir, conn) = setup();
        seed_sortable(&conn);
        let dao = BookDao::new(&conn);

        // TimeAdd DESC：order_time 500,400,300,200,100 → b2,b5,b3,b4,b1
        let by_time_add = dao.get_all_sorted(BookSort::TimeAdd).unwrap();
        let ids: Vec<&str> = by_time_add.iter().map(|b| b.id.as_str()).collect();
        assert_eq!(ids, vec!["b2", "b5", "b3", "b4", "b1"]);

        // DurTime DESC：dur_chapter_time 5,4,3,2,1 → b1,b5,b3,b4,b2
        let by_dur = dao.get_all_sorted(BookSort::DurTime).unwrap();
        let ids: Vec<&str> = by_dur.iter().map(|b| b.id.as_str()).collect();
        assert_eq!(ids, vec!["b1", "b5", "b3", "b4", "b2"]);

        // ChapterCount DESC：50,40,30,20,10 → b2,b5,b3,b4,b1
        let by_count = dao.get_all_sorted(BookSort::ChapterCount).unwrap();
        let ids: Vec<&str> = by_count.iter().map(|b| b.id.as_str()).collect();
        assert_eq!(ids, vec!["b2", "b5", "b3", "b4", "b1"]);

        // Default = rowid ASC = 插入顺序 b1..b5
        let by_default = dao.get_all_sorted(BookSort::Default).unwrap();
        let ids: Vec<&str> = by_default.iter().map(|b| b.id.as_str()).collect();
        assert_eq!(ids, vec!["b1", "b2", "b3", "b4", "b5"]);
    }

    #[test]
    fn test_list_by_group_sorted_filters_and_orders() {
        let (_dir, conn) = setup();
        let dao = BookDao::new(&conn);
        // 3 本到分组 7，name 不同；额外 1 本到 0 分组，确保 group filter 生效
        dao.upsert(&sortable_book("g1", "Zebra", Some("Y"), 1, 1, 30))
            .unwrap();
        dao.upsert(&sortable_book("g2", "apple", Some("A"), 2, 2, 10))
            .unwrap();
        dao.upsert(&sortable_book("g3", "Mango", Some("M"), 3, 3, 20))
            .unwrap();
        // 让组 7 的 3 本都进 group_id=7
        dao.set_group("g1", 7).unwrap();
        dao.set_group("g2", 7).unwrap();
        dao.set_group("g3", 7).unwrap();
        // 一本未分组的，必须不出现在 group=7 的结果里
        dao.upsert(&sortable_book("u1", "unrelated", None, 9, 9, 99))
            .unwrap();

        // Name ASC（NOCASE）：apple < Mango < Zebra
        let by_name = dao.list_by_group_sorted(7, BookSort::Name).unwrap();
        let names: Vec<&str> = by_name.iter().map(|b| b.name.as_str()).collect();
        assert_eq!(names, vec!["apple", "Mango", "Zebra"]);
        assert!(by_name.iter().all(|b| b.group_id == 7));

        // ChapterCount DESC：30,20,10 → g1,g3,g2
        let by_count = dao
            .list_by_group_sorted(7, BookSort::ChapterCount)
            .unwrap();
        let ids: Vec<&str> = by_count.iter().map(|b| b.id.as_str()).collect();
        assert_eq!(ids, vec!["g1", "g3", "g2"]);

        // group_id=-1 + Name ASC：所有书（含 u1），apple < Mango < unrelated < Zebra
        let all_by_name = dao.list_by_group_sorted(-1, BookSort::Name).unwrap();
        let names: Vec<&str> = all_by_name.iter().map(|b| b.name.as_str()).collect();
        assert_eq!(names, vec!["apple", "Mango", "unrelated", "Zebra"]);
    }
}
