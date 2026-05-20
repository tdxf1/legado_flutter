use super::models::{DownloadChapter, DownloadTask};
use chrono::Utc;
use rusqlite::{params, Connection, Result as SqlResult};
use std::path::PathBuf;
use std::sync::OnceLock;
use tracing::{debug, info};
use uuid::Uuid;

/// 下载根目录（一次性配置）。
///
/// 批次 08 (BATCH-08 / F-W1A-016) 把原 `RwLock<Option<PathBuf>>` 改成
/// `OnceLock<PathBuf>`：set 路径仅 1 处（FRB 启动时由
/// `bridge::api::download_and_save_chapter` 一次性 set），mutable global
/// 不必要。
static DOWNLOAD_ROOT: OnceLock<PathBuf> = OnceLock::new();

/// 设置下载根目录。
///
/// 重复 set 静默忽略（OnceLock 语义）：FRB 启动时一次性 set 后，后续
/// 同一 db_path 的 set 调用不再生效；目前只有一次 set 路径，重复 set
/// 仅在测试 fixture / 多 db 切换场景下出现，对生产无影响。
pub fn set_download_root(path: &str) {
    if let Ok(canonical) = PathBuf::from(path).canonicalize() {
        // OnceLock::set 第二次调用返回 Err(value) 表示已被设置；丢弃即可。
        let _ = DOWNLOAD_ROOT.set(canonical);
    }
}

fn get_download_root() -> Option<PathBuf> {
    DOWNLOAD_ROOT.get().cloned()
}

pub struct DownloadDao<'a> {
    conn: &'a Connection,
}

impl<'a> DownloadDao<'a> {
    pub fn new(conn: &'a Connection) -> Self {
        Self { conn }
    }

    pub fn upsert(&self, task: &DownloadTask) -> SqlResult<()> {
        debug!("插入/更新下载任务: {}", task.book_name);
        self.conn.execute(
            "INSERT INTO download_tasks (
                id, book_id, book_name, cover_url, total_chapters, downloaded_chapters,
                status, total_size, downloaded_size, error_message, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                book_name = excluded.book_name,
                cover_url = excluded.cover_url,
                total_chapters = excluded.total_chapters,
                downloaded_chapters = excluded.downloaded_chapters,
                status = excluded.status,
                total_size = excluded.total_size,
                downloaded_size = excluded.downloaded_size,
                error_message = excluded.error_message,
                updated_at = excluded.updated_at",
            params![
                task.id,
                task.book_id,
                task.book_name,
                task.cover_url,
                task.total_chapters,
                task.downloaded_chapters,
                task.status,
                task.total_size,
                task.downloaded_size,
                task.error_message,
                task.created_at,
                task.updated_at,
            ],
        )?;
        Ok(())
    }

    pub fn get_by_id(&self, id: &str) -> SqlResult<Option<DownloadTask>> {
        let mut stmt = self.conn.prepare(
            "SELECT id, book_id, book_name, cover_url, total_chapters, downloaded_chapters,
                    status, total_size, downloaded_size, error_message, created_at, updated_at
             FROM download_tasks WHERE id = ?",
        )?;
        let mut rows = stmt.query(params![id])?;
        if let Some(row) = rows.next()? {
            Ok(Some(task_from_row(row)?))
        } else {
            Ok(None)
        }
    }

    pub fn get_by_book(&self, book_id: &str) -> SqlResult<Vec<DownloadTask>> {
        let mut stmt = self.conn.prepare(
            "SELECT id, book_id, book_name, cover_url, total_chapters, downloaded_chapters,
                    status, total_size, downloaded_size, error_message, created_at, updated_at
             FROM download_tasks WHERE book_id = ? ORDER BY created_at DESC",
        )?;
        let rows = stmt.query_map(params![book_id], task_from_row)?;
        rows.collect()
    }

    pub fn get_all(&self) -> SqlResult<Vec<DownloadTask>> {
        let mut stmt = self.conn.prepare(
            "SELECT id, book_id, book_name, cover_url, total_chapters, downloaded_chapters,
                    status, total_size, downloaded_size, error_message, created_at, updated_at
             FROM download_tasks ORDER BY created_at DESC",
        )?;
        let rows = stmt.query_map([], task_from_row)?;
        rows.collect()
    }

