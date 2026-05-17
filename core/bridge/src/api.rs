//! # bridge API - 暴露给 Dart 的接口
//!
//! 复杂类型使用 JSON 字符串传递，避免 FRB 类型解析问题。

use regex::Regex;

// ============================================================
// 核心初始化
// ============================================================

/// Smoke test — 验证桥接是否正常工作
pub fn ping() -> String {
    "pong".to_string()
}

/// 初始化函数 - 在 Flutter 应用启动时调用
pub fn init_legado(db_path: String) -> Result<String, String> {
    core_storage::database::init_database(&db_path)
        .map(|_| "初始化成功".to_string())
        .map_err(|e| format!("初始化失败: {}", e))
}

/// 获取数据库版本
pub fn get_db_version(db_path: String) -> Result<i32, String> {
    let conn =
        core_storage::database::get_connection(&db_path).map_err(|e| format!("连接失败: {}", e))?;
    Ok(conn
        .pragma_query_value(None, "user_version", |row| row.get(0))
        .unwrap_or(0))
}

// ============================================================
// 书架 (Books) — 返回 JSON 字符串
// ============================================================

/// 获取书架上的所有书籍，返回 JSON 数组
pub fn get_all_books(db_path: String) -> Result<String, String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::book_dao::BookDao::new(&conn);
    let books = dao
        .get_all()
        .map_err(|e| format!("获取书籍列表失败: {}", e))?;
    serde_json::to_string(&books).map_err(|e| format!("序列化失败: {}", e))
}

/// 搜索书架中的书籍，返回 JSON 数组
pub fn search_books_offline(db_path: String, keyword: String) -> Result<String, String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::book_dao::BookDao::new(&conn);
    let books = dao
        .search(&keyword)
        .map_err(|e| format!("搜索失败: {}", e))?;
    serde_json::to_string(&books).map_err(|e| format!("序列化失败: {}", e))
}

/// 保存一本书到书架（book_json 为 storage::Book 的 JSON）
pub fn save_book(db_path: String, book_json: String) -> Result<(), String> {
    let conn = open_db(&db_path)?;
    let book: core_storage::models::Book =
        serde_json::from_str(&book_json).map_err(|e| format!("JSON 解析失败: {}", e))?;
    let dao = core_storage::book_dao::BookDao::new(&conn);
    dao.upsert(&book).map_err(|e| format!("保存失败: {}", e))
}

/// 从书架删除一本书（同时级联删除该书籍的章节和阅读进度）
pub fn delete_book(db_path: String, id: String) -> Result<(), String> {
    let conn = open_db(&db_path)?;
    let book_dao = core_storage::book_dao::BookDao::new(&conn);
    // 先删除章节和进度（子记录）
    let _ = core_storage::chapter_dao::ChapterDao::new(&conn).delete_by_book(&id);
    let _ = core_storage::progress_dao::ProgressDao::new(&conn).delete(&id);
    // 再删除书籍本身
    book_dao.delete(&id).map_err(|e| format!("删除失败: {}", e))
}

// ============================================================
// 书源 (Book Sources) — 返回 JSON 字符串
// ============================================================

/// 获取所有书源，返回 JSON 数组
pub fn get_all_sources(db_path: String) -> Result<String, String> {
    let mut conn = open_db(&db_path)?;
    let dao = core_storage::source_dao::SourceDao::new(&mut conn);
    let sources = dao
        .get_all()
        .map_err(|e| format!("获取书源列表失败: {}", e))?;
    serde_json::to_string(&sources).map_err(|e| format!("序列化失败: {}", e))
}

/// 获取所有已启用的书源，返回 JSON 数组
pub fn get_enabled_sources(db_path: String) -> Result<String, String> {
    let mut conn = open_db(&db_path)?;
    let dao = core_storage::source_dao::SourceDao::new(&mut conn);
    let sources = dao
        .get_enabled()
        .map_err(|e| format!("获取已启用书源失败: {}", e))?;
    serde_json::to_string(&sources).map_err(|e| format!("序列化失败: {}", e))
}

/// 保存书源（source_json 为 storage::BookSource 的 JSON）
pub fn save_source(db_path: String, source_json: String) -> Result<(), String> {
    let mut conn = open_db(&db_path)?;
    let source: core_storage::models::BookSource =
        serde_json::from_str(&source_json).map_err(|e| format!("JSON 解析失败: {}", e))?;
    let dao = core_storage::source_dao::SourceDao::new(&mut conn);
    dao.upsert(&source)
        .map(|_| ())
        .map_err(|e| format!("保存书源失败: {}", e))
}

/// 便捷函数：仅需 name + url 即可创建书源（自动填充 id/enabled/timestamps 等必填字段）
pub fn create_source(db_path: String, name: String, url: String) -> Result<String, String> {
    let mut conn = open_db(&db_path)?;
    let dao = core_storage::source_dao::SourceDao::new(&mut conn);
    let source = dao
        .create(&name, &url)
        .map_err(|e| format!("创建书源失败: {}", e))?;
    serde_json::to_string(&source).map_err(|e| format!("序列化失败: {}", e))
}

/// 删除书源
pub fn delete_source(db_path: String, id: String) -> Result<(), String> {
    let mut conn = open_db(&db_path)?;
    let dao = core_storage::source_dao::SourceDao::new(&mut conn);
    dao.delete(&id).map_err(|e| format!("删除书源失败: {}", e))
}

/// 批量删除书源 (ids_json 为 JSON 字符串数组)
pub fn delete_sources_batch(db_path: String, ids_json: String) -> Result<(), String> {
    let mut conn = open_db(&db_path)?;
    let ids: Vec<String> =
        serde_json::from_str(&ids_json).map_err(|e| format!("JSON 解析失败: {}", e))?;
    let dao = core_storage::source_dao::SourceDao::new(&mut conn);
    dao.delete_batch(&ids)
        .map_err(|e| format!("批量删除书源失败: {}", e))
}

