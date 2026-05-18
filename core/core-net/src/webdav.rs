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
use std::time::Duration;
use tracing::{debug, warn};

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
            .unwrap_or_else(|_| Client::new());
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

    // ---- internal helpers ----

    fn url_for(&self, file_name: &str) -> String {
        // 简单 URL-encode 文件名里的空格 + #;其它字符暂时透传。
        let encoded = file_name.replace(' ', "%20").replace('#', "%23");
        format!("{}{}", self.base_url, encoded)
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
