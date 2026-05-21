# BATCH-17: core-net cookie + WebDavClient quick wins

## Goal

3 个 P1 finding 保守补丁，覆盖 `core/core-net/src/{cookie.rs, webdav.rs}`。每条最小侵入，**不重写** add_cookie / save 主流程：

- **F-W1B-043**：`add_cookie` retain 闭包对每条已有 cookie 重复 `Url::parse + StoreCookie::parse`。把 dedup key 缓存到 `CookieEntry` 结构里，下次 retain 直接读取。
- **F-W1B-044**：`save_persistent_cookies` 每次都全量序列化 + I/O。加 `dirty: bool` 标记，新增 `save_persistent_cookies_if_dirty(path)` 方法供调度方使用，原 save 保持兼容。
- **F-W1B-045**：`WebDavClient::new` 用 `unwrap_or_else(|_| Client::new())` 兜底丢失超时配置。改成 `expect("WebDavClient: reqwest client must build")`。

## What I already know

### 现有架构（core/core-net/src/cookie.rs:13-43）

```rust
struct CookieEntry {
    raw_cookie: String,
    url: String,
}

struct CookieManagerInner {
    store: CookieStore,
    raw_cookies: Vec<CookieEntry>,
}

pub struct CookieManager {
    inner: Arc<Mutex<CookieManagerInner>>,
}
```

`add_cookie` 流程（L121-180）：parse cookie → 计算 dedup key (`name`, `domain_flag`, `path`) → store.insert → **retain raw_cookies**：闭包内对每条 existing 都重做 Url::parse + StoreCookie::parse 算同样的 key 比较。

`save_persistent_cookies`（L88-117）：原子写（tmp + rename），全量 pretty JSON。caller 是 `core/core-net/src/client.rs:150::save_cookies`，由外部 controller 决定调用时机。

`WebDavClient::new`（webdav.rs:59-76）：`Client::builder().timeout(30s).connect_timeout(10s).build().unwrap_or_else(|_| Client::new())`。caller 在 `bridge::api::webdav_*` 与单测 6 处。

### 测试基线

`cargo test -p core-net --lib` 当前 19 通过 0 失败。其中 cookie 相关 13 个，含两个边界关键测：`test_clear_domain_subdomain` 和 `test_host_only_vs_domain_cookie_coexist`。

### 调用面（grep 后确认）

- `add_cookie` 仅由 `client.rs:141::extract_cookies` + 各单测调用。
- `save_persistent_cookies` 仅由 `client.rs:152::save_cookies` + 单测调用。
- `WebDavClient::new` 由 `bridge::api::webdav_check / upload / download / delete / list` 5 处 + 6 个单测调用。

## 实施方案

### 1. F-W1B-043 dedup key 缓存

修改 `CookieEntry`：

```rust
#[derive(Debug, Clone, Serialize, Deserialize)]
struct CookieEntry {
    raw_cookie: String,
    url: String,
    /// 缓存 dedup key（`name`, `domain_flag`, `path`）到 entry 上，避免每次
    /// `add_cookie` retain 时对所有 existing entries 重做 Url::parse +
    /// StoreCookie::parse。新加 entry 时一次性算好；旧格式（serde 反序列
    /// 化没这个字段）走 `#[serde(default)]` 兜底空字符串，下次 add_cookie
    /// 触发到匹配时仍走 fallback 完整解析（向后兼容）。
    #[serde(default)]
    dedup_name: String,
    #[serde(default)]
    dedup_domain_flag: String,  // "domain:..." 或 "host:..."
    #[serde(default)]
    dedup_path: String,
}
```

`add_cookie` 改造：

```rust
inner.raw_cookies.retain(|existing| {
    // F-W1B-043 优化：优先用缓存的 dedup key。旧格式 entry 缓存为空字符串
    // 时回退到旧路径完整解析，保证向后兼容。
    if !existing.dedup_name.is_empty() {
        let domain_match = existing.dedup_domain_flag == dedup_domain_flag.as_deref().unwrap_or("");
        return !(existing.dedup_name == dedup_name
            && domain_match
            && existing.dedup_path == dedup_path);
    }
    // 旧路径 fallback（仅旧格式加载场景下首次写入触发，一次性回退）
    if let Ok(existing_url) = Url::parse(&existing.url) {
        // ... 原有解析逻辑保留
    }
    true
});