/// 启用 / 禁用书源
pub fn set_source_enabled(db_path: String, id: String, enabled: bool) -> Result<(), String> {
    let mut conn = open_db(&db_path)?;
    let dao = core_storage::source_dao::SourceDao::new(&mut conn);
    dao.set_enabled(&id, enabled)
        .map_err(|e| format!("更新书源状态失败: {}", e))
}

/// 从 JSON 批量导入书源
pub fn import_sources_from_json(db_path: String, json: String) -> Result<i32, String> {
    let mut conn = open_db(&db_path)?;
    let mut dao = core_storage::source_dao::SourceDao::new(&mut conn);
    let count = dao
        .import_from_json(&json)
        .map_err(|e| format!("导入书源失败: {}", e))?;
    Ok(count as i32)
}

/// 获取书源（core_source::types::BookSource 格式），用于下载
pub fn get_source_for_download(db_path: String, source_id: String) -> Result<String, String> {
    let storage_source = {
        let mut conn = open_db(&db_path)?;
        let dao = core_storage::source_dao::SourceDao::new(&mut conn);
        dao.get_by_id(&source_id)
            .map_err(|e| format!("查询书源失败: {}", e))?
            .ok_or_else(|| format!("书源不存在: {}", source_id))?
    };
    let source = storage_to_source_book_source(&storage_source)?;
    serde_json::to_string(&source).map_err(|e| format!("序列化失败: {}", e))
}

// ============================================================
// 章节 (Chapters) — 返回 JSON 字符串
// ============================================================

/// 获取某本书的所有章节，返回 JSON 数组
pub fn get_book_chapters(db_path: String, book_id: String) -> Result<String, String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::chapter_dao::ChapterDao::new(&conn);
    let chapters = dao
        .get_by_book(&book_id)
        .map_err(|e| format!("获取章节列表失败: {}", e))?;
    serde_json::to_string(&chapters).map_err(|e| format!("序列化失败: {}", e))
}

/// 更新章节内容
pub fn update_chapter_content(
    db_path: String,
    chapter_id: String,
    content: String,
) -> Result<(), String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::chapter_dao::ChapterDao::new(&conn);
    dao.update_content(&chapter_id, &content)
        .map_err(|e| format!("更新章节内容失败: {}", e))
}

/// 保存章节（chapter_json 为 storage::Chapter 的 JSON）
pub fn save_chapter(db_path: String, chapter_json: String) -> Result<(), String> {
    let conn = open_db(&db_path)?;
    let chapter: core_storage::models::Chapter =
        serde_json::from_str(&chapter_json).map_err(|e| format!("JSON 解析失败: {}", e))?;
    let dao = core_storage::chapter_dao::ChapterDao::new(&conn);
    dao.upsert(&chapter)
        .map_err(|e| format!("保存章节失败: {}", e))
}

/// 批量替换某本书的章节（chapters_json 为 storage::Chapter 数组 JSON），保留相同 URL 的已缓存正文
pub fn replace_book_chapters_preserving_content(
    db_path: String,
    book_id: String,
    chapters_json: String,
) -> Result<(), String> {
    let conn = open_db(&db_path)?;
    let chapters: Vec<core_storage::models::Chapter> =
        serde_json::from_str(&chapters_json).map_err(|e| format!("JSON 解析失败: {}", e))?;
    let dao = core_storage::chapter_dao::ChapterDao::new(&conn);
    dao.replace_by_book_preserving_content(&book_id, &chapters)
        .map_err(|e| format!("批量保存章节失败: {}", e))
}

/// 批量替换某本书的章节（chapters_json 为 storage::Chapter 数组 JSON），不保留旧章节正文
pub fn replace_book_chapters(
    db_path: String,
    book_id: String,
    chapters_json: String,
) -> Result<(), String> {
    let conn = open_db(&db_path)?;
    let chapters: Vec<core_storage::models::Chapter> =
        serde_json::from_str(&chapters_json).map_err(|e| format!("JSON 解析失败: {}", e))?;
    let dao = core_storage::chapter_dao::ChapterDao::new(&conn);
    dao.replace_by_book(&book_id, &chapters)
        .map_err(|e| format!("批量替换章节失败: {}", e))
}

/// 删除章节
pub fn delete_chapter(db_path: String, id: String) -> Result<(), String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::chapter_dao::ChapterDao::new(&conn);
    dao.delete(&id).map_err(|e| format!("删除章节失败: {}", e))
}

// ============================================================
// 阅读进度 (Reading Progress)
// ============================================================

/// 保存阅读进度
pub fn save_reading_progress(
    db_path: String,
    book_id: String,
    chapter_index: i32,
    paragraph_index: i32,
    offset: i32,
) -> Result<(), String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::progress_dao::ProgressDao::new(&conn);
    dao.update_progress(&book_id, chapter_index, paragraph_index, offset)
        .map_err(|e| format!("保存阅读进度失败: {}", e))
}

/// 获取阅读进度，返回 JSON 或 null
pub fn get_reading_progress(db_path: String, book_id: String) -> Result<String, String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::progress_dao::ProgressDao::new(&conn);
    let progress = dao
        .get_by_book(&book_id)
        .map_err(|e| format!("获取进度失败: {}", e))?;
    serde_json::to_string(&progress).map_err(|e| format!("序列化失败: {}", e))
}

// ============================================================
// 书签 (Bookmarks) — 返回 JSON 字符串
// ============================================================

