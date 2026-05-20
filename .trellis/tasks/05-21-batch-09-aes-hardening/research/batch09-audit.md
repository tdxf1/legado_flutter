# BATCH-09 备份 AES 加固 — Audit 笔记

- **Query**: 为 BATCH-09 准备 implement 阶段精确清单（4 条 P0/P1 finding 现状 + 推荐 PRD 范围）
- **Scope**: internal（Rust workspace）
- **Date**: 2026-05-21
- **范围**: 仅 audit，未改动任何代码

---

## 1. legado_aes.rs（292 行）现状

### 1.1 公开 API

| 函数 | 签名 | 暴露面 |
|---|---|---|
| `legado_md5_key` | `pub fn legado_md5_key(password: &str) -> [u8; 16]` | `legado_aes.rs:49` — module 内为单测开放，外部无 caller |
| `encrypt_legado_aes` | `pub fn encrypt_legado_aes(plain: &str, password: &str) -> Result<String, String>` | `legado_aes.rs:91` — **目前外部无 caller**（仅 PRD batch12 文档提到"未来可调"，仅本模块单测引用）|
| `decrypt_legado_aes` | `pub fn decrypt_legado_aes(b64: &str, password: &str) -> Result<String, String>` | `legado_aes.rs:109` — **目前外部无 caller**，仅 `try_decrypt_or_passthrough_array` 内部调用 + 单测 |
| `try_decrypt_or_passthrough_array` | `pub fn try_decrypt_or_passthrough_array(text: &str, password: &str) -> Result<String, String>` | `legado_aes.rs:140` — **目前外部无 caller**（设计为 servers.json 解码兜底，但批次 12 PRD 还没接入实际 zip 流水线）|

> **关键发现**：批次 12 只落地了**算法 + persistence 钩子**（`set_backup_password` / `get_backup_password` 在 `api.rs:1366+`），**zip 加密流水线本身还未接入** —— `backup_dao::export_to_zip` 没有调过 `encrypt_legado_aes`，`backup_dao::import_from_zip` 也没调过 `decrypt_*`。意味着：
> - F-W1A-001 和 F-W1A-003 当前对**用户实际备份**毫无影响（备份 zip 仍是明文 JSON）
> - 这次加固相当于**还没"投产"的代码上做防御性整改**，迁移压力极小（无历史密文需要兼容）

### 1.2 历史 weak/warning 标记审查

源文件正文 + 注释 grep `weak|warn|deprecated|TODO|FIXME|fallback|legacy`：

- **`legado_aes.rs:7`** — doc 注释提到 `try_decrypt_or_passthrough_array` 为 "未加密 fallback"
- **`legado_aes.rs:108`** — `decrypt_legado_aes` doc："失败原因可能是 base64 非法、密文长度不是 16 倍数、padding 不合法、或解出的字节不是 UTF-8。所有情况都返回 `Err(String)`，由 caller 决定 fallback。"
- **`legado_aes.rs:229-234`**（test_decrypt_legado_compatible 内）：
  > "错密码应失败（PKCS7 反填充几乎必然校验失败）。**注意小概率错密码也能"解出"看似合法的 PKCS7 字节流**，所以这里不强测必失败 — 退而求其次：错密码 != 原文。"

**结论**：作者明确知道 PKCS7 校验有"看似合法"的假阳性窗口（这正是 F-W1A-003 的攻击面），但**没有在产品文档/UI/log 层面打"weak"标签**。注释里没有"weak"/"warning"/"deprecated"字样，也没有指向 AES-GCM/Argon2 的迁移提示。算法选型沿用 Hutool/Legado 默认 AES-128-ECB+MD5，选型动机是"与原 Legado 比特级互通"（`legado_aes.rs:1-31` doc），不是密码学最优。

