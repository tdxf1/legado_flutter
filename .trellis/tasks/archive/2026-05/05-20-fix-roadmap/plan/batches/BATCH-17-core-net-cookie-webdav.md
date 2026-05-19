# BATCH-17: core-net cookie / WebDAV 性能与稳健性

**Stage**: P1
**Slug**: `core-net-cookie-webdav`
**Effort**: S (≤200 行)
**Depends on**: none

## 1. 范围

清理 core-net 3 条性能 / 稳健性问题：add_cookie 每条 Url::parse、save_persistent_cookies 每次全量 pretty JSON、WebDavClient 构造 fallback 丢失超时配置。

## 2. 包含的 findings

- [F-W1B-043] add_cookie dedup 每条都 Url::parse — `core/core-net/src/cookie.rs:142-163, 206-243`
- [F-W1B-044] save_persistent_cookies 每次全量序列化 pretty JSON — `core/core-net/src/cookie.rs:108-117`
- [F-W1B-045] WebDavClient 30s timeout 偏长 + 构造 fallback 丢失配置 — `core/core-net/src/webdav.rs:65-70`

## 3. 影响文件

- `core/core-net/src/cookie.rs:142-163, 206-243` — 用 `(name, domain, path)` 索引 + dedup；`clear_domain` 改原地 retain 不 rebuild
- `core/core-net/src/cookie.rs:108-117` — 加 dirty flag，仅在新 cookie 添加时标记；定时 flush 或退出时统一保存
- `core/core-net/src/webdav.rs:65-70` — `unwrap_or_else` 改 `expect("WebDAV client must build")`；或返回 Result

## 4. 修复方向

复用 master findings-rust-logic.md 各条建议。

## 5. 测试策略

- Rust benchmark：1000 cookie 添加耗时下降
- Rust unit test：dirty flag + flush 行为正确
- Rust unit test：WebDavClient build 失败时上抛 Result

## 6. 验收

- [ ] master finding F-W1B-043/044/045 全部消解

## 7. implement.jsonl 草稿

```jsonl
{"file": ".trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings-rust-logic.md", "reason": "本批次涉及的 wave 1B findings"}
{"file": "core/core-net/src/cookie.rs", "reason": "cookie store"}
{"file": "core/core-net/src/webdav.rs", "reason": "WebDavClient 构造"}
```

## 8. check.jsonl 草稿

```jsonl
{"file": ".trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings.md", "reason": "master report"}
{"file": ".trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings-rust-logic.md", "reason": "Wave 1B"}
{"file": ".trellis/tasks/05-20-fix-roadmap/plan/batches/BATCH-17-core-net-cookie-webdav.md", "reason": "本批次自身验收清单"}
```
