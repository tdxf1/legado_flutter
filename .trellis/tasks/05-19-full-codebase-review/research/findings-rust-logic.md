# Findings — Wave 1B (Rust logic/net/parser tier)

**Scope**: core-source (all) + core-net + core-parser
**Reviewed at**: 2026-05-19
**File count**: 26 (.rs in core-source 16 + core-net 7 + core-parser 6, excluding mod-only)
**Lines reviewed**: ~19,077 (per `wc -l`)

## 统计

### 按严重度
| Severity | Count |
|---|---|
| P0 严重 | 4 |
| P1 主要 | 41 |
| P2 次要 | 20 |
| P3 nice-to-have | 8 |
| **合计** | **73** |

### 按维度
| 维度 | Count |
|---|---|
| A-架构 | 10 |
| B-正确性 | 17 |
| C-性能 | 16 |
| D-安全 | 17 |
| E-代码异味 | 13 |

### 按模块
| 模块 | P0 | P1 | P2 | P3 |
|---|---|---|---|---|
| core-source/parser | 0 | 13 | 3 | 0 |
| core-source/rule_engine | 0 | 0 | 1 | 0 |
| core-source/legado/js_runtime | 4 | 11 | 2 | 1 |
| core-source/legado/url | 0 | 4 | 3 | 0 |
| core-source/legado/rule | 0 | 4 | 3 | 1 |
| core-source/legado/selector | 0 | 0 | 1 | 0 |
| core-source/legado/http | 0 | 1 | 2 | 0 |
| core-source/legado/import | 0 | 2 | 2 | 0 |
| core-source/legado (misc + 跨模块) | 0 | 1 | 1 | 0 |
| core-source/rss | 0 | 1 | 0 | 0 |
| core-source (顶层 lib/utils) | 0 | 1 | 0 | 2 |
| core-net | 0 | 3 | 2 | 3 |
| core-parser | 0 | 0 | 0 | 1 |

---

## Findings

### F-W1B-001 [P0 严重][D-安全][core-source/legado/js_runtime]

**File**: `core/core-source/src/legado/js_runtime.rs:886-998`

**问题**: JS 桥接 `java.ajax/get/post/connect` 没有任何 SSRF 防护，远程书源 JS 可任意访问内网/loopback/元数据服务（169.254.169.254 等）。

**详细**: `java_http_request_blocking` 直接接受 JS 传来的 URL 字符串构造 reqwest 请求，scheme/host 不做白名单校验。配合 `proxy` header 还可让脚本走任意上游代理。在桌面/服务器场景这等同于把宿主网络栈交给陌生书源；移动端则可让恶意书源探测局域网设备。同模块 `java.connect/get` 走相同路径。

**建议**: 默认阻止 RFC1918 / loopback / link-local / 多播地址；做一个可配置 allowlist；URL scheme 限制到 http/https；所有 `java.proxy` 走系统代理或拒绝。

---

### F-W1B-002 [P0 严重][D-安全][core-source/legado/js_runtime]

**File**: `core/core-source/src/legado/js_runtime.rs:1733-1796` `1799-1817` `1820-1906`

**问题**: 文件类 `java.downloadFile / getFile / deleteFile / unzipFile` 通过 `LEGADO_FILE_ROOT` 环境变量决定可写根目录；若该变量未设置则函数静默返回 `""`，但若设置了就把 JS 当作"可信下载器"放权写盘 — 远程书源可在沙箱根下下载任意 URL（含 file://?）并写入用户存储。

**详细**: `resolve_write_path` 仅做路径前缀校验、未对 URL/源加入白名单。结合 F-W1B-001，恶意书源能：1) 下载任意 URL 到 sandbox 根；2) 解压压缩包（虽然有 zip-bomb 上限 50MB），覆盖以前下载的同名文件；3) `deleteFile` 删除 sandbox 内文件。`MAX_ZIP_DOWNLOAD = 50MB` 单文件还偏宽。

**建议**: 默认禁用文件类 bridge；用户级 opt-in（书源可信开关）；下载 URL 校验同 F-W1B-001；缩小 MAX_ZIP_DOWNLOAD/ENTRY 到 10MB/2MB；解压前严格 enclosed_name 校验已有，但建议同时拒绝符号链接条目。

---

### F-W1B-003 [P0 严重][D-安全][core-source/legado/js_runtime]

**File**: `core/core-source/src/legado/js_runtime.rs:301-329`

**问题**: QuickJS 沙箱默认没有内存上限和 stack size 限制，仅 `set_interrupt_handler` 做 wall-clock 超时；恶意 JS 可分配大数组耗尽进程内存或递归触发 stack overflow（取决于 quickjs 默认栈大小）。

**详细**: `Runtime::new()` + `Context::full(&runtime)` 不调用 `runtime.set_memory_limit(...)` 或 `set_max_stack_size`。timeout=5000ms 只能阻止 CPU 燃烧，不能阻止 `new Array(1<<28)` 类内存攻击。Android 上进程被 OOM kill 即等于 DoS。

**建议**: 调 `Runtime::set_memory_limit(64 * 1024 * 1024)` + `set_max_stack_size(1 * 1024 * 1024)`，并把 GC threshold 调小让长期运行的服务也及时释放。

---

### F-W1B-004 [P0 严重][D-安全][core-source/legado/js_runtime]

**File**: `core/core-source/src/legado/js_runtime.rs:1966-1999`

**问题**: `java.queryTtf` 在 input 满足 `len > 100 && !contains('/') && !contains('\\')` 时会先把它当 base64 解码，否则当 URL/文件路径 — 这意味着远程书源可以直接传 URL 让宿主下载任意远程二进制（fonts / payload）然后调用 `ttf_parser::Face::parse` 解析。

**详细**: 这是除 `java.ajax/downloadFile` 之外另一条 SSRF 通道；并且 `Face::parse` 在历史上有过 panic / 崩溃 CVE。如果攻击者投毒书源喂入畸形 ttf 也可能导致 panic（`ttf_parser` 文档承诺 panic-free，但作为外部依赖应假设有意外）。

**建议**: 与 F-W1B-001 共用 SSRF 白名单；并把 Face::parse 包 `catch_unwind`；输入大小封 5MB。

---

### F-W1B-005 [P1 主要][D-安全][core-source/legado/js_runtime]

**File**: `core/core-source/src/legado/js_runtime.rs:1640-1675` `2041-2052`

**问题**: `java.getZipStringContent` / `java.getZipByteArrayContent` / `read_allowed_file` 把 zip entry path 直接传给 `archive.by_name(path)`，没显式拒绝 zip-slip / `..` 路径；`read_allowed_file` 用 `path.trim_start_matches('/')` 拼接后再 canonicalize 校验 starts_with(root)，但漏洞窗口在 canonicalize 前 — 若 fs 上有 symlink，prefix 校验通过仍可读出 root 之外文件。

**详细**: `unzipFile` 已经做了 `enclosed_name` 校验和 `parent_canonical.starts_with(dest_canonical)` 双重校验，但 `getZipStringContent` 单纯 `by_name(path)` 没校验 — 取出 `../../etc/passwd` 这种 entry 的 zip 是合法 zip，archive.by_name 可能返回数据。

**建议**: `getZipStringContent` 在解压前校验 `path.split('/').all(|p| p != ".." && !p.is_empty())`；read_allowed_file 在 join 前显式拒绝绝对路径与 `..`。

---

### F-W1B-006 [P1 主要][D-安全][core-source/legado/js_runtime]

**File**: `core/core-source/src/legado/js_runtime.rs:2081-2265`