### 1.3 `try_decrypt_or_passthrough_array` 完整代码（F-W1A-003 主战场）

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
    decrypt_legado_aes(trimmed, password)
}
```

**F-W1A-003 攻击路径**：
1. `is_array()` 兜底：攻击者构造 `[<恶意 JSON>]` 明文头，绕开 AES 解密
2. `decrypt_legado_aes` 内部 `pkcs7_unpad`（`legado_aes.rs:70-86`）只校验 padding 字节一致性，错密码也有概率通过；通过后 `String::from_utf8` 可能拒绝，但**也存在错密码解出"合法 UTF-8 但乱码"的小概率窗口**（注释里已自承）
3. 解密成功的字符串**直接返回**，没有"必须 parse 为 JSON Array"的二次校验

**最小整改路径（建议）**：

- 不动 `decrypt_legado_aes` 本身（保留低层比特级互通）
- 在 `try_decrypt_or_passthrough_array` 解密分支后追加 `serde_json::from_str::<Value>` + `is_array()` 强制校验，不通过即返回 `Err("解密成功但不是合法 JSON Array...")`
- 上层 caller（未来批次接入 zip 时）拿到 `Err` 即视为密文损坏，不再做静默 fallback

### 1.4 v2 强加密接入点（如选方案 B）

如要做 AES-GCM + Argon2id，需要：
- 新增 `encrypt_legado_aes_v2` / `decrypt_legado_aes_v2` 函数对（独立 base64 prefix 区分，例如 `v2:<base64>` 或 zip 内 `*.v2.json` 后缀）
- `Cargo.toml` 已含 `aes = { workspace = true }`，需新增 `aes-gcm` + `argon2`（workspace 依赖范围未含）
- zip 包内**没有 manifest.json**（`backup_dao.rs:17` 明确说"按文件名硬识别"），所以 v1/v2 区分要么靠**单独文件名后缀**要么靠**密文头 magic byte**（base64 解码后前 N 字节）
- Flutter 端 `backup_page.dart` 需加 toggle + 新文案；`set_backup_password` 接口可能要扩成 `(password, mode)`
- Dart 端 `frb_generated.dart` 自动生成，但 toggle UI/i18n 是手动改

---

## 2. backup_dao.rs zip 解压区现状（L150-220 + 上下文）

### 2.1 解压流程概览

`backup_dao.rs:194-217`（`import_from_zip`）：

```rust
let file = File::open(zip_path)...;
let mut archive = ZipArchive::new(file)...;

