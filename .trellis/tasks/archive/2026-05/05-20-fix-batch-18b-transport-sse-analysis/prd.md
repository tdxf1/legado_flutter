# BATCH-18b: Transport / HttpTransport / SSE 存活分析与决策

## Goal

闭环 BATCH-18a 留下的"`Transport` / `HttpTransport` / `LocalTransport` / `BackendMode` / `transportProvider` / search_page SSE 路径"是否还有真实消费者的问题。BATCH-18a commit message 里写了"保留，search_page SSE 路径在引用，需 BATCH-18b 专项确认"。本批次目标：拿出存活审计，决定整删 / 部分删 / 全保留，并执行该决定。

## What I already know

### 来自 `findings-flutter-core.md` (F-W2A-002)
- `LocalTransport.invoke` 是 `throw UnimplementedError(...)` 占位（`flutter_app/lib/core/transport.dart:305`）
- `LocalTransport.stream` 是 `return const Stream.empty()`（`:312`）
- `HttpTransport` 实现完整（含 SSE 协议解析）

### 来自本批次 explore 审计（2026-05-20）

**1. Transport 抽象的 production 消费者**
- 唯一 production 调用点：`search_page.dart:415-422` 的 `_doSearchViaSse` 方法
- 其余 import 都是测试：`test/transport_test.dart:4` / `test/search_sse_test.dart:4`

**2. HttpTransport 永不实例化（production）**
- 唯一构造点：`providers.dart:42`，需要 `BackendMode == .http`
- 整个仓库 0 处把 `backendModeProvider` 写成 `.http`：grep `backendModeProvider.notifier` / `).state =` / `overrideWith.*backendMode` 全空
- `BackendMode` 默认 `.frb`（`providers.dart:27`），运行期不可变
- settings 模块也无 UI 切换（grep 5 个 settings 文件无 `backend` / `Backend` / `Transport`）

**3. LocalTransport 占位实现**
- `invoke` 抛 `UnimplementedError`、`stream` 返回 empty stream、`close` 空 body
- 唯一被构造点：`providers.dart:39`（`BackendMode.frb` 分支）
- 但 search_page 仅在 `BackendMode.http` 分支才调它的方法 ⇒ 实际从未被调用

**4. `_doSearchViaSse` 调用栈**
- 入口：`search_page.dart:_doSearch` `:324`
- 条件：`:331` `if (_onlineMode && ref.read(backendModeProvider) == BackendMode.http)` — **永假**
- 即使强制走：`LocalTransport.stream()` ⇒ empty stream ⇒ UI 立即空结果
- 注：`_onlineMode` 是独立 widget state，控制 FRB 在线书源 vs FRB 离线 DB（与 HTTP/FRB transport 无关），其 production 路径走 `_searchWithSource` → FRB `searchBooks` API

**5. BackendMode 写入路径分析**
- 该枚举 + StateProvider 的存在意义本来是"未来切到 HTTP 模式 / 接 api-server"
- 但 `core/api-server/` 是独立 axum binary，Flutter 不内嵌、不启动、不配置 baseUrl（`providers.dart:43` 硬编码 `localhost:3000`，而 api-server 默认端口 `8787` — URL 都对不上）
- `CURRENT_STATUS.md` Phase 4.5 标 "进行中 2026-05-06"，已停滞

**6. BATCH-18a 死 provider 复核**
- `apiClientProvider` / `readerApiProvider` / `bookshelfApiProvider` / `sourceApiProvider` / `searchApiProvider` / `apiBaseUrlProvider` / `apiTokenProvider` 七个 — **全部 0 引用**（`providers.dart` 仅留历史注释）

### 范围内文件（删除候选）

| File | 删除范围 | 行数估计 |
|---|---|---|
| `flutter_app/lib/core/transport.dart` | 整文件 | 319 |
| `flutter_app/lib/core/providers.dart` | `import transport.dart` + `BackendMode` + `backendModeProvider` + `transportProvider` + 相关历史注释 | ~30 |
| `flutter_app/lib/features/search/search_page.dart` | `import transport.dart` + `:329-334` 条件分支 + 整个 `_doSearchViaSse` 方法 + `_onlineMode` 与 `BackendMode.http` 联动逻辑 | ~85 |
| `flutter_app/test/transport_test.dart` | 整文件 | 262 |
| `flutter_app/test/search_sse_test.dart` | 整文件 | 71 |

预估净 diff：**-700 ~ -750 行**。

## Open Questions

- [ ] **Expansion sweep**：删完 `transport.dart` 后是否顺手 grep 一遍 `dio` 在 `flutter_app/lib/` 的引用，确认仅剩 `cover_cache.dart`（与 BATCH-18 路线图 Acceptance #4 的"dio 仅被 cover_cache 使用"对齐）？只做 grep 报告，不删 dio 依赖（删 dio 留给替换 cover_cache 的独立批次）

## Requirements (evolving)

### MVP scope（整组删除）

1. **删 `flutter_app/lib/core/transport.dart` 整文件**（319 行）：`Transport` / `HttpTransport` / `LocalTransport` / `TransportEvent` / `parseSseStream` / `_parseSseBlock` 全部
2. **`flutter_app/lib/core/providers.dart` 内删除**：
   - `import 'transport.dart';`（`:11`）
   - `enum BackendMode { frb, http }`（`:25`）
   - `backendModeProvider`（`:27`）
   - `transportProvider` 工厂（`:36-49`）
   - 历史注释块（`:14-24` / `:29-35`）
