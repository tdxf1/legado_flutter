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

/// 获取书架上的所有书籍，返回 JSON 数组。
///
/// 批次 8 (2026-05): 加 `sort_order: i32` 参数（0=Default/1=Name/2=Author/
/// 3=TimeAdd/4=DurTime/5=ChapterCount，越界回 Default）。语义详见
/// [`core_storage::book_dao::BookSort::from_i32`]。Flutter 端 `bookshelfSort`
/// 设置直接透传过来。
pub fn get_all_books(db_path: String, sort_order: i32) -> Result<String, String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::book_dao::BookDao::new(&conn);
    let sort = core_storage::book_dao::BookSort::from_i32(sort_order);
    let books = dao
        .get_all_sorted(sort)
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
    let mut conn = open_db(&db_path)?;
    // 先删除章节和进度（子记录）
    let _ = core_storage::chapter_dao::ChapterDao::new(&mut conn).delete_by_book(&id);
    let _ = core_storage::progress_dao::ProgressDao::new(&conn).delete(&id);
    // 再删除书籍本身
    let book_dao = core_storage::book_dao::BookDao::new(&conn);
    book_dao.delete(&id).map_err(|e| format!("删除失败: {}", e))
}

// ============================================================
// 书架分组 (Book Groups) — 批次 7 / 返回 JSON 字符串
// ============================================================

/// 列出所有书架分组（按 sort_order 升序），返回 JSON 数组
pub fn list_book_groups(db_path: String) -> Result<String, String> {
    let conn = open_db(&db_path)?;
    let groups = core_storage::book_group_dao::BookGroupDao::list_all(&conn)
        .map_err(|e| format!("获取分组列表失败: {}", e))?;
    serde_json::to_string(&groups).map_err(|e| format!("序列化失败: {}", e))
}

/// 创建新分组，返回新分组的 JSON
pub fn create_book_group(
    db_path: String,
    name: String,
    sort_order: i32,
) -> Result<String, String> {
    let conn = open_db(&db_path)?;
    let group = core_storage::book_group_dao::BookGroupDao::create(&conn, &name, sort_order)
        .map_err(|e| format!("创建分组失败: {}", e))?;
    serde_json::to_string(&group).map_err(|e| format!("序列化失败: {}", e))
}

/// 更新分组的 name + sort_order
pub fn update_book_group(
    db_path: String,
    id: i64,
    name: String,
    sort_order: i32,
) -> Result<(), String> {
    let conn = open_db(&db_path)?;
    core_storage::book_group_dao::BookGroupDao::update(&conn, id, &name, sort_order)
        .map_err(|e| format!("更新分组失败: {}", e))
}

/// 删除分组（同事务把组内书的 group_id 重置为 0）
pub fn delete_book_group(db_path: String, id: i64) -> Result<(), String> {
    let mut conn = open_db(&db_path)?;
    core_storage::book_group_dao::BookGroupDao::delete(&mut conn, id)
        .map_err(|e| format!("删除分组失败: {}", e))
}

/// 列出某分组下的书籍。
///
/// `group_id` 语义：
/// - `-1` → 全部（等价 [`get_all_books`]）
/// - `0`  → 未分组
/// - `>= 1` → 具体某个分组
///
/// 批次 8 (2026-05): 加 `sort_order: i32`，与 [`get_all_books`] 同语义。
pub fn list_books_by_group(
    db_path: String,
    group_id: i64,
    sort_order: i32,
) -> Result<String, String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::book_dao::BookDao::new(&conn);
    let sort = core_storage::book_dao::BookSort::from_i32(sort_order);
    let books = dao
        .list_by_group_sorted(group_id, sort)
        .map_err(|e| format!("按分组获取书籍失败: {}", e))?;
    serde_json::to_string(&books).map_err(|e| format!("序列化失败: {}", e))
}

/// 把一本书移动到指定分组（`group_id = 0` 表示移回"未分组"）
pub fn set_book_group(
    db_path: String,
    book_id: String,
    group_id: i64,
) -> Result<(), String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::book_dao::BookDao::new(&conn);
    dao.set_group(&book_id, group_id)
        .map_err(|e| format!("移动书籍失败: {}", e))
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
    let mut conn = open_db(&db_path)?;
    let dao = core_storage::chapter_dao::ChapterDao::new(&mut conn);
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
    let mut conn = open_db(&db_path)?;
    let dao = core_storage::chapter_dao::ChapterDao::new(&mut conn);
    dao.update_content(&chapter_id, &content)
        .map_err(|e| format!("更新章节内容失败: {}", e))
}

/// 保存章节（chapter_json 为 storage::Chapter 的 JSON）
pub fn save_chapter(db_path: String, chapter_json: String) -> Result<(), String> {
    let mut conn = open_db(&db_path)?;
    let chapter: core_storage::models::Chapter =
        serde_json::from_str(&chapter_json).map_err(|e| format!("JSON 解析失败: {}", e))?;
    let dao = core_storage::chapter_dao::ChapterDao::new(&mut conn);
    dao.upsert(&chapter)
        .map_err(|e| format!("保存章节失败: {}", e))
}

/// 批量替换某本书的章节（chapters_json 为 storage::Chapter 数组 JSON），保留相同 URL 的已缓存正文
pub fn replace_book_chapters_preserving_content(
    db_path: String,
    book_id: String,
    chapters_json: String,
) -> Result<(), String> {
    let mut conn = open_db(&db_path)?;
    let chapters: Vec<core_storage::models::Chapter> =
        serde_json::from_str(&chapters_json).map_err(|e| format!("JSON 解析失败: {}", e))?;
    let mut dao = core_storage::chapter_dao::ChapterDao::new(&mut conn);
    dao.replace_by_book_preserving_content(&book_id, &chapters)
        .map_err(|e| format!("批量保存章节失败: {}", e))
}

/// 批量替换某本书的章节（chapters_json 为 storage::Chapter 数组 JSON），不保留旧章节正文
pub fn replace_book_chapters(
    db_path: String,
    book_id: String,
    chapters_json: String,
) -> Result<(), String> {
    let mut conn = open_db(&db_path)?;
    let chapters: Vec<core_storage::models::Chapter> =
        serde_json::from_str(&chapters_json).map_err(|e| format!("JSON 解析失败: {}", e))?;
    let mut dao = core_storage::chapter_dao::ChapterDao::new(&mut conn);
    dao.replace_by_book(&book_id, &chapters)
        .map_err(|e| format!("批量替换章节失败: {}", e))
}

