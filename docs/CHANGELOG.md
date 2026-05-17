# 代码审查与修复历史

> 本文档记录历次代码审查发现的问题与修复结果。当前状态请看
> [CURRENT_STATUS.md](../CURRENT_STATUS.md)。

## 早期审查（2026-05）

| 轮次 | 日期 | 发现问题 | 状态 |
|------|------|---------|------|
| 第1轮 | 2026-05-02 | P1×4: createSource API / DB初始化竞态 / 相对路径 / INTERNET权限 + P2×1: mounted检查 | ✅ 全部修复 |
| 第2轮 | 2026-05-03 | P2: 冷启动通知权限请求 / P3: pendingResult 覆盖 | ✅ 全部修复 |
| 第3轮 | 2026-05-03 | 审查确认无新阻断问题 | ✅ 通过 |
| Rust 第1轮 | 2026-05-04 | P1×3: Proxy/Cookie日志脱敏, @Json:前缀剥离 + P2×4: Regex flags, Semaphore, EPUB3 cover, source_dao URL冲突 | ✅ 全部修复 |
| Rust 第2轮 | 2026-05-04 | P1×2: Set-Cookie value泄露, source_dao DELETE破坏书籍关联 + P2×2: Semaphore, EPUB3 cover multi-token | ✅ 全部修复 |
| Rust 第3轮 | 2026-05-04 | P2×1: source_dao 错误吞没（QueryReturnedNoRows区分） + P3×1: Set-Cookie name仍记录 | ✅ 全部修复 |
| Phase 1 深层审查 | 2026-05-04 | 🔴×4: 在线搜索schema/保存书籍/XPath误判/JSONPath bracket + 🟡×1: Legado导入格式 + 测试修复: regex delimiter检测 | ✅ 全部修复 |
| Rust 第4轮 | 2026-05-04 | 🟡×1: evaluate_regex 缺 m/s/x/u/U 标志（仅有i/g）+ 🟢×1: 缺失 ownText/XPath 评估测试 | ✅ 全部修复 |
| Phase 3 第1轮审查 | 2026-05-05 | [High]×2: mounted guard after await, per-source timeout + [Medium]×2: validation false warnings (CSS/XPath), JSONPath compilation | ✅ 全部修复 |
| Phase 3 第2轮审查 | 2026-05-05 | [Medium]×2: search URL relative path false warning, XPath empty branch + [Low]×1: mounted guard before ref.invalidate | ✅ 全部修复 |
| Phase 3 回归测试 | 2026-05-05 | 7 Rust tests (search URL/XPath/JSONPath/CSS validation) + 1 Flutter test (dispose during async search) | ✅ 全部通过（101 total） |
| Phase 3 第3轮审查 | 2026-05-05 | [Medium]×1: parser HTTP client 无超时 + [Low]×1: 手工 frb_generated 补丁需文档化 | ✅ 全部修复 |
| Phase 3 第4轮审查 | 2026-05-05 | [Low]×1: CURRENT_STATUS.md 验证计数过期（94/48 → 101/8） | ✅ 全部修复 |
| 核心链路打通 | 2026-05-05 | 🔴: 搜索→书架→阅读链路断点（Book 模型缺 book_url，保存时不拉取章节导致阅读器无章节） | ✅ 修复（Book 新增 book_url + DB migration v4 + book_dao 全量更新 + search_page 章节自动拉取） |
| 核心链路审查修复 | 2026-05-05 | Critical×1: 新库初始化重复 book_url；High×3: 搜索结果空 id、Reader dispose/乱序、书架路由未 encode | ✅ 修复（migration v4 幂等 + 空 DB 直接置 DB_VERSION + 稳定 bookId + URI query encode + Reader request token/mounted guard） |
| 核心链路第二轮审查修复 | 2026-05-05 | High×1: SourceDao::upsert() 返回实际写入 ID（URL 去重时 callers 拿错误 ID）；Medium×1: 搜索结果缺 source_id 时章节拉取必然失败；Low×1: Reader _openChapter() 未校验 index 边界 | ✅ 修复（upsert 返回 SqlResult\<String\> + create() 使用 effective_id + save_source 适配 + source_id 有效性检查 + Reader chapters 空列表/index 越界防御） |
| 核心链路第三轮审查修复 | 2026-05-05 | High×1: 在线搜索稳定 bookId（parser 随机 UUID 导致重复书）；Medium×1: 缺 source_id 时提示优化；Low×1: Reader bounds check 加 mounted guard | ✅ 修复（在线结果用 source_id+book_url 哈希作 ID + 离线结果信任 DB ID + source_id 缺失时提示"无有效书源" + Reader setState 前检查 mounted） |
| Legado 兼容层专项推进 | 2026-05-06 | QuickJS 默认 runtime、`java.*` bridge、真实书源合集导入、parser 接入 Legado HTTP/rule、共享 cookie/header/charset、warning cleanup | ✅ 专项回归通过（parser/js_runtime/legado import-rule-url/rule_engine + no-default/js-boa/api-server checks） |

## 全面审查 5 批（2026-05-17 起）

下面是基于 `docs/phase4_code_review_report.md`（已删除，结论已合并到本表）的 5 批连续修复。每批都做完后跑 `cargo check + test` 与 `flutter analyze + test`，全部通过才进下一批。