/// 获取某本书的所有书签，返回 JSON 数组
pub fn get_bookmarks(db_path: String, book_id: String) -> Result<String, String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::progress_dao::ProgressDao::new(&conn);
    let bookmarks = dao
        .get_bookmarks(&book_id)
        .map_err(|e| format!("获取书签失败: {}", e))?;
    serde_json::to_string(&bookmarks).map_err(|e| format!("序列化失败: {}", e))
}

/// 添加书签，返回新书签的 JSON
pub fn add_bookmark(
    db_path: String,
    book_id: String,
    chapter_index: i32,
    paragraph_index: i32,
    content: Option<String>,
) -> Result<String, String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::progress_dao::ProgressDao::new(&conn);
    let bookmark = dao
        .create_bookmark(&book_id, chapter_index, paragraph_index, content.as_deref())
        .map_err(|e| format!("添加书签失败: {}", e))?;
    serde_json::to_string(&bookmark).map_err(|e| format!("序列化失败: {}", e))
}

/// 删除书签
pub fn delete_bookmark(db_path: String, bookmark_id: String) -> Result<(), String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::progress_dao::ProgressDao::new(&conn);
    dao.delete_bookmark(&bookmark_id)
        .map_err(|e| format!("删除书签失败: {}", e))
}

// ============================================================
// 在线搜索 & 内容获取 — 返回 JSON 字符串
// ============================================================

/// 搜索在线书籍（source_json 为 core_source::BookSource 的 JSON），返回搜索结果 JSON 数组
pub async fn search_books_online(source_json: String, keyword: String) -> Result<String, String> {
    let source: core_source::types::BookSource =
        serde_json::from_str(&source_json).map_err(|e| format!("解析书源失败: {}", e))?;
    let parser = core_source::parser::BookSourceParser::new();
    let results = parser.search(&source, &keyword).await;
    serde_json::to_string(&results).map_err(|e| format!("序列化失败: {}", e))
}

/// 获取在线书籍详情，返回 JSON 或 null
pub async fn get_book_info_online(source_json: String, book_url: String) -> Result<String, String> {
    let source: core_source::types::BookSource =
        serde_json::from_str(&source_json).map_err(|e| format!("解析书源失败: {}", e))?;
    let parser = core_source::parser::BookSourceParser::new();
    let detail = parser.get_book_info(&source, &book_url).await;
    serde_json::to_string(&detail).map_err(|e| format!("序列化失败: {}", e))
}

/// 获取在线章节列表，返回 JSON 数组
pub async fn get_chapter_list_online(
    source_json: String,
    book_url: String,
) -> Result<String, String> {
    let source: core_source::types::BookSource =
        serde_json::from_str(&source_json).map_err(|e| format!("解析书源失败: {}", e))?;
    let parser = core_source::parser::BookSourceParser::new();
    let chapters = parser.get_chapters(&source, &book_url).await;
    serde_json::to_string(&chapters).map_err(|e| format!("序列化失败: {}", e))
}

/// 获取在线章节内容，返回 JSON 或 null
pub async fn get_chapter_content_online(
    source_json: String,
    chapter_url: String,
) -> Result<String, String> {
    let source: core_source::types::BookSource =
        serde_json::from_str(&source_json).map_err(|e| format!("解析书源失败: {}", e))?;
    let parser = core_source::parser::BookSourceParser::new();
    let content = parser.get_chapter_content(&source, &chapter_url).await;
    serde_json::to_string(&content).map_err(|e| format!("序列化失败: {}", e))
}

// ============================================================
// 诊断函数：导出书源原始规则用于调试
// ============================================================

/// 获取书源的原始 rule_search JSON（用于诊断），返回 JSON 或 null
pub fn get_source_rule_search_raw(
    db_path: String,
    source_id: String,
) -> Result<String, String> {
    let mut conn = open_db(&db_path)?;
    let dao = core_storage::source_dao::SourceDao::new(&mut conn);
    let source = dao
        .get_by_id(&source_id)
        .map_err(|e| format!("查询书源失败: {}", e))?
        .ok_or_else(|| format!("书源不存在: {}", source_id))?;
    serde_json::to_string(&source.rule_search).map_err(|e| format!("序列化失败: {}", e))
}

// ============================================================
// 便捷函数：从数据库取书源后直接操作
// ============================================================

/// 从数据库加载书源并搜索（异步），返回搜索结果 JSON 数组
/// 包装结果：正常时返回 [{"ok":true,"data":[...]}]，失败时返回 [{"ok":false,"error":"..."}]
pub async fn search_with_source_from_db_v2(
    db_path: String,
    source_id: String,
    keyword: String,
) -> Result<String, String> {
    let storage_source = {
        let mut conn = open_db(&db_path)?;
        let dao = core_storage::source_dao::SourceDao::new(&mut conn);
        dao.get_by_id(&source_id)
            .map_err(|e| format!("查询书源失败: {}", e))?
            .ok_or_else(|| format!("书源不存在: {}", source_id))?
    };

    let source = match storage_to_source_book_source(&storage_source) {
        Ok(s) => s,
        Err(e) => {
            let resp = serde_json::json!({"ok": false, "error": format!("转换书源失败: {}", e), "source_name": storage_source.name});
            return serde_json::to_string(&vec![resp]).map_err(|e| format!("序列化失败: {}", e));
        }
    };

    let parser = core_source::parser::BookSourceParser::new();
    match parser.search(&source, &keyword).await {
        results if results.is_empty() => {
            let resp = serde_json::json!({"ok": false, "error": "搜索返回0结果", "source_name": source.name, "search_url": source.rule_search.as_ref().and_then(|r| r.search_url.as_ref().cloned()).unwrap_or_default()});
            serde_json::to_string(&vec![resp])
                .map_err(|e| format!("序列化失败: {}", e))
        }
        results => {
            serde_json::to_string(&results).map_err(|e| format!("序列化失败: {}", e))
        }
    }
}