inner.raw_cookies.push(CookieEntry {
    raw_cookie: cookie_str.to_string(),
    url: url.to_string(),
    dedup_name: dedup_name.clone(),
    dedup_domain_flag: dedup_domain_flag.clone().unwrap_or_default(),
    dedup_path: dedup_path.clone(),
});
```

复杂度变化：原 retain 每条 O(parse)，现在缓存命中走 3 次 string compare。冷启动加载旧格式仍走原路径——但只在该批 cookie 的下一次 add_cookie 触发时才 fallback，之后 entry 自动升级为带缓存。

### 2. F-W1B-044 dirty flag

在 `CookieManagerInner` 加：

```rust
struct CookieManagerInner {
    store: CookieStore,
    raw_cookies: Vec<CookieEntry>,
    /// F-W1B-044：标记自上次 save_persistent_cookies 以来是否有变更。
    /// add_cookie / clear_all / clear_domain 都置 true；save 后置 false。
    /// 新加 save_persistent_cookies_if_dirty 让 caller 跳过空 save 的 IO。
    dirty: bool,
}
```

新加方法：

```rust
/// 仅在自上次保存后有变更时写盘（F-W1B-044）。caller 可定时（如每 30s）
/// 调用本方法，避免高频 search 后每次 save 都全量 pretty JSON。
pub fn save_persistent_cookies_if_dirty<P: AsRef<Path>>(
    &self,
    path: P,
) -> Result<bool, Box<dyn std::error::Error>> {
    let dirty = self.inner.lock().unwrap().dirty;
    if !dirty {
        debug!("Cookie 未变更，跳过持久化");
        return Ok(false);
    }
    self.save_persistent_cookies(path)?;
    Ok(true)
}
```

修改：`add_cookie` / `clear_all` / `clear_domain` 在锁内置 `dirty = true`；`save_persistent_cookies` 在成功写盘后 `dirty = false`。`load_persistent_cookies` 初始 `dirty = false`。

接口契约：原 `save_persistent_cookies` 仍可调（无脑全写），新方法是优化路径。caller `client.rs::save_cookies` 不强制改——这条 finding 里 caller 决定调度，core-net 只暴露能力。本批保留 `save_cookies` 行为不变，但**新加**等价 `save_cookies_if_dirty` 给未来 caller 用。

### 3. F-W1B-045 WebDavClient build

```rust
let client = Client::builder()
    .timeout(Duration::from_secs(30))
    .connect_timeout(Duration::from_secs(10))
    .build()
    .expect("WebDavClient: reqwest client must build with default TLS config");
```

`reqwest::Client::builder().build()` 在 native 仅 TLS 配置失败时返回 Err；本项目用 reqwest 默认 rustls/native-tls，build 失败属于环境异常，不应静默兜底。`expect` 让失败立即 panic 暴露问题，用户不会看到无超时的"半坏"client。

## Open Questions

（已收敛 — 用户选保守三补丁方案）

## Requirements

### MVP scope

1. **CookieEntry 结构扩展** + add_cookie retain 优化（含旧格式 fallback）
2. **CookieManagerInner.dirty** + 3 处置位 + `save_persistent_cookies_if_dirty` 新方法 + `client.rs::save_cookies_if_dirty` 转发
3. **WebDavClient::new** unwrap_or_else → expect
4. 至少 3 个新单测：
   - `test_add_cookie_dedup_uses_cached_keys` — 验证缓存命中路径不需要 parse Url
   - `test_save_if_dirty_skips_when_unchanged` — 验证 dirty=false 时跳过 IO
   - `test_save_if_dirty_writes_after_modify` — 验证 add_cookie 后 dirty 自动置 true
5. 现有 19 个 core-net 测全部仍通过（含旧格式向后兼容场景）
6. master report F-W1B-043/044/045 标 Resolution by BATCH-17

### 不在范围

- 完整 HashMap 索引重写 add_cookie（用户拒绝候选 B）。
- 调度策略改动（`client.rs::save_cookies` 何时调由 caller 决定）。
- WebDavClient 改 `Result<Self>`（候选项之一，用户选 expect）。
- 其它 cookie 行为变更（path 大小写、domain 边界等）。

## Acceptance Criteria

- [ ] `CookieEntry` 含 `dedup_name / dedup_domain_flag / dedup_path` 字段，全部 `#[serde(default)]` 向后兼容
- [ ] `add_cookie` retain 优先用缓存键比较，回退路径仍存在
- [ ] `CookieManagerInner` 含 `dirty: bool` 字段
- [ ] `add_cookie` / `clear_all` / `clear_domain` 锁内置 `dirty = true`
- [ ] `save_persistent_cookies` 成功后置 `dirty = false`
- [ ] `save_persistent_cookies_if_dirty` 新方法存在，`dirty=false` 时跳过 IO 返回 `Ok(false)`
- [ ] `client.rs` 有 `save_cookies_if_dirty` 转发方法
- [ ] `WebDavClient::new` 用 `expect(...)` 替换 `unwrap_or_else`
- [ ] `cargo build --workspace` 0 warning 0 error
- [ ] `cargo test -p core-net --lib` 全过（基线 19 + 新 3 = 22）
- [ ] `cargo test --workspace --lib` 全绿
- [ ] master report `findings-rust-logic.md` F-W1B-043/044/045 标 Resolution
- [ ] master report 主索引 `findings.md` 同步

## Definition of Done

- 3 项全做完 + 3 单测 + cargo build/test 全绿
- 旧格式 cookie JSON 向后兼容（`#[serde(default)]` + retain fallback）
- F-W1B-043/044/045 三条 finding 闭环

## Decision (ADR-lite)