let mut payloads: HashMap<String, String> = HashMap::new();
for i in 0..archive.len() {
    let mut entry = archive.by_index(i)...;
    let name = entry.name().to_string();
    if !KNOWN_FILE_NAMES.contains(&name.as_str()) {
        continue;
    }
    let mut buf = String::new();
    entry.read_to_string(&mut buf)
        .map_err(|e| format!("读取 {} 失败: {}", name, e))?;
    payloads.insert(name, buf);
}
```

**所有 5 张表**（`bookshelf.json` / `bookGroup.json` / `bookmark.json` / `replaceRule.json` / `bookSource.json` —— 见 `KNOWN_FILE_NAMES` 常量在 `backup_dao.rs:63-69`）走**完全相同**的 `read_to_string` 路径，统一塞进 `payloads: HashMap<String, String>`。

### 2.2 5 张表 dispatch（`backup_dao.rs:222-396`）

把内存里的 `payloads` map 按固定顺序解析，全部在**单事务**内：

| 顺序 | 文件 | dispatch 行 | 依赖 |
|---|---|---|---|
| 1 | `bookSource.json` | L226-265 | 无（先读，构造 url→id 映射）|
| 2 | `bookGroup.json` | L268-288 | 无 |
| 3 | `bookshelf.json` | L292-338 | sources_url_to_id（构造 (name,author)→book_id 映射）|
| 4 | `bookmark.json` | L341-370 | book_key_to_id |
| 5 | `replaceRule.json` | L373-394 | 无 |

每张表都用 `serde_json::from_str::<Vec<Value>>(text)` 把整段字符串一次性反序列化（**全 JSON 一起进内存**）。

### 2.3 entry size 检查可行性

`zip = "2"` crate 的 `ZipFile` 提供：
- `entry.size() -> u64` —— 解压后明文大小（来自 zip central directory）
- `entry.compressed_size() -> u64` —— 压缩后大小

**两者都可用**，只需在 `read_to_string` 之前 check。Cargo.toml 现已是 zip v2（`backup_dao.rs:49` 用 `zip::write::SimpleFileOptions`，是 v2 API），无依赖升级压力。

### 2.4 加大小限制最简实现路径

```rust
// 建议位置: backup_dao.rs:204-216 之间
const MAX_ENTRY_SIZE: u64 = 50 * 1024 * 1024;       // 50MB 单文件
const MAX_TOTAL_SIZE: u64 = 500 * 1024 * 1024;      // 500MB 累计
let mut total: u64 = 0;
for i in 0..archive.len() {
    let mut entry = archive.by_index(i)...;
    let name = entry.name().to_string();
    if !KNOWN_FILE_NAMES.contains(&name.as_str()) { continue; }

    let entry_size = entry.size();
    if entry_size > MAX_ENTRY_SIZE {
        return Err(format!("zip entry {} 超过 50MB 限制 ({}B)", name, entry_size));
    }
    total = total.saturating_add(entry_size);
    if total > MAX_TOTAL_SIZE {
        return Err(format!("zip 累计解压超过 500MB 限制"));
    }
    let mut buf = String::with_capacity(entry_size as usize);  // 顺便预分配
    entry.read_to_string(&mut buf)...;
    payloads.insert(name, buf);
}
```

**注意**：`entry.size()` 来自 zip central directory，是攻击者**可控字段**（理论上可以谎报"小"实际给一大块）。要彻底防御 zip-bomb，最好同步 cap **实际读出的字节数**（用 `Read::take(MAX_ENTRY_SIZE)`）。这是更稳健的写法：

```rust
use std::io::Read;
let mut buf = String::new();
entry.take(MAX_ENTRY_SIZE + 1).read_to_string(&mut buf)?;
if buf.len() as u64 > MAX_ENTRY_SIZE {
    return Err(format!("zip entry {} 超过 50MB 限制", name));
}
```

可选：流式解析（`serde_json::from_reader`）能把峰值内存进一步压低，但需要从"读 String 后 from_str"改成"读 Reader 后 from_reader"。改动量比 size 限制大但仍局限在本函数内。

---

## 3. apply_replace_rules_impl 现状（api.rs:1002-1075 + cache）

### 3.1 函数签名与调用链

```rust
// api.rs:984
pub fn apply_replace_rules(
    db_path: String,
    content: String,
    cache_generation: i64,
    book_name: Option<String>,
    book_origin: Option<String>,
    apply_to_title: bool,
) -> Result<String, String>
```

**FRB 暴露**：通过 `frb_generated.rs:92` 的 `wire__crate__api__apply_replace_rules_impl`，在 `build.rs:56-57` 标记 funcId=57。

**Caller**（仅 Flutter 端 grep 暴露的）：reader 章节渲染流水线（标题/正文按 `apply_to_title` 双跑）。Rust 端单测在 `api::regex_cache_tests` / `api::scope_filter_tests` / `api::cache_concurrency_tests`（共 11 测，已通过）。

### 3.2 当前 Mutex 类型 + 锁住的对象

`api.rs:1210-1211`：

```rust
static REPLACE_RULES_CACHE: std::sync::LazyLock<std::sync::Mutex<ReplaceRulesCache>> =
    std::sync::LazyLock::new(|| std::sync::Mutex::new(ReplaceRulesCache::new()));
