# BATCH-18a: 纯死代码删除（core/api Dio 客户端 + Rust delete_book 多余 dao）

> 修复路线图 BATCH-18 的**缩范围版本（仅死代码）**。原 BATCH-18 还包含 4 类需要重构 / 产品决策的项（F-W2A-002 Transport 抽象 / F-W2A-003 settings IO 模板 / F-W2A-008 fontSize 双源 / F-W2B-016 bookshelf 菜单 / F-W2B-022 documents 路径），均拆出延后。
> 路线图原文：[`.trellis/tasks/archive/2026-05/05-20-fix-roadmap/plan/batches/BATCH-18-flutter-dead-code-and-io-abstract.md`](../archive/2026-05/05-20-fix-roadmap/plan/batches/BATCH-18-flutter-dead-code-and-io-abstract.md)
>
> 同时本批顺手吸收路线图 BATCH-07 中的 F-W1A-018 子项（同样是"纯死代码"性质，跨 batch 合做能让一次 commit 覆盖完整"死代码主题"）。

## Goal

删除两类**真死代码 + FK 兜底冗余 dao 调用**，瘦身 ~400 行：

1. **Flutter 端 `core/api/` Dio 客户端目录**（F-W2A-001 P1 缩范围）：5 个 `_api.dart` 文件 + 5 个 `*ApiProvider` 在仓库内**零消费者**。仅 `dto.dart` 中的 `PlatformRequest` 仍被 reader_page 使用（其余 5 个 DTO 类也是死的）——保留 `PlatformRequest`，移到 `core/dto.dart`。
2. **Rust 端 `delete_book`**（F-W1A-018 P1）：`chapter_dao.delete_by_book` + `progress_dao.delete` 两行调用是**死代码**，schema FK `ON DELETE CASCADE` 已兜底（`core/core-storage/src/database.rs:162` 和其他位置确认 chapters / progress / read_records / bookmarks 全部走 FK CASCADE）；同时这两行用 `let _ = ...` 吞掉错误，删除后语义反而更清晰。

## Why

- **F-W2A-001 (P1)**：300+ 行 Dart 代码 + `dio` 依赖（`core/api/api_client.dart` 等 5 个 `_api.dart` 文件）从未被任何 widget 消费。`grep` 验证：`apiClientProvider` / `readerApiProvider` / `bookshelfApiProvider` / `sourceApiProvider` / `searchApiProvider` 只在 `providers.dart` 自身定义，无消费者。`dto.dart` 6 个类仅 `PlatformRequest` 在 `reader_page.dart` 9 处使用（`PlatformRequest.fromJson` + `_executePlatformRequest`）；其余 5 个（`FailedSource / SearchResponse / AddBookRequest / AddBookResponse / ChapterContentResponse`）零消费者。
- **F-W1A-018 (P1)**：`bridge/api.rs:72-80` `delete_book` 显式调 chapter / progress dao 删除是**5/14 之前的写法**，schema 已加 `ON DELETE CASCADE`（database.rs L162 等多处）；显式调用既冗余又用 `let _ =` 吞错，删除后 SQL 引擎自行级联且错误正常 propagate。

## Scope

### in scope（本批做）

**Flutter 端**：
- 删 `flutter_app/lib/core/api/api_client.dart`（31 行）
- 删 `flutter_app/lib/core/api/bookshelf_api.dart`（22 行）
- 删 `flutter_app/lib/core/api/reader_api.dart`（43 行）
- 删 `flutter_app/lib/core/api/search_api.dart`（17 行）
- 删 `flutter_app/lib/core/api/source_api.dart`（42 行）
- `flutter_app/lib/core/api/dto.dart` → 移到 `flutter_app/lib/core/dto.dart`，**只保留** `PlatformRequest` 类（约 25 行），删除 `FailedSource / SearchResponse / AddBookRequest / AddBookResponse / ChapterContentResponse` 5 个死类（约 125 行）
- 删除目录 `flutter_app/lib/core/api/`（应该空了）
- `flutter_app/lib/core/providers.dart`：删除 `apiClientProvider / readerApiProvider / bookshelfApiProvider / sourceApiProvider / searchApiProvider / apiBaseUrlProvider / apiTokenProvider` 7 个 provider（约 30 行）+ 相关 import
- `flutter_app/lib/features/reader/reader_page.dart`：把 `import '../../core/api/dto.dart';` 改为 `import '../../core/dto.dart';`

**Rust 端**：
- `core/bridge/src/api.rs:72-80` `delete_book` 删除 2 行 `chapter_dao.delete_by_book / progress_dao.delete`（外加注释 `// 先删除章节和进度（子记录）`）

### out of scope（明确延后）

