# 书源验证增强 — 实跑 Live Test (批次 21)

## Goal

阶段 5 收尾批次（最后一批，21/21）：把现有 `validate_book_source` 的**纯静态规则校验** + 加上**实跑 4 路 live test**（search / book_info / toc / content），返回每条结果的 ok / latency / sample / error，UI 用分阶段进度条 + 卡片列表展示。让用户能"一键诊断"书源是否真的能跑。

## What I already know

### 现状
- `core-source/src/lib.rs::validate_book_source` 仅静态规则校验（rule_search 是否存在、CSS 选择器语法是否合法、JSONPath 编译错误等），不实际拉网络
- `core-source/src/parser.rs::BookSourceParser` 已有 search / get_book_info / get_chapters / get_chapter_content 4 个 async fn
- bridge 已有 `validate_source_from_db(db_path, source_id) -> Vec<ValidationIssue>` (sync) — 这是 Flutter 现用的 API
- Flutter `source_page.dart::_showValidateDialog` 已实现：调 validate_source_from_db 拿 issues，渲染 dialog
- bridge funcId 已用到 108

### Flutter 现状
- 验证 dialog 比较简陋：列字段 + severity 图标 + 消息，仅静态检查 ok 但跑不通的源识别不出来

## Decision

**MVP — 加 1 个新 bridge fn `validate_source_live(source_id, keyword)` (async)**，在静态校验之上实际跑 4 路 + 分阶段 UI：

### Rust 端

1. **`core/core-source/src/lib.rs`** 新增 `LiveTestResult` struct：
   ```rust
   #[derive(Debug, Clone, Serialize, Deserialize)]
   pub struct LiveTestStage {
       pub stage: String,           // "search" / "book_info" / "toc" / "content"
       pub ok: bool,
       pub latency_ms: i64,
       pub sample: Option<String>,  // 抓到的代表性数据，比如 search 第一本书名
       pub error: Option<String>,   // ParserError::Display 的字符串
   }

   #[derive(Debug, Clone, Serialize, Deserialize)]
   pub struct LiveTestReport {
       pub stages: Vec<LiveTestStage>,
       pub static_issues: Vec<ValidationIssue>,
   }
   ```

2. **`core-source/src/lib.rs`** 加 `pub async fn run_live_test(source: &BookSource, keyword: &str) -> LiveTestReport`：
   - 先跑静态校验（复用 validate_book_source）
   - 4 个阶段顺序跑（前一个失败仍跑下一个，但 toc/content 用的 url 来自前一阶段；前一空就用 fallback dummy URL 让后续 stage 也能给出 RuleConfig 错误）：
     - **stage=search**: 调 search(source, keyword) → ok=true 时取 results[0].name 当 sample；results[0].book_url 留给下一阶段
     - **stage=book_info**: 用上一阶段的 book_url（或 `source.url + "/book/1"` fallback）→ get_book_info → sample = name
     - **stage=toc**: 用 book_info 返回的 chapters_url → get_chapters → sample = chapters[0].title + " (共 N 章)"
     - **stage=content**: 用 chapters[0].url → get_chapter_content → sample = content[..200]
   - 每阶段计时 (Instant::now()) 算 latency_ms
   - 任一 stage 抛 ParserError → ok=false，error = e.to_string()，sample=None；后续 stage 仍尝试（用上次成功的 url 或 fallback）

3. **bridge api 加 1 个 pub fn (funcId 109)**：
   ```rust
   pub async fn validate_source_live(
       db_path: String,
       source_id: String,
       keyword: String,  // 用户在 UI 输入的搜索关键字，默认"测试" / "test"
   ) -> Result<String, String>  // JSON of LiveTestReport
   ```

4. **`core/bridge/src/frb_generated.rs`** 加 wire fn + dispatcher arm 109 (async)

5. **`core/bridge/build.rs`** 加 `wire__crate__api__validate_source_live_impl` + `"        109 =>"`

### Flutter 端

6. **`flutter_app/lib/src/rust/api.dart` + `frb_generated.dart`** 加 1 个 wrapper

7. **改 `flutter_app/lib/features/source/source_page.dart::_showValidateDialog`**：
   - 添加"实跑测试"按钮（在原静态校验对话框里增加 IconButton）
   - 点后弹新 dialog `_LiveTestDialog`：
     - 顶部：关键字 TextField（默认"test"）+ "开始测试" FilledButton
     - 测试中：4 个 ListTile 一行行点亮（CircularProgressIndicator → check / error）
     - 结果：每条 ListTile 显示 stage 名 / latency / sample / error
   - 用 hooks 注入：`liveTestOverride` 接受 `Future<String> Function(...)` 注入假 LiveTestReport JSON

8. **新建独立 `_LiveTestDialog`** widget — 因为 source_page 已比较长，独立成 stateful widget 在同一文件内

### 测试

- Rust ≥ 4 单测（**用 httpmock 起本地 mock server**）：
  1. `test_run_live_test_all_pass` — 4 个 mock 端点全 200 → 返回 4 stages 全 ok=true
  2. `test_run_live_test_search_fail` — search mock 返回 500 → stage[0].ok=false / 后续 stages 仍尝试但 book_info 拿不到 url 也 fail
  3. `test_run_live_test_static_issues_included` — rule_search 缺失 → static_issues 非空 + stages 都 RuleConfig
  4. `test_live_test_report_json_round_trip` — Serialize + Deserialize 不丢字段
- Flutter ≥ 2 widget tests:
  1. `_LiveTestDialog` 渲染中间状态 + 完成状态（mock liveTestOverride）
  2. 关键字默认填 "test"

## Acceptance Criteria

- [ ] cargo test core-source ≥ baseline + 4
- [ ] cargo test bridge 16 不变
- [ ] cargo build bridge 通过 + FRB regen + build.rs 守护更新（funcId 109）
- [ ] flutter analyze 0 issue
- [ ] flutter test ≥ 393 (391 baseline + 2)
- [ ] **手工**：source_page 选一个真实书源 → 校验对话框 → 点"实跑测试" → 看到 4 阶段进度 + 结果

## Definition of Done

- cargo + flutter test 全绿
- analyze 0 issue
- 不打 APK
- commit "feat: 第六十一批 — 书源实跑验证 (批次 21) 阶段 5 收尾" + archive
- **21 批全部完成**

## Out of Scope

- RSS 源 live test — 留 TODO，本批次仅书源
- 自动定时跑测试 — 不做
- 多关键字批量测试 — 不做
- 返回原始 HTML 给 UI 调试 — 太大；MVP 仅 sample 200 字符

## Technical Notes

- `Instant::now()` + `elapsed().as_millis() as i64` 计时
- 4 个 stage 顺序运行，不并行（避免对书源造成压力）
- httpmock 已在 core-source dev-deps，复用现有测试 mock 方法
- LiveTestReport 序列化用现有 `validate_source_from_db` 同样的 JSON 模式（field tag）
- Flutter dialog 用 ListTile + leading 状态图标（loading/check/error）+ subtitle 显示 sample / error
