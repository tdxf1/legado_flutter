# BATCH-23: Rust silent error + 凭证日志 + dep 清理批量小修

## Goal

6 条 Rust P1-P3 finding 一批清，主题"silent error / 凭证日志泄漏 / dep 重复 / 死代码 / 函数名误导"。零回归风险，主要价值是 F-W1A-023 安全修复（token 不再明文 log）+ F-W1A-030 错误传播取代 silent flatten。

## What I already know

### 来自 explore 扫描（2026-05-21）+ 主对话精确核实

**1. F-W1A-023 [P1 主要] api-server token 在 warn 日志输出明文**

`core/api-server/src/main.rs:108-119`：
```rust
let api_token = std::env::var("LEGADO_API_TOKEN")
    .ok()
    .filter(|s| !s.is_empty())
    .unwrap_or_else(|| {
        let generated = uuid::Uuid::new_v4().to_string();
        tracing::warn!(
            "LEGADO_API_TOKEN not set; generated ephemeral token for this run: {} \
             (set LEGADO_API_TOKEN to keep a stable token across restarts)",
            generated
        );
        generated
    });
```

token 完整明文进 warn 日志 — 服务器日志 / log aggregator（journalctl / docker logs / 云端 sink）会截留，被任何能读 log 的人拿到。修复：log 只记前 8 char + `(set LEGADO_API_TOKEN to ... full token written to stderr only)`，完整 token 走 `eprintln!`（不进结构化日志），或一概不 log（强制要求设环境变量）。

**保留可观察性的折中方案**：log 前 8 char 作为 fingerprint + 完整 token 走 stderr 一次性输出。

**2. F-W1A-030 [P2 次要] backup_dao `rows.flatten()` 静默吞 SQL 错误**

`core/core-storage/src/backup_dao.rs:254-259, 320-330`，两处：

```rust
let rows = stmt
    .query_map([], |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)))
    .map_err(|e| format!("查 sources 失败: {}", e))?;
for r in rows.flatten() {  // ← 这里 flatten 把 Err 全部吞掉
    sources_url_to_id.entry(r.1).or_insert(r.0);
}
```

`rows` 类型是 `MappedRows<F>` 实现 `Iterator<Item = Result<T>>`。`.flatten()` 把 `Result<T>` 当作 `Iterator` 处理（`Ok(t)` → `[t]`，`Err(_)` → `[]`），等同 `.filter_map(Result::ok)` 静默吞错。

修复：改 `for r in rows { let r = r.map_err(|e| format!("读 sources 行失败: {}", e))?; ... }` 把错误向上传播。两处独立改。

**3. F-W1A-037 [P2 次要] legado_local.json 损坏时 silent 丢失**

`core/bridge/src/api.rs:1366-1395 (set_backup_password)` + `1398-1413 (get_backup_password)`：

```rust
// set_backup_password：read existing → modify password field → write back
let mut map: serde_json::Map<String, serde_json::Value> = match std::fs::read_to_string(&path) {
    Ok(text) => serde_json::from_str(&text)
        .ok()                                                    // ← Err 吞掉
        .and_then(|v: serde_json::Value| v.as_object().cloned()) // ← 非 object 吞掉
        .unwrap_or_default(),                                    // ← 空 map
    Err(_) => serde_json::Map::new(),                            // ← 文件不存在 ok
};
```

风险：用户的 legado_local.json 因任何原因（外部编辑出错、磁盘损坏、并发写）变成无效 JSON，下次 set_backup_password 会用空 Map 覆盖原文件 → 用户其它配置（未来扩展）丢失。

修复：解析失败时**写入 .bak 副本**保留原内容，然后才用空 Map 重置；同时 log warn。

`get_backup_password` 也类似（解析失败返回空串，但不会破坏文件）— 该处只补 log warn 不动行为。

**4. F-W3-030 [P2 次要]**（**已修复但 master report 未标 Resolution**）

`core/bridge/Cargo.toml:25-26` 已经显示：
```toml
# tempfile 同时是 build-time / test 用，统一进 [dependencies] 即够；dev-deps 不再重复。
tempfile = { workspace = true }
```

dev-deps 里已经没有重复的 `tempfile` 行（注释说明已合并）。本批顺手把 master report `findings-cross-config.md` 的 F-W3-030 标 Resolution。

**5. F-W1A-040 [P3 nice-to-have] `clean_legado_url` 函数名误导**