```

**`std::sync::Mutex`**（不是 `parking_lot`）。Cache 类型 `ReplaceRulesCache`（`api.rs:1135-1208`）：
- `rule_list: Option<(String, i64, Arc<Vec<ReplaceRule>>)>` — `(db_path, generation, rules)`
- `regex_generation: Option<i64>`
- `regex_entries: HashMap<(String, String), Option<regex::Regex>>` — `(rule_id, pattern) → 编译结果`

### 3.3 锁内 SQL 调用具体内容

**SQL 调用点**：`api.rs:1038-1043` 的闭包，传给 `cache.get_or_load_rules`（`api.rs:1161-1179`）：

```rust
let rules = cache.get_or_load_rules(db_path, cache_generation, || {
    let mut conn = open_db(db_path)?;                                // ← 打开 DB（PRAGMA + SQLite open）
    let dao = core_storage::replace_rule_dao::ReplaceRuleDao::new(&mut conn);
    dao.get_enabled()                                                // ← 真正的 SQL SELECT
        .map_err(|e| format!("加载替换规则失败: {}", e))
})?;
```

`dao.get_enabled()` 内部（`replace_rule_dao.rs:89-99`）：

```sql
SELECT id, name, pattern, replacement, enabled,
       scope, scope_title, scope_content, exclude_scope,
       sort_number, created_at, updated_at
FROM replace_rules WHERE enabled = 1 ORDER BY sort_number ASC
```

外加 `open_db(db_path)`（`api.rs:2318+`）—— 每次 cache miss 都开新连接 + PRAGMA。

**关键**：`get_or_load_rules` 内部先做 `(db_path, generation)` 命中检查（`api.rs:1170-1174`），命中即 return cached `Arc`，**不会跑 SQL**。SQL **只在 cache miss 触发**：
- 首次调用（cache 空）
- generation 变更（用户 CRUD 替换规则后 bump）
- db_path 变更（多档 profile）

热路径（同 generation 同 db_path 反复读章节）**不跑 SQL，只做 HashMap 查表 + 克隆**。但 lock 是全局排他，章节切换 burst 时即便不跑 SQL，单是 regex 查表 + clone 也会串行。

### 3.4 重构难度评估

**方案 A —— 把 SQL 移出 lock（推荐，最小改动）**：

冷启动序列：
1. **第一次加锁**：检查 `(db_path, gen)` 是否命中 → 命中 return；不命中**复制出 generation/db_path 后立即 drop lock**
2. **lock-free 跑 SQL**：`open_db` + `dao.get_enabled()`
3. **第二次加锁**：double-check `(db_path, gen)` 是否被别的线程已填好 → 是则丢掉自己 SQL 结果用别人的；否则写入 cache
4. **regex 查/编译/收集**：当前已经在锁内，可继续

**改动量**：拆 `get_or_load_rules` 闭包 → 改成"返回是否需要 SQL"的两阶段 API。约 30-50 行（含注释）。

**风险**：double-check 逻辑要对：A 线程 SQL 跑到一半 B 线程跑完写入 cache，A 拿回锁要丢自己的结果用 B 的（保持 generation 单调一致性，即 R123 注释里强调的不变量）。**已有测试 `api::cache_concurrency_tests::unified_cache_keeps_generations_isolated` 覆盖了 generation 隔离**，这次重构不能破坏它。

**方案 B —— 切 `parking_lot::RwLock`**：

`parking_lot` 不在 workspace 依赖里（grep 全工程 0 命中），需要新增。RwLock 对"读多写少"有用，但本场景每次 chapter 切换都会 `get_or_compile_regex` 触发 mutation（filter 失败的 None 也要写入），写多读少，RwLock 帮助有限。**不推荐**。

**方案 C —— 完全 lock-free（DashMap）**：

需新依赖 + 重写 cache 数据结构。改动量大，不在 P1 quick-win 范围。

---

## 4. cargo build / test 状态（2026-05-21 实测）

### 4.1 cargo build --workspace（debug）

```
Finished `dev` profile [unoptimized + debuginfo] target(s) in 5.74s
```

**通过，零 warning**。

### 4.2 cargo test --workspace --lib

| Crate | 通过 / 失败 / 忽略 |
|---|---|
| `core-storage` | 91 passed / 0 failed / 0 ignored |
| `bridge` | 16 passed / 0 failed / 0 ignored |
| `core-source` | 195（187 passed / 0 failed / 8 ignored）|
| `core-net` | 19 passed / 0 failed / 0 ignored（这就是 user 说的 8 — 实测 19）|
| `core-parser` | 41 passed / 0 failed / 0 ignored |

> User 说基线 91+16+8 — core-storage 91 ✓、bridge 16 ✓ 对得上；"8" 应该是 user 笔误（可能指 core-source 的 8 ignored，或某个子模块）。**全工程 lib 测都过**。

### 4.3 legado_aes 现有 unit test 覆盖

`legado_aes.rs:153-291` 共 7 个 `#[test]`：