/// 删除章节
pub fn delete_chapter(db_path: String, id: String) -> Result<(), String> {
    let mut conn = open_db(&db_path)?;
    let dao = core_storage::chapter_dao::ChapterDao::new(&mut conn);
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
///
/// R82: 区分 ParserError::Empty（成功 0 结果，返回 `[]`）与其他失败（Network /
/// RuleConfig / Parse，作为 Err(String) 返回让 Dart 侧能 toast 出来）。
pub async fn search_books_online(source_json: String, keyword: String) -> Result<String, String> {
    let source: core_source::types::BookSource =
        serde_json::from_str(&source_json).map_err(|e| format!("解析书源失败: {}", e))?;
    let parser = core_source::parser::BookSourceParser::new();
    match parser.search(&source, &keyword).await {
        Ok(results) => serde_json::to_string(&results).map_err(|e| format!("序列化失败: {}", e)),
        Err(core_source::ParserError::Empty) => Ok("[]".to_string()),
        Err(e) => Err(e.to_string()),
    }
}

/// 获取在线书籍详情，返回 JSON 或 null
pub async fn get_book_info_online(source_json: String, book_url: String) -> Result<String, String> {
    let source: core_source::types::BookSource =
        serde_json::from_str(&source_json).map_err(|e| format!("解析书源失败: {}", e))?;
    let parser = core_source::parser::BookSourceParser::new();
    match parser.get_book_info(&source, &book_url).await {
        Ok(detail) => serde_json::to_string(&detail).map_err(|e| format!("序列化失败: {}", e)),
        Err(core_source::ParserError::Empty) => Ok("null".to_string()),
        Err(e) => Err(e.to_string()),
    }
}

/// 获取在线章节列表，返回 JSON 数组
pub async fn get_chapter_list_online(
    source_json: String,
    book_url: String,
) -> Result<String, String> {
    let source: core_source::types::BookSource =
        serde_json::from_str(&source_json).map_err(|e| format!("解析书源失败: {}", e))?;
    let parser = core_source::parser::BookSourceParser::new();
    match parser.get_chapters(&source, &book_url).await {
        Ok(chapters) => serde_json::to_string(&chapters).map_err(|e| format!("序列化失败: {}", e)),
        Err(core_source::ParserError::Empty) => Ok("[]".to_string()),
        Err(e) => Err(e.to_string()),
    }
}

/// 获取在线章节内容，返回 JSON 或 null
pub async fn get_chapter_content_online(
    source_json: String,
    chapter_url: String,
) -> Result<String, String> {
    let source: core_source::types::BookSource =
        serde_json::from_str(&source_json).map_err(|e| format!("解析书源失败: {}", e))?;
    let parser = core_source::parser::BookSourceParser::new();
    match parser.get_chapter_content(&source, &chapter_url).await {
        Ok(content) => serde_json::to_string(&content).map_err(|e| format!("序列化失败: {}", e)),
        Err(core_source::ParserError::Empty) => Ok("null".to_string()),
        Err(e) => Err(e.to_string()),
    }
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
        Ok(results) => serde_json::to_string(&results).map_err(|e| format!("序列化失败: {}", e)),
        Err(core_source::ParserError::Empty) => {
            // R82: explicit "0 results" diagnostic envelope (preserves
            // the existing v2-wrapper UI contract for source-validation
            // pages that show why a search came back empty).
            let resp = serde_json::json!({
                "ok": false,
                "error": "搜索返回0结果",
                "source_name": source.name,
                "search_url": source
                    .rule_search
                    .as_ref()
                    .and_then(|r| r.search_url.as_ref().cloned())
                    .unwrap_or_default(),
            });
            serde_json::to_string(&vec![resp]).map_err(|e| format!("序列化失败: {}", e))
        }
        Err(e) => {
            // Network / RuleConfig / Parse — same envelope shape so the
            // diagnostic UI doesn't have to special-case error types.
            let resp = serde_json::json!({
                "ok": false,
                "error": e.to_string(),
                "source_name": source.name,
                "search_url": source
                    .rule_search
                    .as_ref()
                    .and_then(|r| r.search_url.as_ref().cloned())
                    .unwrap_or_default(),
            });
            serde_json::to_string(&vec![resp]).map_err(|e| format!("序列化失败: {}", e))
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
    match parser.search(&source, &keyword).await {
        Ok(results) => serde_json::to_string(&results).map_err(|e| format!("序列化失败: {}", e)),
        Err(core_source::ParserError::Empty) => Ok("[]".to_string()),
        Err(e) => Err(e.to_string()),
    }
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
    match parser.get_chapter_content(&source, &chapter_url).await {
        Ok(content) => serde_json::to_string(&content).map_err(|e| format!("序列化失败: {}", e)),
        Err(core_source::ParserError::Empty) => Ok("null".to_string()),
        Err(e) => Err(e.to_string()),
    }
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

    // R82: differentiate "got chapter but body empty / parse failed" from
    // "network or rule error". The former gets logged as "章节内容为空"
    // (matches legacy behaviour), the latter surfaces the real reason
    // so the download UI can show what went wrong.
    let text = match &content {
        Ok(c) => c.content.clone(),
        Err(core_source::ParserError::Empty) => {
            let conn = open_db(&db_path)?;
            let dao = core_storage::download_dao::DownloadDao::new(&conn);
            dao.update_chapter_status(&download_chapter_id, 3, None, 0, Some("章节内容为空"))
                .map_err(|e| format!("更新章节状态失败: {}", e))?;
            recompute_download_task_status(&dao, &task_id)
                .map_err(|e| format!("更新任务状态失败: {}", e))?;
            return Err("章节内容为空".to_string());
        }
        Err(e) => {
            let msg = e.to_string();
            let short = if msg.len() > 200 { &msg[..200] } else { &msg };
            let conn = open_db(&db_path)?;
            let dao = core_storage::download_dao::DownloadDao::new(&conn);
            dao.update_chapter_status(&download_chapter_id, 3, None, 0, Some(short))
                .map_err(|e| format!("更新章节状态失败: {}", e))?;
            recompute_download_task_status(&dao, &task_id)
                .map_err(|e| format!("更新任务状态失败: {}", e))?;
            return Err(msg);
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

/// 实跑 live test — 在静态校验之上 顺序跑 search / book_info / toc / content
/// 4 路 (批次 21 / 05-19, funcId 109)。
///
/// 返回 [`core_source::LiveTestReport`] 的 JSON 字符串。任一阶段失败不
/// 短路，4 个 stages 一定都会出现在结果里 — 失败的 stage 用 `error` 字段
/// 标明原因（[`ParserError::Display`] 字符串）。
///
/// `keyword` 由 UI 端传入，建议默认 `"测试"` / `"test"`。
pub async fn validate_source_live(
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
    let report = core_source::run_live_test(&source, &keyword).await;
    serde_json::to_string(&report).map_err(|e| format!("序列化失败: {}", e))
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
    match block_on_explore(|rt| rt.block_on(parser.explore(&core_source, &explore_url, page))) {
        Ok(results) => serde_json::to_string(&results).map_err(|e| format!("序列化失败: {}", e)),
        Err(core_source::ParserError::Empty) => Ok("[]".to_string()),
        Err(e) => Err(e.to_string()),
    }
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
///
/// **R24**: scope 现在按 Legado 原版语义匹配。`book_name` 与
/// `book_origin` 由 caller 提供（reader_page 持有），filter 逻辑见
/// [`matches_scope`]。`apply_to_title=true` 表示本次跑作用于标题
/// 的规则；false 表示作用于正文。
pub fn apply_replace_rules(
    db_path: String,
    content: String,
    cache_generation: i64,
    book_name: Option<String>,
    book_origin: Option<String>,
    apply_to_title: bool,
) -> Result<String, String> {
    apply_replace_rules_impl(
        &db_path,
        &content,
        cache_generation,
        book_name.as_deref().unwrap_or(""),
        book_origin.as_deref().unwrap_or(""),
        apply_to_title,
    )
}

fn apply_replace_rules_impl(
    db_path: &str,
    content: &str,
    cache_generation: i64,
    book_name: &str,
    book_origin: &str,
    apply_to_title: bool,
) -> Result<String, String> {
    // R123: rule list cache + compiled regex cache live under a SINGLE
    // mutex (`REPLACE_RULES_CACHE`). Previously the two caches each had
    // their own lock, so two concurrent callers with different
    // generations could interleave such that one's `ensure_generation`
    // wiped the other's freshly-built regex entries — leaving callers
    // with regexes from the wrong generation. Unified lock guarantees
    // that within a single critical section both halves of the cache
    // are observed at the same generation.
    //
    // R12: compiled regexes are cloned out of the cache (cheap — Regex
    // is internally Arc-based) before releasing the lock. `replace_all`
    // runs over arbitrary user-supplied content WITHOUT holding the
    // lock, so concurrent callers don't serialise on regex evaluation.
    //
    // R27/R47: regex cache is tagged with `cache_generation`. When the
    // caller bumps the generation (rule CRUD), the regex entries are
    // dropped — guaranteeing a freshly-edited pattern actually takes
    // effect, and bounding memory to the current generation's enabled
    // rule count.
    //
    // R24: filter by scope (book_name / book_origin substring match) +
    // scope_title vs scope_content before compiling, so unrelated rules
    // don't even hit the regex cache.
    let compiled: Vec<(Regex, String)> = {
        let mut cache = REPLACE_RULES_CACHE
            .lock()
            .map_err(|e| format!("replace rules cache lock poisoned: {e}"))?;

        let rules = cache.get_or_load_rules(db_path, cache_generation, || {
            let mut conn = open_db(db_path)?;
            let dao = core_storage::replace_rule_dao::ReplaceRuleDao::new(&mut conn);
            dao.get_enabled()
                .map_err(|e| format!("加载替换规则失败: {}", e))
        })?;
        cache.ensure_regex_generation(cache_generation);

        // `rules` is an Arc — clone bumps the refcount only, but the
        // borrow checker also needs us to detach the iteration source
        // from `cache` so we can take `&mut cache` for `get_or_compile_regex`
        // inside the filter_map closure.
        let rules_for_iter = rules.clone();
        rules_for_iter
            .iter()
            .filter(|r| !r.pattern.is_empty())
            .filter(|r| {
                if apply_to_title {
                    r.scope_title
                } else {
                    r.scope_content
                }
            })
            .filter(|r| matches_scope(r, book_name, book_origin))
            .filter_map(|rule| {
                cache
                    .get_or_compile_regex(&rule.id, &rule.pattern)
                    .map(|re| (re.clone(), rule.replacement.clone()))
            })
            .collect()
    }; // lock released here — `replace_all` runs lock-free below.

    let mut out = content.to_string();
    for (re, replacement) in compiled.iter() {
        out = re.replace_all(&out, replacement.as_str()).into_owned();
    }
    Ok(out)
}

/// R24: scope 子串匹配 + exclude 优先。模仿原 Legado
/// `ReplaceRuleDao.findEnabledByContentScope` 的 SQL LIKE 语义：
///
/// - `scope` 为 `None` 或空字符串 → 全局，对所有书生效
/// - 否则 `scope` 字符串里**包含** `book_name` 或 `book_origin` 即匹配
/// - `exclude_scope` 同语义但反向：命中即跳过该规则
/// - 当 `book_name` / `book_origin` 自身为空时，不参与子串匹配（防御
///   `"".contains("") == true` 的边界 case），相当于"我们不知道这本
///   书是什么"，scope 非空的规则就会被跳过
fn matches_scope(rule: &core_storage::models::ReplaceRule, book_name: &str, book_origin: &str) -> bool {
    let scope = rule.scope.as_deref().unwrap_or("");
    if scope.is_empty() {
        // Even with global scope, an excluded book name/origin still skips.
        if let Some(ref exclude) = rule.exclude_scope {
            if !exclude.is_empty() {
                let name_excluded = !book_name.is_empty() && exclude.contains(book_name);
                let origin_excluded =
                    !book_origin.is_empty() && exclude.contains(book_origin);
                if name_excluded || origin_excluded {
                    return false;
                }
            }
        }
        return true;
    }
    let name_match = !book_name.is_empty() && scope.contains(book_name);
    let origin_match = !book_origin.is_empty() && scope.contains(book_origin);
    if !(name_match || origin_match) {
        return false;
    }
    if let Some(ref exclude) = rule.exclude_scope {
        if !exclude.is_empty() {
            let name_excluded = !book_name.is_empty() && exclude.contains(book_name);
            let origin_excluded =
                !book_origin.is_empty() && exclude.contains(book_origin);
            if name_excluded || origin_excluded {
                return false;
            }
        }
    }
    true
}

/// R123: unified cache for both the enabled-rule list and the
/// compiled regexes. Both halves are tagged with the caller's
/// `cache_generation` and can only be observed inside the single
/// `Mutex` below — so concurrent callers with different generations
/// can't interleave such that one wipes the other's freshly-built
/// state. See [`apply_replace_rules_impl`] for the full rationale.
///
/// Compile failures are remembered as `None` within a single
/// generation so we don't re-warn on every chapter; advancing the
/// generation clears them too, which is the right thing if the user
/// fixed the bad pattern.
///
/// R48: the rule-list cache key includes `db_path` so a multi-DB
/// workflow (test fixtures, profile switching, two isolates pointed
/// at different files) doesn't get a hit from another DB's rule set.
struct ReplaceRulesCache {
    /// Rule list cached by `(db_path, generation)`. `None` until
    /// the first cache miss populates it.
    rule_list: Option<(String, i64, std::sync::Arc<Vec<core_storage::models::ReplaceRule>>)>,
    /// Generation tag for the regex entries below; advancing it clears
    /// all entries. `None` on first use (cache empty).
    regex_generation: Option<i64>,
    /// Compiled regex by `(rule_id, pattern)`. A `None` value remembers
    /// a compile failure within the current generation.
    regex_entries: std::collections::HashMap<(String, String), Option<regex::Regex>>,
}

impl ReplaceRulesCache {
    fn new() -> Self {
        Self {
            rule_list: None,
            regex_generation: None,
            regex_entries: std::collections::HashMap::new(),
        }
    }

    /// Returns the cached rule list when `(db_path, generation)` matches;
    /// otherwise loads via the closure and stores. The caller is responsible
    /// for calling [`Self::ensure_regex_generation`] right after — this
    /// method intentionally does NOT touch the regex side so that callers
    /// observe both halves in a single critical section.
    fn get_or_load_rules<F>(
        &mut self,
        db_path: &str,
        generation: i64,
        load: F,
    ) -> Result<std::sync::Arc<Vec<core_storage::models::ReplaceRule>>, String>
    where
        F: FnOnce() -> Result<Vec<core_storage::models::ReplaceRule>, String>,
    {
        if let Some((ref cached_path, gen, ref rules)) = self.rule_list {
            if gen == generation && cached_path == db_path {
                return Ok(rules.clone());
            }
        }
        let fresh = load()?;
        let arc = std::sync::Arc::new(fresh);
        self.rule_list = Some((db_path.to_string(), generation, arc.clone()));
        Ok(arc)
    }

    /// Drop cached regex entries when the caller's generation changes.
    /// Cheap when generation matches (no allocation, no work).
    fn ensure_regex_generation(&mut self, generation: i64) {
        if self.regex_generation == Some(generation) {
            return;
        }
        self.regex_entries.clear();
        self.regex_generation = Some(generation);
    }

    /// Get-or-compile a regex within the current generation. Returns
    /// `None` if the pattern fails to compile (and remembers the failure
    /// so we don't re-warn on every chapter).
    fn get_or_compile_regex(&mut self, id: &str, pattern: &str) -> Option<&regex::Regex> {
        // R50: single hash via `entry` instead of contains_key + insert + get.
        let key = (id.to_string(), pattern.to_string());
        self.regex_entries
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

static REPLACE_RULES_CACHE: std::sync::LazyLock<std::sync::Mutex<ReplaceRulesCache>> =
    std::sync::LazyLock::new(|| std::sync::Mutex::new(ReplaceRulesCache::new()));

// ============================================================
// 本地备份 / 恢复 (批次 10)
// ============================================================

/// 把当前 DB 5 张表（books / book_groups / bookmarks / replace_rules /
/// book_sources）导出成 Legado 兼容的 zip 备份。文件名由 caller 指定。
pub fn export_backup_zip(db_path: String, out_zip_path: String) -> Result<(), String> {
    let conn = open_db(&db_path)?;
    core_storage::backup_dao::export_to_zip(&conn, &out_zip_path)
}

/// 解压 zip → 字段映射 → upsert 入库。返回 `ImportSummary` 的 JSON 字符串
/// （`{books, groups, bookmarks, replace_rules, sources, errors}`）。
pub fn import_backup_zip(db_path: String, zip_path: String) -> Result<String, String> {
    let mut conn = open_db(&db_path)?;
    let summary = core_storage::backup_dao::import_from_zip(&mut conn, &zip_path)?;
    serde_json::to_string(&summary).map_err(|e| format!("序列化 ImportSummary 失败: {}", e))
}

/// 列 zip 内**已识别**的 Legado 备份文件名（不解析内容，dry-run 用）。
/// 返回 JSON 字符串数组。
pub fn validate_backup_zip(zip_path: String) -> Result<String, String> {
    let names = core_storage::backup_dao::validate_zip(&zip_path)?;
    serde_json::to_string(&names).map_err(|e| format!("序列化失败: {}", e))
}

// ============================================================
// WebDAV 同步 (批次 11)
// ============================================================

/// 探活 — 用 PROPFIND Depth=0 验证 url + 凭据是否能访问。
/// 设置页"测试连接"按钮调用。成功返回 ()，失败返回错误描述。
pub async fn webdav_check(
    url: String,
    user: String,
    password: String,
) -> Result<(), String> {
    let client = core_net::webdav::WebDavClient::new(url, user, password);
    client.check().await
}

/// 列远端 base_url 下的 backup*.zip 文件名（已过滤非 backup 前缀的项）。
/// 返回 JSON 字符串数组。Flutter 侧用于"从 WebDAV 恢复" 的下拉单选。
pub async fn webdav_list_backups(
    url: String,
    user: String,
    password: String,
) -> Result<String, String> {
    let client = core_net::webdav::WebDavClient::new(url, user, password);
    let names = client.list_files().await?;
    serde_json::to_string(&names).map_err(|e| format!("序列化失败: {}", e))
}

/// 本地 export → 临时 zip → PUT 到 WebDAV。
///
/// 实现：用 [`tempfile::NamedTempFile`] 创建一次性 zip，调
/// [`core_storage::backup_dao::export_to_zip`] 写入，然后 `std::fs::read`
/// 整体读出 PUT 上去。`NamedTempFile` 会在 fn 返回时自动清理。
///
/// 不需要事先 MKCOL：调用方应自行保证 `url` 指向已存在的 collection,
/// 否则 PUT 一般会 404 / 409。如未来需要"首次同步建目录"，可在 UI 端
/// 单独调 `webdav_check` 失败时回退尝试 mkcol。
pub async fn webdav_upload_backup(
    db_path: String,
    url: String,
    user: String,
    password: String,
    file_name: String,
) -> Result<(), String> {
    // 1. export 到本地临时 zip
    let tmp = tempfile::Builder::new()
        .prefix("legado-backup-")
        .suffix(".zip")
        .tempfile()
        .map_err(|e| format!("创建临时文件失败: {}", e))?;
    let tmp_path = tmp
        .path()
        .to_str()
        .ok_or_else(|| "临时文件路径无效".to_string())?
        .to_string();
    {
        let conn = open_db(&db_path)?;
        core_storage::backup_dao::export_to_zip(&conn, &tmp_path)?;
    }
    // 2. 读 bytes
    let bytes = std::fs::read(&tmp_path).map_err(|e| format!("读取临时 zip 失败: {}", e))?;
    // 3. PUT
    let client = core_net::webdav::WebDavClient::new(url, user, password);
    client.upload(&file_name, bytes).await?;
    // tmp 在此处 drop,自动清理
    drop(tmp);
    Ok(())
}

/// GET 远端 zip → 写到临时文件 → import → 返回 ImportSummary JSON。
///
/// 与 [`import_backup_zip`] 行为完全一致，区别是 zip 来源是远端 GET
/// 而非本地路径。失败时临时文件依然由 `NamedTempFile` 自动清理。
pub async fn webdav_download_backup(
    db_path: String,
    url: String,
    user: String,
    password: String,
    file_name: String,
) -> Result<String, String> {
    // 1. GET
    let client = core_net::webdav::WebDavClient::new(url, user, password);
    let bytes = client.download(&file_name).await?;
    // 2. 写到临时 zip
    let tmp = tempfile::Builder::new()
        .prefix("legado-restore-")
        .suffix(".zip")
        .tempfile()
        .map_err(|e| format!("创建临时文件失败: {}", e))?;
    let tmp_path = tmp
        .path()
        .to_str()
        .ok_or_else(|| "临时文件路径无效".to_string())?
        .to_string();
    std::fs::write(&tmp_path, &bytes).map_err(|e| format!("写入临时 zip 失败: {}", e))?;
    // 3. import
    let summary = {
        let mut conn = open_db(&db_path)?;
        core_storage::backup_dao::import_from_zip(&mut conn, &tmp_path)?
    };
    drop(tmp);
    serde_json::to_string(&summary).map_err(|e| format!("序列化 ImportSummary 失败: {}", e))
}

/// 删除远端 backup zip（用户在恢复对话框里也可"清理远端旧备份"）。
pub async fn webdav_delete_backup(
    url: String,
    user: String,
    password: String,
    file_name: String,
) -> Result<(), String> {
    let client = core_net::webdav::WebDavClient::new(url, user, password);
    client.delete(&file_name).await
}

// ============================================================
// 备份密码持久化 (批次 12 / 05-19)
// ============================================================
//
// 与原 Legado `LocalConfig.password` 行为一致：明文存到 prefs 文件
// （`<documents_dir>/legado_local.json`），密码空串等价于"未设密码"。
// 真正加密生效在导出/导入 zip 时：调
// [`core_storage::legado_aes::encrypt_legado_aes`] / `decrypt_legado_aes`
// 把这个密码作为 key 派生输入。
//
// **不**加密 webdav.json 本机存储 —— 那是另一份独立配置，原 Legado 也只
// 加密**导出 zip 内的 web_dav_password 字段**，不加密本机 prefs。

const LEGADO_LOCAL_FILE: &str = "legado_local.json";

/// 设置备份密码（持久化到 `<documents_dir>/legado_local.json` 的
/// `"password"` 字段）。
///
/// `password = ""` 等价于"未设密码"（与原 Legado `LocalConfig.password`
/// 默认值一致）—— 此时备份 zip 仍走 AES 加密但 key = MD5("")。
pub fn set_backup_password(documents_dir: String, password: String) -> Result<(), String> {
    let path = std::path::Path::new(&documents_dir).join(LEGADO_LOCAL_FILE);
    // 读现有 JSON（若存在），仅覆盖 password 字段，保留未来其它配置项。
    let mut map: serde_json::Map<String, serde_json::Value> = match std::fs::read_to_string(&path)
    {
        Ok(text) => serde_json::from_str(&text)
            .ok()
            .and_then(|v: serde_json::Value| v.as_object().cloned())
            .unwrap_or_default(),
        Err(_) => serde_json::Map::new(),
    };
    map.insert(
        "password".to_string(),
        serde_json::Value::String(password),
    );
    let text = serde_json::to_string(&serde_json::Value::Object(map))
        .map_err(|e| format!("序列化 legado_local.json 失败: {}", e))?;
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|e| format!("创建配置目录失败: {}", e))?;
    }
    std::fs::write(&path, text).map_err(|e| format!("写入 legado_local.json 失败: {}", e))
}

/// 读取当前备份密码；不存在或 JSON 解析失败时返回空串（等价"未设密码"）。
pub fn get_backup_password(documents_dir: String) -> Result<String, String> {
    let path = std::path::Path::new(&documents_dir).join(LEGADO_LOCAL_FILE);
    match std::fs::read_to_string(&path) {
        Ok(text) => {
            let v: serde_json::Value = match serde_json::from_str(&text) {
                Ok(v) => v,
                Err(_) => return Ok(String::new()),
            };
            Ok(v.get("password")
                .and_then(|p| p.as_str())
                .unwrap_or("")
                .to_string())
        }
        Err(_) => Ok(String::new()),
    }
}

// ============================================================
// 本地书导入 (批次 13 / 05-19)
// ============================================================

/// 导入本地书（TXT / EPUB / UMD）。返回 `{"book_id": "..."}` JSON 字符串。
///
/// 流程（对齐原 Legado `ImportBookActivity` MVP）：
/// 1. 按 `file_path` 扩展名分发 `core_parser` 三个解析器之一
/// 2. 复制源文件到 `<documents_dir>/local_books/<book_id>_<basename>`
///    防原文件移动 / 删除断链
/// 3. 确保虚拟"本地书"书源（id="local"/url="loc_book"）存在
/// 4. 构造 `Book`：name 优先取 EPUB metadata.title，fallback basename(去扩展)
///    `book_url = "loc_book:<copied_path>"`，`source_id = "local"`
/// 5. 章节适配后 `ChapterDao::replace_by_book`（不保留旧章节正文）
/// 6. `BookDao::upsert(&book)`
///
/// 不在 scope 内：mobi / pdf / cbz、TxtTocRule 自定义切分、cover 提取。
pub fn import_local_book(
    db_path: String,
    file_path: String,
    documents_dir: String,
) -> Result<String, String> {
    let path = std::path::Path::new(&file_path);
    let ext = path
        .extension()
        .and_then(|e| e.to_str())
        .map(|s| s.to_ascii_lowercase())
        .ok_or_else(|| "缺少文件扩展名".to_string())?;

    // basename 不带扩展，作为 Book.name 的 fallback
    let basename_no_ext = path
        .file_stem()
        .map(|s| s.to_string_lossy().to_string())
        .unwrap_or_default();

    // 1. 分发 parser
    let (chapters, epub_meta) = match ext.as_str() {
        "txt" => (
            core_parser::txt::parse_txt_file(&file_path)
                .map_err(|e| format!("TXT 解析失败: {}", e))?,
            None,
        ),
        "epub" => {
            let (meta, chs) = core_parser::epub::parse_epub_file(&file_path)
                .map_err(|e| format!("EPUB 解析失败: {}", e))?;
            (chs, Some(meta))
        }
        "umd" => (
            core_parser::umd::parse_umd_file(&file_path)
                .map_err(|e| format!("UMD 解析失败: {}", e))?,
            None,
        ),
        other => return Err(format!("不支持的文件类型: .{}", other)),
    };

    if chapters.is_empty() {
        return Err("文件解析后无任何章节".to_string());
    }

    // 2. 生成 book_id（先生成才能拼复制后的目标路径）
    let book_id = uuid::Uuid::new_v4().to_string();
    let now = chrono::Utc::now().timestamp();

    // 3. 复制源文件到 local_books
    let copied_path = crate::local_book::copy_to_local_books_dir(
        path,
        std::path::Path::new(&documents_dir),
        &book_id,
    )?;

    // 4. 打开 db + 确保虚拟 source
    let mut conn = open_db(&db_path)?;
    let source_id = crate::local_book::ensure_local_source(&mut conn)?;

    // 5. 构造 Book
    let book_url = format!(
        "{}:{}",
        crate::local_book::LOCAL_BOOK_URL_KEY,
        copied_path.display()
    );
    // EPUB metadata.title / author 优先，fallback basename
    let (name, author) = match epub_meta {
        Some(ref m) => {
            let n = m
                .title
                .clone()
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
                .unwrap_or_else(|| basename_no_ext.clone());
            let a = m
                .author
                .clone()
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty());
            (n, a)
        }
        None => (basename_no_ext.clone(), None),
    };
    let total_word_count: i32 = chapters
        .iter()
        .map(|c| c.content.chars().count() as i32)
        .sum();
    let latest_chapter_title = chapters.last().map(|c| c.title.clone());
    let book = core_storage::models::Book {
        id: book_id.clone(),
        source_id,
        source_name: Some("本地书".to_string()),
        name,
        author,
        cover_url: None,
        chapter_count: chapters.len() as i32,
        latest_chapter_title,
        intro: None,
        kind: None,
        book_url: Some(book_url),
        toc_url: None,
        last_check_time: None,
        last_check_count: 0,
        total_word_count,
        can_update: false, // 本地书不需要远端更新
        order_time: now,
        latest_chapter_time: Some(now),
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

    // 6. 章节适配 + 入库
    let storage_chapters =
        crate::local_book::parser_chapters_to_storage(&chapters, &book_id, now);
    // 注意：必须先 upsert Book（books.id 是 chapters.book_id 外键），再
    // replace_by_book 写章节，否则触发 FOREIGN KEY constraint failed。
    {
        let book_dao = core_storage::book_dao::BookDao::new(&conn);
        book_dao
            .upsert(&book)
            .map_err(|e| format!("写入书籍失败: {}", e))?;
    }
    {
        let mut chapter_dao = core_storage::chapter_dao::ChapterDao::new(&mut conn);
        chapter_dao
            .replace_by_book(&book_id, &storage_chapters)
            .map_err(|e| format!("写入章节失败: {}", e))?;
    }

    serde_json::to_string(&serde_json::json!({ "book_id": book_id }))
        .map_err(|e| format!("序列化失败: {}", e))
}

// ============================================================
// 阅读时长统计 (批次 14 / 05-19) — ReadRecord
// ============================================================
//
// 对齐原 Legado `ReadRecord.kt`。reader_page Timer 每 60s 调
// [`add_read_time`] 累加；设置页"阅读统计" UI 通过 [`list_read_records`]
// + [`get_total_read_time`] 拉数据；书架卡片需要单本时长用
// [`get_read_record`]（MVP 暂不在书架卡片显示，但 fn 留着以备扩展）。

/// 累加某本书的阅读时长（秒）。若 `book_id` 已有记录则 read_time +=
/// delta_seconds + last_read_at = now；否则 INSERT 新行。
pub fn add_read_time(
    db_path: String,
    book_id: String,
    book_name: String,
    delta_seconds: i64,
) -> Result<(), String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::read_record_dao::ReadRecordDao::new(&conn);
    dao.add_time(&book_id, &book_name, delta_seconds)
        .map_err(|e| format!("累加阅读时长失败: {}", e))
}

/// 取单本书的阅读记录，返回 JSON `Option<ReadRecord>`。
pub fn get_read_record(db_path: String, book_id: String) -> Result<String, String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::read_record_dao::ReadRecordDao::new(&conn);
    let rec = dao
        .get_by_book(&book_id)
        .map_err(|e| format!("查询阅读记录失败: {}", e))?;
    serde_json::to_string(&rec).map_err(|e| format!("序列化失败: {}", e))
}

/// 列出所有阅读记录（按 last_read_at DESC），返回 JSON 数组。
/// 设置页"阅读统计"用。
pub fn list_read_records(db_path: String) -> Result<String, String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::read_record_dao::ReadRecordDao::new(&conn);
    let list = dao
        .list_all()
        .map_err(|e| format!("获取阅读记录列表失败: {}", e))?;
    serde_json::to_string(&list).map_err(|e| format!("序列化失败: {}", e))
}

/// 全局总阅读时长（秒）。空表返回 0。
pub fn get_total_read_time(db_path: String) -> Result<i64, String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::read_record_dao::ReadRecordDao::new(&conn);
    dao.total_read_time()
        .map_err(|e| format!("获取总阅读时长失败: {}", e))
}

// ============================================================
// 缓存管理 (批次 15 / 05-19) — CacheStats
// ============================================================
//
// 对齐原 Legado `CacheActivity.kt`。设置页"缓存管理" UI 通过
// [`list_books_with_cache_stats`] 拉数据；用户点单本/全局清空时分别
// 调 [`clear_book_cache`] / [`clear_all_cache`]。后者只动 chapters.content
// 字段（置 NULL），不删 chapters 行 — 章节列表与目录依旧完整，仅释放
// 已下载的正文文本。

/// 单本已缓存章节数（content IS NOT NULL 且非空串）。MVP 暂未在 UI 端
/// 直接调用（list_books_with_cache_stats 已包含），但保留便于上层扩展
/// 单本详情页。
pub fn count_cached_chapters_for_book(
    db_path: String,
    book_id: String,
) -> Result<i64, String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::cache_stats_dao::CacheStatsDao::new(&conn);
    dao.count_cached_chapters_for_book(&book_id)
        .map_err(|e| format!("查询缓存章节数失败: {}", e))
}

/// 列出所有书的缓存统计（按 cached DESC），返回
/// `Vec<BookCacheStats>` 的 JSON。
pub fn list_books_with_cache_stats(db_path: String) -> Result<String, String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::cache_stats_dao::CacheStatsDao::new(&conn);
    let stats = dao
        .list_books_with_cache_stats()
        .map_err(|e| format!("获取缓存统计失败: {}", e))?;
    serde_json::to_string(&stats).map_err(|e| format!("序列化失败: {}", e))
}