**问题**: PREAMBLE 把 `__legado_variables__`（书源里 user-defined 变量）整体绑定到 `java._vars` 然后用 `java.put/get` 暴露，意味着任何 JS 规则都能读到其它阶段的变量内容（包括 cookies / 认证 token），跨规则隔离弱。

**详细**: `book.variable` / `chapter.variable` / shared_variables 在 RuleContext 是 `Arc<Mutex<HashMap>>`（context.rs:39）— 全部 fields 共享，跨字段评估时一个字段写入 `__legado_variables__` 后续字段可见。如果用户同时启用多个书源做并行搜索，Context 不共享但 `LEGADO_JS_VARIABLES` thread_local 在同一线程上的多次 eval 之间也可能泄漏（虽然有 JsVariablesOverride RAII guard，但只覆盖一次 `eval_default_with_http_state`）。

**建议**: 把 `java._vars` 限制成只读（不把 cookie 字段塞进去）；显式列白允许 JS 写入的变量名；shared_variables 改成 per-rule scope。

---

### F-W1B-007 [P1 主要][D-安全][core-source/legado/http]

**File**: `core/core-source/src/legado/http.rs:25-30` `46-52`

**问题**: `LegadoHttpClient` 显式 `https_only(false)`，且没有禁用 redirect 跨 scheme 跳转（http→file? http→localhost?），书源可在 search/toc/content 阶段以 http 发起请求被攻击者中间人重定向到内网 host。

**详细**: ureq 默认 follow_redirects 行为没显式覆盖；`https_only(false)` 表明设计上允许 plain HTTP，但项目针对的中文小说网站很多就是 HTTP。问题在于这一切叠加 F-W1B-001 的 SSRF 缺失就让重定向变成额外的攻击面。

**建议**: 限制最大重定向跳数（如 5）；对每一跳的 host 都做 SSRF 校验；增加配置位允许用户对受信任书源开启 plain HTTP。

---

### F-W1B-008 [P1 主要][D-安全][core-source/legado/url]

**File**: `core/core-source/src/legado/url.rs:185-213` `496-560`

**问题**: `resolve_template_expressions` / `resolve_single_template_rule` 把 `{{...}}` 内容当作 JavaScript 直接 eval；URL 模板由用户/书源 JSON 控制，意味着搜索 keyword 也可被注入到 URL 模板进而进入 JS 执行环境。

**详细**: 例如 source.search_url = `/x?q={{key}}` 时 keyword 仅被 urlencoding 替换 — 安全；但若 source.search_url = `/x?q={{java.encodeURIComponent(key)}}` 这种 JS 表达式由书源作者写死，恶意书源可把 key 拼到 `{{ eval(key) }}` 让 keyword 直接成为 JS 代码（即用户输入的搜索词被当代码运行）。`build_template_vars` 给 JS 注入 `key=keyword`，没做任何转义。

**建议**: 模板表达式只允许预定义白名单（key/keyword/page/encodeKey 等）；扩展表达式（`(page-1)*20`）走简单 expression evaluator 而非完整 JS；如必须保留 JS，则 keyword 注入前做 sanitize（拒绝包含 `;`/`'`/换行的关键词或更安全地改为 base64 → JS 端 decode）。

---

### F-W1B-009 [P1 主要][D-安全][core-source/legado/import]

**File**: `core/core-source/src/legado/import.rs:264-272`

**问题**: `import_legado_source` 直接 `serde_json::from_str` 后无任何字段长度/数量上限校验；攻击者可上传 100MB JSON 数组耗尽内存，或单 source 含 10MB jsLib JS 代码后续每次 eval 都加载。

**详细**: 没有 max_entries / max_field_len。`1778070297.json` 已经包含 100 个书源，是合法用例；但批量导入时一个恶意 JSON 可塞 1M sources 把 SQLite 写挂。

**建议**: 在 import 入口设 max_size（如 5MB）+ max_entries（如 5000）；jsLib 字段单独限长（如 256KB）。

---

### F-W1B-010 [P1 主要][D-安全][core-source/legado/js_runtime]

**File**: `core/core-source/src/legado/js_runtime.rs:980-992`

**问题**: `java_http_request_blocking` 用 `response.take(max_bytes+1).read_to_end(&mut buf)`，在网络速度极慢但持续不超时的情况下，30 秒超时窗口内可下载 10MB 的攻击仍然消费 10MB×N 并发 — 没有总下载并发上限。

**详细**: 同模块没有 Semaphore；恶意书源 jsLib 可在 for 循环里 `java.ajax(slowUrl)` 100 次，并发可能不高但每次 30s 超时 + 10MB 缓冲，足以引起瞬时内存压力。

**建议**: 给 JS bridge 设全局 in-flight Semaphore（如 8 并发）；总并发被卡住的 caller 走 timeout error 而非排队 hang。

---

### F-W1B-011 [P1 主要][B-正确性][core-source/legado/js_runtime]

**File**: `core/core-source/src/legado/js_runtime.rs:303-329`

**问题**: 每次 `eval()` 都 `Runtime::new()` + `Context::full()`，没有任何缓存；这既是性能问题（见 F-W1B-031）也意味着调 `java.put` 写入变量后无法在下一次 eval 看到（除非走 thread_local），thread_local 又只在 `eval_default_with_http_state` 里被 install。

**详细**: 因此 `java.put(key, value)` 在 PREAMBLE 里只写 `this._vars[key] = value`，而 `_vars` 是 `__legado_variables__` 的副本，每次 eval 都是新副本 — 写入完全丢失。Legado 真实书源大量依赖 `java.put('cookie', ...)` 在 search→content 阶段传递状态，本实现这一路基本失效。

**建议**: 让 Runtime/Context 在 BookSourceParser 实例上下文里复用（per-source 池）；或显式把 `java.put` 写到 `LEGADO_JS_VARIABLES` thread_local（write-through），这样下次 eval 还能拿到。

---

### F-W1B-012 [P1 主要][B-正确性][core-source/legado/js_runtime]

**File**: `core/core-source/src/legado/js_runtime.rs:323-326`

**问题**: `format!("JSON.stringify(({}))", expression)` 把脚本结果用 JSON.stringify 序列化，但 `undefined` / `function` 被 JSON.stringify 转成空（或省略），导致脚本 `"return undefined"` 和 `"return ''"` 被 caller 视作同一种"无结果"。

**详细**: 后续 `js_json_to_legado` 在 json == "undefined" 返回 Null（line 483），但 `JSON.stringify(undefined)` 实际返回 `undefined` 字符串 → ok。但 `JSON.stringify(function(){})` 返回 `undefined` 同理 → 函数返回值丢失。Legado 真实规则常 `return [item1, item2]`（数组）—— 这里 OK；但 `result` 是一个有 toString 但非 JSON-safe 的对象时（如 java._wrapElement 返回的 wrapper）会被序列化成空对象 `{}`。

**建议**: 文档化这个限制；或在 PREAMBLE 增加 `result.toString` 兜底；或 wrapper 提供 `toJSON`。

---

### F-W1B-013 [P1 主要][B-正确性][core-source/legado/js_runtime]

**File**: `core/core-source/src/legado/js_runtime.rs:411-419`

**问题**: `js_script_to_expression` 用 `serde_json::to_string(script)` 把含 `var/let/if/for` 的脚本包装成 `eval(...)` 字符串再 `JSON.stringify((eval(...)))`；这样脚本里的 `;return x` 在 eval 内会抛 SyntaxError（return 不能在普通脚本顶层）。

