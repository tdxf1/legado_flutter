# BATCH-09: 备份 AES 加固（4 条 finding，方案 A 保守 quick wins）

## Goal

补 4 条 backup AES + zip + replace_rules 安全/性能 finding：
- F-W1A-001 [P0] AES-128/ECB + MD5 弱算法 — 仅做 doc + tracing::warn 标记 weak（不做 v2 强加密）
- F-W1A-003 [P1] 解密缺认证 — `try_decrypt_or_passthrough_array` 解密分支强制 JSON Array 校验
- F-W1A-012 [P1] zip-bomb OOM — `import_from_zip` 加单 entry 50MB / 总 500MB 上限 + `Read::take` cap
- F-W1A-019 [P1] replace_rules Mutex 阻塞 — `get_or_load_rules` SQL 移出 lock + double-check 重新加锁

**关键决策**：F-W1A-001 v2 强加密**不做**，因 audit 揭示 legado_aes 模块**还未投产**（backup_dao 当前导出明文 JSON，未调 encrypt_legado_aes）。零真实用户密文存量场景下，提前做 v2 是 over-engineering，留待真正接入加密备份功能时再上。

## What I already know

完整 audit 落盘 `research/batch09-audit.md`（343 行，sub-agent 出品）。摘要：

### F-W1A-001 现状

`core/core-storage/src/legado_aes.rs`（292 行）4 个 pub fn：
- `legado_md5_key` / `encrypt_legado_aes` / `decrypt_legado_aes` / `try_decrypt_or_passthrough_array`
- **外部 caller 为零** — 仅本模块单测引用
- 单测注释自承"错密码也可能解出看似合法字节流"
- 但**没有产品级 weak/deprecated 标签** — 模块顶部 doc 仅写"与 Hutool 默认 ECB 比特互通"，沿用 Legado 选型动机

历史背景：BATCH-12（已完成）只落了**算法 + persistence 钩子**（`api.rs::set_backup_password` / `get_backup_password`），zip 加密流水线还没接入。

### F-W1A-003 主战场代码

```rust
// legado_aes.rs:140-151
pub fn try_decrypt_or_passthrough_array(
    text: &str,
    password: &str,
) -> Result<String, String> {
    let trimmed = text.trim();
    if let Ok(v) = serde_json::from_str::<serde_json::Value>(trimmed) {
        if v.is_array() {
            return Ok(text.to_string());
        }
    }
    decrypt_legado_aes(trimmed, password)  // ← 解密成功直接返回，没二次校验
}
```

**漏洞**：
1. `decrypt_legado_aes` 内部 `pkcs7_unpad` 错密码也有概率通过
2. `String::from_utf8` 也有解出"合法 UTF-8 但乱码"的小概率窗口
3. 解密成功后**没强制校验"必须是 JSON Array"** — F-W1A-003 攻击面

修：解密分支后追加 `serde_json::from_str::<Value>` + `is_array()` 强制检查。

### F-W1A-012 主战场代码

`backup_dao.rs:194-217` (`import_from_zip`)：

```rust
let mut payloads: HashMap<String, String> = HashMap::new();
for i in 0..archive.len() {
    let mut entry = archive.by_index(i)...;
    let name = entry.name().to_string();
    if !KNOWN_FILE_NAMES.contains(&name.as_str()) { continue; }
    let mut buf = String::new();
    entry.read_to_string(&mut buf)
        .map_err(|e| format!("读取 {} 失败: {}", name, e))?;
    payloads.insert(name, buf);
}
```

5 张表（bookSource / bookGroup / bookshelf / bookmark / replaceRule）走相同路径。

修：加 `MAX_ENTRY_SIZE = 50MB` + `MAX_TOTAL_SIZE = 500MB`，**先 entry.size() 预检 + 再 Read::take(MAX+1) 实读 cap**（zip central directory 的 size 字段可被攻击者篡改，需双层防御）。

### F-W1A-019 主战场代码

`api.rs:1038-1043`：

```rust
let rules = cache.get_or_load_rules(db_path, cache_generation, || {
    let mut conn = open_db(db_path)?;                 // ← lock 内 SQL
    let dao = ReplaceRuleDao::new(&mut conn);
    dao.get_enabled().map_err(...)
})?;
```

`std::sync::Mutex<ReplaceRulesCache>` 全局锁。SQL 仅在 cache miss 跑（首次 / generation 变 / db_path 变），但 lock 是排他的；reader 章节 burst 切换时即便不跑 SQL，单查表 + clone 也串行。

修：拆成两阶段 API：
1. **第 1 次加锁**：检查命中 → 命中 return；不命中 copy db_path/gen 后 drop lock
2. **lock-free 跑 SQL**
3. **第 2 次加锁**：double-check 命中（其它线程可能已填好）→ 是用别人的；否则写入 cache