3. **`flutter_app/lib/features/search/search_page.dart` 内删除**：
   - `import '../../core/transport.dart';`（`:10`）
   - `_doSearch` 内 `if (_onlineMode && ref.read(backendModeProvider) == BackendMode.http)` 死分支（`:329-334`）— 保留 `if (_onlineMode)` → 走 FRB `_searchWithSource` 的现有 production 路径
   - 整个 `_doSearchViaSse` 方法（`:409-489`）
4. **删测试文件**：
   - `flutter_app/test/transport_test.dart`（262 行）
   - `flutter_app/test/search_sse_test.dart`（71 行）
5. **同步 master report**：`findings-flutter-core.md` F-W2A-002 加 "Resolved by BATCH-18b" 状态注释
6. **expansion**：grep `dio` 引用并在 PRD/commit 中报告剩余消费者（不动代码）

### 不在范围内

- `core/api-server/` Rust binary（独立可执行，不消费）
- `dio` 依赖删除（cover_cache 还在用，单独批次处理）
- `_onlineMode` toggle UI 自身（保留，控制 FRB 在线/离线 DB）

## Acceptance Criteria (evolving)

- [ ] master finding F-W2A-002 (LocalTransport 占位) 标 "Resolved by BATCH-18b"
- [ ] grep `Transport` / `BackendMode` / `transportProvider` / `backendModeProvider` / `HttpTransport` / `LocalTransport` 在 `flutter_app/lib/` 下零命中
- [ ] grep `parseSseStream` / `TransportEvent` 在 `flutter_app/` 下零命中（包括测试目录）
- [ ] `flutter analyze` 无新 warning（与本批次前 baseline 对比）
- [ ] `flutter test` 全部 PASS（删 `transport_test.dart` / `search_sse_test.dart` 后剩余测试不受影响）
- [ ] `search_page` 的 production 搜索路径行为不变：`_onlineMode=true` 走 FRB `_searchWithSource`、`_onlineMode=false` 走 FRB 离线 DB
- [ ] `dio` 引用 grep 报告：本批次不删 dio，但记录"`flutter_app/lib/` 下还有哪些消费者"，给后续批次留 baseline

## Definition of Done

- 决定（整删 / 部分 / 保留）写进 ADR 段落
- 按决定执行删除 / 重命名 / 注释
- 测试套件 PASS
- 路线图 master finding 状态同步

## Out of Scope (explicit)

- `core/api-server/` Rust binary（独立可执行，Flutter 不消费）
- `dio` 依赖（`cover_cache.dart` 还在用，由 BATCH-18a/未来批次单独处理）
- search_page 内 `_onlineMode` toggle UI 自身（production 在用，保留）
- search_page 走 FRB 在线搜索的真实路径（`_searchWithSource`）

## Decision (ADR-lite)

**Context**: BATCH-18a 删除 `core/api/` 死目录时保留了 `Transport` / `HttpTransport` / `LocalTransport` / `BackendMode` / `transportProvider` / search_page `_doSearchViaSse`，理由是 search_page SSE 路径还有引用，需 BATCH-18b 专项确认。本批次审计确认：

- `BackendMode.http` 在整个仓库 0 个写入路径（无 settings UI、无 `.notifier`/`.state` write、无 `overrideWith`），永假
- `HttpTransport` production 永不实例化
- `LocalTransport.invoke` 抛 `UnimplementedError`、`stream` 返回 empty stream — 占位
- `_doSearchViaSse` 在 production 不可达；即便强制走，`LocalTransport.stream()` 也立即返回空流，UI 表现为"瞬间空结果"
- BATCH-18a 那 7 个旧 API provider（`apiClientProvider` 等）已 0 引用残留（仅历史注释）
- `core/api-server/` 是独立 axum binary，Flutter 不内嵌、不启动、URL 端口都对不上（Flutter 硬编码 `localhost:3000`，api-server 默认 `8787`），CURRENT_STATUS.md Phase 4.5 标"进行中"但已停滞

**Decision**: 整组删除（选项 A）。删除范围见 Requirements MVP scope。

**Consequences**:
- F-W2A-002 直接 resolved
- 减少 ~700-750 行死代码 + 减少 `flutter analyze` / 编译时间
- 失去未来"零成本接 api-server HTTP 模式"的脚手架；但 (a) 该路线已停滞 (b) git 历史可恢复 (c) 真要重启需先明确 api-server 启动机制 / baseUrl 配置 / 默认值切换策略，到那时重写一版干净 transport 抽象比维护半死代码更便宜
- search_page `_onlineMode` toggle UI 与"FRB 在线书源"路径不受影响（production 真用的）



- `Transport` 抽象类、`TransportEvent`、`parseSseStream` / `_parseSseBlock` 都在 `transport.dart` 内 — 整删时一并清掉
- `HttpTransport` 含完整 SSE 解析（被两个测试文件覆盖），但 production 永不可达
- 删除 `_doSearchViaSse` 后，`_doSearch` 内的 `if (_onlineMode && ... == BackendMode.http)` 死分支也要一并清理，保留 `if (_onlineMode)` → 走 FRB `searchBooks` 的现有路径（`:335` 起）

## Research References

- 本任务 explore audit（in-context，不持久化）
- BATCH-18 路线图：`.trellis/tasks/archive/2026-05/05-20-fix-roadmap/plan/batches/BATCH-18-flutter-dead-code-and-io-abstract.md`
- BATCH-18a archive：`.trellis/tasks/archive/2026-05/05-20-fix-batch-18a-pure-dead-code/`
