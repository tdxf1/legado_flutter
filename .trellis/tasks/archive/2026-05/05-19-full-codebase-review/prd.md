# Flutter + Rust 全量代码审查与修复

## Goal

对仓库现有 ~6.4 万行代码（Rust core ~3.96 万 / Flutter app ~2.44 万）做一次系统化纵览审查，从 5 个维度（架构/正确性/性能/安全/代码异味）合并出一份"问题清单 + 修复优先级"报告。本任务只产出报告，**不修改业务代码**；后续修复由用户挑选条目，再以子任务（`task.py create --parent`）方式分批推进。

## Why

- 项目已经从批次 1 推进到批次 21（~60 个历史任务），各批次以纵向特性切片为主，跨模块的横向一致性、技术债从未集中复盘
- Rust core 与 Flutter app 之间走 FRB(flutter_rust_bridge)，FFI 边界、错误传播约定、数据类型映射的一致性需要专项体检
- 没有 lint baseline / dead-code 报告 / 一致命名规范，临时 TODO/FIXME 散落各处
- `.trellis/spec/backend/` 5 份 placeholder 至今未填，缺一份"代码当前真实约定"的快照作为后续 spec 的事实依据

## Scope

### 审查范围（in scope）

```
core/                     全部 6 个 Rust crate (39,628 行 / 74 文件)
flutter_app/lib/          全部 Dart 业务代码 (24,385 行 / 72 文件)
flutter_app/android/      仅检查 manifest / Gradle 配置层面的明显问题
build_android_*.sh        构建脚本一致性
flutter_rust_bridge.yaml  FRB 配置
```

### 不在审查范围（out of scope）

