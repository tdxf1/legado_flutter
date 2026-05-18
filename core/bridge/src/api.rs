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