/// 单本清空缓存：UPDATE chapters SET content=NULL WHERE book_id=?。
/// 返回受影响行数。
pub fn clear_book_cache(db_path: String, book_id: String) -> Result<i64, String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::cache_stats_dao::CacheStatsDao::new(&conn);
    dao.clear_book_cache(&book_id)
        .map_err(|e| format!("清空书籍缓存失败: {}", e))
}

/// 全局清空缓存：UPDATE chapters SET content=NULL（无 WHERE）。
/// 返回受影响行数。
pub fn clear_all_cache(db_path: String) -> Result<i64, String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::cache_stats_dao::CacheStatsDao::new(&conn);
    dao.clear_all_cache()
        .map_err(|e| format!("全局清空缓存失败: {}", e))
}

// ============================================================
// RSS 源管理 (批次 16 / 05-19) — RssSource
// ============================================================
//
// 对齐原 Legado RssSource CRUD。schema 在批次 16 (v12) 新增
// (`rss_sources` 表 + 4 个索引)，DAO 在 [`core_storage::rss_source_dao`]。
// 本节仅做"源管理"骨架；拉取 / 解析 / 文章列表 / 收藏 UI 留批次 17/18。

/// 列出所有 RSS 源（按 custom_order ASC, source_name ASC），返回 JSON 数组。
pub fn rss_source_list_all(db_path: String) -> Result<String, String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::rss_source_dao::RssSourceDao::new(&conn);
    let list = dao
        .list_all()
        .map_err(|e| format!("获取 RSS 源列表失败: {}", e))?;
    serde_json::to_string(&list).map_err(|e| format!("序列化失败: {}", e))
}