/// 从数据库加载书源并搜索（异步），返回搜索结果 JSON 数组
pub async fn search_with_source_from_db(
    db_path: String,
    source_id: String,
    keyword: String,
) -> Result<String, String> {
    let storage_source = {
        let mut conn = open_db(&db_path)?;
        let dao = core_storage::source_dao::SourceDao::new(&mut conn);
        dao.get_by_id(&source_id)
            .map_err(|e| format!("查询书源失败: {}", e))?
            .ok_or_else(|| format!("书源不存在: {}", source_id))?
    };

    let source = storage_to_source_book_source(&storage_source)?;
    let parser = core_source::parser::BookSourceParser::new();
    let results = parser.search(&source, &keyword).await;
    serde_json::to_string(&results).map_err(|e| format!("序列化失败: {}", e))
}

/// 从数据库加载书源并获取章节内容（异步），返回 JSON 或 null
pub async fn get_chapter_content_with_source_from_db(
    db_path: String,
    source_id: String,
    chapter_url: String,
) -> Result<String, String> {
    let storage_source = {
        let mut conn = open_db(&db_path)?;
        let dao = core_storage::source_dao::SourceDao::new(&mut conn);
        dao.get_by_id(&source_id)
            .map_err(|e| format!("查询书源失败: {}", e))?
            .ok_or_else(|| format!("书源不存在: {}", source_id))?
    };

    let source = storage_to_source_book_source(&storage_source)?;
    let parser = core_source::parser::BookSourceParser::new();
    let content = parser.get_chapter_content(&source, &chapter_url).await;
    serde_json::to_string(&content).map_err(|e| format!("序列化失败: {}", e))
}

// ============================================================
// 下载管理 (Download Management)
// ============================================================

/// 获取所有下载任务，返回 JSON 数组
pub fn get_download_tasks(db_path: String) -> Result<String, String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::download_dao::DownloadDao::new(&conn);
    let tasks = dao
        .get_all()
        .map_err(|e| format!("获取下载任务失败: {}", e))?;
    serde_json::to_string(&tasks).map_err(|e| format!("序列化失败: {}", e))
}

/// 根据书籍 ID 获取下载任务
pub fn get_download_task_by_book(db_path: String, book_id: String) -> Result<String, String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::download_dao::DownloadDao::new(&conn);
    let tasks = dao
        .get_by_book(&book_id)
        .map_err(|e| format!("获取下载任务失败: {}", e))?;
    serde_json::to_string(&tasks).map_err(|e| format!("序列化失败: {}", e))
}

/// 创建下载任务（task_json 为 DownloadTask 的 JSON），返回 JSON
pub fn create_download_task(db_path: String, task_json: String) -> Result<String, String> {
    let conn = open_db(&db_path)?;
    let task: core_storage::models::DownloadTask =
        serde_json::from_str(&task_json).map_err(|e| format!("JSON 解析失败: {}", e))?;
    let dao = core_storage::download_dao::DownloadDao::new(&conn);
    dao.upsert(&task)
        .map_err(|e| format!("创建下载任务失败: {}", e))?;
    serde_json::to_string(&task).map_err(|e| format!("序列化失败: {}", e))
}

/// 事务性创建下载任务和章节
pub fn create_download_task_with_chapters(
    db_path: String,
    task_json: String,
    chapters_json: String,
) -> Result<String, String> {
    let conn = open_db(&db_path)?;
    let task: core_storage::models::DownloadTask =
        serde_json::from_str(&task_json).map_err(|e| format!("JSON 解析失败: {}", e))?;
    let chapters: Vec<core_storage::models::DownloadChapter> =
        serde_json::from_str(&chapters_json).map_err(|e| format!("JSON 解析失败: {}", e))?;
    let dao = core_storage::download_dao::DownloadDao::new(&conn);
    dao.create_task_with_chapters(&task, &chapters)
        .map_err(|e| format!("创建下载任务失败: {}", e))?;
    serde_json::to_string(&task).map_err(|e| format!("序列化失败: {}", e))
}

/// 更新下载任务状态
pub fn update_download_task_status(
    db_path: String,
    task_id: String,
    status: i32,
    error_message: Option<String>,
) -> Result<(), String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::download_dao::DownloadDao::new(&conn);
    dao.update_status(&task_id, status, error_message.as_deref())
        .map_err(|e| format!("更新下载状态失败: {}", e))
}

/// 更新下载进度
pub fn update_download_progress(
    db_path: String,
    task_id: String,
    downloaded_chapters: i32,
    downloaded_size: i64,
) -> Result<(), String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::download_dao::DownloadDao::new(&conn);
    dao.update_progress(&task_id, downloaded_chapters, downloaded_size)
        .map_err(|e| format!("更新下载进度失败: {}", e))
}

/// 删除下载任务（同时清理已下载的文件）
pub fn delete_download_task(db_path: String, task_id: String) -> Result<(), String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::download_dao::DownloadDao::new(&conn);
    let inferred_root = std::path::Path::new(&db_path)
        .parent()
        .map(|parent| parent.join("downloads"));
    dao.delete_with_files_in_root(&task_id, inferred_root.as_deref())
        .map_err(|e| format!("删除下载任务失败: {}", e))
}

/// 获取下载章节列表，返回 JSON 数组
pub fn get_download_chapters(db_path: String, task_id: String) -> Result<String, String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::download_dao::DownloadDao::new(&conn);
    let chapters = dao
        .get_chapters_by_task(&task_id)
        .map_err(|e| format!("获取下载章节失败: {}", e))?;
    serde_json::to_string(&chapters).map_err(|e| format!("序列化失败: {}", e))
}

