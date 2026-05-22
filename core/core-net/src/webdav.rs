//! # WebDAV 客户端 (批次 11)
//!
//! 对齐原 Legado `lib/webdav/WebDav.kt` 的最小子集。仅支持 https/http
//! scheme（PRD 范围明确 davs:// / dav:// 自定义 scheme 留以后）。
//!
//! ## 协议
//!
//! - `check`     : `PROPFIND Depth=0` 探活
//! - `list_files`: `PROPFIND Depth=1` 列目录，仅返回**文件名**（不含
//!   子目录前缀）；对照 Legado 的 backup zip 扁平存放约定，本方法
//!   **只保留 `displayName.startsWith("backup")` 的项**，其它（如
//!   `bookProgress/` / `background/` 子目录、其它无关文件）直接过滤。
//! - `upload`    : `PUT` 整个文件 body（zip 直接整体写入）
//! - `download`  : `GET` 整个文件
//! - `delete`    : `DELETE`
//! - `mkcol`     : `MKCOL` 建目录（首次同步时建好 `<base>/` 子路径）
//!
//! 鉴权统一走 `Authorization: Basic base64(user:password)`。base_url 必须
//! 以 `/` 结尾以保证 join 拼接简单可靠。
//!
//! ## XML 解析
//!
//! Legado 一侧用 jsoup 取 `<DAV:response>/<DAV:propstat>/<DAV:prop>/
//! <DAV:displayname>`。这里走非依赖的极简解析：服务器返回的 207
//! Multi-Status 体里逐 response 抓 `<displayname>...</displayname>`
//! 的文本（去除前缀 `D:` / `dav:` 命名空间 — 原始字符串匹配）。
//! 这样不引入 quick-xml 依赖，二进制更小。如果未来要解析更复杂的
//! 属性（mtime / size），再考虑加 xml crate。

use base64::Engine;
use reqwest::{
    header::{HeaderMap, HeaderValue, AUTHORIZATION, CONTENT_TYPE},
    Client, Method,
};
use serde::Serialize;
use std::path::Path;
use std::time::Duration;
use tracing::{debug, warn};

/// BATCH-27c: WebDAV 目录条目（通用 list_dir 返回类型）。`is_dir = true`
/// 来自 propfind `<resourcetype><collection/>`；`size = 0` 对目录条目恒
/// 等于 0；`last_modified` 是 `<getlastmodified>` parsed 为 unix 秒
/// 时间戳，缺/解析失败时 None。
///
/// 序列化 → JSON 走 FRB 给 Dart 端 jsonDecode 用 camelCase（`isDir`,
/// `lastModified`），与 dart 端约定一致。
#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct DirEntry {
    pub name: String,
    #[serde(rename = "isDir")]
    pub is_dir: bool,
    pub size: u64,
    #[serde(rename = "lastModified")]
    pub last_modified: Option<i64>,
}

const PROPFIND_BODY: &str = r#"<?xml version="1.0" encoding="utf-8" ?>
<propfind xmlns="DAV:">
  <prop>
    <resourcetype/>
    <displayname/>
  </prop>
</propfind>"#;

/// WebDAV 客户端。线程安全（reqwest::Client 是 Arc 内部）。
#[derive(Clone)]
pub struct WebDavClient {
    /// 基础 URL，调用方应保证以 `/` 结尾。
    base_url: String,
    /// 完整的 `Basic <base64>` 字符串。
    auth_header: String,
    client: Client,
}

impl WebDavClient {
    /// 构造一个 WebDavClient。`base_url` 应以 `/` 结尾；不以 `/` 结尾时
    /// 自动补一个，便于调用方少踩坑。
    ///
    /// **F-W1B-045 加固（2026-05-21, BATCH-17）**：build 失败用 `expect`
    /// 触发 panic，不再静默 fallback 到 `Client::new()` —— 后者会丢失
    /// 30s/10s 超时配置，让 WebDAV 操作可能挂住进程。`reqwest::Client::
    /// builder().build()` 在 native 仅 TLS 配置异常时返回 Err；走默认
    /// rustls/native-tls 的本项目里 build 失败属于环境异常，应立即暴露
    /// 而不是带"半坏" client 继续跑。
    pub fn new(base_url: String, user: String, password: String) -> Self {
        let base_url = if base_url.ends_with('/') {
            base_url
        } else {
            format!("{}/", base_url)
        };
        let auth_header = build_basic_auth(&user, &password);
        let client = Client::builder()
            .timeout(Duration::from_secs(30))
            .connect_timeout(Duration::from_secs(10))
            .build()
            .expect("WebDavClient: reqwest client must build with default TLS config");
        Self {
            base_url,
            auth_header,
            client,
        }
    }

    /// 探活：发送 `PROPFIND Depth=0` 到根 URL。常见响应：
    /// - 207 Multi-Status — OK（标准 WebDAV 行为）
    /// - 200/201 — 部分服务器允许，也算 OK
    /// - 401 / 403 / 404 / 5xx — Err
    pub async fn check(&self) -> Result<(), String> {
        let resp = self.send_propfind(0).await?;
        let status = resp.status();
        if status.is_success() || status.as_u16() == 207 {
            Ok(())
        } else {
            Err(format!("WebDAV 探活失败: HTTP {}", status))
        }
    }