- **F-W2A-002 Transport 抽象 / HttpTransport / LocalTransport / BackendMode**：search_page.dart 的 SSE 流式搜索路径还在引用 `transportProvider` + `BackendMode.http`，**不是纯死代码**；判断"是真在用还是占位"需要专项分析 → 留 BATCH-18b
- **F-W2A-003 settings IO 11 函数模板 / 抽 json_store**：~200 行业务代码改动 → 留 BATCH-18c
- **F-W2A-008 fontSize 双 source of truth**：需改 settings_page + main.dart → 留 BATCH-18d
- **F-W2B-016 bookshelf AppBar PopupMenu 重组**：UX 决策（哪些菜单留、哪些移设置）不是技术修复 → 留产品决策
- **F-W2B-022 各 feature documents 路径**：与 F-W2A-003 同一抽象 → 留 BATCH-18c
- **`dio` 依赖**：仍被 `cover_cache.dart` 使用，**不删除** pubspec 里的 dio
- **F-W1A-018 中 `let _ =` 错误吞掉模式的彻底治理**：本批仅删除冗余调用；其它 dao 里类似的 let_eq 散落（F-W1A-015/017/021/022）属于 BATCH-07/08 SQLite 事务批次

## Requirements

- [ ] `flutter_app/lib/core/api/` 目录被删除（仅 dto.dart 移走后剩空）
- [ ] `flutter_app/lib/core/dto.dart` 存在且只含 `PlatformRequest` 一个类
- [ ] `grep "core/api"` 在 `flutter_app/lib` 无任何 import 残留
- [ ] `grep "apiClientProvider\|readerApiProvider\|bookshelfApiProvider\|sourceApiProvider\|searchApiProvider\|apiBaseUrlProvider\|apiTokenProvider"` 全仓库无任何引用
- [ ] `grep "FailedSource\|SearchResponse\|AddBookRequest\|AddBookResponse\|ChapterContentResponse"` 全仓库无任何引用
- [ ] `core/bridge/src/api.rs:delete_book` 内仅保留 `book_dao.delete(&id)` 一步（外加 open_db）
- [ ] `flutter analyze` 全绿（用户验证）
- [ ] `cargo check --workspace` 全绿（用户验证）

## Acceptance Criteria

- [ ] master finding F-W2A-001（缩范围）+ F-W1A-018 消解；finding 报告中 dto.dart 5 死类不再存在
- [ ] 删除净行数 ≥ 250 行 Dart + 4-5 行 Rust
- [ ] 0 业务功能改动（reader_page 的 PlatformRequest 路径不动；只是 import 路径变化）
- [ ] `dio` 依赖未删除（cover_cache 仍在用）

## Definition of Done

- 6 个文件删除（5 个 _api.dart + api_client.dart）
- 1 个文件移动（dto.dart → core/dto.dart）+ 内容缩减（仅保留 PlatformRequest）
- providers.dart 删除 7 个 provider
- reader_page.dart 1 行 import 改路径
- bridge/api.rs delete_book 删 2 行
- commit message 风格 `chore(cleanup):`

## Out of Scope（再次强调）

- Transport / SSE 抽象（→ BATCH-18b）
- settings IO 抽象（→ BATCH-18c）
- fontSize provider 统一（→ BATCH-18d）
- bookshelf 菜单重组（产品决策）
- pubspec.yaml dio 依赖（cover_cache 还在用）
- 其它 `let _ =` 吞错位置（→ BATCH-07/08）

## Technical Approach

### 步骤

#### Flutter 端

1. **创建 `flutter_app/lib/core/dto.dart`**（新文件），仅含 `PlatformRequest` 类（从 `core/api/dto.dart` line 102-145 抽出来，约 40 行）

2. **删除 `flutter_app/lib/core/api/` 整目录**（6 个 .dart 文件全删，包括原 dto.dart）

3. **改 `flutter_app/lib/core/providers.dart`**：
   - 删除 import：`import 'api/api_client.dart';` / `import 'api/bookshelf_api.dart';` / `import 'api/reader_api.dart';` / `import 'api/search_api.dart';` / `import 'api/source_api.dart';`
   - 删除 7 个 provider：`apiBaseUrlProvider / apiTokenProvider / apiClientProvider / readerApiProvider / bookshelfApiProvider / sourceApiProvider / searchApiProvider`
   - **保留** `BackendMode enum + backendModeProvider`（F-W2A-002 留 BATCH-18b）；保留 `transportProvider`（同上）
   - 这些 provider 在 providers.dart 是约 L20-55；改完后保留 L20-22 的注释 + `enum BackendMode { frb, http }` + `backendModeProvider` 即可

4. **改 `flutter_app/lib/features/reader/reader_page.dart` line 14**：
   - `import '../../core/api/dto.dart';` → `import '../../core/dto.dart';`