/// 批量创建下载章节记录
pub fn batch_create_download_chapters(
    db_path: String,
    chapters_json: String,
) -> Result<(), String> {
    let conn = open_db(&db_path)?;
    let chapters: Vec<core_storage::models::DownloadChapter> =
        serde_json::from_str(&chapters_json).map_err(|e| format!("JSON 解析失败: {}", e))?;
    let dao = core_storage::download_dao::DownloadDao::new(&conn);
    dao.batch_create_chapters(&chapters)
        .map_err(|e| format!("批量创建下载章节失败: {}", e))
}

/// 更新下载章节状态
pub fn update_download_chapter_status(
    db_path: String,
    chapter_id: String,
    status: i32,
    file_path: Option<String>,
    file_size: i64,
    error_message: Option<String>,
) -> Result<(), String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::download_dao::DownloadDao::new(&conn);
    dao.update_chapter_status(
        &chapter_id,
        status,
        file_path.as_deref(),
        file_size,
        error_message.as_deref(),
    )
    .map_err(|e| format!("更新下载章节状态失败: {}", e))
}

/// 下载并保存单个章节到本地文件，更新数据库状态
pub async fn download_and_save_chapter(
    db_path: String,
    task_id: String,
    download_chapter_id: String,
    source_json: String,
    chapter_url: String,
    download_dir: String,
) -> Result<String, String> {
    let download_root = resolve_download_root(&db_path, &download_dir)?;
    core_storage::download_dao::set_download_root(&download_root.to_string_lossy());
    let source: core_source::types::BookSource =
        serde_json::from_str(&source_json).map_err(|e| format!("解析书源失败: {}", e))?;
    let parser = core_source::parser::BookSourceParser::new();
    let content = parser.get_chapter_content(&source, &chapter_url).await;

    let text = match &content {
        Some(c) => c.content.clone(),
        None => {
            let conn = open_db(&db_path)?;
            let dao = core_storage::download_dao::DownloadDao::new(&conn);
            dao.update_chapter_status(&download_chapter_id, 3, None, 0, Some("章节内容为空"))
                .map_err(|e| format!("更新章节状态失败: {}", e))?;
            recompute_download_task_status(&dao, &task_id)
                .map_err(|e| format!("更新任务状态失败: {}", e))?;
            return Err("章节内容为空".to_string());
        }
    };

    let file_name = safe_download_file_name(&download_chapter_id)?;
    let file_path = download_root.join(file_name);
    let parent = file_path
        .parent()
        .ok_or_else(|| "下载文件路径无效".to_string())?;
    std::fs::create_dir_all(parent).map_err(|e| format!("创建目录失败: {}", e))?;
    let root_canonical = download_root
        .canonicalize()
        .map_err(|e| format!("下载目录无效: {}", e))?;
    let parent_canonical = parent
        .canonicalize()
        .map_err(|e| format!("下载目录无效: {}", e))?;
    if !parent_canonical.starts_with(&root_canonical) {
        return Err("下载文件路径越界".to_string());
    }
    if std::fs::symlink_metadata(&file_path)
        .map(|metadata| metadata.file_type().is_symlink())
        .unwrap_or(false)
    {
        return Err("下载文件不能是符号链接".to_string());
    }
    std::fs::write(&file_path, &text).map_err(|e| format!("写入文件失败: {}", e))?;
    let file_size = std::fs::metadata(&file_path)
        .map(|m| m.len() as i64)
        .unwrap_or(0);
    let file_path = file_path.to_string_lossy().to_string();

    let conn = open_db(&db_path)?;
    let dao = core_storage::download_dao::DownloadDao::new(&conn);
    dao.update_chapter_status(&download_chapter_id, 2, Some(&file_path), file_size, None)
        .map_err(|e| format!("更新章节状态失败: {}", e))?;
    recompute_download_task_status(&dao, &task_id)
        .map_err(|e| format!("更新任务状态失败: {}", e))?;

    Ok(file_path)
}

fn recompute_download_task_status(
    dao: &core_storage::download_dao::DownloadDao<'_>,
    task_id: &str,
) -> rusqlite::Result<()> {
    let chapters = dao.get_chapters_by_task(task_id)?;
    let completed_count = chapters.iter().filter(|c| c.status == 2).count() as i32;
    let failed_count = chapters.iter().filter(|c| c.status == 3).count() as i32;
    let total_count = chapters.len() as i32;
    let total_size: i64 = chapters.iter().map(|c| c.file_size).sum();

    dao.update_progress(task_id, completed_count, total_size)?;

    if completed_count + failed_count >= total_count {
        if failed_count > 0 {
            dao.update_status(
                task_id,
                4,
                Some(&format!(
                    "部分章节下载失败 (成功: {}, 失败: {})",
                    completed_count, failed_count
                )),
            )?;
        } else {
            dao.update_status(task_id, 3, None)?;
        }
    }
    Ok(())
}

fn resolve_download_root(db_path: &str, download_dir: &str) -> Result<std::path::PathBuf, String> {
    let expected = std::path::Path::new(db_path)
        .parent()
        .ok_or_else(|| "数据库路径无效".to_string())?
        .join("downloads");
    std::fs::create_dir_all(&expected).map_err(|e| format!("创建下载目录失败: {}", e))?;
    let expected_canonical = expected
        .canonicalize()
        .map_err(|e| format!("下载目录无效: {}", e))?;
    let requested = std::path::Path::new(download_dir);
    let requested_canonical = requested
        .canonicalize()
        .map_err(|e| format!("下载目录无效: {}", e))?;
    if requested_canonical != expected_canonical {
        return Err("下载目录必须位于数据库目录下的 downloads".to_string());
    }
    Ok(expected_canonical)
}