**详细**: 检测 `contains_return_statement` 走 `(function(){...})()` 包装路径 OK，但 `needs_direct_eval` 路径只识别 `; \n var let const if for while try` — 漏了 `function` 关键字声明（顶层 function 可以 eval，但 `(function ...)()` IIFE 已经被 detect_iife 提前判 OK）。组合路径混合时 `var x = ...; return x;` 会先满足 `contains_return_statement` 走 IIFE 路径正确。

**建议**: 整理 wrapper 决策表写到注释里，加单测覆盖各 corner case；或者干脆所有非 IIFE 脚本都包到 IIFE 里，避免分支。

---

### F-W1B-014 [P1 主要][B-正确性][core-source/legado/js_runtime]

**File**: `core/core-source/src/legado/js_runtime.rs:451-478`

**问题**: `legado_value_to_js_expr` 对 `LegadoValue::Map` 用 HashMap 迭代生成 JS 对象字面量，键顺序不稳定 — JS 规则中 `Object.keys(book)[0]` 在不同次 eval 的结果会变。

**详细**: 真实 Legado 规则常 `book.author || book.name` 这类，对顺序不敏感；但若有 `for (var k in obj)` 期望特定顺序则会非确定性。性能上每次都要分配整个对象字面量字符串。

**建议**: 用 BTreeMap 排序后再生成（更稳定 + 单测可重复）；长期用 rquickjs 直接 set object property 而非字符串 eval（更快也更安全）。

---

### F-W1B-015 [P1 主要][B-正确性][core-source/legado/js_runtime]

**File**: `core/core-source/src/legado/js_runtime.rs:2191-2204`

**问题**: PREAMBLE 里 `_resolveUrl` JS 实现的相对 URL 解析与 Rust 端 `crate::utils::build_full_url`（基于 `url::Url::join`）不一致：JS 不处理 `?query` `#fragment` 在 base 中的剥离顺序；JS 不处理 IPv6；JS 处理 `//host/path` 时取 `https:` 兜底而 Rust 取 base scheme。

**详细**: 两个相对 URL 解析器并存，规则里 `element.absUrl(...)` 走 JS 路、Rust 端 `build_full_url` 走 url crate。同一相对路径在两条路径上可能解出不同 URL，下游 cache key 不一致。

**建议**: JS bridge 增加 `__legado_resolve_url` 用 url crate 实现，PREAMBLE 调它；删除 JS 端手写实现。

---

### F-W1B-016 [P1 主要][B-正确性][core-source/legado/js_runtime]

**File**: `core/core-source/src/legado/js_runtime.rs:1574-1585`

**问题**: `java_time_format` 把任何 `<10^9` 或 `>=10^12` 的整数视为毫秒并 `/1000`；当用户传入秒级时间戳 `999_999_999` 就被当作毫秒 → 除以 1000 得到 1000 万秒，与预期相差 30 年。

**详细**: 边界 `1_000_000_000`（约 2001-09-09）和 `1_000_000_000_000`（约 2001-09-09 ms）都是合法时间戳。负数（pre-1970）也被这条 abs() 规则错误压缩。

**建议**: 改成显式格式（毫秒 vs 秒）通过额外参数指定，或用 `>= 10^11` 判定毫秒；记录 Legado 原项目的语义（chrono 默认毫秒）。

---

### F-W1B-017 [P1 主要][B-正确性][core-source/parser]

**File**: `core/core-source/src/parser.rs:1162-1178`

**问题**: `apply_format_js` 对每个章节 eval 两次（line 1866 + line 1887）— 第二次仅为了"提取 g_int 更新值"。这意味着每章触发 2× QuickJS Runtime 创建，1000 章书目录处理 = 2000 次 Runtime 创建。

**详细**: 见 F-W1B-031。逻辑上也不正确：第二次 eval 把整段 format_js 重新跑了一遍（和第一次效果应一致），但若 formatJs 副作用是 `gInt++`，第二次会再 ++ 一次 — gInt 会被错误地 +2 而非 +1。

**建议**: 把 gInt 提取改用闭包封装：`(function(){var gInt=...; var title=(${format_js})(); return [title, gInt];})()` 一次返回两值，避免双跑。

---

### F-W1B-018 [P1 主要][B-正确性][core-source/parser]

**File**: `core/core-source/src/parser.rs:1979-2009`

**问题**: `resolve_image_src_headers` 用 `Regex::new(r#"<img\s+[^>]*src="([^"]*)"[^>]*>"#).unwrap()` 解析 HTML，对 src 属性带单引号或属性顺序奇特的 `<img data-src=".." src="..">` 失效；同时 regex 只在热路径每次重新编译（line 1980 在函数体内）。

**详细**: 双引号被强制；HTML5 允许无引号属性、单引号属性、属性顺序任意。书源返回 `<img alt="" src='/x.jpg'>` 不会被处理，相对图片 src 直接漏修正。

**建议**: 改用 scraper 解析 + 重写 src；或扩展 regex 支持单引号；regex 用 `LazyLock` 缓存。

---

### F-W1B-019 [P1 主要][B-正确性][core-source/parser]

**File**: `core/core-source/src/parser.rs:1538-1542`

**问题**: 章节内容拉到 HTTP 200 但解析为空时，return `Err(ParserError::Empty)`，但 `final_next_chapter_url` 已被赋值 — 用户看到"无内容"错误时，下一章 URL 信息已丢失（内层赋值了 line 1524 但函数早 return）。

**详细**: 不影响数据正确性（Empty 是错误分支），但对 UI 来说"读到一半空章节但下一章 URL 已知"的场景可以"跳过本章继续读下一章"，目前直接挂掉。

**建议**: 若 content empty 但 next_chapter_url 非空，返回 Ok(ChapterContent { content: "[本章无正文]", next_chapter_url, ... }) 让 UI 决定。

---

### F-W1B-020 [P1 主要][B-正确性][core-source/parser]

**File**: `core/core-source/src/parser.rs:1043-1153`

**问题**: 多页目录拉取在子页失败时 `continue`（line 1075），但 `chapter_offset` 已由前面页累加；后续页若顺利返回，章节 index 仍接续，但 seen_urls 已经包含失败 URL 不会重试。同时若失败页是中间页，断开链路意味着丢章节但不报错。

**详细**: 与"first_page failure 报错"形成对照：业务约定是子页失败做 best-effort，但当前没有任何"丢章节告警"机制返回给 caller。在 100 章书的第 50 章拉取超时，用户拿到 90 章静默缺中段。

**建议**: 在 ChapterInfo 的 trailing 加一条 placeholder（"[loading failed]"）或在 Result 中带回 partial flag；至少 warn! 升 ParserError::Empty 的 severity。

---

### F-W1B-021 [P1 主要][B-正确性][core-source/parser]

**File**: `core/core-source/src/parser.rs:1145-1152`

**问题**: 多页 toc 的 `next_urls` 从 `run_rule` 解析后直接 `push_back`，不做去重也不限制队列长度上限；只有 `seen_urls.contains(&full_url)` 防 duplicate，但 url_queue 不去重。

**详细**: 攻击书源若返回 next_toc_url 含 100 个相同的非 base 路径并打乱字符串大小写（`/p/1` vs `/P/1`），canonicalize 后 starts_with(seen) 不一定 dedupe — 队列爆炸到 OOM。MAX_TOC_PAGES = 50 在 seen_urls.len() 上做了上限保护是 OK 的（line 1058-1061），但 url_queue 在被 push 的时候没有上限。

**建议**: 用 `HashSet` 也对 url_queue 内容去重；或在 push 前比对长度限制。

---