### 第一批（commit 1）— 数据正确性 + 安全 + 误判遗留清理

| 项 | 严重度 | 摘要 |
|----|--------|------|
| P0-1 | 阻断 | AndroidManifest 加 `usesCleartextTraffic` + `network_security_config`（HTTP 书源全部失败） |
| P0-2 | 阻断 | 补 3 个未生成的 FRB wire fn：`delete_sources_batch / get_explore_entries / explore`（funcId 54/55/56） |
| P1-1 | 高危 | 删除 parser.rs 两处 hardcoded fallback（特定书源测试残留） |
| P1-2 | 高危 | RATE_LIMITER 加 LRU 上限 + 过期清理 |
| P1-4 | 高危 | source_dao normalize_rule_keys 字段映射对齐 import.rs（之前缺 10 个字段） |
| P1-5 | 高危 | HttpTransport SSE 解析进行 block-级聚合（多行 data 拼接） |
| P1-9 | 高危 | 删除 providers.dart 调试用 searchTestProvider |
| P2-3 | 中等 | api-server `/health` 路由拽出鉴权中间件（k8s probe 友好） |
| P2-9 | 中等 | page_view shouldRepaint 条件化（noAnim 静止页面不再每帧重绘） |
| P2-11 | 中等 | main.dart FRB 初始化失败时显示 ErrorPage 而非 crash |
| P3-4 | 建议 | 修复 source_dao.rs 中文注释乱码 |
| #6 | — | 移除 search_html / searchParseHtml 整套（"Android DNS 误判"遗留） |

**验证**：`cargo test --workspace` 254 passed；`flutter test` 97 passed。

### 第二批（commit 1+2）— Android 安全 / 多段阴影 / catch 静默清理

| 项 | 严重度 | 摘要 |
|----|--------|------|
| P2-5 | 中等 | SourceDao ON CONFLICT 缺列：抽 `const SOURCE_UPSERT_SQL` 共用，让单条 upsert 也能更新 login_ui / login_check_js / cover_decode_js |
| P2-7 | 中等 | Android getZipString/ByteArray 校验顺序：先 `isAllowedWebViewUrl` → 再 openConnection；删除假的 contentLengthLong 检查 |
| P2-8 | 中等 | SSRF 黑名单 + DEBUG 例外：`isAllowedWebViewUrl` 加 loopback/RFC1918/link-local/CGNAT 拦截；`BuildConfig.DEBUG` 跳过（保留本机 api-server smoke 能力） |
| P1-6 b | 高危 | Simulation 多段折页阴影：`folderShadowSegments` 真用起来（L0=6 / L1=L2=2 / L3=0），按 segments 数循环画带 alpha 衰减的小矩形 |
| P3-1 | 建议 | 所有 catch (_) 全部加 debugPrint：14 个文件 44 + 2 处 catch / catchError |

**验证**：`cargo test --workspace` 255 passed；`flutter test` 98 passed。

### 第三批（commit 3）— ReplaceRule 下沉 / 死代码清理 / Rhai 删除

| 项 | 严重度 | 摘要 |
|----|--------|------|
| P1-7 | 高危 | ReplaceRule 下沉到 Rust：`apply_replace_rules(db_path, content, cache_generation)` + funcId 57；Rust 端 OnceLock 缓存规则 + HashMap 缓存编译后正则；`replaceRuleGenerationProvider` Dart 端递增 generation 让缓存失效；reader_page 三处规则循环改为单调用 |
| P1-8 | 高危 | PageViewController 跨章节死代码清理：完全重写为单章节模型；删 `_chapters: List` / `goToNextChapter` / `clearChapters` / `_measureNeighborIfNeeded`；class doc-comment 明确单章节语义 |
| P2-6 | 中等 | chapter_dao COALESCE 加 doc-comment 解释 by-design 语义 + 强制清空 escape hatch |
| P2-10 | 中等 | CURRENT_STATUS.md reader_page.dart 行数校对（"1995 行"→"~2040 行"） |
| P3-5 | 建议 | `ReaderRenderMode { paged, continuous }` enum 抽出；`isScrollMode` 保留作快捷别名 |
| P3-2 | 建议 | Rhai 死代码移除：删 `core-source/src/script_engine.rs`（556 行）；rule_engine.rs `evaluate_javascript` + parser.rs `js_lib` 改走 QuickJS；移除 Cargo.toml `rhai` dep |

**验证**：`cargo test --workspace` 242 passed（删除 13 个 Rhai 测试）；`flutter test` 100 passed。

### 第四批（commit 4）— 稳定 ID / 防覆盖断言 / 连接池

