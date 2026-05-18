# 本地备份/恢复 (批次 10)

## Goal

让用户可在书架顶部菜单"备份/恢复"导出本地 zip 备份，支持原 Legado 兼容的 zip 格式 — 既能导出**与原 Legado 互兼容的备份 zip**（用户从 Android 原版迁移过来），也能导入旧版备份恢复书架。WebDAV 留批次 11、加密留批次 12。

## What I already know

- 调研已经写到 `research/legado-backup-format.md`（807 行）：原 Legado 备份 zip = 14 张表 JSON + 6 个 config + 1 个 SharedPreferences config.xml + servers.json (AES 加密)，**无 manifest.json**，按文件名硬编码识别每张表
- 关键文件名：`bookshelf.json` / `bookGroup.json` / `bookmark.json` / `replaceRule.json` / `readRecord.json` / `bookSource.json` / `searchHistory.json` / `cookie.json` / `txtTocRule.json` / `httpTtsSource.json` / `dictRule.json` / `keyboardAssists.json` / `rssSource.json` / `rssStar.json`
- 我们当前 schema 只覆盖了：books / book_groups / bookmarks / replace_rules / read_records / book_sources / cookies / rule_subs（其中 ReadRecord/Cookie/RuleSub DAO 还没写，schema 在批次 6 已就绪）
- 字段映射表完整，重点风险：
  - `origin` URL ↔ `source_id` UUID（导入时 lookup `book_sources WHERE url=?`）
  - 时间戳单位：原 ms / 新 s（必须 / 1000）
  - `BookGroup.id` bitmask 多分组 → 单 group_id（取最低位 power-of-2）
  - `wordCount` String "5.2M" → i32（解析后缀）
  - 8 个端口缺失字段塞 `custom_info_json`
- pubspec.yaml 已有 `archive: ^4.0.7`（提供 ZipEncoder/ZipDecoder），不需要新依赖

## Decision

**MVP 范围（仅本批次）**：
1. **Rust 端**新增 `core/bridge/src/api.rs` 4 个新 fn：
   - `export_backup_zip(db_path, out_zip_path) -> ()` — 把当前 SQLite 转换成 14 张表的 JSON + zip 打包
   - `import_backup_zip(db_path, zip_path) -> ImportSummary` — 解 zip，按文件名识别，做 upsert + 字段映射
   - `validate_backup_zip(zip_path) -> Vec<String>` — 列出 zip 内识别到的文件类型
   - 字段映射 helper（origin → source_id / wordCount 解析 / bitmask → group_id / 时间戳 ms→s）
2. **Flutter 端**：
   - `core/providers.dart` 加 `backupApiProvider` 调上述 4 个 fn
   - 新建 `lib/features/settings/backup_page.dart`：列出"导出备份" + "导入备份" + 导入预览（显示 books/groups/sources 各多少条要导入）
   - 入口：bookshelf_page AppBar PopupMenu 加"备份/恢复"
   - 路由 `/backup`
3. **测试**：
   - cargo: 4 个新单测覆盖 export/import 往返一致性、字段映射、wordCount 解析、bitmask 转换
   - flutter: 1 个新 widget test（备份页渲染 + "导出"按钮触发 mock）

**MVP 简化**：
- **只支持我们 schema 已有的 5 张表**（books / book_groups / bookmarks / replace_rules / book_sources），其它（searchHistory / cookie / rssSource 等）批次 16+ schema 补齐时再加
- 不导出 `config.xml` SharedPreferences（批次 12 加密备份时再加）
- 不导出 servers.json（WebDAV 留批次 11）
- 不做封面图打包（zip 大小爆炸；只复制 custom_cover_path 路径字符串）
- 导入是 **upsert 合并**（不清空现有数据），与原 Legado 一致
- zip 文件名 `legado_backup_<yyyyMMdd-HHmm>.zip`（兼容原版前缀 `backup` 也能识别）

## Requirements

### Rust 端
1. **新增 `core/core-storage/src/backup_dao.rs`**：
   - `export_to_zip(conn, out_path) -> SqlResult<()>` — 一次性 SELECT 5 张表 → 5 个 JSON 文件 → zip
   - `import_from_zip(conn, zip_path) -> SqlResult<ImportSummary>` — 解 zip → 按文件名读 JSON → 字段映射 → upsert
2. **新增 `core/core-storage/src/legado_field_map.rs`**：
   - `pub fn legado_book_to_storage_book(legado_json: &Value, sources_url_to_id: &HashMap<String,String>) -> Result<Book, String>`
   - `pub fn parse_word_count(s: &str) -> i32` — "5.2M" → 5_200_000
   - `pub fn legado_group_bitmask_to_id(bitmask: i64) -> i64` — 取最低位 power-of-2 的 log2
   - `pub fn ms_to_seconds(ms: i64) -> i64` — 简单 / 1000，但要先判断"看起来像 ms"（>1e10）
3. **`core/bridge/src/api.rs` 4 个新 pub fn**（见 Decision 段）+ FRB regen
4. **依赖**：`Cargo.toml` 加 `zip = "2"`（已有 `serde_json` / `chrono`）

### Flutter 端
5. **`lib/features/settings/backup_page.dart`** ConsumerStatefulWidget：
   - 顶部"导出备份"卡片：选保存目录 → 调 `rust_api.exportBackupZip` → 显示文件路径 SnackBar
   - 中部"导入备份"卡片：file_picker 选 zip → 调 `validateBackupZip` 显示"识别到 X 本书 / Y 个分组" → 用户确认 → 调 `importBackupZip` → 显示导入结果 SnackBar + invalidate providers
6. **`bookshelf_page.dart` AppBar PopupMenu 加 "备份/恢复" 项**（在"管理分组"之后）
7. **路由注册** `/backup` → BackupPage

### 测试
- Rust: ≥ 4 单测 — wordCount_parsing / bitmask_to_id / round_trip_book / round_trip_5_tables
- Flutter: ≥ 1 widget test — BackupPage 显示两个按钮 + "导出"按钮 disabled 当 dbPath 未就绪

## Acceptance Criteria

- [ ] Rust: `cargo test -p core-storage` ≥ 37 (33 baseline + 4 backup)
- [ ] Rust: `cargo build -p bridge` 通过
- [ ] Flutter: `flutter analyze` 0 issue
- [ ] Flutter: `flutter test` ≥ 347 (346 baseline + 1 backup)
- [ ] **互兼容验证（手工）**：用本工程导出的 zip 在原 Legado Android 上能成功导入；原 Legado 导出的 zip 在本工程能成功导入并显示书架

## Definition of Done

- cargo + flutter test 全绿
- analyze 0 issue
- debug APK → dist/legado-arm64-debug-batch10-local-backup.apk
- commit "feat: 第四十九批 — 本地备份/恢复（Legado 兼容） (批次 10)" + archive

## Out of Scope

- WebDAV 同步（批次 11）
- AES 加密 servers.json + webDavPassword（批次 12）
- 14 张表完整覆盖（schema 不全的留批次 16+）
- 封面图打包到 zip（批次 12+ 加密备份时再考虑）
- 阅读时长合并（read_records 表 DAO 还没写，留批次 13）