    /// 列出 base_url 下**直接子项**中文件名以 `backup` 开头的项。
    /// 返回相对文件名（不含路径前缀）。
    pub async fn list_files(&self) -> Result<Vec<String>, String> {
        let resp = self.send_propfind(1).await?;
        let status = resp.status();
        if !(status.is_success() || status.as_u16() == 207) {
            return Err(format!("WebDAV 列目录失败: HTTP {}", status));
        }
        let body = resp
            .text()
            .await
            .map_err(|e| format!("读取响应失败: {}", e))?;
        Ok(parse_displaynames(&body)
            .into_iter()
            .filter(|n| n.starts_with("backup"))
            .collect())
    }

    /// 上传文件（整 body PUT）。`file_name` 是相对 `base_url` 的文件名，
    /// 不应含路径分隔符。
    pub async fn upload(&self, file_name: &str, body: Vec<u8>) -> Result<(), String> {
        let url = self.url_for(file_name);
        let mut headers = self.auth_headers();
        headers.insert(
            CONTENT_TYPE,
            HeaderValue::from_static("application/octet-stream"),
        );
        let resp = self
            .client
            .put(&url)
            .headers(headers)
            .body(body)
            .send()
            .await
            .map_err(|e| format!("上传失败: {}", e))?;
        if !resp.status().is_success() {
            return Err(format!("上传失败: HTTP {}", resp.status()));
        }
        Ok(())
    }

    /// 下载文件，返回原始 bytes。
    pub async fn download(&self, file_name: &str) -> Result<Vec<u8>, String> {
        let url = self.url_for(file_name);
        let resp = self
            .client
            .get(&url)
            .headers(self.auth_headers())
            .send()
            .await
            .map_err(|e| format!("下载失败: {}", e))?;
        if !resp.status().is_success() {
            return Err(format!("下载失败: HTTP {}", resp.status()));
        }
        let bytes = resp
            .bytes()
            .await
            .map_err(|e| format!("读取下载内容失败: {}", e))?;
        Ok(bytes.to_vec())
    }

    /// 删除远端文件。404 视为成功（幂等性）。
    pub async fn delete(&self, file_name: &str) -> Result<(), String> {
        let url = self.url_for(file_name);
        let resp = self
            .client
            .delete(&url)
            .headers(self.auth_headers())
            .send()
            .await
            .map_err(|e| format!("删除失败: {}", e))?;
        let s = resp.status();
        if s.is_success() || s.as_u16() == 404 {
            Ok(())
        } else {
            Err(format!("删除失败: HTTP {}", s))
        }
    }

    /// MKCOL — 建目录。403 / 405 视为已存在（幂等）。
    pub async fn mkcol(&self) -> Result<(), String> {
        let req = self
            .client
            .request(Method::from_bytes(b"MKCOL").unwrap(), &self.base_url)
            .headers(self.auth_headers());
        let resp = req
            .send()
            .await
            .map_err(|e| format!("建目录失败: {}", e))?;
        let s = resp.status();
        if s.is_success() || s.as_u16() == 405 || s.as_u16() == 409 {
            Ok(())
        } else {
            Err(format!("建目录失败: HTTP {}", s))
        }
    }

    /// BATCH-27c: 列任意子路径（`path` 相对 base_url，空串 = base_url
    /// 自身）的所有 entries（不过滤 backup 前缀）。与 [`list_files`]
    /// 区分 — 后者写死过滤 backup 前缀 + 仅返文件名 String。
    ///
    /// `path` 校验：含 `..` 或绝对路径 → 拒绝。这是浅层 SSRF 防护；
    /// 远端 webdav 服务器自身也应做相对路径限制，但 dart 端构造的
    /// pathStack join 不应越界（拼 `..` 是一个明显的代码 bug）。
    pub async fn list_dir(&self, path: &str) -> Result<Vec<DirEntry>, String> {
        if path.contains("..") || path.starts_with('/') {
            return Err(format!("无效路径: {}", path));
        }
        let target_url = self.dir_url_for(path);
        let mut headers = self.auth_headers();
        headers.insert(
            CONTENT_TYPE,
            HeaderValue::from_static("application/xml; charset=utf-8"),
        );
        headers.insert("Depth", HeaderValue::from_static("1"));
        let req = self
            .client
            .request(
                Method::from_bytes(b"PROPFIND").unwrap(),
                &target_url,
            )
            .headers(headers)
            .body(PROPFIND_BODY);
        debug!("PROPFIND {} depth=1 (list_dir)", target_url);
        let resp = req
            .send()
            .await
            .map_err(|e| format!("PROPFIND 失败: {}", e))?;
        let status = resp.status();
        if !(status.is_success() || status.as_u16() == 207) {
            return Err(format!("WebDAV 列目录失败: HTTP {}", status));
        }
        let body = resp
            .text()
            .await
            .map_err(|e| format!("读取响应失败: {}", e))?;
        let entries = parse_propfind_entries(&body);
        // 服务器一般会把"当前目录自身"也作为第一个 response 返回（href
        // 等于 list 路径）。靠 displayname 不一定能区分，但其 href 会
        // 等于（或非常接近）请求的目录 URL；保守做法：过滤 name 为空
        // 的项 + 当 name 与 path 末段相等且 isDir 时也跳过（自身）。
        let self_segment = path
            .rsplit('/')
            .find(|s| !s.is_empty())
            .unwrap_or("")
            .to_string();
        let filtered: Vec<DirEntry> = entries
            .into_iter()
            .filter(|e| {
                if e.name.is_empty() {
                    return false;
                }
                if e.is_dir && !self_segment.is_empty() && e.name == self_segment {
                    return false;
                }
                true
            })
            .collect();
        Ok(filtered)
    }