`core/core-storage/src/source_dao.rs:729-731`：
```rust
fn clean_legado_url(url: &str) -> String {
    url.trim().to_string()
}
```

函数名暗示"清理 URL"但只做 trim。一处 caller 在 L724。修复：内联到 caller `url.trim().to_string()`，删除 fn。

**6. F-W1A-047 [P3 nice-to-have] api-server/src/dto.rs orphan 文件**

```
$ cat core/api-server/src/dto.rs
// DTOs (Data Transfer Objects) will be added as endpoints are implemented.
```

整文件 1 行 placeholder 注释，**主对话核实** grep `mod dto|use.*dto` 在 api-server 内 0 命中 — 完全 orphan。直接删文件。

### 改动清单

| # | finding | 文件 | 改动 | 净行 |
|---|---|---|---|---|
| 1 | F-W1A-023 | `core/api-server/src/main.rs:108-119` | log 改前 8 char + eprintln 完整 token；改注释说明 | +6 / -2 = +4 |
| 2 | F-W1A-030 | `core/core-storage/src/backup_dao.rs:257, 327` | 2 处 `rows.flatten()` 改 for-loop 错误传播 | +6 / -2 = +4 |
| 3 | F-W1A-037 | `core/bridge/src/api.rs:1376-1383` | 解析失败时写 .bak 副本 + warn log；read fn 加 warn log | +12 / -3 = +9 |
| 4 | F-W3-030 | `findings-cross-config.md:545-553` | master report 标 Resolution（代码已无重复，本批仅补文档） | +1 / 0 |
| 5 | F-W1A-040 | `core/core-storage/src/source_dao.rs:724,729-731` | 内联 clean_legado_url 到 caller，删函数 | +1 / -4 = -3 |
| 6 | F-W1A-047 | `core/api-server/src/dto.rs` | 整文件删（1 行 placeholder） | 0 / -1 文件 |

总计净 diff：**约 +14 行**（含 .bak 副本逻辑 + log 改造）。

## Open Questions

（已收敛）

## Requirements (final)

### MVP scope（6 项 + 1 项 master report 同步）

1. **改 `core/api-server/src/main.rs:108-119`**
   - log 改：`tracing::warn!("LEGADO_API_TOKEN not set; generated ephemeral token (fingerprint: {}…); set LEGADO_API_TOKEN to ...", &generated[..8])`
   - `eprintln!("[legado api-server] full token: {}", generated)` 一次性 stderr 输出（不进结构化日志）
   - 加注释说明 BATCH-23 / F-W1A-023

2. **改 `core/core-storage/src/backup_dao.rs:254-259, 320-330`**
   - 两处 `for r in rows.flatten()` → `for r in rows { let r = r.map_err(|e| format!("读 ... 行失败: {}", e))?; ... }`
   - sources 路径错误信息 "读 sources 行失败"；books 路径 "读 books 行失败"

3. **改 `core/bridge/src/api.rs::set_backup_password`**
   - 解析失败时（不区分 from_str Err / as_object None）：写 `.bak` 副本（用 timestamp 后缀防覆盖）+ `tracing::warn!` 记录原因
   - 然后用空 Map 重置（保持原行为，但有备份兜底）

4. **改 `core/bridge/src/api.rs::get_backup_password`**
   - 解析失败时 `tracing::warn!` 记录但仍返回空串（保持行为）

5. **删 `core/core-storage/src/source_dao.rs::clean_legado_url`**
   - 内联到 L724：`.or_insert_with(|| serde_json::Value::String(url.trim().to_string()))`
   - 删 L729-731 函数定义

6. **删 `core/api-server/src/dto.rs`** 整文件（1 行 placeholder）
   - 同步检查 `core/api-server/src/lib.rs` / `main.rs` 是否有 `mod dto;` 声明（前面 grep 已确认 0）

7. **master report 同步**
   - F-W1A-023/030/037/040/047 各加 Resolution
   - F-W3-030 加 Resolution（代码已无重复）
   - findings.md 主索引同步

### 不在范围内

- token 强制要求设环境变量（启动时拒绝运行）— 行为变化大，本批保守保留 ephemeral 生成
- 用 `secrecy::SecretString` 包 token — 引入新依赖
- legado_local.json 完整 schema 校验
- 其它 Rust silent error finding（rss_article_dao / chapter_dao 等）— 留独立批次