fn safe_download_file_name(download_chapter_id: &str) -> Result<String, String> {
    let id = download_chapter_id.trim();
    if id.is_empty()
        || id == "."
        || id == ".."
        || id.contains('/')
        || id.contains('\\')
        || id.contains(std::path::MAIN_SEPARATOR)
    {
        return Err("下载章节 ID 不能作为安全文件名".to_string());
    }
    Ok(format!("{id}.txt"))
}

/// 验证书源规则（source_json 为 core_source::types::BookSource 的 JSON），返回 JSON 数组
pub fn validate_source_rules(source_json: String) -> Result<String, String> {
    core_source::validate_source_json(&source_json).map_err(|e| format!("验证书源规则失败: {}", e))
}

/// 验证数据库中的书源规则，返回 JSON 数组 [{field, severity, message}]
pub fn validate_source_from_db(db_path: String, source_id: String) -> Result<String, String> {
    let storage_source = {
        let mut conn = open_db(&db_path)?;
        let dao = core_storage::source_dao::SourceDao::new(&mut conn);
        dao.get_by_id(&source_id)
            .map_err(|e| format!("查询书源失败: {}", e))?
            .ok_or_else(|| format!("书源不存在: {}", source_id))?
    };
    let source = storage_to_source_book_source(&storage_source)?;
    let issues = core_source::validate_book_source(&source);
    serde_json::to_string(&issues).map_err(|e| format!("序列化失败: {}", e))
}

/// 导出所有书源为 Legado 兼容 JSON 数组（camelCase 格式）
pub fn export_all_sources(db_path: String) -> Result<String, String> {
    let mut conn = open_db(&db_path)?;
    let dao = core_storage::source_dao::SourceDao::new(&mut conn);
    dao.export_legado_json()
        .map_err(|e| format!("导出失败: {}", e))
}

// ============================================================
// 发现页 (Explore) — FRB 桥接
// ============================================================

/// 获取书源的发现入口列表
pub fn get_explore_entries(db_path: String, source_id: String) -> Result<String, String> {
    let mut conn = open_db(&db_path)?;
    let dao = core_storage::source_dao::SourceDao::new(&mut conn);
    let source = dao
        .get_by_id(&source_id)
        .map_err(|e| format!("数据库错误: {}", e))?
        .ok_or_else(|| format!("书源不存在: {}", source_id))?;
    let core_source = storage_to_source_book_source(&source)?;
    let entries = core_source::parser::BookSourceParser::get_explore_entries(&core_source);
    serde_json::to_string(&entries).map_err(|e| format!("序列化失败: {}", e))
}

fn block_on_explore<F, R>(f: F) -> R
where
    F: FnOnce(&tokio::runtime::Runtime) -> R,
{
    static RT: std::sync::OnceLock<tokio::runtime::Runtime> = std::sync::OnceLock::new();
    let rt = RT.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(1)
            .enable_all()
            .build()
            .expect("explore runtime")
    });
    f(rt)
}

/// 执行发现页请求，获取书籍列表
pub fn explore(
    db_path: String,
    source_id: String,
    explore_url: String,
    page: i32,
) -> Result<String, String> {
    let mut conn = open_db(&db_path)?;
    let dao = core_storage::source_dao::SourceDao::new(&mut conn);
    let source = dao
        .get_by_id(&source_id)
        .map_err(|e| format!("数据库错误: {}", e))?
        .ok_or_else(|| format!("书源不存在: {}", source_id))?;
    let core_source = storage_to_source_book_source(&source)?;
    let parser = core_source::parser::BookSourceParser::new();
    let results =
        block_on_explore(|rt| rt.block_on(parser.explore(&core_source, &explore_url, page)));
    serde_json::to_string(&results).map_err(|e| format!("序列化失败: {}", e))
}

// ============================================================
// 替换规则 (Replace Rules) — 返回 JSON 字符串
// ============================================================

/// 获取所有替换规则，返回 JSON 数组
pub fn get_replace_rules(db_path: String) -> Result<String, String> {
    let mut conn = open_db(&db_path)?;
    let dao = core_storage::replace_rule_dao::ReplaceRuleDao::new(&mut conn);
    let rules = dao
        .get_all()
        .map_err(|e| format!("获取替换规则列表失败: {}", e))?;
    serde_json::to_string(&rules).map_err(|e| format!("序列化失败: {}", e))
}

/// 保存替换规则（rule_json 为 storage::ReplaceRule 的 JSON），upsert 语义
pub fn save_replace_rule(db_path: String, rule_json: String) -> Result<(), String> {
    let mut conn = open_db(&db_path)?;
    let rule: core_storage::models::ReplaceRule =
        serde_json::from_str(&rule_json).map_err(|e| format!("JSON 解析失败: {}", e))?;
    let dao = core_storage::replace_rule_dao::ReplaceRuleDao::new(&mut conn);
    dao.upsert(&rule)
        .map_err(|e| format!("保存替换规则失败: {}", e))
}

/// 删除替换规则
pub fn delete_replace_rule(db_path: String, id: String) -> Result<(), String> {
    let mut conn = open_db(&db_path)?;
    let dao = core_storage::replace_rule_dao::ReplaceRuleDao::new(&mut conn);
    dao.delete(&id)
        .map_err(|e| format!("删除替换规则失败: {}", e))
}

/// 启用 / 禁用替换规则
pub fn set_replace_rule_enabled(db_path: String, id: String, enabled: bool) -> Result<(), String> {
    let mut conn = open_db(&db_path)?;
    let dao = core_storage::replace_rule_dao::ReplaceRuleDao::new(&mut conn);
    dao.set_enabled(&id, enabled)
        .map_err(|e| format!("更新替换规则状态失败: {}", e))
}