    pub fn delete(&self, id: &str) -> SqlResult<()> {
        info!("删除下载任务: {}", id);
        self.conn.execute(
            "DELETE FROM download_chapters WHERE task_id = ?",
            params![id],
        )?;
        self.conn
            .execute("DELETE FROM download_tasks WHERE id = ?", params![id])?;
        Ok(())
    }

    pub fn update_status(
        &self,
        id: &str,
        status: i32,
        error_message: Option<&str>,
    ) -> SqlResult<()> {
        self.conn.execute(
            "UPDATE download_tasks SET status = ?, error_message = ?, updated_at = ? WHERE id = ?",
            params![status, error_message, Utc::now().timestamp(), id],
        )?;
        Ok(())
    }

    pub fn update_progress(
        &self,
        id: &str,
        downloaded_chapters: i32,
        downloaded_size: i64,
    ) -> SqlResult<()> {
        self.conn.execute(
            "UPDATE download_tasks SET downloaded_chapters = ?, downloaded_size = ?, updated_at = ? WHERE id = ?",
            params![downloaded_chapters, downloaded_size, Utc::now().timestamp(), id],
        )?;
        Ok(())
    }

    pub fn create(
        &self,
        book_id: &str,
        book_name: &str,
        cover_url: Option<&str>,
        total_chapters: i32,
    ) -> SqlResult<DownloadTask> {
        let now = Utc::now().timestamp();
        let task = DownloadTask {
            id: Uuid::new_v4().to_string(),
            book_id: book_id.to_string(),
            book_name: book_name.to_string(),
            cover_url: cover_url.map(|s| s.to_string()),
            total_chapters,
            downloaded_chapters: 0,
            status: 0,
            total_size: 0,
            downloaded_size: 0,
            error_message: None,
            created_at: now,
            updated_at: now,
        };
        self.upsert(&task)?;
        Ok(task)
    }

    pub fn create_task_with_chapters(
        &self,
        task: &DownloadTask,
        chapters: &[DownloadChapter],
    ) -> SqlResult<()> {
        // RAII guard：之前手写 `BEGIN/COMMIT/ROLLBACK` 在 `let _ = ROLLBACK`
        // 路径会吞 SQL 错误且嵌套 transaction 时直接 panic。改用
        // [`Connection::unchecked_transaction`]：DAO 持有 `&Connection`（不
        // 可变借用，与所有 caller 兼容），失败 / 提前 return / panic 时 Drop
        // 自动 rollback。`unchecked_*` 命名是因为 rusqlite 无法从 `&Connection`
        // 静态保证当前没有其它显式 transaction 在跑——本路径调用都是从
        // bridge fn 里临时 `open_db` 出来的新连接，约束天然满足。
        let tx = self.conn.unchecked_transaction()?;
        self.upsert(task)?;
        self.batch_create_chapters(chapters)?;
        tx.commit()?;
        Ok(())
    }

    pub fn delete_with_files(&self, id: &str) -> SqlResult<()> {
        self.delete_with_files_in_root(id, get_download_root().as_deref())
    }

    pub fn delete_with_files_in_root(
        &self,
        id: &str,
        root: Option<&std::path::Path>,
    ) -> SqlResult<()> {
        let chapters = self.get_chapters_by_task(id)?;

        let root = root.and_then(|path| path.canonicalize().ok());

        for ch in &chapters {
            if let Some(ref path) = ch.file_path {
                let Ok(canonical) = std::path::Path::new(path).canonicalize() else {
                    continue;
                };
                if root
                    .as_ref()
                    .is_some_and(|root| canonical.starts_with(root))
                {
                    let _ = std::fs::remove_file(&canonical);
                }
            }
        }
        self.delete(id)
    }