### F-W1B-022 [P1 主要][C-性能][core-source/parser]

**File**: `core/core-source/src/parser.rs:1980`

**问题**: `let img_re = regex::Regex::new(r#"..."#).unwrap();` 在 `resolve_image_src_headers` 函数体内，每次调用都重新编译 regex；该函数对每个章节都调用一次。

**详细**: regex compile 是有显著开销的（毫秒级）；100 章书 = 100 次重复编译。应改 LazyLock。

**建议**: `static IMG_RE: LazyLock<Regex> = LazyLock::new(...);` 改造。

---

### F-W1B-023 [P1 主要][C-性能][core-source/legado/js_runtime]

**File**: `core/core-source/src/legado/js_runtime.rs:303-322`

**问题**: 每次 `QuickJsRuntime::eval` 都 `Runtime::new()` → `Context::full()` → 注册 30+ Function bridge → eval PREAMBLE → eval user script — 一次 JS bridge 调用要 4 步重型初始化。Legado 书源典型 100 章解析每章 2 次 eval（content + jsLib）= 200 次重建，bridge register 累计开销远超脚本本身。

**详细**: rquickjs 文档明确推荐 Runtime per-thread 复用。当前每个 spawn_blocking 任务都自己建 runtime，pool 概念缺失。

**建议**: 在 BookSourceParser / RuleEngine 实例上挂一个 `thread_local!` 的 lazy Runtime，每个工作线程一次性初始化。或者 rquickjs Runtime 是 Send，做 Mutex<Runtime> + Vec<Context> pool。

---

### F-W1B-024 [P1 主要][C-性能][core-source/parser]

**File**: `core/core-source/src/parser.rs:1551-1567`

**问题**: `if let Some(ref js_lib) = source.js_lib { let runtime = DefaultJsRuntime::new(); ... }` 每章节都建一个 Runtime 跑 jsLib 后处理。

**详细**: jsLib 存在的书源每章触发一次重型初始化；同 F-W1B-023。

**建议**: 同上，复用 runtime；jsLib 脚本编译结果本身也可 cache（key=书源 ID）。

---

### F-W1B-025 [P1 主要][C-性能][core-source/parser]

**File**: `core/core-source/src/parser.rs:1198-1366`

**问题**: `parse_chapters_from_page` 对每个章节 item 单独调 `extract_from_contexts`（line 1294-1297）和 `is_vip/is_volume/is_pay/update_time` 各 4 个 closure（line 1298-1357）；每条规则在每个 item 上 clone context、push 到 `ctx.result` 后再跑 `run_rule_first`。

**详细**: N 个章节 item × 5 个字段 = 5N 次规则执行；每次 `ctx.clone()` 还会 `Arc::clone` shared_variables。1000 章书 = 5000 次 clone + rule 执行。如果规则是 `@js:`，对应 5000 次 QuickJS Runtime 创建。

**建议**: 对 JS-only 规则做 batch（一次 eval 处理所有 items）；Rust 端规则保持 per-item 但避免 ctx.clone（用 `&mut ctx`）。

---

### F-W1B-026 [P1 主要][C-性能][core-source/legado/url]

**File**: `core/core-source/src/legado/url.rs:185-213`

**问题**: `resolve_template_expressions` 对每个 `{{...}}` 块构建一次 `DefaultJsRuntime::new()`，URL 模板若含 N 个表达式就 N 次 Runtime 创建。

**详细**: line 187 `let runtime = DefaultJsRuntime::new();` 在 captures_iter 之前 — 复用一次，OK。但 `resolve_single_template_rule` (line 546, 555) 又新建 runtime。

**建议**: 把 `runtime` 作为参数传入，函数链路上只建一次。

---

### F-W1B-027 [P1 主要][C-性能][core-source/legado/rule]

**File**: `core/core-source/src/legado/rule.rs:514-523` `593-655`

**问题**: `execute_js_rule` 和 `execute_inline_js_rule` 各自 `js_runtime::DefaultJsRuntime::new()`；`<js>...</js>` 内联场景下若被 N 个 item 触发，每个 item 都 new runtime（line 617）。

**详细**: 同 F-W1B-023/025。

**建议**: 见 F-W1B-023。

---

### F-W1B-028 [P1 主要][C-性能][core-source/parser]

**File**: `core/core-source/src/parser.rs:558-612`

**问题**: `search()` 对每个 item 一行 `extract_from_contexts` 然后聚合 names/authors/covers/book_urls/intros — 若 `book_list` 规则解析出 N items，每条规则都跑了 N 次（5 条规则 = 5N 次）。

**详细**: 实际上 Legado 原版做法是对每个 item 一次性提取所有字段（context 内）— 我们这里是 per-rule × per-item，慢且 cache 不友好。

**建议**: 重构为 per-item 一次性提取所有字段（嵌套循环外层 items 内层 fields）。

---

### F-W1B-029 [P1 主要][C-性能][core-source/legado/rule]

**File**: `core/core-source/src/legado/rule.rs:312-340`

**问题**: `execute_single_css` 每次 `parse_document(html)` 重新构建 DOM，对一个 search 结果页可能调用 5+ 次（name/author/cover/url/intro），同一个 html 解析 5 次。

**详细**: scraper Html::parse_document 占大头时间；对小 HTML 可能不显著但 1MB+ 页 5 次解析很可观。

**建议**: 对同一 html 只 parse 一次，按 RuleEngine 调用周期缓存（per-context cache_key）。

---

### F-W1B-030 [P1 主要][C-性能][core-source/parser]

**File**: `core/core-source/src/parser.rs:29-30` `162`

**问题**: `RATE_LIMITER` 用 `std::sync::Mutex<HashMap>`，每个 search/fetch 都要 lock；高并发场景（多书源同时搜索）会形成全局 contention 瓶颈。

**详细**: 注释 line 22-28 说明了短临界区+release before sleep，但对每个 URL 在 hot path 都 lock 仍是 O(1) 但有竞争。`should_run_sweep_now` 用 atomic 已经分担一部分。

**建议**: 改用 `dashmap` 或者 sharded mutex；单个 source 的连续请求才需要严格同步，跨 source 完全可并行。

---

### F-W1B-031 [P1 主要][C-性能][core-source/legado/js_runtime]

**File**: `core/core-source/src/legado/js_runtime.rs:1924-1953`

**问题**: `font_mappings_json` 把 ttf 的所有 codepoint→glyph 映射序列化为 JSON 字符串再 `JSON.parse` 回 JS — 对常见 CJK 字体 mapping 数千条目，每章节解析一次开销巨大。

**详细**: 调用栈：`java.queryTtf` → 下载/读取 ttf → 全 mapping 转 JSON → JS 端 parse → JS 端遍历调 `replaceFont`。最优实现应直接在 Rust 内一次性 `replaceFont(text, fontUrl1, fontUrl2)` 接口。

**建议**: 增加一个 `__legado_replace_font_with_urls` 接口，全过程在 Rust 内完成，PREAMBLE 包装；保留旧接口兼容旧书源。

---

### F-W1B-032 [P1 主要][A-架构][core-source]

**File**: `core/core-source/src/parser.rs` `core/core-source/src/legado/rule.rs` `core/core-source/src/rule_engine.rs`

**问题**: 项目存在两套并行的规则执行系统：`crate::rule_engine::RuleEngine`（旧，CSS/XPath/JsonPath/Regex/JS）和 `crate::legado::rule::execute_legado_rule`（新，含 JSOUP Default + 组合符 + put/get + inline JS）；BookSourceParser 在 `run_rule` 里"先试新再 fallback 旧"（parser.rs:455-469），覆盖度复杂、行为不易预测。