**Context**: BATCH-09 后做 BATCH-17 quick win 收尾 core-net P1。3 条 finding 都是 micro-perf / 健壮性，没有大改动空间。

**Decision**: 保守三补丁 — 缓存 dedup key（不重写 add_cookie 主流程）+ 加 dirty flag（不强制改 caller 调度）+ expect()（让 build 失败响亮）。

**Consequences**:
- 净 ~80-120 行 + 3 单测，0 新依赖
- `CookieEntry` JSON 多 3 字段，旧格式 entry 走 `#[serde(default)]` + fallback 路径仍正确
- 消除 add_cookie 内 retain 的 O(n × Url::parse) 开销；常见 cookie 列表 <100 也能省一些
- 给 caller 提供"不脏不写"能力，但不强制使用，避免破坏现有调度
- WebDavClient build 失败将 panic（环境异常），不再吞配置错误

## Technical Notes

### 风险点

- **`#[serde(default)]` 兼容性**：现有持久化 JSON 文件没 dedup_* 字段，加载时会拿空字符串。**第一次 add_cookie 触发 retain 时会走 fallback 路径**正确处理一次后，新写盘的 JSON 自带新字段，下次加载就走快路径。`test_save_and_load_backward_compat` 已覆盖旧→新格式迁移，本批改动需保证它仍过。
- **dirty flag 锁竞争**：dirty 读写都在 `inner.lock()` 内，与原有 store/raw_cookies 同一把锁。无新增锁，无 race 风险。
- **save_persistent_cookies_if_dirty 的 false 返回值**：caller 关心"是否真写"，但目前的 `save_cookies` 返回 `Result<()>`。新加的 if_dirty 版本返回 `Result<bool>`（true=写了 / false=skip）让 caller 可记日志或做后续动作。

### 测试 case 设计

```rust
#[test]
fn test_add_cookie_dedup_uses_cached_keys() {
    let manager = CookieManager::default();
    manager.add_cookie("a=1", "https://example.com").unwrap();
    manager.add_cookie("a=2", "https://example.com").unwrap();  // 应替换 a=1
    let inner = manager.inner.lock().unwrap();
    let count = inner.raw_cookies.iter().filter(|e| e.dedup_name == "a").count();
    assert_eq!(count, 1);
    let only = inner.raw_cookies.iter().find(|e| e.dedup_name == "a").unwrap();
    assert!(only.raw_cookie.contains("a=2"));
    // 验证 cached key 字段已填
    assert_eq!(only.dedup_name, "a");
    assert!(!only.dedup_path.is_empty());
}

#[test]
fn test_save_if_dirty_skips_when_unchanged() {
    let manager = CookieManager::default();
    manager.add_cookie("x=1; Max-Age=3600", "https://example.com").unwrap();
    let path = temp_dir().join("test_dirty_skip.json");
    let written = manager.save_persistent_cookies_if_dirty(&path).unwrap();
    assert!(written, "first save must write");
    let mtime1 = fs::metadata(&path).unwrap().modified().unwrap();

    // 等待 1ms 让 mtime 有可观测差
    std::thread::sleep(std::time::Duration::from_millis(10));

    // 第二次无变更
    let written2 = manager.save_persistent_cookies_if_dirty(&path).unwrap();
    assert!(!written2, "no changes → skip write");
    let mtime2 = fs::metadata(&path).unwrap().modified().unwrap();
    assert_eq!(mtime1, mtime2, "file mtime should not change");

    fs::remove_file(&path).ok();
}

#[test]
fn test_save_if_dirty_writes_after_modify() {
    let manager = CookieManager::default();
    let path = temp_dir().join("test_dirty_write.json");
    manager.add_cookie("a=1; Max-Age=3600", "https://example.com").unwrap();
    manager.save_persistent_cookies_if_dirty(&path).unwrap();

    // dirty 应被清，跳过
    assert!(!manager.save_persistent_cookies_if_dirty(&path).unwrap());

    // 再加 cookie，dirty 应重置
    manager.add_cookie("b=2; Max-Age=3600", "https://example.com").unwrap();
    assert!(manager.save_persistent_cookies_if_dirty(&path).unwrap());

    fs::remove_file(&path).ok();
}
```

### 实施顺序

1. F-W1B-045 expect()（最简单，先做）
2. F-W1B-044 dirty flag（结构改动小）
3. F-W1B-043 dedup 缓存（最复杂；放最后避免破坏前面测试基线）
4. cargo test -p core-net --lib 全过
5. cargo build --workspace 0 warning
6. master report 更新

## Research References

- 路线图 BATCH-17：`.trellis/tasks/archive/2026-05/05-20-fix-roadmap/plan/roadmap.md:29` — `core-net cookie + webdav | 3 | S | none`
- F-W1B-043/044/045 master：`.trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings-rust-logic.md:553-585`
- core/core-net/src/cookie.rs L121-180 (add_cookie)、L88-117 (save)
- core/core-net/src/webdav.rs L66-76 (WebDavClient::new)
- core/core-net/src/client.rs L141, L150-155 (callers)