/// 对内容应用所有已启用的替换规则。
///
/// 这是 P1-7 的修复：之前 Dart 端在每次切章节时通过 FRB 拉一次规则列表，
/// 然后在主 isolate 里循环 `RegExp(...).replaceAll`，长正文 + 多条规则会
/// 阻塞 UI。现在统一下沉到 Rust 单次调用：
///
///   - 编译失败的规则只 warn 一次（避免每章都 spam 日志）
///   - 整个循环在 Rust 端跑，不占 Dart 主 isolate
///   - 调用方只需把 db_path + 原始内容传过来
///
/// 同时 Dart 侧的 ReplaceRule 缓存也可以复用：参数加 `cache_generation`，
/// Rust 端用 OnceLock + RwLock 保存上次拉取的规则；调用方在 ReplaceRule
/// CRUD 后递增 generation 即可让缓存失效，不必每次走 DAO。
pub fn apply_replace_rules(
    db_path: String,
    content: String,
    cache_generation: i64,
) -> Result<String, String> {
    apply_replace_rules_impl(&db_path, &content, cache_generation)
}

fn apply_replace_rules_impl(
    db_path: &str,
    content: &str,
    cache_generation: i64,
) -> Result<String, String> {
    let rules = load_enabled_replace_rules(db_path, cache_generation)?;
    // R12: collect all compiled regexes under a *single* short critical
    // section, then drop the lock before running `replace_all`. Previously
    // each iteration re-acquired the global REGEX_CACHE mutex and held it
    // across `replace_all`, serialising every concurrent caller and
    // throwing away the perf wins of moving regex evaluation off the Dart
    // main isolate. `regex::Regex` clones are cheap (Arc internally).
    //
    // R27/R47: pin the regex cache to `cache_generation`. When the caller
    // bumps the generation (rule CRUD), the cache is dropped and rebuilt
    // — this is what guarantees a freshly-edited pattern actually takes
    // effect (previously the cache keyed by `id` only and silently served
    // the old compiled regex). It also bounds memory: cache size never
    // exceeds the current generation's enabled rule count.
    let compiled: Vec<(Regex, String)> = {
        let mut cache = REGEX_CACHE
            .lock()
            .map_err(|e| format!("regex cache lock poisoned: {e}"))?;
        cache.ensure_generation(cache_generation);
        rules
            .iter()
            .filter(|r| !r.pattern.is_empty())
            .filter_map(|rule| {
                cache
                    .get_or_compile(&rule.id, &rule.pattern)
                    .map(|re| (re.clone(), rule.replacement.clone()))
            })
            .collect()
    };
    let mut out = content.to_string();
    for (re, replacement) in compiled.iter() {
        out = re.replace_all(&out, replacement.as_str()).into_owned();
    }
    Ok(out)
}

/// Reload the enabled replace-rule list from the DB iff the caller's
/// `generation` is newer than the cached one. Cached snapshot is shared
/// across threads.
///
/// R48: cache key includes `db_path` so a multi-DB workflow (test
/// fixtures, future profile switching, two isolates pointed at
/// different files) doesn't get a hit from another DB's rule set.
fn load_enabled_replace_rules(
    db_path: &str,
    generation: i64,
) -> Result<std::sync::Arc<Vec<core_storage::models::ReplaceRule>>, String> {
    use std::sync::{Mutex, OnceLock};
    type Cell = Mutex<Option<(String, i64, std::sync::Arc<Vec<core_storage::models::ReplaceRule>>)>>;
    static CACHE: OnceLock<Cell> = OnceLock::new();
    let cell = CACHE.get_or_init(|| Mutex::new(None));
    {
        let guard = cell.lock().map_err(|e| format!("rule cache lock: {e}"))?;
        if let Some((ref cached_path, gen, ref rules)) = *guard {
            if gen == generation && cached_path == db_path {
                return Ok(rules.clone());
            }
        }
    }
    let mut conn = open_db(db_path)?;
    let dao = core_storage::replace_rule_dao::ReplaceRuleDao::new(&mut conn);
    let fresh = dao
        .get_enabled()
        .map_err(|e| format!("加载替换规则失败: {}", e))?;
    let arc = std::sync::Arc::new(fresh);
    if let Ok(mut guard) = cell.lock() {
        *guard = Some((db_path.to_string(), generation, arc.clone()));
    }
    Ok(arc)
}

/// Compiled-regex cache.
///
/// R27/R47: keyed on `(rule_id, pattern)` and tagged with the caller's
/// `cache_generation`. When the generation changes (i.e. caller bumped the
/// counter after a rule CRUD), the entire cache is dropped on the next
/// `ensure_generation` call — guaranteeing that a freshly-edited pattern
/// actually compiles fresh, and bounding memory at "current enabled rule
/// count" rather than growing unbounded across migrations.
///
/// Compile failures are remembered as `None` within a single generation so
/// we don't re-warn on every chapter; a `bumpReplaceRuleGeneration` clears
/// them too, which is the right thing if the user fixed the bad pattern.
struct RegexCache {
    /// `cache_generation` of every entry currently in `entries`. `None` on
    /// first use (cache empty).
    generation: Option<i64>,
    entries: std::collections::HashMap<(String, String), Option<regex::Regex>>,
}

impl RegexCache {
    fn new() -> Self {
        Self {
            generation: None,
            entries: std::collections::HashMap::new(),
        }
    }

    /// Drop cached entries when the caller's generation changes. Cheap when
    /// generation matches (no allocation, no work).
    fn ensure_generation(&mut self, generation: i64) {
        if self.generation == Some(generation) {
            return;
        }
        self.entries.clear();
        self.generation = Some(generation);
    }