    /// BATCH-27c: 通用 GET → 流式写入本地路径。返写入 byte 数。
    /// `target_local_path` 父目录需存在（caller 保证）；不在此 fn 创建。
    /// 实现取 full body bytes 再一次性写盘 —— 与 `download` 同模式。
    /// 流式分块写入需引入 `futures::StreamExt`，当前 deps 没有；备份 zip
    /// 历史路径走 full bytes，这里保持一致。文件较大（>>100MB）时再
    /// 评估是否升级流式（评估触发：reqwest::bytes_stream + futures 加 dep）。
    pub async fn download_to_path(
        &self,
        remote_path: &str,
        target_local_path: &Path,
    ) -> Result<u64, String> {
        let url = self.url_for(remote_path);
        let resp = self
            .client
            .get(&url)
            .headers(self.auth_headers())
            .send()
            .await
            .map_err(|e| format!("下载失败: {}", e))?;
        if !resp.status().is_success() {
            return Err(format!("下载失败: HTTP {}", resp.status()));
        }
        let bytes = resp
            .bytes()
            .await
            .map_err(|e| format!("读取下载内容失败: {}", e))?;
        let len = bytes.len() as u64;
        tokio::fs::write(target_local_path, &bytes)
            .await
            .map_err(|e| format!("写入本地文件失败: {}", e))?;
        Ok(len)
    }

    // ---- internal helpers ----

    fn url_for(&self, file_name: &str) -> String {
        // 简单 URL-encode 文件名里的空格 + #;其它字符暂时透传。
        let encoded = file_name.replace(' ', "%20").replace('#', "%23");
        format!("{}{}", self.base_url, encoded)
    }

    /// BATCH-27c: 给 list_dir 用的子路径 URL 拼接。`path` 已被
    /// [`list_dir`] 校验过（无 `..` / abs path）；空串直接返回 base_url。
    /// 末尾**保持** `/` —— webdav 协议很多服务器把 collection PROPFIND
    /// 必须以 `/` 结尾，否则 response href 形态会变。
    fn dir_url_for(&self, path: &str) -> String {
        let p = path.trim_matches('/');
        if p.is_empty() {
            return self.base_url.clone();
        }
        let encoded = p.replace(' ', "%20").replace('#', "%23");
        format!("{}{}/", self.base_url, encoded)
    }

    fn auth_headers(&self) -> HeaderMap {
        let mut headers = HeaderMap::new();
        if let Ok(v) = HeaderValue::from_str(&self.auth_header) {
            headers.insert(AUTHORIZATION, v);
        }
        headers
    }

    async fn send_propfind(&self, depth: u8) -> Result<reqwest::Response, String> {
        let mut headers = self.auth_headers();
        headers.insert(
            CONTENT_TYPE,
            HeaderValue::from_static("application/xml; charset=utf-8"),
        );
        headers.insert("Depth", HeaderValue::from_str(&depth.to_string()).unwrap());
        let req = self
            .client
            .request(
                Method::from_bytes(b"PROPFIND").unwrap(),
                &self.base_url,
            )
            .headers(headers)
            .body(PROPFIND_BODY);
        debug!("PROPFIND {} depth={}", self.base_url, depth);
        req.send()
            .await
            .map_err(|e| format!("PROPFIND 失败: {}", e))
    }
}

/// 构造 `Basic base64(user:password)` 头值。
pub fn build_basic_auth(user: &str, password: &str) -> String {
    let raw = format!("{}:{}", user, password);
    let b64 = base64::engine::general_purpose::STANDARD.encode(raw.as_bytes());
    format!("Basic {}", b64)
}