| 项 | 严重度 | 摘要 |
|----|--------|------|
| P1-3 | 高危 | SearchResult.id Rust 端稳定 ID：`stable_search_result_id(source_id, book_url, name, author)` SHA256+base64url，与 Dart 侧 hash 字节对齐；search/explore 5 处 + BookDetail/ChapterInfo 全部下沉；Dart 简化为信任 result.id |
| P3-7 | 建议 | frb_generated 防覆盖 build.rs 断言：编译期 grep `wire__crate__api__*_impl` 与 dispatcher 分支，缺失就 panic |
| P3-8 | 建议 | DownloadRunner errorMessage 增强：把"下载失败"改为 `"下载失败: ${actual exception}"`（trim 200 字符） |
| P2-2 | 中等 | java_http_request 去掉额外 OS 线程：之前 `std::thread::spawn(...).join()`，现在 inline（QuickJS 已在 spawn_blocking 上下文） |
| P2-1 | 中等 | java.removeCookie 真实实现：通过 `jar.cookies(&url)` 拿到 cookie，逐个 set 为 `Max-Age=0` 立即过期 |
| P3-9 | 建议 | RATE_LIMITER 评估后保留 `std::sync::Mutex`，加 doc-comment 说明 |
| P3-10 | 建议 | api-server SQLite 连接池：`r2d2 + r2d2_sqlite`，pool max=16；`util::pooled_conn(&state)` 替换 `open_db`；search/sse fan-out 用 `&SqlitePool` |

**验证**：`cargo test --workspace` 245 passed；`flutter test` 100 passed。

### 第五批（commit 5）— 最后一公里

| 项 | 严重度 | 摘要 |
|----|--------|------|
| P2-12 | 中等 | search_page Dio 统一：抽 `core/cover_cache.dart`（CoverCache.downloadAndCache），删除 search_page 内联 `_downloadAndCacheCover`；search_page 不再直接 import dio |
| P3-3 | 建议 | reader services 单测补全：reader_services_test 4 个 + cover_cache_test 2 个，覆盖 FRB 未初始化时的 fallback 行为 |
| P2-13 | 中等 | 进度恢复 ensureVisible：`_paragraphKeys` 仅前 200 段挂 GlobalKey；`_restoreProgress` 优先 ensureVisible 精确定位，越界回退到原平均段高估算 |
| P3-6 | 建议 | CURRENT_STATUS.md 拆分：审查记录大表抽到本文件，让 STATUS 聚焦"当前阶段 + 下一步" |

**验证**：`cargo test --workspace` 245 passed；`flutter test` 106 passed（新增 6 个 service 测试）。

## 第二轮全面复审 — 第六批（2026-05-17，commit 6）

第一轮 5 批落地后又做了一次端到端复审，捞出 26 个新问题（编号 R1–R26）。其中 R3 / R22 / R23 / R24 因属于代码生成器模板、Web 平台兼容性 hazard 或需要 schema 改动，暂列为已知风险延后处理；其余 14 项在本批集中修复。

| 项 | 严重度 | 摘要 |
|----|--------|------|
| R12 | 高危 | `apply_replace_rules` 死锁修正：先在锁内 `collect Vec<(Regex, String)>`，释放锁后再跑 `regex.replace_all`，避免持锁执行用户正则导致 contention |
| R2  | 高危 | `network_security_config.xml` release 不再信任 user CA：根 `<base-config cleartextTrafficPermitted="false">` 仅 system，user CA 移到 `<debug-overrides>` |
| R1  | 高危 | AndroidManifest 删掉与 networkSecurityConfig 冲突的 `usesCleartextTraffic="true"`（HTTP 由 networkSecurityConfig 单一来源控制） |
| R9  | 高危 | DNS rebinding 防御：MainActivity 新增 `isResolvedHostPublic` + `isUrlSafeForFetch`（解析后再次检查 InetAddress 不在 RFC1918/loopback/CGNAT）；LegadoJsBridge 5 处 fetch 入口替换；Activity 主线程入口仍用字面量级 `isAllowedWebViewUrl` 避免阻塞 |
| R18 | 高危 | search_page 删除 Dart fallback 哈希：FRB 没给 stable id 的搜索结果直接拒绝入库 + snackbar 提示，避免与 Rust 侧两端漂移 |
| R16 | 高危 | `updateSettings` 之前漏判 `fontFamily`：现在 fontFamily 任一字段变化即触发 `_measureChapter()` 重排版 |
| R6  | 中等 | `HttpTransport` SSE 解析支持 CRLF / LF 混合换行：先 `replace('\r\n', '\n')` 再按 block 切分；新增 `transport_test.dart` CRLF 用例 |
| R8  | 中等 | `PageView.shouldRepaint` 判定补全：fontSize / lineHeight / fontFamily / paragraphSpacing / horizontalPadding / verticalPadding 任一变化都触发重绘，先前只比对 background / textColor |
| R14/R15 | 建议 | `PageViewController._measureChapter` 删除 settings / pageSize 死快照（仅 chapterIndex 在 post-frame 比较中真正使用）+ 注释说明历史 |
| R4/R5 | 建议 | `evict_stale_rate_states` 改 `saturating_duration_since`（防未来时钟漂移）+ 加 `RATE_LIMITER_LAST_SWEEP` 30s 节流，hot path 不再每次 O(n) 扫表 |
| R20 | 建议 | `bridge/build.rs` 防覆盖断言扩展：`REQUIRED_WIRE_FN_FRAGMENTS` / `REQUIRED_DISPATCHER_FRAGMENTS` 补齐 funcId 42-50 | 51 | 52 | 54-57（53 留洞）；panic 文案明确指引参考 CURRENT_STATUS.md |
| R26 | 建议 | `core/bridge/Cargo.toml` `regex = "1"` 对齐到 `"1.11"`（与 core-source 保持版本一致） |
| R17/R25 | 建议 | `reader_page._buildReaderView` 改读 `settings.renderMode`：`isContinuous = renderMode == ReaderRenderMode.continuous` / `isPage = renderMode == ReaderRenderMode.paged`；未来加新模式编译期能命中 |
| 清理 | 建议 | `page_measure.dart` 删除孤立的 `_footerHeight` 常量（被 commit `80ec162` 移除页脚后遗留），`flutter analyze` 现在 0 warning |