    fn get_or_compile(&mut self, id: &str, pattern: &str) -> Option<&regex::Regex> {
        // R50: single hash via `entry` instead of contains_key + insert + get.
        // Compile failures are stored as `None` so we don't re-warn.
        let key = (id.to_string(), pattern.to_string());
        self.entries
            .entry(key)
            .or_insert_with(|| {
                let compiled = regex::Regex::new(pattern);
                if let Err(ref e) = compiled {
                    tracing::warn!("ReplaceRule {} regex 编译失败: {}", id, e);
                }
                compiled.ok()
            })
            .as_ref()
    }
}

static REGEX_CACHE: std::sync::LazyLock<std::sync::Mutex<RegexCache>> =
    std::sync::LazyLock::new(|| std::sync::Mutex::new(RegexCache::new()));

// ============================================================
// 内部辅助函数
// ============================================================

fn open_db(db_path: &str) -> Result<rusqlite::Connection, String> {
    core_storage::database::get_connection(db_path).map_err(|e| format!("数据库连接失败: {}", e))
}

fn storage_to_source_book_source(
    s: &core_storage::models::BookSource,
) -> Result<core_source::types::BookSource, String> {
    let rule_search = s
        .rule_search
        .as_deref()
        .map(|r| serde_json::from_str(r).map_err(|e| format!("解析 rule_search JSON 失败: {}", e)))
        .transpose()?;

    let rule_book_info = s
        .rule_book_info
        .as_deref()
        .map(|r| {
            serde_json::from_str(r).map_err(|e| format!("解析 rule_book_info JSON 失败: {}", e))
        })
        .transpose()?;

    let rule_toc = s
        .rule_toc
        .as_deref()
        .map(|r| serde_json::from_str(r).map_err(|e| format!("解析 rule_toc JSON 失败: {}", e)))
        .transpose()?;

    let rule_content = s
        .rule_content
        .as_deref()
        .map(|r| serde_json::from_str(r).map_err(|e| format!("解析 rule_content JSON 失败: {}", e)))
        .transpose()?;

    let rule_explore = s
        .rule_explore
        .as_deref()
        .map(|r| serde_json::from_str(r).map_err(|e| format!("解析 rule_explore JSON 失败: {}", e)))
        .transpose()?;

    Ok(core_source::types::BookSource {
        id: s.id.clone(),
        name: s.name.clone(),
        url: s.url.clone(),
        source_type: s.source_type,
        enabled: s.enabled,
        group_name: s.group_name.clone(),
        custom_order: s.custom_order,
        weight: s.weight,
        rule_search,
        rule_book_info,
        rule_toc,
        rule_content,
        rule_review: None,
        login_url: s.login_url.clone(),
        login_ui: s.login_ui.clone(),
        login_check_js: s.login_check_js.clone(),
        header: s.header.clone(),
        js_lib: s.js_lib.clone(),
        cover_decode_js: s.cover_decode_js.clone(),
        explore_url: s.explore_url.clone(),
        rule_explore,
        book_url_pattern: s.book_url_pattern.clone(),
        enabled_explore: s.enabled_explore,
        last_update_time: s.last_update_time,
        book_source_comment: s.book_source_comment.clone(),
        concurrent_rate: s.concurrent_rate.clone(),
        variable_comment: s.variable_comment.clone(),
        explore_screen: s.explore_screen,
        created_at: s.created_at,
        updated_at: s.updated_at,
    })
}

#[cfg(test)]
mod regex_cache_tests {
    use super::*;

    /// R27: a freshly-edited pattern under the SAME rule id must produce a
    /// different compiled Regex once the caller bumps the generation. The
    /// previous keying-by-id-only kept the stale compile around forever.
    #[test]
    fn cache_invalidates_on_generation_bump() {
        let mut cache = RegexCache::new();

        cache.ensure_generation(1);
        let r1_addr = cache.get_or_compile("rule-A", "foo").unwrap() as *const _ as usize;
        // Same pattern within the same generation should hit the cache.
        let r1_again = cache.get_or_compile("rule-A", "foo").unwrap() as *const _ as usize;
        assert_eq!(r1_addr, r1_again, "same gen + pattern should reuse compile");

        // Caller edits rule "A" pattern; bumps generation.
        cache.ensure_generation(2);
        let r2 = cache.get_or_compile("rule-A", "bar").unwrap();
        assert!(r2.is_match("bar"));
        assert!(!r2.is_match("foo"), "old pattern must not still apply");
    }

    /// R47: cache size never grows beyond the current generation's worth
    /// of (id, pattern) tuples.
    #[test]
    fn cache_drops_old_entries_on_generation_bump() {
        let mut cache = RegexCache::new();
        cache.ensure_generation(1);
        for i in 0..50 {
            let id = format!("rule-{i}");
            let pattern = format!("p{i}");
            cache.get_or_compile(&id, &pattern);
        }
        assert_eq!(cache.entries.len(), 50);
        cache.ensure_generation(2);
        assert_eq!(
            cache.entries.len(),
            0,
            "generation bump should drop all entries"
        );
        cache.get_or_compile("rule-0", "p0");
        assert_eq!(cache.entries.len(), 1);
    }

    /// Compile failures still get remembered within a generation but do
    /// NOT survive a generation bump (so a user fixing a bad pattern sees
    /// the fix take effect on next chapter).
    #[test]
    fn compile_failures_clear_on_generation_bump() {
        let mut cache = RegexCache::new();
        cache.ensure_generation(1);
        // Invalid pattern: unclosed bracket.
        assert!(cache.get_or_compile("bad-rule", "[").is_none());
        assert_eq!(cache.entries.len(), 1);
        cache.ensure_generation(2);
        // Fixed pattern under same id.
        let fixed = cache.get_or_compile("bad-rule", "[abc]").unwrap();
        assert!(fixed.is_match("a"));
    }
}