| 测试 | 覆盖点 |
|---|---|
| `test_legado_md5_key_empty_password` | MD5("") 已知向量 |
| `test_legado_md5_key_with_password` | MD5("password") 已知向量 |
| `test_encrypt_decrypt_roundtrip` | 1B/16B/100B/1KB 多长度往返 |
| `test_encrypt_decrypt_empty_password` | 空密码往返 |
| `test_decrypt_legado_compatible` | 自洽往返 + 错密码 != 原文 |
| `test_try_decrypt_or_passthrough_handles_plain_array` | 明文 `[...]` 走 passthrough |
| `test_try_decrypt_or_passthrough_decrypts_ciphertext` | 密文走解密分支 |
| `test_pkcs7_padding_boundaries` | padding 边界 0/15/16/17 |

**F-W1A-003 的"乱码"分支（错密码 PKCS7 通过 + UTF-8 通过 + 解出非 JSON Array）目前没有专门测试**。`test_decrypt_legado_compatible` 的"错密码 != 原文"是弱断言，没强制要求"必须 Err"。这正是本批次需要补的测点。

---

## 5. 建议方案

### 推荐：**方案 A**（保守 quick wins，4 项全做但 F-W1A-001 仅做 doc/warn）

**理由**：
1. **F-W1A-001 v2 强加密在当前阶段是空头部署** —— legado_aes 模块还**没接入实际 zip 流水线**（见 §1.1）。在零真实用户密文存量的情况下，先加好"v1 是 weak"的标签 + log warning，等未来真正要做"加密备份"功能时再上 v2。提前做 v2 等于在没有真实使用场景下做 over-engineering，且 Flutter UI 也要联动（增加跨语言 PR 复杂度）。
2. **F-W1A-003 / F-W1A-012 / F-W1A-019 都是定位明确的小重构**：每条 30-80 行，单测易加，**不会破坏现有 91+16+19+41+187 个绿测**。
3. F-W1A-019 性能优化对**实际用户体验有立刻可观察的好处**（章节切换 burst），值得本批一起做。

**方案 A 改动概算**：

| Finding | 改动文件 | 预估行数（含注释/测试）| 备注 |
|---|---|---|---|
| F-W1A-001 doc/warn | `core/core-storage/src/legado_aes.rs`（doc 注释 + `tracing::warn` 在 encrypt/decrypt 入口）| ~30 行 | 同时审查/修订模块顶部 doc 中"已加密"措辞 |
| F-W1A-003 强 JSON 校验 | `core/core-storage/src/legado_aes.rs`（`try_decrypt_or_passthrough_array` 解密分支后追加 parse 校验）| ~40 行（含 2 单测：错密码乱码 / 解出非 Array）| 不动 `decrypt_legado_aes` 本体 |
| F-W1A-012 zip 大小限制 | `core/core-storage/src/backup_dao.rs:194-217` | ~50 行（含 `Read::take` cap + 2 单测：单 entry 超限/总和超限）| 单测可造小 zip + 谎报 size 字段 |
| F-W1A-019 SQL 移出 lock | `core/bridge/src/api.rs:1002-1075` + `ReplaceRulesCache::get_or_load_rules` | ~70 行（含 double-check + 0 新测，跑现有 `cache_concurrency_tests`）| 改 `get_or_load_rules` 为两阶段 API |
| **合计** | 4 个文件 | **~190 行 + 4 单测** | **不新增 Cargo 依赖** |