/// 列出已启用的 RSS 源。
pub fn rss_source_list_enabled(db_path: String) -> Result<String, String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::rss_source_dao::RssSourceDao::new(&conn);
    let list = dao
        .list_enabled()
        .map_err(|e| format!("获取已启用 RSS 源失败: {}", e))?;
    serde_json::to_string(&list).map_err(|e| format!("序列化失败: {}", e))
}

/// 列出指定分组下的 RSS 源（严格按 source_group = ? 匹配）。
pub fn rss_source_list_by_group(db_path: String, group: String) -> Result<String, String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::rss_source_dao::RssSourceDao::new(&conn);
    let list = dao
        .list_by_group(&group)
        .map_err(|e| format!("按分组获取 RSS 源失败: {}", e))?;
    serde_json::to_string(&list).map_err(|e| format!("序列化失败: {}", e))
}

/// DISTINCT 分组列表（跳过 NULL/空），返回 JSON 字符串数组。
pub fn rss_source_list_groups(db_path: String) -> Result<String, String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::rss_source_dao::RssSourceDao::new(&conn);
    let groups = dao
        .list_groups()
        .map_err(|e| format!("获取 RSS 分组失败: {}", e))?;
    serde_json::to_string(&groups).map_err(|e| format!("序列化失败: {}", e))
}