/// BATCH-27c: 解析 PROPFIND multi-status 响应里的 `<response>` 块，
/// 每个块抽出 `displayname` / `resourcetype/collection` /
/// `getcontentlength` / `getlastmodified` 4 个字段构造 [`DirEntry`]。
///
/// 与 [`parse_displaynames`] 区分：后者**只**抽 displayname 文本（用
/// 于 list_files 配 backup 前缀过滤），本函数还要识别 collection / size /
/// lastModified，给 list_dir 用。
///
/// 实现思路同 [`parse_displaynames`]：纯字符串搜索 + tag-open / tag-close
/// 复用，不引 quick-xml。`response` 块用 `<...:?response>` 开 +
/// `</...:?response>` 闭框定，块内字段独立 parse。命名空间前缀
/// (`D:` / `dav:` 大小写) 一并兼容。
fn parse_propfind_entries(xml: &str) -> Vec<DirEntry> {
    let mut out = Vec::new();
    let lower = xml.to_ascii_lowercase();
    let bytes = xml.as_bytes();
    let mut cursor = 0usize;
    while cursor < lower.len() {
        // Find next <response>
        let open_pos = match find_tag_open(&lower, "response", cursor) {
            Some(p) => p,
            None => break,
        };
        let body_start = match lower[open_pos..].find('>') {
            Some(p) => open_pos + p + 1,
            None => break,
        };
        let close_pos = match find_tag_close(&lower, "response", body_start) {
            Some(p) => p,
            None => break,
        };
        // Slice out the response block bytes
        let block_bytes = &bytes[body_start..close_pos];
        let block_lower = &lower[body_start..close_pos];
        let block_str = std::str::from_utf8(block_bytes).unwrap_or("");

        let name = extract_first_tag_text(block_lower, block_str, "displayname")
            .unwrap_or_default();
        // resourcetype/collection 标识 dir
        let is_dir = block_contains_collection(block_lower);
        // getcontentlength
        let size = extract_first_tag_text(block_lower, block_str, "getcontentlength")
            .and_then(|s| s.trim().parse::<u64>().ok())
            .unwrap_or(0);
        // getlastmodified
        let last_modified = extract_first_tag_text(block_lower, block_str, "getlastmodified")
            .and_then(|s| parse_http_or_iso_date(s.trim()));

        out.push(DirEntry {
            name,
            is_dir,
            size,
            last_modified,
        });

        // Skip past this response close tag
        if let Some(after) = lower[close_pos..].find('>') {
            cursor = close_pos + after + 1;
        } else {
            break;
        }
    }
    if out.is_empty() {
        debug!("parse_propfind_entries 未提取到任何 response 块");
    }
    out
}

/// 从 propfind response 块内抽第一个匹配 tag 的内部文本，返回 trim +
/// xml-entity 还原后的字符串。块内查找用 `find_tag_open` / `find_tag_close`
/// 同 parse_displaynames。
fn extract_first_tag_text(lower: &str, original: &str, tag: &str) -> Option<String> {
    let open_pos = find_tag_open(lower, tag, 0)?;
    let body_start = lower[open_pos..].find('>').map(|p| open_pos + p + 1)?;
    let close_pos = find_tag_close(lower, tag, body_start)?;
    if body_start > close_pos || close_pos > original.len() {
        return None;
    }
    let text = &original[body_start..close_pos];
    let trimmed = text.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(decode_xml_entities(trimmed))
    }
}

/// `<resourcetype>` 内含 `<collection/>` 或 `<...:collection ...>` 标签则
/// 返 true。空 `<resourcetype/>` / `<resourcetype></resourcetype>` 表示文件。
fn block_contains_collection(block_lower: &str) -> bool {
    // We do simple substring search constrained to the resourcetype tag
    // contents; this avoids picking up "<collection>" elsewhere in the
    // response (none should exist in standard webdav, but defensive).
    let rt_open = match find_tag_open(block_lower, "resourcetype", 0) {
        Some(p) => p,
        None => return false,
    };
    let rt_body_start = match block_lower[rt_open..].find('>') {
        Some(p) => rt_open + p + 1,
        None => return false,
    };
    // 自闭合 <resourcetype/> → 无 inner，标记为文件
    // detect by stepping back: if char before `>` is `/`, it's self-close
    if rt_body_start >= 2 && &block_lower[rt_body_start - 2..rt_body_start - 1] == "/" {
        return false;
    }
    let rt_close = match find_tag_close(block_lower, "resourcetype", rt_body_start) {
        Some(p) => p,
        None => return false,
    };
    let inner = &block_lower[rt_body_start..rt_close];
    inner.contains("collection")
}

/// 解析 `<getlastmodified>` 字段。webdav 服务器多数返 RFC 1123 格式
/// （`Thu, 01 Jan 2026 12:34:56 GMT`），少数返 ISO 8601；两个都试。
/// 解析失败返 None；DirEntry.last_modified None 等价于"未提供"。
fn parse_http_or_iso_date(s: &str) -> Option<i64> {
    if s.is_empty() {
        return None;
    }
    // RFC 1123 / 2822 (HTTP date)
    if let Ok(dt) = chrono::DateTime::parse_from_rfc2822(s) {
        return Some(dt.timestamp());
    }
    // ISO 8601 / RFC 3339
    if let Ok(dt) = chrono::DateTime::parse_from_rfc3339(s) {
        return Some(dt.timestamp());
    }
    None
}

