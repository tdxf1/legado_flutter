# R123 — REGEX_CACHE 与 rule list cache 锁原子化

## 背景

第十一轮全面复审捞出 R123：`apply_replace_rules_impl` 内部用了两个独立 mutex 保护两个相关缓存：

1. `load_enabled_replace_rules` 内的 `CACHE` (rule list, `Mutex<Option<(String, i64, Arc<Vec<ReplaceRule>>)>>`)
2. `REGEX_CACHE` (compiled regex, `Mutex<RegexCache>`)

两者通过 `cache_generation` 关联，但**写入时序不原子**。两个并发 caller（不同 generation）race 时：

- T1 写 rule cache (gen=1) → 进 REGEX_CACHE 锁前被 T2 抢先
- T2 写 rule cache (gen=2) → 进 REGEX_CACHE → ensure_generation(2) → 装 V2 regex
- T1 进 REGEX_CACHE → ensure_generation(1) → 把 T2 的 V2 cache **clear** 掉，重装 V1
- T2 下次再用以为 cache 是 V2，实际被 T1 重置成 V1

**真实危害**：
- reader 串行调用不会 race（每章一次，generation 在调用之间稳定）
- 但 download isolate 并发 + 用户恰好 bump generation 时窗口存在
- 表现：用户改了规则后，下载 isolate 内某章应用的是旧规则，下次再调又应用新规则

## 目标

让"读 rule list cache + 编译 regex"这一对操作在并发下保持 generation 一致性。即：同一次 `apply_replace_rules_impl` 调用拿到的 (rules, regexes) 必须属于同一 generation。

## 实现策略

### 方案 A：单锁守一切（推荐）

合并两个 cache 为单一 `OnceLock<Mutex<ReplaceRulesCache>>`，结构：

```rust
struct ReplaceRulesCache {
    /// (db_path, generation) 为 key 的 rule list 缓存。
    rule_list: Option<(String, i64, Arc<Vec<ReplaceRule>>)>,
    /// 当前 generation 的 compiled regex 缓存。generation 切换时清空。
    regex_generation: Option<i64>,
    regex_entries: HashMap<(String, String), Option<Regex>>,
}
```

`apply_replace_rules_impl` 工作流：

```rust
let cache = REPLACE_RULES_CACHE.get_or_init(...).lock()?;
// 1. 加载 / 复用 rule list（同一锁内）
let rules = cache.load_or_get(db_path, generation, || dao.get_enabled())?;
// 2. 同步 regex_generation
cache.ensure_regex_generation(generation);
// 3. 编译并收集 (Regex, replacement) 对
let compiled: Vec<_> = filter_by_scope_and_compile(&rules, &mut cache, ...);
// 4. 释放锁，跑 replace_all（不持锁）
drop(cache);
let mut out = content.to_string();
for (re, rep) in compiled { out = re.replace_all(&out, rep.as_str()).into_owned(); }
```

关键不变量：rule list cache 的 generation 与 regex cache 的 generation 始终在同一锁的临界区内同步推进，外部观察永远一致。

### 方案 B：保留两锁但加 CAS

保留分离的两个 mutex，把 `RegexCache.generation` 改成 atomic，`ensure_generation` 用 compare_exchange，只有"我看到的 generation 比当前 cache 旧"才 clear。复杂得多，正确性论证麻烦。

**选 A**：合并锁。`replace_all` 在锁外跑（regex 是 Arc 内部，clone cheap），不会持锁跨用户正则的执行——保留 R12 的 perf 修复。

## 实现要点

1. 删除独立的 `load_enabled_replace_rules` 与 `REGEX_CACHE` static + 函数
2. 新增 `ReplaceRulesCache` struct 包含 rule_list + regex_generation + regex_entries 三件套
3. 新增 `static REPLACE_RULES_CACHE: OnceLock<Mutex<ReplaceRulesCache>>`
4. 重写 `apply_replace_rules_impl`：单锁 → 加载/复用 rules + ensure regex generation + filter + 编译 + clone regexes → 释放锁 → 跑 replace_all
5. 现有 8 个 scope filter 单测 + 3 个 RegexCache 单测必须仍然通过
6. 新增并发回归单测：模拟两个 thread 用不同 generation 调 `apply_replace_rules_impl` 各 100 次（用 in-memory db），断言每个调用拿到的输出与该 generation 下的 ground truth 一致

## 验收标准

- cargo check --workspace: clean
- cargo test --workspace: 至少 259 passed + 1 个并发回归单测
- flutter analyze / test：无变化（259 + 112）
- 手动 trace：合并锁后 download isolate 并发场景（参见 prd 背景）数据流不会出现"caller 拿到错 generation 的 regex"

## 不在范围

- R120 (TextEditingController dispose)：分到下一批 UI 收尾
- R115/R116 (R105 backfill 注释/UX)：同上
- R117-R119/R121/R122/R124：trivial 或 nano，留 backlog