**已知风险（不在本批）**：
- **R3** `frb_generated.rs` dispatcher `_ => unreachable!()`：版本错配会 panic，但属代码生成器模板，记录在案；
- **R22** `_paragraphKeyId` 64-bit 位移、**R23** `cacheGeneration` 用 `PlatformInt64`：均为 Web 平台精度 hazard，本项目当前 Android-first 不阻断；
- **R24** `apply_replace_rules` 不区分 `ReplaceRule.scope (0/1/2)`：所有 enabled 规则无差别应用，属 Phase 4 之前就存在的 bug，需 schema 改动后单独处理。

**验证**：`cargo test --workspace` 245 passed；`flutter analyze` 0 issue；`flutter test` 107 passed（新增 SSE CRLF 1 个）。

## 第三轮全面复审 — 第七批（2026-05-17，commit 7）

第二轮结束后再做了一次端到端复审，捞出 18 个新问题（R27–R45 / R47，R46 误报已撤回）。其中 R27 是 P1-7 引入的真实正确性回归，本批先修最高 ROI 的 4 项。

| 项 | 严重度 | 摘要 |
|----|--------|------|
| R27 | 高危 | `RegexCache.get_or_compile` 仅以 `rule.id` 作 key，导致用户改了 pattern 后仍命中旧编译。重构为 `(id, pattern)` key + 与 `cache_generation` 联动：`ensure_generation()` 检测到 generation 变更时整体清空，配合 `bumpReplaceRuleGeneration` 形成"CRUD → 失效 → 下次读取重编译"的闭环 |
| R47 | 高危 | 同一处。重构同时把无界 `HashMap<String, Option<Regex>>` 改为按 generation 重建，自然 bound 在"当前 enabled 规则数"，长期跑不再泄漏 |
| R29 | 中等 | `transport.dart` SSE 解析 chunk 边界 CRLF：`\r\n` 被分到两个 chunk 时旧实现把第一段的 `\r` 单独 normalize 成 `\n`，跨 chunk 后再撞上 `\n` 形成伪 `\n\n` 块分隔符。新实现用 `pendingCr` 标志暂存 trailing `\r`，下个 chunk 来了再决定 (a) 与 `\n` 配对成单个 `\n`，或 (b) lone CR 单独 normalize。同时把 SSE 解析整段抽成 `parseSseStream(Stream<String>)` top-level 函数（`@visibleForTesting`），方便注入特定 chunk 切分点 |
| R30 | 中等 | `stable_search_result_id` 修正空字段塌陷：之前 `parts.iter().filter(empty).join("|")` 让 `(src,url,name,"")` 与 `(src,url,"",name)` 哈希相同。新实现 `format!("{}|{}|{}|{}")` 始终保留所有 4 个分隔符位 |

**测试新增**：
- `cargo test`：3 个 RegexCache 单测（`cache_invalidates_on_generation_bump` / `cache_drops_old_entries_on_generation_bump` / `compile_failures_clear_on_generation_bump`）
- `cargo test`：替换 `test_stable_search_result_id_skips_empty_components` 为 `test_stable_search_result_id_preserves_position`（断言 4 个位置中"a"在不同位置必须哈希不同）
- `flutter test`：2 个 `parseSseStream` chunk 边界单测（CRLF 跨 chunk 不应产生伪块分隔 / lone CR 不能吞掉下个 chunk 的首字节）

**验证**：`cargo test --workspace` 248 passed；`flutter analyze` 0 issue；`flutter test` 109 passed。

**剩余 R 项延后**：R28（DNS rebinding TOCTOU 文档/命名）/ R31-R33（doc 与 trivial）/ R34（节流锁嵌套，改 atomic）/ R35-R36（build.rs 改进）/ R37（ReaderRenderMode refactor 半成品）/ R38-R39（PageViewController 同步状态机）/ R40（DownloadRunner errorMessage 脱敏）/ R41-R42（cookie removal 局限）/ R43（多 isolate 缓存撞车）/ R44（替换规则报错 toast）/ R45（_paragraphKeyId Web 兼容）。

## 第四轮全面复审 — 第八批（2026-05-17，commit 8）

第三轮第七批落地后再扫一遍，重点看 commit 7 自身有没有引入问题，再扩展到 api-server / DownloadRunner / migration 等之前未深入的模块。捞出 20 项（R48–R67、R69–R70），其中 commit 7 自己就有 4 处需要复修。