约 70 行重构。必须保留现有 `cache_concurrency_tests::unified_cache_keeps_generations_isolated` 不变量。

### 测试基线

`cargo test --workspace --lib` 全绿：
- core-storage 91 / bridge 16 / core-source 187(+8 ignored) / core-net 19 / core-parser 41
- legado_aes 7 测，**不 cover** F-W1A-003 错密码乱码分支（本批次需补）
- `cache_concurrency_tests::unified_cache_keeps_generations_isolated` 已覆盖 generation 隔离不变量

## Open Questions

（已收敛 — 走方案 A 保守 quick wins）

## Requirements (final)

### MVP scope（4 项）

1. **F-W1A-001 doc + log warning**（核心代码改动 ~30 行）
   - `legado_aes.rs` 模块顶部 doc 加"⚠ WARNING: AES-128/ECB + MD5 KDF is cryptographically weak..."
   - `encrypt_legado_aes` / `decrypt_legado_aes` 函数 doc 加 weak 标记
   - encrypt 入口加 `tracing::warn!("legado_aes encrypt: AES-128/ECB+MD5 is weak...")` 一次/进程（用 `Once` 限频）
   - 不动函数签名，不引入新 module

2. **F-W1A-003 强 JSON Array 校验**（~40 行 + 2 单测）
   - `try_decrypt_or_passthrough_array` 解密分支后追加 `serde_json::from_str::<Value>` + `is_array()` 强制校验
   - 不通过返回 `Err("解密成功但内容不是合法 JSON Array")`
   - 不动 `decrypt_legado_aes` 本体（保留低层比特互通）
   - 新增 2 个单测：错密码 PKCS7/UTF-8 都通过但解出非 Array → Err / 错密码解出非 UTF-8 → Err

3. **F-W1A-012 zip 大小限制**（~50 行 + 2 单测）
   - 加 `MAX_ENTRY_SIZE = 50 * 1024 * 1024` 和 `MAX_TOTAL_SIZE = 500 * 1024 * 1024` 常量
   - `import_from_zip` 循环内：`entry.size()` 预检超 50MB 即拒；累计 `total` 超 500MB 拒
   - **同时**用 `entry.take(MAX_ENTRY_SIZE + 1).read_to_string()` 实读 cap（防 size 字段被篡改）
   - 新增 2 单测：单 entry 超限 / 总和超限均返回 Err

4. **F-W1A-019 SQL 移出 lock**（~70 行 + 0/1 新测）
   - 拆 `ReplaceRulesCache::get_or_load_rules` 为两阶段 API
   - 第 1 次加锁 check 命中；miss 时 drop lock 后 lock-free 跑 SQL；第 2 次加锁 double-check + 写入
   - 保留所有现有 `cache_concurrency_tests` 测过
   - 可选：新增一个多线程 stress 测验证 SQL 期间 cache miss 抢锁不会死锁/race

### 不在范围

- **F-W1A-001 v2 强加密**：legado_aes 未投产，留待真正接入备份加密时再做（建议拆 BATCH-09b）
- BATCH-09 路线图原描述含的"备份 zip 加密流水线接入" — 不做
- 其它 backup_dao 死代码 / replace_rule_dao 重构

## Acceptance Criteria

- [ ] `legado_aes.rs` 模块顶部 doc 含 "WARNING / weak / 不建议作生产加密" 中英文
- [ ] `encrypt_legado_aes` 入口 `tracing::warn!` 一次/进程（grep 命中）
- [ ] `try_decrypt_or_passthrough_array` 解密分支后含 `serde_json::from_str::<Value>` + `is_array()` 强制校验
- [ ] `legado_aes` 模块新增 2+ 单测覆盖错密码乱码分支
- [ ] `backup_dao.rs::import_from_zip` 含 `MAX_ENTRY_SIZE` / `MAX_TOTAL_SIZE` 常量 + `Read::take` cap
- [ ] `backup_dao.rs` 新增 2+ 单测覆盖 zip 大小超限
- [ ] `api.rs` `apply_replace_rules_impl` 路径下的 cache miss SQL 在 mutex 外执行（grep 验证 lock guard 不持有 SQL 调用）
- [ ] `cargo build --workspace` 0 warning 0 error
- [ ] `cargo test --workspace --lib` 全绿（基线 91+16+187+19+41 + 新增 4-5 个测）
- [ ] 现有 `cache_concurrency_tests::unified_cache_keeps_generations_isolated` 通过
- [ ] master report `findings-rust-data.md` F-W1A-001/003/012 + bridge findings F-W1A-019 标 Resolution
- [ ] master report `findings.md` 主索引同步

## Definition of Done