## Acceptance Criteria

- [ ] `api-server/main.rs` token log 不再含完整 token 字符串（grep `tracing::warn!.*generated\b` 改成只含 8 char fingerprint）
- [ ] `eprintln!` 输出完整 token 一次（grep `eprintln!.*full token`）
- [ ] `backup_dao.rs` `rows.flatten()` 0 命中（grep）
- [ ] `bridge/api.rs::set_backup_password` 解析失败路径含 `tracing::warn!` + `.bak` 副本写入
- [ ] `source_dao.rs::clean_legado_url` 函数 0 命中（grep；caller 已内联）
- [ ] `core/api-server/src/dto.rs` 文件不存在
- [ ] `cargo build --workspace` PASS
- [ ] `cargo test --workspace` 维持 PASS（baseline: core-storage 91 + bridge 16/8 + 其它）
- [ ] `cargo clippy --workspace` 0 新 warning
- [ ] master report `findings-rust-data.md` F-W1A-023/030/037/040/047 加 Resolution
- [ ] master report `findings-cross-config.md` F-W3-030 加 Resolution
- [ ] master report `findings.md` 主索引同步

## Definition of Done

- 6 条 finding 闭环（5 条新做 + 1 条已修复补 Resolution）
- token 安全提升（不再明文 log）
- backup_dao 错误传播取代 silent flatten
- legado_local.json 损坏时有 .bak 副本兜底
- orphan 文件清除

## Decision (ADR-lite)

**Context**: BATCH-22 后 user-driven scan 在 explore audit 给的候选 A/B/C 中选 C — Rust silent error / 凭证日志批量小修，6 条 P1-P3 finding 打包。

**Decision**: 选项 C — 6 条 Rust finding 一批清。

**Consequences**:
- 净 +14 行（保守 .bak 副本 + log 改造）
- F-W1A-023 安全修复（token 不再明文 log）— 真实价值
- F-W1A-030 错误传播取代 silent flatten — 防御性
- F-W1A-037 .bak 副本兜底 — 防御性
- F-W3-030 顺手补 Resolution（代码已修，文档未追）
- 不引入 token 强制要求（保留 ephemeral 生成行为，本批保守）

## Technical Notes

### 风险点

- **`rows.flatten()` 改错误传播**：调用 fn 现在签名是 `Result<...>` 已支持 `?`，改后 `Err` 直接传上去；caller 已经在 try-catch 链上没有"silent skip 一行"的需求 — 行为等价但向上 surface 错误（更安全）。需 `cargo test --workspace` 全绿确认无 caller 期望 silent skip。
- **`.bak` 副本路径**：`legado_local.json.bak` vs `legado_local.json.<timestamp>.bak`？保守选 timestamp（防覆盖既存 .bak），用 `chrono::Utc::now().timestamp()` 拼接。chrono 已是 core-storage 依赖。
- **`api-server/src/dto.rs` 删除**：grep 确认 0 caller。删除后 `cargo build` 应通过（mod 未声明则不会被引用）。

### 实施顺序

1. read 6 处 file:line 完整 chunk 做 final review
2. 改 main.rs token log（最关键安全修复）
3. 改 backup_dao.rs 两处 flatten
4. 改 bridge/api.rs set_backup_password / get_backup_password
5. 改 source_dao.rs clean_legado_url 内联
6. 删 api-server/src/dto.rs
7. cargo build --workspace + cargo test --workspace + cargo clippy
8. 更新 master report 6 条 finding
9. archive + commit

### 净 diff 估算

| 文件 | 改动 |
|---|---|
| `core/api-server/src/main.rs` | +6 / -2 = +4 |
| `core/core-storage/src/backup_dao.rs` | +6 / -2 = +4 |
| `core/bridge/src/api.rs` | +12 / -3 = +9 |
| `core/core-storage/src/source_dao.rs` | +1 / -4 = -3 |
| `core/api-server/src/dto.rs` | -1 整文件 |
| **合计** | **+14 行净 + 删 1 文件** |

## Research References

- 本任务沿用 BATCH-22 后 scan audit（in-context）
- F-W1A-023/030/037/040/047 master entries：`.trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings-rust-data.md`
- F-W3-030 master entry：`.trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings-cross-config.md`
- BATCH-22 archive：`.trellis/tasks/archive/2026-05/05-21-batch-22-flutter-sentinel/`