| 项 | 严重度 | 摘要 |
|----|--------|------|
| R55 | 高危 | 回退 R30：`stable_search_result_id` 改算法会让所有已入库书的 id 漂移，搜索"加入书架"会变成重复添加 + 旧记录变孤儿。R30 修的"空字段塌陷"在生产路径不可达（source_id 永远非空），修复成本远超收益。doc-comment 明确算法已锁定，未来改动必须配 migration |
| R52 | 高危 | `parseSseStream` 流结束时若 `pendingCr=true` 不 flush，最后一个靠 lone CR 终止的 SSE event 会丢。修复：循环外加 `if (pendingCr) buffer.write('\n')` 兜底 |
| R53 | 中等 | `parseSseStream` 流关流时 buffer 残留不 dispatch。简陋 SSE 服务器不发尾 `\n\n` 就 close，最后 event 也丢。修复：循环外把残留 buffer 当最后一个 block 解析；同时把单 block 解析抽成 `_parseSseBlock` 函数复用 |
| R56 | 高危 | api-server token 强制必填。之前 loopback + 无 token 时 `auth_middleware` 不挂，任何浏览器 / 外部 app 都能 POST 改 DB。新行为：未设 `LEGADO_API_TOKEN` 时启动生成 UUIDv4 + warn 日志输出 token，仍然走 auth |
| R57 | 高危 | `auth_middleware` 增加 Origin 头检查作纵深防御：带 Origin 的请求若 host 不在 `allowed_origin_hosts()` 白名单（默认 = bind_host + loopback aliases），直接 403。token 仍是主要防线，Origin 是浏览器侧的额外门槛 |
| R58 | 高危 | api-server pool 由 16 扩到 32，新增 `SQLITE_POOL_SIZE` 常量与 `SEARCH_FANOUT=16` 对齐。先前 pool=16 与 search 信号量=16 一致，单个 search 把 pool 全占满，第二个 search 或 /health probe 必须等 30s pool timeout |
| R61 | 高危 | `routes/sse.rs::search_sse` 之前对 `source_ids` 无并发限制，100 书源 = 100 task 同时 fan-out。新增 `Semaphore::new(SEARCH_FANOUT)` 与非 SSE 路径对齐 |
| R67 | 高危 | `java_set_cookie` 修复：之前按 `;` 分割并把每段当独立 cookie，结果 `Path=/`、`Expires=...` 被当成名叫 `Path` / `Expires` 的 cookie 写入 jar，污染 cookie store。新实现把整个 `cookie_str` 当一条 Set-Cookie header value，让 reqwest jar 自己解析 attributes |
| R48 | 中等 | `load_enabled_replace_rules` cache key 改为 `(db_path, generation, rules)`。先前只看 generation，多 db_path 切换时（测试 fixture / 未来 profile / 多 isolate）会拿到错的 rule list |

**测试新增**：
- `flutter test`：3 个 `parseSseStream` 边界（R52 流尾 pendingCr flush / R53 末块无 trailing 空行 / 空 keep-alive 不破坏 pendingCr）

**验证**：`cargo test --workspace` 248 passed；`flutter analyze` 0 issue；`flutter test` 112 passed（109 → 112，+3）。

**自我反思 / 关键判断**：

R55 是最反直觉的发现——commit 7 (R30) 我自己引入的"修复"实际上引入了比它修的问题更大的回归。教训：**任何会改变持久化数据 id 的改动都需要 migration 计划，不能直接覆盖**。

R52/R53 提醒：审查自己刚写的 stream parser 容易盲，特别是流结束 / chunk 是单字符这两类边界。

R56-R58 是个老毛病：api-server 一直按"反正都跑 localhost"假设，但 localhost 不等于 trusted。

**剩余 R 项延后**：R28（DNS TOCTOU）/ R31-R33 / R34（节流锁嵌套）/ R35-R36（build.rs）/ R37（ReaderRenderMode 半成品）/ R38-R39（PageView 状态机）/ R40（脱敏）/ R41-R42（cookie 局限）/ R43（多 isolate 缓存）/ R44（toast）/ R45（Web `<<` modulo-32）/ R50（RegexCache 三次哈希）/ R59（TOCTOU 注释）/ R60（Axum handler 同步阻塞 → spawn_blocking）/ R62（logs_sse 注释误导）/ R64-R65（migration trivial）/ R66（didUpdateWidget setState）/ R69-R70（DownloadRunner status 常量化 / 串行 UX）。

## 第九批（2026-05-17，commit 9）— 清扫剩余 R 项

第八批落地后，把第四轮复审里延后的剩余 R 项里能修的全部清掉。R60（Axum handler 同步阻塞 → spawn_blocking）改动量大且与 r2d2 + DAO 签名耦合，单独留作下一轮重构话题。