/// 按 source_url 取单条 RSS 源，返回 JSON `Option<RssSource>`。
pub fn rss_source_get(db_path: String, url: String) -> Result<String, String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::rss_source_dao::RssSourceDao::new(&conn);
    let s = dao
        .get_by_url(&url)
        .map_err(|e| format!("查询 RSS 源失败: {}", e))?;
    serde_json::to_string(&s).map_err(|e| format!("序列化失败: {}", e))
}

/// upsert 单条 RSS 源（source_json = `RssSource` 的 JSON），返回受影响行数。
pub fn rss_source_upsert(db_path: String, source_json: String) -> Result<i64, String> {
    let conn = open_db(&db_path)?;
    let source: core_storage::models::RssSource =
        serde_json::from_str(&source_json).map_err(|e| format!("JSON 解析失败: {}", e))?;
    let dao = core_storage::rss_source_dao::RssSourceDao::new(&conn);
    dao.upsert(&source)
        .map(|n| n as i64)
        .map_err(|e| format!("写入 RSS 源失败: {}", e))
}

/// 切换 enabled，返回受影响行数。
pub fn rss_source_set_enabled(
    db_path: String,
    url: String,
    enabled: bool,
) -> Result<i64, String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::rss_source_dao::RssSourceDao::new(&conn);
    dao.set_enabled(&url, enabled)
        .map(|n| n as i64)
        .map_err(|e| format!("更新 RSS 源状态失败: {}", e))
}

/// 按 source_url 删除 RSS 源，返回受影响行数。
pub fn rss_source_delete(db_path: String, url: String) -> Result<i64, String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::rss_source_dao::RssSourceDao::new(&conn);
    dao.delete_by_url(&url)
        .map(|n| n as i64)
        .map_err(|e| format!("删除 RSS 源失败: {}", e))
}

/// 从 JSON 批量导入 RSS 源（支持端口内部 / 原 Legado 双格式）。返回
/// [`core_storage::models::RssImportSummary`] 的 JSON 字符串
/// （`{added, updated, skipped}`）。
pub fn rss_source_import_json(db_path: String, json: String) -> Result<String, String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::rss_source_dao::RssSourceDao::new(&conn);
    let summary = dao.import_from_json(&json)?;
    serde_json::to_string(&summary).map_err(|e| format!("序列化 RssImportSummary 失败: {}", e))
}

// ============================================================
// RSS 拉取 + 文章列表 (批次 17 / 05-19)
// ============================================================
//
// 6 个 fn (funcId 91-96) — 沿袭 RssSource CRUD（批次 16）/ webdav 异步
// (批次 11) 的格式。`rss_get_articles` 为 async：拉取 + 解析 + upsert
// 入库 + 返回排序后的列表；其它 5 个为 sync。