- 4 项全做完 + 4-5 个单测 + cargo build/test 全绿
- F-W1A-001 doc/warn 标记完整
- F-W1A-003 强 Array 校验落地
- F-W1A-012 zip 双层 cap 落地
- F-W1A-019 SQL 移出 lock
- master report 更新

## Decision (ADR-lite)

**Context**: 路线图 BATCH-09 4 条 finding，audit 揭示 legado_aes 模块未投产（backup zip 当前明文）；4 条性质各异：1 个 P0 doc 决策类、2 个 P1 简单补丁、1 个 P1 性能微优化。

**Decision**: 走方案 A — F-W1A-001 仅做 doc + warn，其它 3 条全做。F-W1A-001 v2 强加密留 BATCH-09b 等真正接入时再做。

**Consequences**:
- 净 ~190 行 + 4-5 单测 + 0 新依赖
- 4 个 finding 闭环（其中 F-W1A-001 缩范围 — 仅 doc/warn 不做 v2）
- 章节切换 burst 卡顿改善（F-W1A-019 lock 时间从 SQL 数十 ms 降到 hash 查表 ns 级）
- zip 解压加双层 cap 防 OOM
- legado_aes 解密路径不再返回乱码字符串（强 Array 校验）

## Technical Notes

### 风险点

- **F-W1A-019 race condition**：double-check 逻辑必须正确，A 线程 SQL 跑期间 B 线程拿锁写完，A 重新加锁需丢自己结果用 B 的（保持 generation 单调）。已有 `unified_cache_keeps_generations_isolated` 测覆盖；如重构后该测仍过即认为 race 安全。
- **F-W1A-012 entry.size() 不可信**：zip central directory size 字段可篡改。预检（快路径）+ `Read::take` 实读 cap（慢路径兜底）双层防御。两者都返回 Err 时只取一方信息，不让攻击者通过两层差异爆 panic。
- **F-W1A-003 行为变更**：`try_decrypt_or_passthrough_array` 之前会返回乱码（pkcs7+utf8 双过的小概率窗口），改后返回 Err。**审 caller** — audit 已确认零外部 caller，所以仅影响未来 caller 与单测。
- **F-W1A-001 doc tone**：明确说"weak / not for production encryption / 仅为 Legado 互兼容标记"，但不能让用户误以为算法损坏到无法用（如果用户已用此功能加密了 webdav.json，仍能解密回来）。tone 是"⚠ 弱混淆，请勿视为真加密"。

### 实施顺序

1. **F-W1A-001 doc/warn**（最简单，先做让 IDE 一直提示）
2. **F-W1A-003 强 Array 校验** + 2 单测
3. **F-W1A-012 zip 大小限制** + 2 单测（独立文件，不与上面冲突）
4. **F-W1A-019 SQL 移出 lock** + 0-1 新测（最复杂留最后，避免影响前面测试基线）
5. `cargo build --workspace` 0 warning
6. `cargo test --workspace --lib` 全绿
7. 更新 master report

### 测试 case 设计

```rust
// legado_aes.rs (additions)
#[test]
fn try_decrypt_rejects_garbage_when_pkcs7_passes() {
    // 错密码触发 PKCS7+UTF-8 双过但解出乱码（非 Array）
    // 期待 Err
}

#[test]
fn try_decrypt_rejects_decrypt_to_non_array_json() {
    // 正确密码但加密前是 `{"foo": 1}` 而非 array
    // 解密成功但 is_array() 不通过
    // 期待 Err
}

// backup_dao.rs (additions)
#[test]
fn import_zip_rejects_oversized_single_entry() {
    // 造一个 zip 含 60MB 单文件（虚拟流写）
    // 期待 Err contain "50MB"
}

#[test]
fn import_zip_rejects_total_oversize() {
    // 造一个 zip 含 11 个 50MB-1 文件（每个刚好不超单限，总超 500MB）
    // 期待 Err contain "500MB"
}

// api.rs replace_rules (optional new stress)
#[test]
fn replace_rules_cache_miss_no_deadlock_under_contention() {
    // 10 个线程同时请求不同 db_path/generation，看不卡 / 不 race
}
```

### 已确认测试基线

| Crate | 通过数 |
|---|---|
| core-storage | 91 |
| bridge | 16 |
| core-source | 187 (+8 ignored) |
| core-net | 19 |
| core-parser | 41 |
| **总** | **354** |

本批后预期：354 + 4-5 = 358-359。

## Research References

- `research/batch09-audit.md` — 完整 audit 343 行
- F-W1A-001/003/012 master：`.trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings-rust-data.md:50,74,188`
- F-W1A-019 master：`.trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings-rust-data.md:294`
- 路线图 BATCH-09 描述：`.trellis/tasks/archive/2026-05/05-20-fix-roadmap/plan/roadmap.md:21`