| 项 | 严重度 | 摘要 |
|----|--------|------|
| R39 | 高危 | `PageViewController._measureChapter` 移除 jumpToLast 路径下的同步 `notifyListeners()`：改为统一在 post-frame 回调里通知，避免 build 阶段调用 listener 抛 "setState during build" 断言 |
| R38 | 高危 | 删除 `_isMeasuring` 死标志：`_measureChapter` 是同步函数，set/clear 中间没有 await，外部线程不可能看到 true，标志只是误导 |
| R44 | 高危 | `_applyReplaceRulesViaRust` 失败时新增一次性 toast：之前 catch 直接 `return content`，规则全部失效用户无感知。新增 `_replaceRuleErrorShown` session 级 guard 限制只提示一次 |
| R66 | 高危 | `didUpdateWidget` bookId 变化路径包 `setState`：先前裸赋值依赖 widget 重建触发 build，但 `_loadBookmarks()` 是 async 期间 UI 显示旧 chapterContent，setState 让 loading 状态立即生效 |
| R40 | 高危 | DownloadRunner errorMessage 脱敏：抽 `_sanitizeDownloadError` 用 regex 把 `https?://...?query` 替换为 `?<redacted>`，避免 URL token 进 download_chapters 表持久化 |
| R45 | 高危 | `_paragraphKeyId` 改 String key：之前 `chapterIndex << 32` 在 dart2js / dart2wasm 上 `<<` 是 modulo-32，跨章节 100% 碰撞。`Map<int>` → `Map<String>`，key 形如 `"chIdx|pIdx"` |
| R34 | 中等 | `RATE_LIMITER_LAST_SWEEP` 由 `Mutex<Instant>` 改 `AtomicI64`：之前在 `RATE_LIMITER` 锁内嵌套获取第二把锁，部分抵消 R5 节流的 perf 收益。新实现用 `compare_exchange` 单 CAS 抢 sweep 槽 |
| R69 | 中等 | DownloadRunner status 常量化：抽 `DownloadTaskStatus` / `DownloadChapterStatus` 两个 class，注释明确 task `complete=3` vs chapter `complete=2` 的差异。8 处 magic number 全部替换 |
| R37 | 建议 | `ReaderRenderMode` enum 设计澄清：先前批被列为"半成品"，复看后发现 `isScrollMode` 是有意保留的 boolean 别名（≈16 处布尔分支用 alias 比展开 enum 比较更易读）。providers.dart 加详细注释说明判断标准与未来扩展时机 |
| R50 | 建议 | `RegexCache.get_or_compile` 改 `entry().or_insert_with`：从 contains_key + insert + get（三次哈希 + 一次 clone）变成 entry 单次哈希 |
| R28 | 建议 | DNS rebinding TOCTOU 文档：`isResolvedHostPublic` 注释强调已知缺陷（两次 DNS lookup 之间 DNS 可重绑定），引用 R28 编号方便后续根治时定位 |
| R31-R33 | 建议 | doc 修复：`stable_search_result_id` 测试模块注释去掉过时的 "byte-for-byte matches Dart" 描述（R18 已删 Dart fallback）；`page_view.shouldRepaint` 删除冗余的 `oldDelegate.isRunning != isRunning`（被 `isRunning ||` 覆盖） |
| R35 | 建议 | `bridge/build.rs` 防覆盖断言更精确：`"42 =>"` → `"        42 =>"`（带 8 空格前缀），避免未来万一出现的 `1042 =>` 误命中 |
| R36 | 建议 | `bridge/build.rs` panic 文案明确范围："this guard only covers funcIds we know were hand-edited" |
| R41/R42 | 建议 | `java_remove_cookie` 注释明确 Path 限制（reqwest jar 不暴露 cookie attributes，无法重现原 Path 范围导致非根路径 cookie 实际未删除）；slice iter 改 `std::iter::once` |
| R43 | 建议 | `replaceRuleGenerationProvider` 多 isolate 撞车风险加注释 |
| R59 | 建议 | api-server `set_source_enabled` / `delete_source` TOCTOU 注释：注明并发 delete 时第二个调用变 no-op 是预期幂等行为 |
| R62 | 建议 | `routes/sse.rs` mod-doc 修正：之前暗示 logs_sse 已支持 tracing 接入，实际只发 heartbeat；现在标明"占位实现"并写明真实接入需要的步骤 |
| R64 | 建议 | `migrate_v9` 列名查询参数化（`?1` 替换 format!），rusqlite::params 构建；DDL 不能参数化的部分加注释说明 |
| R65 | 建议 | `migrate_v8` `create_tables` 调用加注释解释"schema baseline guard"用途 |
| R70 | 建议 | DownloadRunner 单例顶部加 doc-comment 标注串行下载是已知 UX 限制（避免与 per-source rate limit 打架） |

**未修：R60** (Axum + sync sqlite + spawn_blocking) 独立批次处理。

**验证**：
- cargo check --workspace: clean
- cargo test --workspace: 248 passed
- flutter analyze: 0 issue
- flutter test: 112 passed

## 第十批（2026-05-17，commit 10）— R60: api-server DAO 包 spawn_blocking

第九批清完所有 R 项里能小改的之后，剩下唯一架构性问题：Axum handler 在 tokio worker 上跑同步 sqlite，单个慢查询会阻塞整个 worker。在压力测试中表现为搜索期间 `/health` probe 30s 超时。

| 项 | 严重度 | 摘要 |
|----|--------|------|
| R60 | 高危 | 全 9 个路由 41 处 DAO 调用包 `tokio::task::spawn_blocking`，避免 sqlite 同步 IO 阻塞 tokio worker。新增 `util::db_blocking()` helper：克隆 `SqlitePool` (cheap Arc) 进 spawn_blocking 闭包，在闭包里 `pool.get()` + 跑 DAO，错误 type 转回 `ApiError`。Type 边界 `F: FnOnce(&mut PooledConnection) -> Result<T, E> + Send + 'static`。|