- `core/target/` 编译产物
- `flutter_app/lib/src/rust/frb_generated*.dart`（FRB 自动生成，跳过）
- `flutter_app/build/`、`dist/`、`.dart_tool/`
- `legado.db`（参考数据库快照，不审）
- iOS / macOS / Linux / Windows 平台目录（项目当前主线是 Android，跳过）
- `.trellis/` 自身（流程文件不审）
- 测试代码本身的"质量"（test/* 是否覆盖足够另开任务，不在本次范围）
- 历史任务 PRD 与归档（不审，但可作为审查时的背景参考）

## 审查的 5 个维度

每条发现都按「**维度 × 严重度 × 模块**」三轴标签化，便于后续筛选。

| 维度 | 关注点 |
|---|---|
| **A. 架构/分层** | FFI 边界数据契约、跨模块耦合、provider/状态管理是否合理、命名/分层一致性、死代码、TODO/FIXME 残留、重复实现 |
| **B. 正确性** | Rust 端 `unwrap` / `expect` / `panic!` 滥用、错误丢弃、并发/`Mutex` 死锁风险、SQL 注入、未关闭句柄、Dart 未 await 的 Future、null 解引用、生命周期 bug、StreamSubscription/Timer 泄漏 |
| **C. 性能** | 不必要 rebuild（`Consumer`/`Selector` 粒度）、大列表缺 `ListView.builder`/虚拟化、Rust 端无谓 clone、跨 FFI 频繁调用、SQLite N+1 / 缺索引、JS 引擎重复实例化 |
| **D. 安全/隐私** | 输入校验、JS 沙箱（rquickjs/quickjs 可达性）、文件路径穿越、cookie/凭据明文、HTTPS 强制、WebView JavascriptInterface、URL Scheme 注入、订阅源 SSRF |
| **E. 代码异味** | 长函数（>200 行）、深嵌套（>4 层）、魔法数字、无文档的公共 API、命名不一致（中英混用）、不一致的错误返回风格、Cargo/pubspec 依赖未锁版本/重复 |

### 严重度分级

- **P0 严重** — 数据丢失 / 崩溃 / 安全漏洞 / 阻塞主流程
- **P1 主要** — 明显 bug / 性能瓶颈 / 长期维护负担大 / 跨模块约定不一致
- **P2 次要** — 局部代码异味 / 风格不一致 / 死代码
- **P3 nice-to-have** — 文档/注释/命名建议

## Requirements

- [ ] 对 Rust core 的 6 个 crate 全部完成纵览审查（按文件而非按行）
- [ ] 对 Flutter `lib/core` + `lib/features/*` 全部 10 个 feature 模块完成纵览审查
- [ ] FFI 边界（`core/bridge` ↔ `flutter_app/lib/src/rust/api.dart`）做专项审查（最容易出错的薄弱点）
- [ ] Android 工程层（manifest / Gradle / network_security_config / jniLibs）做轻量配置审查
- [ ] 输出一份机器可解析 + 人可读的报告 `research/findings.md`：
  - 每个发现一条，含 `id`（如 `F-001`）、`维度`、`严重度`、`模块`、`file:line` 引用、问题描述、建议修复方向
  - 末尾按"严重度 → 维度"做分组汇总
- [ ] 在 `prd.md` 末尾追加 `## Findings Summary` 段落，仅列出 P0 / P1 条目供你快速过目
- [ ] 整个过程中**不修改任何业务代码**；如发现 trivial 错别字或注释错误等，也只记录不改（避免与后续修复任务的 commit 边界混淆）

## Acceptance Criteria

- [ ] `research/findings.md` 存在且每条发现都带 `file:line` 锚点（保证后续修复任务可直接跳转）
- [ ] 每条 P0 / P1 发现至少给出一种可落地的修复方向（不必给出代码补丁，但必须可被独立成一个子任务）
- [ ] 报告头部有"按维度统计"和"按模块统计"两张表，便于挑批次
- [ ] PRD 末尾的 `Findings Summary` ≤ 200 行，能让你不打开 findings.md 也能挑出第一批要修的条目

## Definition of Done

- 报告完成并自检（无重复、无未填项）
- 没有任何业务代码改动（`git status` 仅有 `.trellis/tasks/05-19-full-codebase-review/` 的新增）
- 在 `Findings Summary` 中明确给出"建议第一批修复 5-10 个 P0/P1 条目"的推荐拆分

## Out of Scope（再次强调）

- 修复代码（包含 trivial 修复也不做）
- 写新测试用例
- 重构建议落地（仅给方向）
- 性能基准测试（profiling 留给后续子任务）
- iOS / 桌面平台审查
- 第三方依赖深度安全审计（仅看显式调用面，不做 SBOM 级别审计）

## Technical Approach

### 审查执行策略

**单 sub-agent + 顺序遍历**：派发 `trellis-research` 到每个模块，找到的每个发现立刻 append 到 `research/findings.md`，避免最后归并出错。

按以下顺序推进，每个模块审完即写 findings：

1. **Rust 端**（先审底层，理解数据流）
   - `core/core-storage`（SQLite 数据层）
   - `core/core-net`（HTTP/cookie/encoding）
   - `core/core-parser`（HTML/JSON/regex 解析）
   - `core/core-source`（书源规则引擎）— 最大头，分 3-5 个子文件单独走
   - `core/api-server`（本地 HTTP 服务）
   - `core/bridge`（FRB 桥接，专项审 FFI 边界）

2. **Flutter 端**（自底向上）
   - `flutter_app/lib/core/`（API client / providers / router / theme / transport）
   - 各 feature 按行数从大到小：reader → settings → rss → bookshelf → search → source → qr → rule_sub → replace_rule → download

3. **跨层一致性**（所有模块审完后做最终汇总）
   - FFI 数据契约（Rust struct ↔ Dart class 字段名/类型对照）
   - 错误码 / 错误消息文案的中英一致性
   - 日志格式（Rust `tracing` vs Dart `debugPrint`）

4. **配置 & 构建**
   - `pubspec.yaml` / `Cargo.toml` / `flutter_rust_bridge.yaml`
   - `build_android_debug.sh` / `build_android_release.sh`
   - `AndroidManifest.xml` / `network_security_config.xml`

### 工具

- 主要靠 `Grep` / `Read` 静态分析
- 不跑 `cargo clippy` / `flutter analyze`（避免触发 build；如需可单独子任务）
- 不跑测试

### 报告格式（findings.md 头部模板）

```markdown
# Findings — 全量代码审查 (2026-05-19)

## 统计

### 按严重度
| Severity | Count |
|---|---|
| P0 严重 | _ |
| P1 主要 | _ |
| P2 次要 | _ |
| P3 nice-to-have | _ |

### 按维度
| 维度 | Count |
|---|---|
| A. 架构 | _ |
| B. 正确性 | _ |
| C. 性能 | _ |
| D. 安全 | _ |
| E. 代码异味 | _ |

### 按模块
| 模块 | P0 | P1 | P2 | P3 |
|---|---|---|---|---|
| ... | | | | |

---

## Findings

### F-001 [P1][B-正确性][core/core-source]

**File**: `core/core-source/src/.../foo.rs:123-128`

**问题**: 简短一句话

**详细**:
<2-4 句详述>

**建议**:
<可落地的修复方向，1-2 句>

---
```

## Decision (ADR-lite)

**Context**: 6.4 万行跨语言代码缺一次系统性体检；继续按特性切片推进新功能不解决横向一致性问题。
**Decision**:
1. 用一个独立 review 任务输出"只读报告"，把"扫描"和"修复"在 git 历史上分开，避免一个 commit 既改业务又改 review 报告造成审计困难。
2. 审查深度采用**广覆盖优先**策略：每个 in-scope 文件都过一遍，每条发现停留在"指认问题 + 建议方向"层面，不深挖单条 bug 的最小复现路径或代码骨架。深挖留给后续每个修复子任务（彼时上下文更聚焦）。
**Consequences**:
- ✅ 报告 commit 与后续修复 commit 边界清晰，可单独 revert
- ✅ 用户可挑条目分批修，不被一次性大 PR 绑架
- ✅ 广覆盖让用户先看见"全貌"，避免深挖少数模块导致其他模块的问题被遗漏
- ⚠️ 审完到完全修完之间会有一段时间报告"过期"——每次启动修复子任务时由该子任务自己 re-verify 当前状态
- ⚠️ 单条 P0/P1 不附"详细复现路径"，转修复子任务时需 sub-agent 自己重新读上下文

## Technical Notes

- 当前批次：批次 21 已收尾（commit `fc72603`），无并行未完成功能任务
- 仓库参考来源：legado-with-MD3（Kotlin）、Legado-Tauri（Rust + 前端）— 审查时遇到"为什么这么写"的疑问可对照参考项目的语义
- `.trellis/spec/backend/` 现有 5 份 placeholder 文件（`directory-structure / database-guidelines / error-handling / quality-guidelines / logging-guidelines`），本次审查产出物可作为后续填充 spec 的事实依据
- libbridge.so 是 19MB 二进制（commit `b0dfa87` 刚刷新），不审

## Findings Summary

**Total**: 320 findings (P0: 10, P1: 122, P2: 127, P3: 61)
**Master report**: [`research/findings.md`](research/findings.md)
**Read-only**: 没有任何业务代码改动；仅新增 `research/findings*.md` + 本节。

### Wave 文件
- 1A Rust data: [`research/findings-rust-data.md`](research/findings-rust-data.md) — 54 (P0:2 P1:22)
- 1B Rust logic: [`research/findings-rust-logic.md`](research/findings-rust-logic.md) — 73 (P0:4 P1:41)
- 2A Flutter core+reader: [`research/findings-flutter-core.md`](research/findings-flutter-core.md) — 80 (P0:1 P1:13)
- 2B Flutter features: [`research/findings-flutter-features.md`](research/findings-flutter-features.md) — 70 (P0:2 P1:26)
- 3 cross-layer+config+deps: [`research/findings-cross-config.md`](research/findings-cross-config.md) — 43 (P0:1 P1:20)

### P0 严重 (10)

- **[F-W1A-001]** 备份加密 AES-128/ECB + MD5 弱算法 — `core/core-storage/src/legado_aes.rs`
- **[F-W1A-002]** FRB 同步 fn `explore` 内 `block_on` 嵌套 runtime 风险 — `core/bridge/src/api.rs:933`
- **[F-W1B-001]** JS 桥接 java.ajax 系列无 SSRF 防护 — `core/core-source/src/legado/js_runtime.rs`
- **[F-W1B-002]** java.downloadFile 等沙箱可被环境变量豁免 — `core/core-source/src/legado/js_runtime.rs`
- **[F-W1B-003]** QuickJS 无内存/栈上限 — `core/core-source/src/legado/js_runtime.rs`
- **[F-W1B-004]** java.queryTtf 把任意 base64 输入当 ttf 解析 — `core/core-source/src/legado/js_runtime.rs`
- **[F-W2A-009]** WebView 始终 unrestricted JS + 无 userAgent 校验 — `flutter_app/lib/core/platform_webview_executor.dart:104`
- **[F-W2B-001]** WebDAV 凭据明文写 `webdav.json` — `flutter_app/lib/features/settings/webdav_config_page.dart:181`
- **[F-W2B-002]** QR 扫码 URL 无 host 校验直接 dio.get — `flutter_app/lib/features/qr/legado_qr_protocol.dart:55`
- **[F-W3-001]** 仓库 4 ABI stale `libbridge.so`（3 个停在 5/14） — `flutter_app/android/.../jniLibs/`

### P1 主要 (122 共，按主题列前 20 条最关键的；其余见 master report)

按"主题相关性 + 影响面"挑出（同主题的 P1 在 master report 的"主题汇总"段落已聚合，方便决定批次）：

- **[F-W1A-020]** 备份密码明文 JSON 写盘 — `core/bridge/src/api.rs:1407` （凭据存储主题）
- **[F-W1A-023]** api-server 临时 token 在 warn 日志输出明文 — `core/api-server/src/main.rs:108` （凭据存储主题）
- **[F-W1A-003]** 备份解密无认证（HMAC/GCM 缺失） — `core/core-storage/src/legado_aes.rs` （加密强度主题）
- **[F-W1A-005]** migrate 手写 BEGIN/COMMIT 非 RAII — `core/core-storage/src/database.rs:455` （SQLite 事务主题）
- **[F-W1A-009]** import_local_book 多 dao 多事务，FK 失败留脏数据 — `core/core-storage/src/chapter_dao.rs:115`
- **[F-W1A-021]** download_and_save_chapter 多 conn 无事务，~7 次独立 commit — `core/bridge/src/api.rs:730`
- **[F-W1B-005]** ZIP 路径无 traversal 防护 — `core/core-source/src/legado/js_runtime.rs` （JS 沙箱主题）
- **[F-W1B-007]** LegadoHttpClient https_only(false) + 无 cross-scheme redirect 限制
- **[F-W1B-009]** import_legado_source 无大小/字段数上限 (DoS)
- **[F-W1B-013]** js_script_to_expression 字符串拼接生成 JS（注入风险）
- **[F-W2A-001]** core/api/ Dio 客户端目录是死代码 (~300 行)
- **[F-W2A-002]** LocalTransport 是 UnimplementedError 占位
- **[F-W2A-008]** fontSize 双 source of truth (provider vs readerSettings)
- **[F-W2A-011]** ReaderPage build watch 多 provider 引发 rebuild 链
- **[F-W2B-010]** RSS WebView unrestricted JS 加载远端 HTML 无 NavigationDelegate
- **[F-W2B-019]** 多书源并行搜索旧 future 无法取消
- **[F-W3-002]** AndroidManifest 缺 `allowBackup="false"`
- **[F-W3-003]** network_security_config 全局 cleartext
- **[F-W3-005]** FFI 全表 JSON-string 模式，无类型校验（架构主题，~80% pub fn）
- **[F-W3-013]** release APK 用 debug keystore 签名

完整 P1 列表 + 按主题聚合 + 文件锚点见 [`research/findings.md`](research/findings.md) 的"单条索引"和"主题汇总"段落。

### 推荐第一批修复（5-10 个 P0/P1 条目）

按"风险高 + 修复成本低 + 可独立成子任务"挑 8 条：

| # | finding id | 风险 | 一句话 | 建议 slug | 范围 |
|---|---|---|---|---|---|
| 1 | F-W3-013 | 高 | release APK 用 debug keystore 签名 | `fix-release-keystore` | gradle + key.properties.example + README，~30 行 |
| 2 | F-W3-002 | 高 | AndroidManifest 缺 allowBackup="false" | `fix-manifest-disable-backup` | manifest 1 行 + 文档，~5 行 |
| 3 | F-W3-001 | 高 | 4 ABI stale libbridge.so 占 45MB | `cleanup-stale-jnilibs` | git rm 3 目录 + gitignore + build script 清理，~10 行 |
| 4 | F-W2B-001 + F-W1A-020 | 高 | 凭据 / 备份密码明文存储 | `secure-credentials-via-keystore` | 引入 Android Keystore wrapper，~150 行 + tests |
| 5 | F-W1B-001 | 高 | JS 桥 java.ajax 无 SSRF 防护 | `harden-js-shim-ssrf` | 复用 Android `isPrivateHost` 写 Rust 等价实现，~200 行 |
| 6 | F-W3-011 | 中 | Cargo workspace 同 crate 多版本 | `cargo-workspace-deps-cleanup` | `[workspace.dependencies]` + 6 sub-crate 改写，~80 行 |
| 7 | F-W2A-001 + F-W2A-002 + F-W1A-018 | 低 | 删 3 处死代码（core/api / LocalTransport / 多余 dao 调用） | `remove-dead-code-batch-1` | 纯减法 ~500 行 |
| 8 | F-W3-014 | 中 | release build 缺 R8 / proguard | `enable-r8-release` | gradle + proguard-rules.pro + 真机回归，~40 行 + 测试 |

**为什么是这 8 条**: #1-#3 是 quick wins（低改动 + 高收益）；#4 把两个相同主题合并不浪费；#5 是 P0 里修复路径最清晰的；#6 是后续所有依赖升级的 baseline；#7 commit 历史清爽；#8 顺势收紧 release 边界。

**不建议放第一批的 P0/P1**:
- JS 沙箱深度加固（F-W1B-002/003/004 等）— 需重设计 capability 模型
- FFI 全表迁移强类型（F-W3-005）— 工作量超大，分批做样板
- Reader 状态机重构（F-W2A-005~014）— 需 reader test harness 先到位
- 双规则系统去一（F-W1B-032）— 是产品决策，不是技术修复