5. **grep 验证**：
   - `grep -r "core/api/" flutter_app/lib` 应为空
   - `grep -rE "apiClientProvider|readerApiProvider|bookshelfApiProvider|sourceApiProvider|searchApiProvider|apiBaseUrlProvider|apiTokenProvider" flutter_app/lib` 应为空
   - `grep -rE "FailedSource|SearchResponse|AddBookRequest|AddBookResponse|ChapterContentResponse" flutter_app/lib` 应为空

#### Rust 端

6. **改 `core/bridge/src/api.rs:72-80`** `delete_book`：

   原代码：
   ```rust
   pub fn delete_book(db_path: String, id: String) -> Result<(), String> {
       let mut conn = open_db(&db_path)?;
       // 先删除章节和进度（子记录）
       let _ = core_storage::chapter_dao::ChapterDao::new(&mut conn).delete_by_book(&id);
       let _ = core_storage::progress_dao::ProgressDao::new(&conn).delete(&id);
       // 再删除书籍本身
       let book_dao = core_storage::book_dao::BookDao::new(&conn);
       book_dao.delete(&id).map_err(|e| format!("删除失败: {}", e))
   }
   ```

   新代码：
   ```rust
   pub fn delete_book(db_path: String, id: String) -> Result<(), String> {
       // chapters / progress / read_records / bookmarks 表均通过 schema 的
       // ON DELETE CASCADE 自动级联删除（见 core-storage/src/database.rs
       // L162 等），无需在 bridge 层显式调用各 dao。
       let conn = open_db(&db_path)?;
       let book_dao = core_storage::book_dao::BookDao::new(&conn);
       book_dao.delete(&id).map_err(|e| format!("删除失败: {}", e))
   }
   ```

   注意 `let mut conn` → `let conn`（不再需要 mut）。

### 工具

- `Edit` / `Write` (新增 dto.dart) / `Bash`（git rm 整目录）
- 不跑 `flutter analyze` / `cargo check`（留给用户验证）

### 风险

- **dto.dart 5 个死类是否真死**：grep 已验证全仓库零消费者（包括测试代码 / FRB 生成的 src/rust/）。低风险。
- **delete_book 行为**：`ON DELETE CASCADE` 在 SQLite 中需要 `PRAGMA foreign_keys = ON`，本仓库 `database.rs:init_database` 已启用且 `get_connection` 也设置（已在 master review F-W1A-004 / F-W1A-018 中确认）。低风险。
- **`reader_page.dart` import 路径**：Dart 不允许 forward-declare，改 import 后必须重新跑 `flutter analyze`。本批由 sub-agent 改后留给用户验证。
- **未来若有人想恢复 HTTP 模式**：本批保留了 `BackendMode + transportProvider + HttpTransport`，HTTP 路径基础设施完整；只是 5 个 `_Api` 类 + 5 个 provider 删了——若未来真要做 HTTP，重新 codegen 这些薄壳类成本很低（每个 30-40 行）。

## Decision (ADR-lite)

**Context**: 路线图 BATCH-18 含 6 类问题（死代码 + 抽象 + 重构 + UX）；要在"零业务代码改动"基线上做完不可能。

**Decision**:
1. 缩 BATCH-18 范围至**纯死代码删除**（F-W2A-001 + F-W1A-018），其它 5 类拆出 BATCH-18b/18c/18d
2. **保留 dto.dart 中 `PlatformRequest`**（仍被 reader_page 真用），把它移到 `core/dto.dart`
3. **保留 `BackendMode + transportProvider + HttpTransport`**——search_page 的 SSE 路径在用，是否真死需 BATCH-18b 专项确认
4. **不删 `dio` 依赖**——`cover_cache.dart` 还在用
5. **吸收 F-W1A-018**（路线图原属 BATCH-07）—— 同样是"FK 兜底冗余 dao 调用"，与 Flutter 死代码同主题

**Consequences**:
- ✅ 净删除 ~250 行 Dart + ~4 行 Rust，0 业务功能改动
- ✅ master 报告 2 条 finding 直接消解（F-W2A-001 缩范围 + F-W1A-018）
- ✅ 路线图 BATCH-18 原 #6 finding 显式分散到 18a/18b/18c/18d/产品决策/BATCH-07，每条都有清晰归属
- ⚠️ 若未来 HTTP 模式真要做，5 个 `_Api` 薄壳类需要重新写——但这些类历史就是 codegen，重做成本低

## Technical Notes

- 上一任务（BATCH-06）已完成（commit `f4c4f88`），workspace 依赖治理就绪
- master finding：
  - F-W2A-001 详情：`.trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings-flutter-core.md`
  - F-W1A-018 详情：`.trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings-rust-data.md`
- grep 已验证：dto.dart 中除 `PlatformRequest` 外的 5 个类（`FailedSource / SearchResponse / AddBookRequest / AddBookResponse / ChapterContentResponse`）全仓库 0 消费者
- 本批完成后用户应跑：`cd core && cargo check --workspace` + `cd flutter_app && flutter analyze` 双重验证