/// async 拉取 + 解析 + upsert + 返回入库后排序的列表。
///
/// 工作流：
/// 1. 从 DB 取 RssSource（不存在 → Err）
/// 2. 调 RssParser::get_articles 拉取 + 解析（XML 路 / 规则路自适应）
/// 3. RssArticleDao::upsert_batch（保留每条已有 read_time/star）
/// 4. RssArticleDao::list_by_origin_sort 返回 sorted Vec<RssArticle> 的 JSON
///
/// 注意：本实现**不**把 ParserError::Empty 转 `[]`，而是返回 Err 让
/// UI 层显示"暂无文章"。这里区分自 search_books_online 的处理 — RSS
/// "暂无文章"是 UI 友好提示，不是搜索结果空集。
pub async fn rss_get_articles(
    db_path: String,
    source_url: String,
    sort_name: String,
    sort_url: String,
    page: i32,
) -> Result<String, String> {
    // 1. 取 source（在 await 前结束 conn 的 lifetime）
    let source = {
        let conn = open_db(&db_path)?;
        let dao = core_storage::rss_source_dao::RssSourceDao::new(&conn);
        dao.get_by_url(&source_url)
            .map_err(|e| format!("查询 RSS 源失败: {}", e))?
            .ok_or_else(|| format!("RSS 源不存在: {}", source_url))?
    };

    // 2. 拉取 + 解析
    let parser = core_source::RssParser::new();
    let mut articles = match parser
        .get_articles(&source, &sort_name, &sort_url, page)
        .await
    {
        Ok(a) => a,
        Err(core_source::ParserError::Empty) => Vec::new(),
        Err(e) => return Err(e.to_string()),
    };

    // 3. order_num 重排（确保从 0 开始）
    for (i, a) in articles.iter_mut().enumerate() {
        a.order_num = i as i32;
    }

    // 4. upsert + 重读
    let conn = open_db(&db_path)?;
    let dao = core_storage::rss_article_dao::RssArticleDao::new(&conn);
    if !articles.is_empty() {
        dao.upsert_batch(&articles)
            .map_err(|e| format!("写入 RSS 文章失败: {}", e))?;
    }
    // 重读 — 拿到 DB 已有 read_time/star 的最终结果
    let sort_filter = if sort_name.trim().is_empty() {
        None
    } else {
        Some(sort_name.as_str())
    };
    let final_list = dao
        .list_by_origin_sort(&source.source_url, sort_filter, -1, 0)
        .map_err(|e| format!("读取 RSS 文章失败: {}", e))?;
    serde_json::to_string(&final_list).map_err(|e| format!("序列化失败: {}", e))
}

/// 列出 DB 中已有的 RSS 文章（不拉取）。UI 切 sort tab 时用，避免
/// 每次切换都 round-trip 网络。
pub fn rss_list_articles(
    db_path: String,
    source_url: String,
    sort: Option<String>,
) -> Result<String, String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::rss_article_dao::RssArticleDao::new(&conn);
    let sort_filter = sort.as_deref().filter(|s| !s.trim().is_empty());
    let articles = dao
        .list_by_origin_sort(&source_url, sort_filter, -1, 0)
        .map_err(|e| format!("读取 RSS 文章失败: {}", e))?;
    serde_json::to_string(&articles).map_err(|e| format!("序列化失败: {}", e))
}

/// 标记文章已读：双写 rss_articles + rss_read_records，返回受影响行数。
pub fn rss_mark_read(db_path: String, link: String, ts: i64) -> Result<i64, String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::rss_article_dao::RssArticleDao::new(&conn);
    dao.mark_read(&link, ts)
        .map(|n| n as i64)
        .map_err(|e| format!("标记已读失败: {}", e))
}

/// 某 RSS 源的未读文章数。
pub fn rss_count_unread(db_path: String, source_url: String) -> Result<i64, String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::rss_article_dao::RssArticleDao::new(&conn);
    dao.count_unread_by_origin(&source_url)
        .map_err(|e| format!("统计未读失败: {}", e))
}

/// 删除某 RSS 源下的全部文章（删源时清理）。
pub fn rss_delete_articles_by_source(
    db_path: String,
    source_url: String,
) -> Result<i64, String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::rss_article_dao::RssArticleDao::new(&conn);
    dao.delete_by_origin(&source_url)
        .map(|n| n as i64)
        .map_err(|e| format!("清理 RSS 文章失败: {}", e))
}

/// 解析 source.sort_url → `[{name, url}]` JSON。空字符串 / 缺源都返回 `[]`。
///
/// `sort_url` 格式（与原 Legado 同）：`name1::url1\nname2::url2` —
/// 单 URL 模式可空。
pub fn rss_get_sort_tabs(db_path: String, source_url: String) -> Result<String, String> {
    let source = {
        let conn = open_db(&db_path)?;
        let dao = core_storage::rss_source_dao::RssSourceDao::new(&conn);
        dao.get_by_url(&source_url)
            .map_err(|e| format!("查询 RSS 源失败: {}", e))?
    };
    let mut tabs: Vec<serde_json::Value> = Vec::new();
    if let Some(s) = source.as_ref().and_then(|s| s.sort_url.as_deref()) {
        for line in s.split('\n') {
            let line = line.trim();
            if line.is_empty() {
                continue;
            }
            if let Some((name, url)) = line.split_once("::") {
                let name = name.trim();
                let url = url.trim();
                if name.is_empty() && url.is_empty() {
                    continue;
                }
                tabs.push(serde_json::json!({"name": name, "url": url}));
            } else {
                // 没有 :: 分隔，把整行当 name + 空 url（兼容退化格式）
                tabs.push(serde_json::json!({"name": line, "url": ""}));
            }
        }
    }
    serde_json::to_string(&tabs).map_err(|e| format!("序列化失败: {}", e))
}

// ============================================================
// RSS 文章详情 + 收藏 (批次 18 / 05-19)
// ============================================================
//
// 5 个 fn (funcId 97-101)。`rss_fetch_article_content` 为 async（拉取
// HTML），其它 4 个为 sync（DB 操作）。
//
// 设计要点：
// - rss_fetch_article_content 内部走 RssParser::fetch_article_content_full
//   返回 `{html, base_url}` JSON，dart 端用 WebViewController.loadHtmlString
//   渲染（base_url 让 WebView 解析相对链接）。
// - rss_star_add 接收 `article_json`（RssArticle 的 JSON 字符串）+
//   `source_name`，在 dart 端方便构造（detail 页拿到 RssArticle 直接序列化）。

/// async：读 source / article → 调 fetch_article_content_full → 返回
/// 拼装好的 `{html, base_url}` JSON。
///
/// 错误：
/// - source / article 不存在 → Err
/// - fetch 内部错误 → 透传（参考 ParserError::Display）
pub async fn rss_fetch_article_content(
    db_path: String,
    source_url: String,
    link: String,
) -> Result<String, String> {
    // 1. 取 source（async 前结束 conn lifetime）
    let (source, article) = {
        let conn = open_db(&db_path)?;
        let source = core_storage::rss_source_dao::RssSourceDao::new(&conn)
            .get_by_url(&source_url)
            .map_err(|e| format!("查询 RSS 源失败: {}", e))?
            .ok_or_else(|| format!("RSS 源不存在: {}", source_url))?;
        let article = core_storage::rss_article_dao::RssArticleDao::new(&conn)
            .get_by_origin_link(&source_url, &link)
            .map_err(|e| format!("查询 RSS 文章失败: {}", e))?
            .ok_or_else(|| format!("RSS 文章不存在: {}", link))?;
        (source, article)
    };

    // 2. 拉取
    let parser = core_source::RssParser::new();
    let fetched = parser
        .fetch_article_content_full(&source, &article)
        .await
        .map_err(|e| e.to_string())?;
    serde_json::to_string(&fetched).map_err(|e| format!("序列化失败: {}", e))
}

/// 收藏一篇文章。`article_json` 应为 [`core_storage::models::RssArticle`]
/// 的 JSON 字符串；`source_name` 来自 [`RssSource::source_name`]。
/// 重复收藏走 `INSERT OR REPLACE`，star_time 自动刷新。返回受影响行数（i64）。
pub fn rss_star_add(
    db_path: String,
    article_json: String,
    source_name: String,
) -> Result<i64, String> {
    let article: core_storage::models::RssArticle =
        serde_json::from_str(&article_json).map_err(|e| format!("JSON 解析失败: {}", e))?;
    let conn = open_db(&db_path)?;
    let dao = core_storage::rss_star_dao::RssStarDao::new(&conn);
    dao.add(&article, &source_name)
        .map(|n| n as i64)
        .map_err(|e| format!("添加收藏失败: {}", e))
}

/// 取消收藏。返回受影响行数（0 表示原本就没收藏）。
pub fn rss_star_remove(
    db_path: String,
    origin: String,
    link: String,
) -> Result<i64, String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::rss_star_dao::RssStarDao::new(&conn);
    dao.remove(&origin, &link)
        .map(|n| n as i64)
        .map_err(|e| format!("取消收藏失败: {}", e))
}

/// 是否已收藏。
pub fn rss_star_is_starred(
    db_path: String,
    origin: String,
    link: String,
) -> Result<bool, String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::rss_star_dao::RssStarDao::new(&conn);
    dao.is_starred(&origin, &link)
        .map_err(|e| format!("查询收藏状态失败: {}", e))
}