**详细**: 这是历史演进留下的债。两套都有 CSS / XPath / Regex / JsonPath 实现，几乎是重复代码；但行为细节不同（rule_engine 处理 css_index/css_skip/replace_rules，legado/rule 处理 ## purification/ pseudo）。

**建议**: 单一 source-of-truth：把 rule_engine 的能力合并到 legado/rule，标 deprecated；新增 case 都进 legado/rule；分阶段删除 rule_engine。

---

### F-W1B-033 [P1 主要][A-架构][core-source/legado]

**File**: `core/core-source/src/legado/js_shim.rs`

**问题**: `js_shim.rs` 90 行的 `is_js_rule / js_requires_http / js_uses_clist_api / js_uses_challenge` 等检测函数大多无用 — 只 `is_js_rule` 被引出，其余在仓库里搜不到调用方。

**详细**: 死代码 + 误导（看起来像设计文档但实际未实施）。

**建议**: 删除未引用函数；保留 `is_js_rule` 改放 rule.rs 私有 helper。

---

### F-W1B-034 [P1 主要][A-架构][core-source/legado/import]

**File**: `core/core-source/src/legado/import.rs:594-606`

**问题**: `clean_legado_url` 用 `rsplit_once(',')` 拼字符串特征剥离 URL 选项（`{...}`）；与 `url::extract_json_option`（url.rs:101-142）做相同工作但实现方式完全不同 — import 阶段直接用字符串分割容易误剥离 URL 中合法逗号。

**详细**: import 阶段用 split，运行时阶段用 brace-depth 扫描。两套语义不一致：导入时把 `/x?a=1,2&b=3` 误判成 path = `/x?a=1` + options = `2&b=3`（不解析为 JSON 时回退为 path 全保留 — 走 line 600 检查 `{` 才剥离，OK）；但 URL 模板 + JSON 选项的边界判断行为差异微妙。

**建议**: import.rs 调用 url::parse_legado_url 后取 path 字段；移除手写的 clean_legado_url。

---

### F-W1B-035 [P1 主要][A-架构][core-source/parser]

**File**: `core/core-source/src/parser.rs:1820-1822`

**问题**: `content_rule_field` 是 `source.rule_content.as_ref().and_then(f).filter(|s| !s.trim().is_empty())` 三连组合的 helper；调用点 4 处分散在 parser.rs 不同位置（1425/1426/1427, 1576-1578）。和 `rule_engine.rs::strip_css_modifiers` / `parser.rs::extract_from_contexts` 同样定位为"helper"，但散落各处缺统一组织。

**详细**: 影响可读性；新加 ContentRule 字段时容易漏 helper。

**建议**: 把 ContentRule field 提取的 helper 都搬到 types.rs 作为 ContentRule 方法（如 `image_style_or_default`）。

---

### F-W1B-036 [P1 主要][A-架构][core-source/legado/url]

**File**: `core/core-source/src/legado/url.rs:236-268`

**问题**: `resolve_conditional_page` + `resolve_conditional_placeholder` 处理 `<,{{page}}>` 语法，但只识别第一个 `<...>` 块且实现是 byte 级 find — 对 URL 模板含多个 `<...>` 段（如分两段 page 和 sort）只处理第一个。