    pub fn upsert_chapter(&self, chapter: &DownloadChapter) -> SqlResult<()> {
        self.conn.execute(
            "INSERT INTO download_chapters (
                id, task_id, chapter_id, chapter_index, chapter_title,
                status, file_path, file_size, error_message, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                status = excluded.status,
                file_path = excluded.file_path,
                file_size = excluded.file_size,
                error_message = excluded.error_message,
                updated_at = excluded.updated_at",
            params![
                chapter.id,
                chapter.task_id,
                chapter.chapter_id,
                chapter.chapter_index,
                chapter.chapter_title,
                chapter.status,
                chapter.file_path,
                chapter.file_size,
                chapter.error_message,
                chapter.created_at,
                chapter.updated_at,
            ],
        )?;
        Ok(())
    }

    pub fn get_chapters_by_task(&self, task_id: &str) -> SqlResult<Vec<DownloadChapter>> {
        let mut stmt = self.conn.prepare(
            "SELECT id, task_id, chapter_id, chapter_index, chapter_title,
                    status, file_path, file_size, error_message, created_at, updated_at
             FROM download_chapters WHERE task_id = ? ORDER BY chapter_index ASC",
        )?;
        let rows = stmt.query_map(params![task_id], chapter_from_row)?;
        rows.collect()
    }

    pub fn update_chapter_status(
        &self,
        chapter_id: &str,
        status: i32,
        file_path: Option<&str>,
        file_size: i64,
        error_message: Option<&str>,
    ) -> SqlResult<()> {
        self.conn.execute(
            "UPDATE download_chapters SET status = ?, file_path = ?, file_size = ?, error_message = ?, updated_at = ? WHERE id = ?",
            params![status, file_path, file_size, error_message, Utc::now().timestamp(), chapter_id],
        )?;
        Ok(())
    }

    /// `&Transaction` 版的 [`update_chapter_status`]：caller 在外层事务
    /// 内复用，让"更新单章状态 + 重算任务整体进度"两步 SQL 跑单事务。
    /// 之前 [`crate::api::download_and_save_chapter`] 走 `&self` 版每步
    /// 独立 commit，中间 panic 时章节标 status=2 但任务 progress 未刷
    /// 新留下脏数据（批次 69 / BATCH-07b）。
    pub fn update_chapter_status_in_tx(
        tx: &rusqlite::Transaction<'_>,
        chapter_id: &str,
        status: i32,
        file_path: Option<&str>,
        file_size: i64,
        error_message: Option<&str>,
    ) -> SqlResult<()> {
        tx.execute(
            "UPDATE download_chapters SET status = ?, file_path = ?, file_size = ?, error_message = ?, updated_at = ? WHERE id = ?",
            params![status, file_path, file_size, error_message, Utc::now().timestamp(), chapter_id],
        )?;
        Ok(())
    }

    pub fn batch_create_chapters(&self, chapters: &[DownloadChapter]) -> SqlResult<()> {
        for chapter in chapters {
            self.upsert_chapter(chapter)?;
        }
        Ok(())
    }
}

fn task_from_row(row: &rusqlite::Row) -> SqlResult<DownloadTask> {
    Ok(DownloadTask {
        id: row.get(0)?,
        book_id: row.get(1)?,
        book_name: row.get(2)?,
        cover_url: row.get(3)?,
        total_chapters: row.get(4)?,
        downloaded_chapters: row.get(5)?,
        status: row.get(6)?,
        total_size: row.get(7)?,
        downloaded_size: row.get(8)?,
        error_message: row.get(9)?,
        created_at: row.get(10)?,
        updated_at: row.get(11)?,
    })
}

fn chapter_from_row(row: &rusqlite::Row) -> SqlResult<DownloadChapter> {
    Ok(DownloadChapter {
        id: row.get(0)?,
        task_id: row.get(1)?,
        chapter_id: row.get(2)?,
        chapter_index: row.get(3)?,
        chapter_title: row.get(4)?,
        status: row.get(5)?,
        file_path: row.get(6)?,
        file_size: row.get(7)?,
        error_message: row.get(8)?,
        created_at: row.get(9)?,
        updated_at: row.get(10)?,
    })
}