**风险评估**：
- F-W1A-019 重构有 race condition 风险 → 强烈建议本批次**不破坏现有 generation 隔离测**，并加一条新 stress 测（多线程 cache miss 抢 SQL）
- F-W1A-012 `entry.size()` 攻击者可控 → 一定要同时上 `Read::take` cap，不能只信 size 字段
- F-W1A-003 改 `try_decrypt_or_passthrough_array` 返回错误时，要确认无现有 caller 在做"Err 即视为明文 fallback"的二次兜底（grep 确认目前**外部无 caller**，所以安全）

### 不推荐：方案 B（含 v2 强加密）

理由如上 §5.1。如果产品方明确要"防止 webdav.json 备份被云端误读"，可以拆成 BATCH-09a（A 全做）+ BATCH-09b（v2 强加密 + Flutter UI），分两批走，避免本批 PR 体积过大。

### 不推荐：方案 C（仅 P0 + 简单 P1，跳过 F-W1A-019）

理由：F-W1A-019 是 4 项里**对热路径用户体验影响最大**的（章节切换 burst 时 UI 卡顿），改动量也是中等（~70 行）。延后到 BATCH-13/14 没有明显收益，反而拉长缺陷暴露期。

---

## 6. 输出汇总

1. **legado_aes.rs 公开 API** — `legado_md5_key` / `encrypt_legado_aes` / `decrypt_legado_aes` / `try_decrypt_or_passthrough_array`，目前**外部 caller 为零**（仅本模块单测）。历史 weak 标记**没有**（注释只在 batch12 doc 里说"等价于 Hutool 默认 ECB"），但单测注释里自承"错密码也可能解出看似合法字节流"。`try_decrypt_or_passthrough_array` 完整代码见 §1.3。
2. **backup_dao.rs zip 解压** — `entry.size()` 和 `compressed_size()` 都可用（zip v2 已在 Cargo.toml）。5 张表统一走 `read_to_string` 进 `HashMap<String, String>`，dispatch 顺序：sources → groups → books → bookmarks → replace_rules（事务内）。加大小限制最稳的做法：`entry.size()` 预检 + `Read::take(N+1)` 实读 cap，约 50 行。
3. **apply_replace_rules_impl** — `std::sync::Mutex<ReplaceRulesCache>`（不是 parking_lot）。锁内 SQL：`open_db(db_path) + ReplaceRuleDao::get_enabled()`（SELECT enabled=1 ORDER BY sort_number），但**只在 cache miss 跑**。重构难度：中等，**~70 行**两阶段 API 重构 + double-check，必须保留 `cache_concurrency_tests::unified_cache_keeps_generations_isolated` 不变量。
4. **cargo build/test** — `cargo build --workspace` 5.74s 通过零 warning。`cargo test --workspace --lib` 全绿：core-storage 91 / bridge 16 / core-source 195(187+8 ignored) / core-net 19 / core-parser 41。legado_aes 7 测 cover 往返 + padding 边界，**不 cover F-W1A-003 错密码乱码分支**（本批次需补）。
5. **建议方案 A**（doc/warn for F-W1A-001 + 校验/限制/锁优化 for 其它三条），**~190 行 + 4 单测**，不新增依赖。
6. **本笔记路径**：`/tmp/opencode/batch09-audit.md`

## Caveats / Not Found

- 没找到现有 "weak"/"deprecated" 字样产品级警告 — 模块作者似乎默认 "Legado 兼容" 比 "密码学最佳实践" 优先级高
- legado_aes 模块本身**还未在生产路径接入** — 备份 zip 当前是明文 JSON。这降低了向后兼容压力，但也意味着：本批次改 `try_decrypt_or_passthrough_array` 返回类型不会破坏任何用户存量数据
- 用户提到 "8 测基线" 未对上 — 实测最接近的是 core-source 8 ignored 或 bridge 早期版本测数。当前真实基线 91/16/195/19/41
- F-W1A-019 改动需要新增一条多线程 stress 测（建议）—— 现有 `cache_concurrency_tests` 是用 `Arc<Mutex<Cache>>` 直接构造的单进程伪并发，"SQL 跑期间另一线程拿锁"路径未直接覆盖