**详细**: Legado 原版 `<...>` 可能允许多次出现（虽未在 sy/*.json 见到），实现的 contract 不明确。

**建议**: 加测试明确"仅支持第一处"的契约或扩展支持多处；至少在 doc 注释里注明限制。

---

### F-W1B-037 [P1 主要][A-架构][core-source/parser]

**File**: `core/core-source/src/parser.rs:1899-1923`

**问题**: `execute_chapter_list_js_rule` 与外层 `execute_chapter_list_js_rule_blocking` 名字几乎一致仅 sync/async 区别；对 JS 规则的处理代码存在三个变体：execute_legado_rule_values / execute_legado_rule_with_http_state / execute_chapter_list_js_rule，调用方很容易选错。

**详细**: 调用方语义不清；维护时改一个忘改另一个。

**建议**: 统一入口 `RuleEngineExt::execute(rule, ctx, opts)` 用 builder 选择 mode（async/blocking, with-cookie-jar/without）。

---

### F-W1B-038 [P1 主要][A-架构][core-source/parser]

**File**: `core/core-source/src/parser.rs:1582-1607`

**问题**: `BookSourceParser::run_rule_first_blocking` 通过 `tokio::task::spawn_blocking` 调用 `execute_legado_rule_with_http_state`，但只在 content 路径下用（line 1484）；其它路径（search/toc/book_info）也跑 JS 规则却走非 blocking 路径（rule.rs::execute_legado_rule_values_with_http_state 直接同步），等于在异步 reactor 上跑 5s 阻塞超时。

**详细**: 不一致：content 走 spawn_blocking + 30s 网络超时，其它走主 reactor 5s 默认超时。reactor 上跑同步 JS（含 java.ajax 同步 HTTP）等于 starve 掉同 reactor 上其它 task。

**建议**: 所有 `@js:` 规则统一走 spawn_blocking；rule_engine 的 JS 路径也改成 async wrapper。

---

### F-W1B-039 [P1 主要][A-架构][core-source/rss]

**File**: `core/core-source/src/rss/parse_xml.rs:55-76` `core/core-source/src/rss/mod.rs:87-89`

**问题**: BOM/前置空白剥离逻辑在 mod.rs 和 parse_xml.rs 各写一份（mod.rs:87 仅 `trim_start_matches('\u{FEFF}').trim_start()`，parse_xml.rs:55-76 走完整 prologue 解析）；重复实现易漂移。

**详细**: parse_xml::skip_xml_prologue 处理 `<?xml...?>` 和 `<!--...-->`，mod.rs 简化版不做 — 若 feed 头部有 XML 声明，detect_format 在 mod.rs 里返回 false 走规则路。

**建议**: 公开 `skip_xml_prologue` 给 mod.rs 复用。

---

### F-W1B-040 [P1 主要][B-正确性][core-source/legado/rule]

**File**: `core/core-source/src/legado/rule.rs:283-295`

**问题**: `execute_css_rule` 中 `||` 组合的语义是"取首个非空结果"，但实现里检测 `if !results.is_empty() { break; }`；当某个分支返回空列表 + 错误，会 silently 用空 vec 跳过下一个分支。

**详细**: line 289 `Err(_) => {}` 吞掉错误，line 293 检查非空 break — 若第一个 part 解析报错（panic-protected 走 Err），results 仍为初始空 vec，break 不触发，正常继续；OK。但 Err 没记日志，调试困难。

**建议**: 至少 `warn!` 记录错误；或返回 Vec<Result<...>> 让 caller 区分"全部失败"和"匹配为空"。

---

### F-W1B-041 [P1 主要][B-正确性][core-source/legado/rule]

**File**: `core/core-source/src/legado/rule.rs:80-83`

**问题**: `execute_legado_rule` 在 rule_str 为空时 `return Ok(vec![html.to_string()])` — 对调用方等于"空规则等于把整个 html 作为单值返回"，行为奇怪：若 caller 用此结果做"是否成功匹配"判断会误以为成功。

**详细**: 这是 Legado 的"空规则=透传"语义复刻，但 Rust 端 `execute_rule_part_with_context` 在 combinator 路径会触发 — 用户写 `||` 组合两个规则中间不小心多个 `||` 就出现空 part，然后透传整个 html。

**建议**: 文档化此契约，并在 combinator 解析阶段过滤掉空 parts；或改返回 Vec::new()。

---

### F-W1B-042 [P1 主要][D-安全][core-source/legado/url]

**File**: `core/core-source/src/legado/url.rs:471-495`

**问题**: `resolve_single_brace_jsonpath` 用 `\{(\$[\.\[][^}]*)\}` 匹配 `{$.path}` 但用手动 lookbehind 跳 `{{...}}` — 对嵌套 `{{ {$.x} }}` 模式行为不明确，可能多解析一遍。

**详细**: 不会触发安全问题但对模板解析结果有歧义。

**建议**: 加 unit test 覆盖嵌套场景；或在文档注明边界。

---

### F-W1B-043 [P1 主要][C-性能][core-net]

**File**: `core/core-net/src/cookie.rs:142-163` `206-243`

**问题**: `add_cookie` 在 dedup 时遍历 `inner.raw_cookies` 并对每条都 `Url::parse` + `StoreCookie::parse`；`clear_domain` 用 partition + rebuild CookieStore（line 232-240）— 对每次添加 cookie 都 O(n)，clear 是 O(n²)（rebuild 内部又是 insert）。

**详细**: 多书源同时拉数据，cookie 列表上千条时 add_cookie 显著变慢。

**建议**: 用 `(name, domain, path)` 索引 + dedup；clear_domain 改原地 retain 不 rebuild。

---

### F-W1B-044 [P1 主要][C-性能][core-net]

**File**: `core/core-net/src/cookie.rs:108-117`

**问题**: `save_persistent_cookies` 把整个 store + raw_cookies 序列化为 pretty JSON 写到磁盘；每次保存都全量重写。

**详细**: 数千 cookie 时 O(n) 序列化 + I/O；高频调用（每次 search 后）会 IO 抖动。

**建议**: 用单独的 dirty flag，仅在新 cookie 添加时标记；定时 flush 或退出时统一保存。

---

### F-W1B-045 [P1 主要][D-安全][core-net]

**File**: `core/core-net/src/webdav.rs:65-70`

**问题**: WebDavClient 用 `reqwest::Client::builder().timeout(30s).connect_timeout(10s).build().unwrap_or_else(|_| Client::new())` — 构造失败兜底用默认 Client，超时配置丢失。

**详细**: 通常构造不会失败，但若失败用户用默认 client（无超时）的 WebDAV 操作可能挂住进程；同时 `auth_header` 仍传入但 client 行为变化用户无感。

**建议**: 改 unwrap_or_else 为 expect("WebDAV client must build")；或返回 Result。

---

### F-W1B-046 [P2 次要][D-安全][core-net]

**File**: `core/core-net/src/webdav.rs:191-195`

**问题**: `url_for` 仅 percent-encode 空格和 `#`，其它特殊字符（`?`、`&`、非 ASCII 中文文件名）不处理 — 中文 backup 文件名 PUT 时可能被服务端按 query string 切断。

**详细**: 简单替换不替代标准 URL encoding；URL 路径空格已有 `%20` ASCII 兼容，但 `?` 留下会被 reqwest 视为 query。

**建议**: 用 `url::Url::join` 或 `urlencoding::encode_for_path`。

---

### F-W1B-047 [P2 次要][D-安全][core-net]

**File**: `core/core-net/src/cookie.rs:271-282`

**问题**: `cookie_path` 标 `#[allow(dead_code)]` — 死代码，且实现在 line 270-280 有 commented note 说"留给将来 clear_domain 使用"，但 clear_domain 已经走 effective_domain 路径不需要它。

**建议**: 删除。

---

### F-W1B-048 [P2 次要][C-性能][core-source/legado/url]

**File**: `core/core-source/src/legado/url.rs:309-321`

**问题**: `guess_charset_from_response` 对 `body_bytes[..1024]` 做 `to_lowercase()`，每次 fetch 都对 1KB 字节做 String 分配 + lowercase。

**详细**: 单次开销不大（µs 级）；但每次 HTTP 都跑，多个并发 search 累计可见。

**建议**: 改为 byte 级 case-insensitive find（如使用 memchr 或手写 ASCII 匹配）。

---

### F-W1B-049 [P2 次要][B-正确性][core-source/legado/url]

**File**: `core/core-source/src/legado/url.rs:284-323`

**问题**: 字符集探测仅识别 utf-8/gbk/gb2312/gb18030/big5/shift_jis/euc-kr，其它如 `iso-8859-1`、`windows-1252` 直接退化为 utf-8 — 真实欧文书源可能乱码。

**详细**: 项目主要面向中文，影响范围有限；但 RSS feed 来源更杂。

**建议**: 改用 `encoding_rs::Encoding::for_label` 接受所有合法 IANA 名；只在无 charset 头时走 fallback。

---

### F-W1B-050 [P2 次要][A-架构][core-source/legado/url]

**File**: `core/core-source/src/legado/url.rs:271-281`

**问题**: 模块级 `build_full_url` 与 `crate::utils::build_full_url` 同名同语义；调用方有的用 `legado::url::build_full_url`（path scope），有的用 `crate::utils::build_full_url`（全局工具）。

**详细**: 重复实现增加维护负担。

**建议**: 删除 legado/url.rs 内副本，统一用 crate::utils。

---

### F-W1B-051 [P2 次要][E-代码异味][core-source/parser]

**File**: `core/core-source/src/parser.rs`

**问题**: 文件 3854 行，单 impl block + 大量 free function helper + module-level constants 混合；`BookSourceParser::search` / `get_chapters` / `get_chapter_content` 单方法 100+ 行。

**详细**: 长函数与文件行数令上下文加载困难，新人难以快速 onboard。

**建议**: 拆成 `parser/search.rs`、`parser/toc.rs`、`parser/content.rs`、`parser/rate_limit.rs` 等子模块。

---

### F-W1B-052 [P2 次要][E-代码异味][core-source/legado/js_runtime]

**File**: `core/core-source/src/legado/js_runtime.rs`

**问题**: 文件 3072 行，30+ Rust 函数和 200+ 行 JS PREAMBLE 混在一起；`#[cfg(feature = "js-quickjs")]` 标注成倍重复。

**详细**: 阅读心智负担巨大；条件编译让基础工具（如 hex_to_bytes）也只在 quickjs 下编译。

**建议**: 拆分为：`js_runtime/quickjs.rs`、`js_runtime/bridge_funcs.rs`（base64/md5/aes 等纯函数）、`js_runtime/preamble.rs`（仅 const）、`js_runtime/file_bridge.rs`（path-bound 操作）。

---

### F-W1B-053 [P2 次要][E-代码异味][core-source/legado/selector]

**File**: `core/core-source/src/legado/selector.rs`

**问题**: 文件 1062 行；多个 type 嵌套（LegadoSelectorChain / SelectorSegment / SelectorModifiers / ArrayModifier / ExtractSuffix）但仅 selector.rs 内部使用，外部只暴露 parse_legado_selector + execute_selector_chain。

**详细**: 内部数据结构暴露范围过广（pub 字段），破坏封装。

**建议**: 把内部结构改 pub(crate)；考虑拆 parsing / execution 两个子模块。

---

### F-W1B-054 [P2 次要][E-代码异味][core-source/rule_engine]

**File**: `core/core-source/src/rule_engine.rs:23-32`

**问题**: `RuleType` 是 `#[derive(Default)]` + `Default` 为 Css，但 `default` 概念语义不明 — 没有规则时该返回什么类型？强制默认值会让"未提供规则"和"提供了 css 规则"难以区分。

**详细**: 同时 `RuleExpression::default()` 也存在但相关字段都是空字符串；这种"空 RuleExpression"作为 sentinel 可能在调用链中被错误执行。

**建议**: 删掉 RuleType / RuleExpression 的 Default impl；强制 caller 显式构造。

---

### F-W1B-055 [P2 次要][E-代码异味][core-source/legado/rule]

**File**: `core/core-source/src/legado/rule.rs:259-269`

**问题**: `strip_css_prefix_case_insensitive` 手写大小写比较，eq_ignore_ascii_case 5 字节 prefix；同模块下 `execute_prefixed_rule` 又用 `strip_prefix("@css:")`（区分大小写，line 243 才走 case-insensitive）。

**详细**: 相同前缀剥离逻辑两套；调用顺序保证 case-insensitive 先 strip 但读起来困惑。

**建议**: 统一使用一种 case-insensitive helper；记入 spec。

---

### F-W1B-056 [P2 次要][B-正确性][core-source/legado/rule]

**File**: `core/core-source/src/legado/rule.rs:416-433`

**问题**: `split_css_output` 用 `rsplit_once('@')` 把规则末尾视为输出后缀；当 CSS 选择器本身含 `@` 属性选择器（如 `[type$=author]@content`）时，`@content` 是真后缀但 CSS 内的 `[...$=...]` 可能被误判。

**详细**: 实测示例 `meta[property$=author]@content` — rsplit_once `@` 在 `=author]` 之后第一个 `@`，剥离 → `(meta[property$=author], content)`，OK。但若属性值含 `@` 如 `[data-handle="@xyz"]@text` 会被误剥成 `(meta[data-handle="@xyz"]@text, none)` 或反向。

**建议**: 用 split_by_at_sign（同 selector.rs:193）保护 `[]` 内的 `@`。

---

### F-W1B-057 [P2 次要][C-性能][core-source/legado/rule]

**File**: `core/core-source/src/legado/rule.rs:344-369`

**问题**: `extract_jsoup_pseudos` 用 LazyLock regex，OK；但每次调用都返回新 String + Vec 分配 — 高频规则解析时无 cache。

**详细**: 单次 µs 级，主路径上累计可观。

**建议**: 解析后的 Selector / filter 列表可在 BookSource 维度 cache（key = 规则字符串）。

---

### F-W1B-058 [P2 次要][C-性能][core-source/parser]

**File**: `core/core-source/src/parser.rs:1043-1051`

**问题**: `seen_urls: HashSet<String>` 用 String key，每个 URL 多次 clone（line 1098 build_full_url 后又 clone）。

**详细**: 不影响正确性；URL 长度通常 ≤ 200 字节，影响有限。

**建议**: 用 `Arc<str>` 或保留 hash-only 索引。

---

### F-W1B-059 [P2 次要][D-安全][core-source/legado/http]

**File**: `core/core-source/src/legado/http.rs:13`

**问题**: MAX_RESPONSE_BYTES = 10MB 固定；jsLib / 大型 JSON API 响应可能合法地 > 10MB（章节列表上万条）—— 但同时这也是 attacker 控制的输入面。

**详细**: 当前选择保守值；若书源真有大 toc，会被 silently 切断。

**建议**: 改可配置，提供 per-source override；UI 暴露 warning 当响应被截断。

---

### F-W1B-060 [P2 次要][D-安全][core-source/legado/http]

**File**: `core/core-source/src/legado/http.rs:124-134`

**问题**: `is_valid_header_name` 基于 RFC 7230 token chars 校验，但实现用 `b <= 0x20` 跳过 SP+控制字符，等价于"非可见 ASCII 全拒"；header 含 UTF-8 中文 key 会被全部 silently 跳过。

**详细**: header_pairs 中的中文 key 直接 drop（debug! 提示）；恶意/损坏书源可借此规避 header injection 检测但导致请求实际不带某 header（如反爬虫缺失）。

**建议**: 至少把 skipped headers 用 warn! 而非 debug! 输出，调试时可见；或映射成 X-Original-Name pattern。

---

### F-W1B-061 [P2 次要][B-正确性][core-source/parser]

**File**: `core/core-source/src/parser.rs:1206-1208`

**问题**: 当 chapter_list 规则 None 时返回 ParsedChaptersPage::empty()，外层 `parse_chapters_from_page` 返回空 page，`get_chapters` 累加 0 章节继续翻 next_toc_url；但若 next_toc_url 也 None，整个循环结束，all_chapters 仍空 → ParserError::Empty（line 1190-1194），用户看到"章节列表为空"。

**详细**: 行为正确但歧义：到底是"规则没配"还是"网站返回空"？两种应区分。

**建议**: chapter_list None 时应直接 RuleConfig 错误，不进 multi-page 循环。

---

### F-W1B-062 [P2 次要][B-正确性][core-source/legado/import]

**File**: `core/core-source/src/legado/import.rs:485-519`

**问题**: `split_rule_with_suffix_and_replace` 在 rule 含 `##` 时把 hash_part 全归为后缀，line 504-505 用 `&rule[rule.len() - remaining.len()..]` 切片；当 rule 含多字节 UTF-8 字符时，rule.len() - remaining.len() 落在字符中间会 panic（slice index outside char boundary）。

**详细**: 实际书源规则字段大多 ASCII，但 `replace_regex` 字段可能含中文 replacement → ## 后段含中文 — index 不对会触发 String slice panic。

**建议**: 用 `rule.split_at_checked` 或 `find` 返回 byte offset 后再 slice。

---

### F-W1B-063 [P2 次要][E-代码异味][core-source/legado/import]

**File**: `core/core-source/src/legado/import.rs:374-403`

**问题**: `key_mappings` 是 `&[(&str, &str)]` 硬编码 28 项；新加 BookSource 字段都得来这里同步，容易漏。

**详细**: 没有编译期保障 import.rs 的映射与 types.rs 的 #[serde(rename)] 字段同步。

**建议**: 用 macro 把 #[serde(rename = "xxx")] 自动转成 mapping；或用单测枚举所有 types 字段并断言每个都在 mapping 表中。

---

### F-W1B-064 [P2 次要][A-架构][core-source/legado/(misc)]

**File**: `core/core-source/src/legado/value.rs:163-194`

**问题**: `LegadoValue` Display 实现把 Map 输出成 `{k: v, k2: v2}` 风格但不是 JSON（值内部用 Display 而非 escape），与 `to_json_value()` 不一致；调试时打印的字符串无法 JSON.parse。

**详细**: Display 是为日志友好，但 user-facing 错误消息若包含 LegadoValue 字符串则可能被误以为 JSON。

**建议**: 加注释说明 Display 仅供日志；要 JSON 用 to_json_value()+to_string()。

---

### F-W1B-065 [P3 nice-to-have][E-代码异味][core-source/utils]

**File**: `core/core-source/src/utils.rs:96-100`

**问题**: `clean_html_fragment` 用 `regex::Regex::new(r"\s+").unwrap()` 内联编译；同样可改 LazyLock。

**详细**: 该函数被调多少次未确认；性能影响小。

**建议**: 改 LazyLock 静态。

---

### F-W1B-066 [P3 nice-to-have][E-代码异味][core-source/lib]

**File**: `core/core-source/src/lib.rs:347-361`

**问题**: `validate_rule_expressions` 仅校验 search_url 看起来像 selector 而非 URL 模板，给 warning；其它规则字段（book_url / cover_url）可能也存在类似 selector 误填，未做对称校验。

**详细**: 校验深度不一；用户体验不一致。

**建议**: 把"看似 selector 的字段"校验抽成 helper，对所有 URL-like 字段统一应用。

---

### F-W1B-067 [P3 nice-to-have][E-代码异味][core-source/legado/js_runtime]

**File**: `core/core-source/src/legado/js_runtime.rs:818-820`

**问题**: `java_log` 实现为 `String::new()` — 把书源调用的 `java.log(msg)` 直接吞掉；调试时无法看 JS 端日志。

**详细**: 注释说明刻意忽略，但应至少走 `tracing::debug!`。

**建议**: 改 `tracing::debug!("[js] {}", _msg);` 让日志可控。

---

### F-W1B-068 [P3 nice-to-have][E-代码异味][core-source/legado/rule]

**File**: `core/core-source/src/legado/rule.rs:867-903`

**问题**: `looks_like_xpath_function` 与 `rule_engine.rs::looks_like_xpath_function` (line 482-516) 重复实现，函数列表也几乎相同。

**详细**: 删除重复代码可减小维护成本。

**建议**: 共用一个 const + helper（放 utils.rs）。

---

### F-W1B-069 [P3 nice-to-have][E-代码异味][core-net/proxy]

**File**: `core/core-net/src/proxy.rs:82-83`

**问题**: `from_url` fallback `host = "127.0.0.1"`、`port = 1080` — 当用户传入畸形 URL 时静默换 localhost SOCKS5；可能让用户误以为代理生效。

**详细**: 本应返回 None，目前返回 Some(localhost-SOCKS5) 会让后续 reqwest 尝试连本机不存在的代理。

**建议**: 必须有 host_str 才返回 Some；缺 host 直接返回 None。

---

### F-W1B-070 [P3 nice-to-have][E-代码异味][core-net]

**File**: `core/core-net/src/client.rs:175-181`

**问题**: `Semaphore::acquire().await.expect("Semaphore closed unexpectedly")` 注释说"never closed during HttpClient lifetime"，但若 HttpClient 被 drop 在 await 中，permit 仍可能 panic — 边界情况不友好。

**详细**: 实际触发概率极低；属代码风格层。

**建议**: 改 `?` 转 reqwest::Error 或自定义 NetError。

---

### F-W1B-071 [P3 nice-to-have][E-代码异味][core-parser/cleaner]

**File**: `core/core-parser/src/cleaner.rs:107-117`

**问题**: `clean()` 内 `Regex::new(r"\n\s*\n\s*\n").unwrap()` 与 `Regex::new(r"[ \t]+").unwrap()` 在每次清洗时重新编译。

**详细**: 类似 F-W1B-022。

**建议**: 改 LazyLock。

---

### F-W1B-072 [P3 nice-to-have][C-性能][core-net]

**File**: `core/core-net/src/encoding.rs:22-41`

**问题**: `detect_and_decode` 用 `bytes.windows(3)` 三字节窗口 + 简单计数法判定 GBK；对 1MB 文本扫两遍统计代价 O(n)，不快。

**详细**: 可用 chardet/charset_detector crate 替代，但增加依赖。

**建议**: 接受当前实现；如真有性能瓶颈再换 crate。

---

### F-W1B-073 [P2 次要][D-安全][core-source/legado/js_runtime]

**File**: `core/core-source/src/legado/js_runtime.rs:1466-1551`

**问题**: AES 实现允许 ECB 模式（`/ECB/` 检测，line 1469-1488）；ECB 已知不安全，但因为兼容 Legado 历史规则不能直接禁用。

**详细**: 书源若依赖 AES/ECB 解密 chapter content 会被攻击者用 chosen-plaintext 攻击；属"由用户决定"层面但缺 warn 提醒。

**建议**: 调 ECB 时打 `tracing::warn!("AES/ECB used by source X; consider migrating to AES/CBC")`。

---

## 审查覆盖度自评

### Read carefully (核心审查)
- `core/core-source/src/parser.rs` — 抽样 1-2400 行（剩余 1400 多行是测试用例）
- `core/core-source/src/legado/js_runtime.rs` — 抽样 1-2270 行（剩余 800 行是测试），重点扫 sandbox/bridge
- `core/core-source/src/legado/url.rs` — 全文
- `core/core-source/src/legado/rule.rs` — 全文
- `core/core-source/src/legado/http.rs` — 全文
- `core/core-source/src/legado/import.rs` — 全文
- `core/core-source/src/legado/regex_rule.rs` — 全文
- `core/core-source/src/legado/context.rs` — 全文
- `core/core-source/src/legado/value.rs` — 全文
- `core/core-source/src/legado/js_shim.rs` — 全文
- `core/core-source/src/legado/mod.rs` — 全文
- `core/core-source/src/utils.rs` — 全文
- `core/core-source/src/lib.rs` — 全文
- `core/core-source/src/rule_engine.rs` — 1-600 行（剩余主要是 utility helpers + 测试）
- `core/core-net/src/cookie.rs` — 1-500 行（剩余 200 行测试）
- `core/core-net/src/client.rs` — 全文
- `core/core-net/src/proxy.rs` — 全文
- `core/core-net/src/encoding.rs` — 全文
- `core/core-net/src/retry.rs` — 全文
- `core/core-net/src/downloader.rs` — 全文
- `core/core-parser/src/cleaner.rs` — 全文
- `core/core-parser/src/txt.rs` — 全文

### Skim (浏览未深读)
- `core/core-source/src/legado/selector.rs` — 仅看 type 定义和 parse 入口（1062 行；选择器执行细节未深查）
- `core/core-source/src/types.rs` — 不在本 Wave 重点（数据类型 271 行，多为 serde 字段定义）
- `core/core-source/src/rss/mod.rs` — 路由部分读了；rss/parse_xml.rs 仅读前 100 行；rss/parse_rule.rs 未深读
- `core/core-net/src/webdav.rs` — 前 200 行；后段（auth + tests）跳过
- `core/core-parser/src/epub.rs` — 仅读前 200 行 + rough scan（694 行，未细查 NCX 解析与 OPF 元数据细节）
- `core/core-parser/src/umd.rs` — 前 150 行；后段未深读
- `core/core-parser/src/types.rs` — 未读（小文件）
- `core/core-parser/src/lib.rs` — 未读（28 行 module exports）

### 未完成 / 留给后续 wave
- `core-source/legado/selector.rs` 1062 行没全读完；ArrayModifier 索引解析、execute_selector_chain 各 ExtractSuffix 处理细节未深查（建议 follow-up 子任务专项审）
- `core-source/rss/parse_rule.rs` 226 行未深读；规则路 RSS 解析的边界处理不完整覆盖
- `core-parser/epub.rs` `parse_chapters` / `parse_ncx` 完整实现未审；EPUB 3 properties / svg cover / encrypted opf 等未覆盖
- `core-parser/umd.rs` zlib 解压 + 章节流读取细节未深查；MAX_CHAPTER_SIZE 边界未确认
- `core-source/parser.rs` 2400-3854 行（测试 + 部分 helper）未细看
- `core-source/legado/js_runtime.rs` 2270-3072 行（基本是测试）未审
- 跨模块一致性（例如 cookie 在 LegadoHttpClient 用 `reqwest::cookie::Jar`，但 core-net::HttpClient 用自家 CookieManager 包 `cookie_store::CookieStore`）— 两套 cookie 状态如何同步未触及，建议 Wave 2 跨层一致性检查时关注

总体覆盖：核心安全攻击面（JS sandbox / HTTP bridge / 文件系统接口 / SSRF）read carefully；非核心 parser 模块（epub / umd / rss-rule）以代表性问题为主。