/// 极简提取 `<displayname>...</displayname>` 文本。
///
/// 同时处理两种常见命名空间前缀：无前缀（`<displayname>`）和
/// `D:` / `dav:` / 大写。返回的字符串已 trim。如果服务器把目录条目的
/// displayname 留空，会返回空串（调用方会自动过滤掉前缀不匹配的项）。
fn parse_displaynames(xml: &str) -> Vec<String> {
    let mut out = Vec::new();
    let lower = xml.to_ascii_lowercase();
    let bytes = xml.as_bytes();
    let mut search_from = 0usize;
    while search_from < lower.len() {
        // 找到 `<...displayname` 开标签的开头
        let open_pos = match find_tag_open(&lower, "displayname", search_from) {
            Some(p) => p,
            None => break,
        };
        // 找开标签的 `>`
        let gt = match lower[open_pos..].find('>') {
            Some(p) => open_pos + p + 1,
            None => break,
        };
        // 找闭标签
        let close_marker = match find_tag_close(&lower, "displayname", gt) {
            Some(p) => p,
            None => break,
        };
        let text = &bytes[gt..close_marker];
        if let Ok(s) = std::str::from_utf8(text) {
            let trimmed = s.trim();
            if !trimmed.is_empty() {
                out.push(decode_xml_entities(trimmed));
            }
        }
        // 跳过本条结束 `>`
        if let Some(after) = lower[close_marker..].find('>') {
            search_from = close_marker + after + 1;
        } else {
            break;
        }
    }
    if out.is_empty() {
        debug!("parse_displaynames 未提取到任何 displayname 元素");
    }
    out
}

/// 在 `lower` 里从 `from` 开始找 `<...:?<tag>` 形式的开标签起点（小写 tag），
/// 返回 `<` 字符的位置。
fn find_tag_open(lower: &str, tag: &str, from: usize) -> Option<usize> {
    let needle = format!("{}", tag);
    let mut i = from;
    while i < lower.len() {
        let rel = lower[i..].find(&needle)?;
        let abs = i + rel;
        // 必须前面是 `<` 或 `<...:`
        // 向前扫到 `<`
        let mut j = abs;
        while j > 0 {
            let c = lower.as_bytes()[j - 1];
            if c == b'<' {
                // OK：开标签起点
                return Some(j - 1);
            }
            if c.is_ascii_alphanumeric() || c == b':' || c == b'-' {
                j -= 1;
                continue;
            }
            break;
        }
        i = abs + needle.len();
    }
    None
}

/// 在 `lower` 里从 `from` 开始找 `</...?:displayname>` 闭标签的 `<` 起点。
fn find_tag_close(lower: &str, tag: &str, from: usize) -> Option<usize> {
    let mut i = from;
    while i < lower.len() {
        let rel = lower[i..].find("</")?;
        let lt = i + rel;
        // 闭标签里的 tag 名（含可能的 `D:` / `dav:`）
        let after = &lower[lt + 2..];
        // 跳过命名空间前缀：字母 / 数字 / `:`
        let mut k = 0;
        let bytes = after.as_bytes();
        while k < bytes.len() && (bytes[k].is_ascii_alphanumeric() || bytes[k] == b':' || bytes[k] == b'-') {
            k += 1;
        }
        let name = &after[..k];
        let stripped = match name.rsplit_once(':') {
            Some((_, rest)) => rest,
            None => name,
        };
        if stripped == tag {
            return Some(lt);
        }
        i = lt + 2;
    }
    None
}

/// 处理 displayname 里常见的 XML 转义。WebDAV 服务器返回的中文文件名
/// 一般已经 UTF-8，不需要再 unescape；这里只处理几个常见实体以稳健。
fn decode_xml_entities(s: &str) -> String {
    s.replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&apos;", "'")
}

#[allow(dead_code)]
fn warn_once(msg: &str) {
    warn!("{}", msg);
}