/// 列出收藏（按 star_time DESC），返回 `Vec<RssStar>` JSON。
/// `limit < 0` 表示无分页（MVP 收藏页用 limit=-1）。
pub fn rss_star_list(
    db_path: String,
    limit: i64,
    offset: i64,
) -> Result<String, String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::rss_star_dao::RssStarDao::new(&conn);
    let list = dao
        .list_all(limit, offset)
        .map_err(|e| format!("读取收藏失败: {}", e))?;
    serde_json::to_string(&list).map_err(|e| format!("序列化失败: {}", e))
}

// ============================================================
// 订阅源 RuleSub (批次 19 / 05-19)
// ============================================================
//
// 7 个 fn (funcId 102-108)。CRUD 全 sync，refresh / refresh_all 异步
// (因为要 reqwest GET)。沿袭 RssSource 源管理（批次 16）+ webdav
// 异步 (批次 11) 风格。
//
// 设计要点：
// - rule_sub_create 内部生成 UUID + now() 时间戳，dart 端只需传 name/url/sub_type
// - rule_sub_refresh 按 sub_type 路由到 SourceDao::import_from_json /
//   RssSourceDao::import_from_json；sub_type=2 (替换规则) 暂占位返回
//   `{"sub_type":2,"error":"替换规则订阅暂未实装"}`，保留批次 21+ 实装
// - rule_sub_refresh_all 遍历所有订阅，单个失败不打断其它，每条结果
//   带 ok / message，方便 UI 滚动 SnackBar 汇总

/// 列出所有订阅源（custom_order ASC, name ASC），返回 JSON 数组。
pub fn rule_sub_list_all(db_path: String) -> Result<String, String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::rule_sub_dao::RuleSubDao::new(&conn);
    let list = dao
        .list_all()
        .map_err(|e| format!("获取订阅源列表失败: {}", e))?;
    serde_json::to_string(&list).map_err(|e| format!("序列化失败: {}", e))
}

/// 按 id 取单条订阅源，返回 JSON `Option<RuleSub>`。
pub fn rule_sub_get(db_path: String, id: String) -> Result<String, String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::rule_sub_dao::RuleSubDao::new(&conn);
    let s = dao
        .get_by_id(&id)
        .map_err(|e| format!("查询订阅源失败: {}", e))?;
    serde_json::to_string(&s).map_err(|e| format!("序列化失败: {}", e))
}

/// 新建订阅源 — 自动生成 UUID + 时间戳。返回新 RuleSub JSON。
///
/// `sub_type`：0=书源 / 1=RSS 源 / 2=替换规则（替换规则当前刷新会
/// 返回占位错误，但条目本身可以正常建）。
pub fn rule_sub_create(
    db_path: String,
    name: String,
    url: String,
    sub_type: i32,
) -> Result<String, String> {
    let conn = open_db(&db_path)?;
    let now = chrono::Utc::now().timestamp();
    let sub = core_storage::models::RuleSub {
        id: uuid::Uuid::new_v4().to_string(),
        name,
        url,
        sub_type,
        custom_order: 0,
        created_at: now,
        updated_at: now,
    };
    let dao = core_storage::rule_sub_dao::RuleSubDao::new(&conn);
    dao.upsert(&sub)
        .map_err(|e| format!("创建订阅源失败: {}", e))?;
    serde_json::to_string(&sub).map_err(|e| format!("序列化失败: {}", e))
}

/// 更新已有订阅源（id 必须存在）。返回受影响行数。
///
/// 调用方应先 get 已有 RuleSub 取出 created_at / custom_order，
/// 但本接口为简化 UI 调用，仅接收 4 个最常改字段（name/url/sub_type）：
/// 内部先 get_by_id 取 created_at + custom_order，再 upsert。
pub fn rule_sub_update(
    db_path: String,
    id: String,
    name: String,
    url: String,
    sub_type: i32,
) -> Result<i64, String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::rule_sub_dao::RuleSubDao::new(&conn);
    let mut existing = dao
        .get_by_id(&id)
        .map_err(|e| format!("查询订阅源失败: {}", e))?
        .ok_or_else(|| format!("订阅源不存在: {}", id))?;
    let now = chrono::Utc::now().timestamp();
    existing.name = name;
    existing.url = url;
    existing.sub_type = sub_type;
    existing.updated_at = now;
    dao.upsert(&existing)
        .map(|n| n as i64)
        .map_err(|e| format!("更新订阅源失败: {}", e))
}

/// 删除订阅源，返回受影响行数（0 表示原本就不存在）。
pub fn rule_sub_delete(db_path: String, id: String) -> Result<i64, String> {
    let conn = open_db(&db_path)?;
    let dao = core_storage::rule_sub_dao::RuleSubDao::new(&conn);
    dao.delete_by_id(&id)
        .map(|n| n as i64)
        .map_err(|e| format!("删除订阅源失败: {}", e))
}

/// async：刷新单条订阅 — 拉 sub.url → 按 sub_type 路由到对应 import。
///
/// 返回 JSON：
/// - `sub_type=0`：`{"sub_type":0, "count": N}` (导入书源数)
/// - `sub_type=1`：`{"sub_type":1, "summary": {added,updated,skipped}}`
/// - `sub_type=2`：`{"sub_type":2, "error": "替换规则订阅暂未实装"}`
///   （仍属"成功响应"，仅 error 字段提示，便于 UI 区分实现差距 vs 网络错）
pub async fn rule_sub_refresh(db_path: String, id: String) -> Result<String, String> {
    // 1. 取订阅条目（async 前先结束 conn lifetime）
    let sub = {
        let conn = open_db(&db_path)?;
        let dao = core_storage::rule_sub_dao::RuleSubDao::new(&conn);
        dao.get_by_id(&id)
            .map_err(|e| format!("查询订阅源失败: {}", e))?
            .ok_or_else(|| format!("订阅源不存在: {}", id))?
    };

    // 2. sub_type=2 直接占位返回（不发起 HTTP）
    if sub.sub_type == 2 {
        return Ok(serde_json::json!({
            "sub_type": 2,
            "error": "替换规则订阅暂未实装",
        })
        .to_string());
    }

    // 3. 拉远端 JSON（用 core_net::HttpClient 复用 cookie/重试/超时配置）
    let body = fetch_subscription_body(&sub.url).await?;

    // 4. 按 sub_type 路由 import
    match sub.sub_type {
        0 => {
            // 书源：SourceDao::import_from_json 需要 &mut Connection
            let mut conn = open_db(&db_path)?;
            let mut dao = core_storage::source_dao::SourceDao::new(&mut conn);
            let count = dao
                .import_from_json(&body)
                .map_err(|e| format!("导入书源失败: {}", e))?;
            Ok(serde_json::json!({
                "sub_type": 0,
                "count": count as i64,
            })
            .to_string())
        }
        1 => {
            // RSS 源：RssSourceDao::import_from_json 只需 &Connection
            let conn = open_db(&db_path)?;
            let dao = core_storage::rss_source_dao::RssSourceDao::new(&conn);
            let summary = dao
                .import_from_json(&body)
                .map_err(|e| format!("导入 RSS 源失败: {}", e))?;
            Ok(serde_json::json!({
                "sub_type": 1,
                "summary": summary,
            })
            .to_string())
        }
        other => Err(format!("未知 sub_type: {}", other)),
    }
}

/// async：刷新全部订阅源。每条独立处理，单个失败不打断其它。
///
/// 返回 JSON 数组：
/// `[{"id":..., "name":..., "sub_type":N, "ok":true/false, "message":"..."}]`
pub async fn rule_sub_refresh_all(db_path: String) -> Result<String, String> {
    let subs = {
        let conn = open_db(&db_path)?;
        let dao = core_storage::rule_sub_dao::RuleSubDao::new(&conn);
        dao.list_all()
            .map_err(|e| format!("获取订阅源列表失败: {}", e))?
    };

    let mut results: Vec<serde_json::Value> = Vec::with_capacity(subs.len());
    for sub in subs {
        // 整条 try/catch — 单条失败不抛
        let item = match rule_sub_refresh(db_path.clone(), sub.id.clone()).await {
            Ok(json) => {
                // 把 refresh 返回的内嵌字段揉进去
                let inner: serde_json::Value =
                    serde_json::from_str(&json).unwrap_or(serde_json::Value::Null);
                let message = if let Some(err) = inner.get("error").and_then(|v| v.as_str()) {
                    err.to_string()
                } else if let Some(count) = inner.get("count").and_then(|v| v.as_i64()) {
                    format!("已导入 {} 个书源", count)
                } else if let Some(summary) = inner.get("summary") {
                    let added = summary.get("added").and_then(|v| v.as_i64()).unwrap_or(0);
                    let updated = summary.get("updated").and_then(|v| v.as_i64()).unwrap_or(0);
                    let skipped = summary.get("skipped").and_then(|v| v.as_i64()).unwrap_or(0);
                    format!(
                        "新增 {}，更新 {}，跳过 {}",
                        added, updated, skipped
                    )
                } else {
                    "已刷新".to_string()
                };
                let ok = inner.get("error").is_none();
                serde_json::json!({
                    "id": sub.id,
                    "name": sub.name,
                    "sub_type": sub.sub_type,
                    "ok": ok,
                    "message": message,
                })
            }
            Err(e) => serde_json::json!({
                "id": sub.id,
                "name": sub.name,
                "sub_type": sub.sub_type,
                "ok": false,
                "message": e,
            }),
        };
        results.push(item);
    }
    serde_json::to_string(&results).map_err(|e| format!("序列化失败: {}", e))
}