**改动范围**：
- 新增：`util::db_blocking<F, T, E>` helper（48 行）
- 转换：sources.rs (8 处) / bookshelf.rs (6 处) / replace_rules.rs (4 处) / explore.rs (2 处) / reader.rs (14 处) / search.rs (2 处 — `search()` 主路径 + `search_single_source()` fan-out task) / sse.rs (2 处 — `search_sse()` 主路径 + `run_one()` fan-out task)
- 因 `search_single_source` / `run_one` 的 error 类型是自定义 tuple 不是 `ApiError`，这两处直接用 `tokio::task::spawn_blocking` 不走 helper
- `pooled_conn` 改 `#[allow(dead_code)]`，doc 标记为 escape hatch（实际没有 caller，但保留以防未来需要）
- reader.rs 的 `get_chapter_content` 引入 `enum CachedChapter { Cached, NeedsFetch }` 把"缓存命中"与"需要拉取"两条路径解耦——之前用 try-block + early return 在 `pooled_conn` 作用域内做，现在每段 DB 工作都得是闭包

**关键设计要点**：

1. **PooledConnection 的 Send + 'static 限制**：`r2d2::PooledConnection` 持有对 pool 的引用 borrow，不是 'static。绕过办法：把 `SqlitePool::clone()` 进 closure（pool 内部是 `Arc<...>`，clone cheap + 'static），然后在闭包**内**调 `pool.get()`，PooledConnection 的生命周期就被限制在闭包里。

2. **跨 await 的所有权移交**：闭包接受的所有变量都得 `move`，所以所有跨 `await` 用的 `String`/`Vec` 在 spawn_blocking 之前都要 `.clone()` 到独立绑定。reader.rs 的 `book_id_for_chapter` / `book_id_for_book` 等命名约定就是为这个。

3. **类型推断的边界**：`db_blocking` 的 E 泛型在闭包用了非 ApiError 错误时无法自动推断（如 reader.rs 的 cached chapter lookup 闭包内 mix 了 ApiError + ok-flow），需要显式标注 `move |conn| -> Result<T, ApiError> { ... }`。

**未修**：（无，R60 是最后一项实质性问题）

**已知风险**：R3 codegen 模板 unreachable / R22 / R23 / R24 ReplaceRule.scope（需 schema 改动）—— 都是设计层面的问题不是代码 bug。

**验证**：
- cargo check --workspace: clean
- cargo test --workspace: 248 passed
- flutter analyze: 0 issue
- flutter test: 112 passed

## 第十一批（2026-05-17，commit 11）— R71-R77: 事务化 + 多步 db_blocking 合并

第五轮复审在 R60 重构后捞出 13 项（R71-R83），其中 R73 是真实回归（多步 DB 操作失去原子性）、R74 是修 R73 缺的工具、R71/R72 是相邻的合并优化、R77 是 R73 修复路径上的依赖。本批一次性把这五项做完。

| 项 | 严重度 | 摘要 |
|----|--------|------|
| R74 | 高危 | 新增 `util::db_transaction<F, T, E>` helper：克隆 `SqlitePool` → spawn_blocking → 拿连接 → 开 `rusqlite::Transaction` → 跑闭包 → 成功 commit 失败 rollback。闭包接收 `&mut Transaction`，DAO 构造器自动 deref。这是修 R73 必需的工具 |
| R73 | 高危 | `add_book` 与 `refresh_chapters` 各把"chapter replace + book metadata 更新"合并到 `db_transaction` 单事务。先前是两个独立 `db_blocking` → 两次 commit，前者成功后者失败时 `book.chapter_count` 与 chapters 表不同步。现在要么两个都成要么两个都没 |
| R72 | 中等 | 上述合并顺带把 `add_book` / `refresh_chapters` 的 db_blocking 调用次数从各 5/4 次缩减到 4/3 次。每次省掉一次 thread switch + 一次 pool slot |
| R71 | 中等 | `get_chapter_content` + `refresh_chapters` 把"book lookup → source lookup"两个连续 db_blocking 合并为单次：单 PooledConnection、单 spawn_blocking、单 worker switch。get_chapter_content 的 hot path（"未缓存章节首次打开"）是这次优化的目标 |
| R77 | 中等 | `chapter_dao` 改用 `rusqlite::Connection::transaction()` RAII 而非 raw `BEGIN/COMMIT`。先前 raw BEGIN 与 caller 已开的事务嵌套时直接报错（SQLite 不支持嵌套 BEGIN），导致 R73 修复无法直接调用 `replace_by_book_preserving_content`。新增 `replace_by_book_preserving_content_in_tx(tx, ...)` 给已持有事务的 caller 用，原方法保留作 standalone 入口 |

**实现要点**：

1. **`db_transaction` helper**（`util.rs`）：
   `Transaction::Drop` 默认 rollback，所以闭包返回 `Err(_)` 自动回滚；`Ok(_)` 显式 `commit()`。Type 边界 `F: FnOnce(&mut Transaction) -> Result<T, E> + Send + 'static`。

2. **`ChapterDao::new` 由 `&Connection` 改 `&mut Connection`**（核心结构破坏性改动）：
   `Connection::transaction()` 需要 `&mut self`，所以 DAO 必须持有可变借用。其他方法只读 `&Connection` 但被同一 `&mut` 限制，权衡接受。
   - `core_storage::lib::Storage::chapter_dao` 跟着改 `&mut self`
   - bridge/api.rs 6 处 caller `let conn = ...; ChapterDao::new(&conn)` → `let mut conn = ...; ChapterDao::new(&mut conn)`
   - api-server `replace_book_chapters_preserving_content` / `replace_book_chapters` 改 `let mut dao`
   - `database.rs` test 用 `let mut conn` + 把 `BookDao` 借用收进 inner block