// ============================================================
// Tests
// ============================================================

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpListener;

    #[test]
    fn test_basic_auth_format() {
        let h = build_basic_auth("alice", "secret");
        // base64("alice:secret") = YWxpY2U6c2VjcmV0
        assert_eq!(h, "Basic YWxpY2U6c2VjcmV0");
    }

    #[test]
    fn test_basic_auth_empty_password() {
        // 空密码: base64("user:") = dXNlcjo=
        let h = build_basic_auth("user", "");
        assert_eq!(h, "Basic dXNlcjo=");
    }

    #[test]
    fn test_parse_displaynames_extracts_all() {
        let xml = r#"<?xml version="1.0"?>
<D:multistatus xmlns:D="DAV:">
  <D:response>
    <D:href>/dav/legado/</D:href>
    <D:propstat><D:prop><D:displayname>legado</D:displayname></D:prop></D:propstat>
  </D:response>
  <D:response>
    <D:href>/dav/legado/backup2026-05-19.zip</D:href>
    <D:propstat><D:prop><D:displayname>backup2026-05-19.zip</D:displayname></D:prop></D:propstat>
  </D:response>
  <D:response>
    <D:href>/dav/legado/bookProgress/</D:href>
    <D:propstat><D:prop><D:displayname>bookProgress</D:displayname></D:prop></D:propstat>
  </D:response>
</D:multistatus>"#;
        let names = parse_displaynames(xml);
        assert_eq!(
            names,
            vec![
                "legado".to_string(),
                "backup2026-05-19.zip".to_string(),
                "bookProgress".to_string()
            ]
        );
    }

    #[test]
    fn test_parse_displaynames_handles_no_namespace() {
        let xml = r#"<multistatus xmlns="DAV:">
  <response>
    <href>/x/</href>
    <propstat><prop><displayname>backup-test.zip</displayname></prop></propstat>
  </response>
</multistatus>"#;
        let names = parse_displaynames(xml);
        assert_eq!(names, vec!["backup-test.zip".to_string()]);
    }

    #[test]
    fn test_parse_displaynames_decodes_entities() {
        let xml = r#"<multistatus><response><propstat><prop>
          <displayname>backup &amp; thing.zip</displayname>
        </prop></propstat></response></multistatus>"#;
        let names = parse_displaynames(xml);
        assert_eq!(names, vec!["backup & thing.zip".to_string()]);
    }

    /// BATCH-27c: parse_propfind_entries 验目录 / 文件 / 大小 / 修改
    /// 时间四字段抽取。fixture 对照原 Legado 用 jianguoyun / nextcloud 风格
    /// `<D:multistatus>` 响应。
    #[test]
    fn test_parse_propfind_entries_files_and_dirs() {
        let xml = r#"<?xml version="1.0"?>
<D:multistatus xmlns:D="DAV:">
  <D:response>
    <D:href>/dav/legado/</D:href>
    <D:propstat>
      <D:prop>
        <D:displayname>legado</D:displayname>
        <D:resourcetype><D:collection/></D:resourcetype>
        <D:getlastmodified>Thu, 01 Jan 2026 12:34:56 GMT</D:getlastmodified>
      </D:prop>
    </D:propstat>
  </D:response>
  <D:response>
    <D:href>/dav/legado/books/</D:href>
    <D:propstat>
      <D:prop>
        <D:displayname>books</D:displayname>
        <D:resourcetype><D:collection/></D:resourcetype>
        <D:getlastmodified>Wed, 31 Dec 2025 23:00:00 GMT</D:getlastmodified>
      </D:prop>
    </D:propstat>
  </D:response>
  <D:response>
    <D:href>/dav/legado/note.txt</D:href>
    <D:propstat>
      <D:prop>
        <D:displayname>note.txt</D:displayname>
        <D:resourcetype/>
        <D:getcontentlength>1024</D:getcontentlength>
        <D:getlastmodified>Thu, 01 Jan 2026 10:00:00 GMT</D:getlastmodified>
      </D:prop>
    </D:propstat>
  </D:response>
</D:multistatus>"#;
        let entries = parse_propfind_entries(xml);
        assert_eq!(entries.len(), 3, "三条 response → 三个 entry");
        // entry[0] 是请求目录自身 (legado / dir)
        assert_eq!(entries[0].name, "legado");
        assert!(entries[0].is_dir);
        assert_eq!(entries[0].size, 0);
        assert!(entries[0].last_modified.is_some());
        // entry[1] 子目录 books/
        assert_eq!(entries[1].name, "books");
        assert!(entries[1].is_dir);
        assert_eq!(entries[1].size, 0);
        // entry[2] 文件 note.txt
        assert_eq!(entries[2].name, "note.txt");
        assert!(!entries[2].is_dir);
        assert_eq!(entries[2].size, 1024);
        assert!(entries[2].last_modified.is_some());
        // 时间戳排序合理
        let t1 = entries[0].last_modified.unwrap();
        let t2 = entries[1].last_modified.unwrap();
        assert!(t1 > t2, "Jan 01 12:34 > Dec 31 23:00 (UTC)");
    }

    /// BATCH-27c: 空 multistatus 响应返空 entries
    #[test]
    fn test_parse_propfind_entries_empty() {
        let xml = r#"<?xml version="1.0"?><D:multistatus xmlns:D="DAV:"></D:multistatus>"#;
        let entries = parse_propfind_entries(xml);
        assert!(entries.is_empty());
    }

    /// BATCH-27c: DirEntry serde 序列化为 camelCase JSON
    #[test]
    fn test_dir_entry_serializes_camel_case() {
        let e = DirEntry {
            name: "books".to_string(),
            is_dir: true,
            size: 0,
            last_modified: Some(1735732496),
        };
        let json = serde_json::to_string(&e).unwrap();
        assert!(json.contains("\"isDir\":true"));
        assert!(json.contains("\"lastModified\":1735732496"));
        assert!(json.contains("\"name\":\"books\""));
    }

    /// BATCH-27c: list_dir 拒绝越界 path（`..` / abs path）。
    #[tokio::test]
    async fn test_list_dir_rejects_invalid_paths() {
        let client =
            WebDavClient::new("http://example.invalid/dav/".into(), "u".into(), "p".into());
        assert!(client.list_dir("../etc").await.is_err());
        assert!(client.list_dir("foo/../bar").await.is_err());
        assert!(client.list_dir("/abs/path").await.is_err());
    }

    /// BATCH-27c: list_dir 用 mock 服务器走 happy path。
    /// 校验：传 path="books" → 末尾自带 `/` + 结果 entries 含子目录与文件。
    #[tokio::test]
    async fn test_list_dir_via_mock_server() {
        let captured_path: Arc<std::sync::Mutex<Option<String>>> =
            Arc::new(std::sync::Mutex::new(None));
        let captured_clone = captured_path.clone();
        let xml = r#"<?xml version="1.0"?>
<D:multistatus xmlns:D="DAV:">
  <D:response>
    <D:href>/dav/legado/books/</D:href>
    <D:propstat><D:prop>
      <D:displayname>books</D:displayname>
      <D:resourcetype><D:collection/></D:resourcetype>
    </D:prop></D:propstat>
  </D:response>
  <D:response>
    <D:href>/dav/legado/books/a.epub</D:href>
    <D:propstat><D:prop>
      <D:displayname>a.epub</D:displayname>
      <D:resourcetype/>
      <D:getcontentlength>2048</D:getcontentlength>
    </D:prop></D:propstat>
  </D:response>
</D:multistatus>"#
            .to_string();
        let (base, _h) = spawn_dav_mock(move |method, path, _body| {
            assert_eq!(method, "PROPFIND");
            *captured_clone.lock().unwrap() = Some(path.to_string());
            (207, xml.clone().into_bytes())
        })
        .await;
        let client =
            WebDavClient::new(format!("{}/dav/legado/", base), "u".into(), "p".into());
        let entries = client.list_dir("books").await.unwrap();
        // 自身目录被过滤 → 仅 1 个文件
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].name, "a.epub");
        assert!(!entries[0].is_dir);
        assert_eq!(entries[0].size, 2048);
        // 校验请求 path 末尾带 `/`（webdav collection 需要）
        let path = captured_path.lock().unwrap().clone().unwrap_or_default();
        assert!(
            path.ends_with("/dav/legado/books/"),
            "expected trailing slash, got {path}"
        );
    }

    /// BATCH-27c: download_to_path 写入 mock 返回的 body 到本地路径。
    #[tokio::test]
    async fn test_download_to_path_writes_target_file() {
        let payload: Vec<u8> = b"webdav-payload-27c".to_vec();
        let payload_clone = payload.clone();
        let (base, _h) = spawn_dav_mock(move |method, _path, _body| {
            assert_eq!(method, "GET");
            (200, payload_clone.clone())
        })
        .await;
        let client =
            WebDavClient::new(format!("{}/dav/legado/", base), "u".into(), "p".into());
        let tmp_dir = tempfile::tempdir().unwrap();
        let target = tmp_dir.path().join("out.bin");
        let n = client
            .download_to_path("books/a.epub", &target)
            .await
            .unwrap();
        assert_eq!(n, payload.len() as u64);
        let got = std::fs::read(&target).unwrap();
        assert_eq!(got, payload);
    }

    /// 简易 WebDAV 测试服务器 — 因 httpmock 0.7 不支持 PROPFIND 等
    /// 自定义 HTTP 方法（其内部 enum Method 写死 GET/POST/PUT/DELETE/...
    /// 见 `httpmock::api::adapter::Method::from_str`），所以 PROPFIND
    /// / MKCOL 之类的 WebDAV 专用动词只能用裸 TCP 起一个 mock。
    ///
    /// `responder` 是路由函数：接收 `(method, path, body)`,返回
    /// `(status_code, response_body)`。请求头不做严格匹配，单测里
    /// 不需要细查 Authorization 内容（已经有专门的 build_basic_auth 单测）。
    async fn spawn_dav_mock<F>(responder: F) -> (String, tokio::task::JoinHandle<()>)
    where
        F: Fn(&str, &str, &[u8]) -> (u16, Vec<u8>) + Send + Sync + 'static,
    {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let responder = Arc::new(responder);
        let handle = tokio::spawn(async move {
            loop {
                let (mut sock, _) = match listener.accept().await {
                    Ok(s) => s,
                    Err(_) => break,
                };
                let responder = responder.clone();
                tokio::spawn(async move {
                    let mut buf = vec![0u8; 8192];
                    let mut total = Vec::new();
                    let mut header_end = None;
                    while header_end.is_none() {
                        let n = match sock.read(&mut buf).await {
                            Ok(0) | Err(_) => return,
                            Ok(n) => n,
                        };
                        total.extend_from_slice(&buf[..n]);
                        if let Some(idx) =
                            total.windows(4).position(|w| w == b"\r\n\r\n")
                        {
                            header_end = Some(idx);
                        }
                        if total.len() > 1024 * 1024 {
                            return;
                        }
                    }
                    let header_end = header_end.unwrap();
                    let header_str =
                        std::str::from_utf8(&total[..header_end]).unwrap_or("");
                    // Parse first line: METHOD PATH HTTP/1.1
                    let mut lines = header_str.split("\r\n");
                    let req_line = lines.next().unwrap_or("");
                    let mut parts = req_line.split_whitespace();
                    let method = parts.next().unwrap_or("").to_string();
                    let path = parts.next().unwrap_or("").to_string();
                    // Find Content-Length
                    let mut clen = 0usize;
                    for line in header_str.split("\r\n").skip(1) {
                        if let Some((k, v)) = line.split_once(':') {
                            if k.eq_ignore_ascii_case("Content-Length") {
                                clen = v.trim().parse().unwrap_or(0);
                            }
                        }
                    }
                    let body_start = header_end + 4;
                    while total.len() < body_start + clen {
                        let n = match sock.read(&mut buf).await {
                            Ok(0) | Err(_) => break,
                            Ok(n) => n,
                        };
                        total.extend_from_slice(&buf[..n]);
                    }
                    let body = if clen > 0 && total.len() >= body_start + clen {
                        total[body_start..body_start + clen].to_vec()
                    } else {
                        Vec::new()
                    };
                    let (status, resp_body) = responder(&method, &path, &body);
                    let reason = match status {
                        200 => "OK",
                        201 => "Created",
                        204 => "No Content",
                        207 => "Multi-Status",
                        401 => "Unauthorized",
                        404 => "Not Found",
                        405 => "Method Not Allowed",
                        _ => "OK",
                    };
                    let response = format!(
                        "HTTP/1.1 {} {}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                        status,
                        reason,
                        resp_body.len()
                    );
                    let _ = sock.write_all(response.as_bytes()).await;
                    let _ = sock.write_all(&resp_body).await;
                    let _ = sock.shutdown().await;
                });
            }
        });
        (format!("http://{}", addr), handle)
    }

    fn multistatus_xml(names: &[&str]) -> String {
        let mut body = String::from(
            "<?xml version=\"1.0\"?><D:multistatus xmlns:D=\"DAV:\">",
        );
        for n in names {
            body.push_str(&format!(
                "<D:response><D:href>/dav/legado/{n}</D:href>\
                 <D:propstat><D:prop><D:displayname>{n}</D:displayname></D:prop></D:propstat>\
                 </D:response>"
            ));
        }
        body.push_str("</D:multistatus>");
        body
    }

    #[tokio::test]
    async fn test_check_returns_ok_on_207() {
        let (base, _h) = spawn_dav_mock(|method, _path, _body| {
            assert_eq!(method, "PROPFIND");
            (207, multistatus_xml(&["legado"]).into_bytes())
        })
        .await;
        let client = WebDavClient::new(format!("{}/dav/legado/", base), "u".into(), "p".into());
        client.check().await.expect("check should succeed");
    }

    #[tokio::test]
    async fn test_check_fails_on_401() {
        let (base, _h) = spawn_dav_mock(|method, _path, _body| {
            assert_eq!(method, "PROPFIND");
            (401, b"Unauthorized".to_vec())
        })
        .await;
        let client =
            WebDavClient::new(format!("{}/dav/legado/", base), "u".into(), "wrong".into());
        let err = client.check().await.unwrap_err();
        assert!(err.contains("401"), "expected 401 in {err}");
    }

    #[tokio::test]
    async fn test_list_files_filters_backup_prefix() {
        let (base, _h) = spawn_dav_mock(|method, _path, _body| {
            assert_eq!(method, "PROPFIND");
            (
                207,
                multistatus_xml(&[
                    "legado",
                    "backup2026-05-19.zip",
                    "bookProgress",
                    "backup2026-05-18-Pixel.zip",
                    "other.txt",
                ])
                .into_bytes(),
            )
        })
        .await;
        let client = WebDavClient::new(format!("{}/dav/legado/", base), "u".into(), "p".into());
        let names = client.list_files().await.unwrap();
        assert_eq!(
            names,
            vec![
                "backup2026-05-19.zip".to_string(),
                "backup2026-05-18-Pixel.zip".to_string(),
            ]
        );
    }

    #[tokio::test]
    async fn test_upload_then_download_roundtrip() {
        let payload: Vec<u8> = b"hello-zip-bytes-roundtrip".to_vec();
        let payload_for_get = Arc::new(std::sync::Mutex::new(Vec::<u8>::new()));
        let payload_for_get_clone = payload_for_get.clone();
        let (base, _h) = spawn_dav_mock(move |method, _path, body| match method {
            "PUT" => {
                *payload_for_get_clone.lock().unwrap() = body.to_vec();
                (201, vec![])
            }
            "GET" => {
                let stored = payload_for_get_clone.lock().unwrap().clone();
                (200, stored)
            }
            _ => (405, vec![]),
        })
        .await;
        let client = WebDavClient::new(format!("{}/dav/legado/", base), "u".into(), "p".into());
        client.upload("test.zip", payload.clone()).await.expect("upload ok");
        let got = client.download("test.zip").await.expect("download ok");
        assert_eq!(got, payload);
    }

    #[tokio::test]
    async fn test_delete_404_treated_as_ok() {
        let (base, _h) = spawn_dav_mock(|method, _path, _body| {
            assert_eq!(method, "DELETE");
            (404, vec![])
        })
        .await;
        let client = WebDavClient::new(format!("{}/dav/legado/", base), "u".into(), "p".into());
        client.delete("old.zip").await.expect("404 should be OK");
    }

    #[tokio::test]
    async fn test_mkcol_405_treated_as_ok() {
        let (base, _h) = spawn_dav_mock(|method, _path, _body| {
            assert_eq!(method, "MKCOL");
            (405, vec![])
        })
        .await;
        let client = WebDavClient::new(format!("{}/dav/legado/", base), "u".into(), "p".into());
        client.mkcol().await.expect("405 should be OK (already exists)");
    }
}
