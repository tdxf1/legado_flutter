# 阅读时长统计 (批次 14)

## Goal

让书架显示每本书的"上次阅读"快照（章节标题 / 时间戳），让书籍详情页 / 设置页能看到该书 / 全局累计阅读时长。对齐原 Legado `ReadRecord.kt` + `Book.durChapterTime` 的体验。

## What I already know

- **schema 已就绪**（批次 6）：
  - `read_records` 表：`id / book_id / book_name / read_time(秒) / last_read_at(秒) / created_at / updated_at`
  - `idx_read_records_book_id` 索引
  - `models::ReadRecord` struct 已定义
- **Book 表已有快照字段**（批次 6 加）：
  - `dur_chapter_index / dur_chapter_pos / dur_chapter_title / dur_chapter_time` — 上次阅读章节快照
- **`book_progress` 表的 `read_time` 字段**已存在（毫秒）但未被使用。**避免冲突**：本批次专门用 `read_records` 表（按书聚合），`book_progress.read_time` 暂保留不动
- **现有 reader 进度回写**：`reader_page.dart` 章节切换时调 `save_reading_progress` 写 `book_progress` 表 + 批次 8 通过 `dur_chapter_time` 控制书架排序"上次阅读"
- **现有 timer**：reader_page 没有"每分钟 +60s"的计时器；需要新加一个 `Timer.periodic(Duration(seconds: 60), ...)`
- 原 Legado `ReadBookActivity.kt` 用 `readTimeRecord` 在 onResume 时记 `startTime`，每章切换 / onPause 时算 delta 累加到 ReadRecord.readTime

## Decision

**MVP 范围**：

### Rust 端
1. **新增 `core/core-storage/src/read_record_dao.rs`**：
   - `pub struct ReadRecordDao<'a> { conn: &'a Connection }`
   - `add_time(book_id: &str, book_name: &str, delta_seconds: i64)` — upsert：若 `book_id` 存在则 `read_time += delta + last_read_at = now`；否则 insert 新行（id=UUID, read_time=delta）
   - `get_by_book(book_id: &str) -> Option<ReadRecord>` — 单本
   - `list_all() -> Vec<ReadRecord>` — 设置页"阅读统计"用，按 last_read_at DESC
   - `total_read_time() -> i64` — 全局总时长（秒）
2. **bridge api 加 4 个 pub fn**：
   - `add_read_time(db_path, book_id, book_name, delta_seconds: i64) -> ()`
   - `get_read_record(db_path, book_id) -> JSON Option<ReadRecord>`
   - `list_read_records(db_path) -> JSON Vec<ReadRecord>`
   - `get_total_read_time(db_path) -> i64`

### Flutter 端
3. **`reader_page.dart` 加 `Timer.periodic(60s, ...)`**：
   - initState 启动；dispose 关闭
   - 后台 / 前台切换：`AppLifecycleState.paused` 暂停；`resumed` 恢复
   - 每 60s 调 `add_read_time(dbPath, bookId, bookName, 60)` 累加
   - 同时**已有的章节切换路径**也调（这部分批次 8 已经在维护 `dur_chapter_*` 字段，本批次只加 read_record 写入，不重写 reader 主流程）
4. **`bookshelf_page.dart` 列表/网格 itemBuilder** 显示"上次读 {dur_chapter_title}"副标题（之前显示作者，现改成 `dur_chapter_title.isNotEmpty ? dur_chapter_title : author`）+ 相对时间戳（"3 小时前 / 昨天 / 5 天前"）— 用一个简单 helper `_formatRelativeTime(seconds_since_epoch)`
5. **新建 `lib/features/settings/read_stats_page.dart`** ConsumerStatefulWidget：
   - AppBar(title: "阅读统计")
   - 顶部 Card：总时长（"今天读了 1 小时 23 分" / "累计 5 天 12 小时"）
   - ListView：每本书一行 (book_name, read_time 格式化, last_read_at 相对时间)
   - 数据来源：`list_read_records` + `get_total_read_time`
6. **路由注册** `/read-stats` → ReadStatsPage
7. **入口**：bookshelf_page AppBar PopupMenu 加"阅读统计"项（在批次 13 的"导入本地书"后）

### 测试
- Rust ≥ 4 单测（`read_record_dao.rs::tests`）：
  1. `test_add_time_creates_new_record` — 新书首次 add 创建一行
  2. `test_add_time_accumulates` — 同 book_id 调两次 → read_time = sum
  3. `test_total_read_time` — 多本书相加正确
  4. `test_list_all_orders_by_last_read_desc`
- Flutter ≥ 1 widget test — read_stats_page 渲染 + 总时长格式化（如 3725 秒 → "1 小时 2 分"）

## Acceptance Criteria

- [ ] cargo test core-storage ≥ 57 (53 baseline + 4)
- [ ] cargo test bridge ≥ 16（不变）
- [ ] cargo build bridge 通过 + FRB regen
- [ ] flutter analyze 0 issue
- [ ] flutter test ≥ 352 (351 baseline + 1)
- [ ] **手工验证**：reader 待 1 分钟 → 关 → 进设置阅读统计页能看到该书 ≥ 60s

## Definition of Done

- cargo + flutter test 全绿
- analyze 0 issue
- 不打 APK
- commit "feat: 第五十三批 — 阅读时长统计 ReadRecord (批次 14)" + archive

## Out of Scope

- 跨设备阅读时长合并（原 Legado 用 deviceId 做主键的一半，端口已弃，留进阶）
- 详细图表（每日 / 每周 / 每月柱状图）
- 阅读速度（字/分钟）
- 分享卡片（截图功能）
- TextInputAction.done 等设置页 UI 优化