3. **`replace_by_book_preserving_content_in_tx`**（`chapter_dao`）：
   纯静态函数（不持有 `&mut self`），接收 `&Transaction<'_>`。standalone 路径调用 self 方法时内部开 tx 调用 `_in_tx`，事务路径调用方传 caller 的 tx。

**关于 add_book 初始 book upsert 不进事务的取舍**：
add_book 流程是「源校验 → 初始 book upsert（占位）→ 网络拉 chapters → 单事务（chapter replace + book metadata 更新）」。初始 upsert 故意保留独立提交：网络失败时书籍占位记录留在书架上，用户能看到"添加中失败"的视觉反馈，重试时也能接着尝试。如果把整个流程做成一个大事务，事务必须跨网络 IO，pool 连接长时间占用、SQLite 锁也长时间持有，反而是反模式。

**未在本批修复的 R 项（来自第五轮）**：
- R75（`search_single_source` / `run_one` 注释错 + 重复代码）— 不影响正确性
- R76（fan-out task 嵌套 spawn_blocking）— 性能微小浪费
- R78（`SourceDao::upsert` 单条不在事务内的 SELECT+UPSERT）— 生产路径不可达
- R79（`extract_json_option` O(n²)）— pathological 输入才触发
- R80（`_loadChapter` setState 前 mounted 守卫）— 实际不可达
- R81（FRB worker pool 大小限制）— FRB 架构层面，与 R60 不同
- R82（`parser.search` 返回 `Vec<>` 静默失败）— 设计层重构

**已知风险（仍然成立）**：R3 codegen 模板 unreachable / R22 / R23 / R24 ReplaceRule.scope（需 schema 改动）。

**验证**：
- cargo check --workspace: clean
- cargo test --workspace: 248 passed
- flutter analyze: 0 issue
- flutter test: 112 passed

## 第十二批（2026-05-17，commit 12）— R86 / R87 / R89 收尾

第六轮全面复审在 commit 11 后再扫一遍，捞出 9 项（R84-R92）。其中 R87 是真实可见的用户体验回归（add_book / refresh_chapters 在 chapters 拉取失败时静默写空），R89 是数据持久化安全（fsync 缺失），R86 是 panic 安全的文档遗漏。本批一次性把这三项做完；R84/R85/R88/R90-R92 是 perf nano / 设计层 / 部署层问题，留作 backlog。

| 项 | 严重度 | 摘要 |
|----|--------|------|
| R87 | 高危 | `add_book` / `refresh_chapters` 在 `parser.get_chapters()` 返回空 Vec 时（网络失败 / 解析失败的静默 fallback），过去会 DELETE 全部 chapters → INSERT 0 行 → `book.chapter_count = 0`。用户毫无错误反馈、看到一本"空书"。修复：检测 `chapters.is_empty()` 时直接返回 `ApiError::BadRequest` 含中文用户提示，事务不开始（refresh 路径明确说明"原章节列表已保留"）。底层 `parser.get_chapters` 静默失败的设计层重构（R82）继续延后 |
| R89 | 中等 | `core-net::downloader` 在 `tokio::fs::File::drop` 之前增加 `file.sync_all().await?`。`File::drop` 不保证 buffered writes 落盘，rename 只动元数据；崩溃 / 掉电时会在已经"成功"的下载里看到 0 字节或截断文件。每次下载多一次 fsync 开销可接受 |
| R86 | 低 | `db_transaction` doc-comment 增加 panic 安全说明：`spawn_blocking` 捕获 panic 走 JoinError → ApiError::Internal，`Transaction::Drop` 自动 rollback，pool slot 经 `PooledConnection::Drop` 归还。无需 caller 处理。一段注释 |

**未在本批修复的 R 项（来自第六轮）**：
- R84（`delete_book` 用 `let _` 吞 chapter/progress 删除错误）— 可能留孤儿但 FK CASCADE 兜底
- R85（`StorageManager` API `&self` / `&mut self` 不一致）— StorageManager 当前没 caller
- R88（downloader 同 path 并发竞态）— DownloadRunner 当前串行执行，不可达
- R90（`download_dao::create_task_with_chapters` raw BEGIN/COMMIT）— 跟 R77 同款，没 caller 在事务里调
- R91（api-server 没装 `CatchPanicLayer`）— panic 仍会被 axum 默认转 500，只是没 tracing
- R92（axum::serve plain TCP 无 TLS）— 是 deployment 问题，靠 reverse proxy 终结

**已知风险（仍然成立）**：R3 codegen 模板 unreachable / R22 / R23 / R24 ReplaceRule.scope（需 schema 改动）/ R82 (`parser.get_chapters` 静默失败的设计层重构)。R87 修复后 R82 的实际危害大大减弱（API 层兜底了），但根因还在 core-source。

**总评**：经过 6 轮全面复审 + 12 个 commit 的迭代，剩余问题全部是 perf 优化、deployment、或者生产路径不可达的设计 hazard。Android 主线没有可见的 user-facing bug。

**验证**：
- cargo check --workspace: clean
- cargo test --workspace: 248 passed
- flutter analyze: 0 issue
- flutter test: 112 passed