/// 用 core_net::HttpClient 拉订阅 URL 的 JSON 文本。
/// 复用项目统一的 cookie/重试/超时/UA 配置；失败时把 reqwest 错误转
/// 成中文描述方便 UI 直接 SnackBar。
async fn fetch_subscription_body(url: &str) -> Result<String, String> {
    let client = core_net::HttpClient::new(core_net::HttpClientConfig::default())
        .map_err(|e| format!("创建 HTTP 客户端失败: {}", e))?;
    client
        .get_text(url)
        .await
        .map_err(|e| format!("拉取订阅源失败: {}", e))
}

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

    /// R27/R123: a freshly-edited pattern under the SAME rule id must
    /// produce a different compiled Regex once the caller bumps the
    /// generation. The previous keying-by-id-only kept the stale compile
    /// around forever.
    #[test]
    fn cache_invalidates_on_generation_bump() {
        let mut cache = ReplaceRulesCache::new();

        cache.ensure_regex_generation(1);
        let r1_addr = cache.get_or_compile_regex("rule-A", "foo").unwrap() as *const _ as usize;
        // Same pattern within the same generation should hit the cache.
        let r1_again = cache.get_or_compile_regex("rule-A", "foo").unwrap() as *const _ as usize;
        assert_eq!(r1_addr, r1_again, "same gen + pattern should reuse compile");

        // Caller edits rule "A" pattern; bumps generation.
        cache.ensure_regex_generation(2);
        let r2 = cache.get_or_compile_regex("rule-A", "bar").unwrap();
        assert!(r2.is_match("bar"));
        assert!(!r2.is_match("foo"), "old pattern must not still apply");
    }

    /// R47/R123: cache size never grows beyond the current generation's
    /// worth of (id, pattern) tuples.
    #[test]
    fn cache_drops_old_entries_on_generation_bump() {
        let mut cache = ReplaceRulesCache::new();
        cache.ensure_regex_generation(1);
        for i in 0..50 {
            let id = format!("rule-{i}");
            let pattern = format!("p{i}");
            cache.get_or_compile_regex(&id, &pattern);
        }
        assert_eq!(cache.regex_entries.len(), 50);
        cache.ensure_regex_generation(2);
        assert_eq!(
            cache.regex_entries.len(),
            0,
            "generation bump should drop all entries"
        );
        cache.get_or_compile_regex("rule-0", "p0");
        assert_eq!(cache.regex_entries.len(), 1);
    }

    /// Compile failures still get remembered within a generation but do
    /// NOT survive a generation bump (so a user fixing a bad pattern sees
    /// the fix take effect on next chapter).
    #[test]
    fn compile_failures_clear_on_generation_bump() {
        let mut cache = ReplaceRulesCache::new();
        cache.ensure_regex_generation(1);
        // Invalid pattern: unclosed bracket.
        assert!(cache.get_or_compile_regex("bad-rule", "[").is_none());
        assert_eq!(cache.regex_entries.len(), 1);
        cache.ensure_regex_generation(2);
        // Fixed pattern under same id.
        let fixed = cache.get_or_compile_regex("bad-rule", "[abc]").unwrap();
        assert!(fixed.is_match("a"));
    }
}

#[cfg(test)]
mod scope_filter_tests {
    use super::matches_scope;
    use core_storage::models::ReplaceRule;

    fn rule(scope: Option<&str>, exclude: Option<&str>) -> ReplaceRule {
        ReplaceRule {
            id: "r1".into(),
            name: "test".into(),
            pattern: "x".into(),
            replacement: "y".into(),
            enabled: true,
            scope: scope.map(|s| s.to_string()),
            scope_title: false,
            scope_content: true,
            exclude_scope: exclude.map(|s| s.to_string()),
            sort_number: 0,
            created_at: 0,
            updated_at: 0,
        }
    }

    /// R24: scope=None → 全局，对所有书生效。
    #[test]
    fn scope_none_matches_anything() {
        let r = rule(None, None);
        assert!(matches_scope(&r, "三体", "https://x.com"));
        assert!(matches_scope(&r, "", ""));
    }

    /// R24: scope="" → 同 None，全局生效。
    #[test]
    fn scope_empty_matches_anything() {
        let r = rule(Some(""), None);
        assert!(matches_scope(&r, "三体", "https://x.com"));
    }

    /// R24: scope 子串包含 book_name 即匹配。
    #[test]
    fn scope_substring_matches_book_name() {
        let r = rule(Some("三体 笔趣阁"), None);
        assert!(matches_scope(&r, "三体", "https://other.com"));
    }

    /// R24: scope 子串包含 book_origin (书源 URL) 即匹配。
    /// 注意子串方向：scope 是 haystack，origin 是 needle。所以
    /// scope 字段需要"包含"完整的 origin 字符串。
    #[test]
    fn scope_substring_matches_book_origin() {
        let r = rule(Some("https://qidian.com/book/1 起点"), None);
        assert!(matches_scope(&r, "无关书名", "https://qidian.com/book/1"));
    }

    /// R24: scope 不命中任何 → 跳过。
    #[test]
    fn scope_no_match() {
        let r = rule(Some("某本书"), None);
        assert!(!matches_scope(&r, "另一本书", "https://other.com"));
    }

    /// R24: book_name / book_origin 都为空时 scope 非空 → 不参与
    /// 子串匹配（防 "".contains("") == true 误命中所有规则）。
    #[test]
    fn empty_caller_context_does_not_match_scoped_rule() {
        let r = rule(Some("三体"), None);
        assert!(!matches_scope(&r, "", ""));
    }

    /// R24: exclude 优先于 scope 命中。
    #[test]
    fn exclude_wins_over_scope_match() {
        let r = rule(Some("三体"), Some("三体"));
        assert!(!matches_scope(&r, "三体", "https://x.com"));
    }

    /// R24: 全局规则也能被 exclude 排除掉。注意 exclude 是 haystack，
    /// 所以排除某本书需要在 exclude_scope 字段里写下完整的 book_name
    /// 或 book_origin 字符串。
    #[test]
    fn exclude_blocks_global_scope() {
        let r = rule(None, Some("三体 烂书一本"));
        assert!(!matches_scope(&r, "三体", "https://x.com"));
        assert!(matches_scope(&r, "其他书", "https://x.com"));
    }
}

#[cfg(test)]
mod cache_concurrency_tests {
    use super::*;
    use std::sync::Arc;
    use std::thread;

    fn make_rule(id: &str, pattern: &str) -> core_storage::models::ReplaceRule {
        core_storage::models::ReplaceRule {
            id: id.into(),
            name: "t".into(),
            pattern: pattern.into(),
            replacement: "X".into(),
            enabled: true,
            scope: None,
            scope_title: false,
            scope_content: true,
            exclude_scope: None,
            sort_number: 0,
            created_at: 0,
            updated_at: 0,
        }
    }

    /// R123: simulate two concurrent threads with different generations
    /// hammering the unified cache. Each thread's per-call view of
    /// `(rules, regex)` must reflect its own generation, not the other
    /// thread's. This is the regression that proves the unified lock
    /// fixed the cross-generation interference bug — pre-fix code with
    /// two independent mutexes would intermittently fail because thread
    /// A could observe a regex compiled from generation 2's pattern
    /// while thinking it was on generation 1.
    #[test]
    fn unified_cache_keeps_generations_isolated() {
        let cache = Arc::new(std::sync::Mutex::new(ReplaceRulesCache::new()));

        let rules_v1 = Arc::new(vec![make_rule("r1", "foo")]);
        let rules_v2 = Arc::new(vec![make_rule("r1", "bar")]);

        let cache_a = cache.clone();
        let rules_v1_a = rules_v1.clone();
        let t_a = thread::spawn(move || {
            for _ in 0..200 {
                let mut c = cache_a.lock().unwrap();
                let r = c
                    .get_or_load_rules("db", 1, || Ok((*rules_v1_a).clone()))
                    .unwrap();
                c.ensure_regex_generation(1);
                let id = r[0].id.clone();
                let pattern = r[0].pattern.clone();
                let re = c.get_or_compile_regex(&id, &pattern).unwrap();
                assert!(re.is_match("foo"));
                assert!(!re.is_match("bar"));
            }
        });

        let cache_b = cache.clone();
        let rules_v2_b = rules_v2.clone();
        let t_b = thread::spawn(move || {
            for _ in 0..200 {
                let mut c = cache_b.lock().unwrap();
                let r = c
                    .get_or_load_rules("db", 2, || Ok((*rules_v2_b).clone()))
                    .unwrap();
                c.ensure_regex_generation(2);
                let id = r[0].id.clone();
                let pattern = r[0].pattern.clone();
                let re = c.get_or_compile_regex(&id, &pattern).unwrap();
                assert!(re.is_match("bar"));
                assert!(!re.is_match("foo"));
            }
        });

        t_a.join().unwrap();
        t_b.join().unwrap();
    }
}
