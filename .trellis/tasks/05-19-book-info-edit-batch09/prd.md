# 书信息编辑页 (批次 9)

## Goal

让用户能编辑书架中已加入的书的元信息：书名 / 作者 / 分类 / 简介 / 封面。对齐原 Legado `BookInfoEditActivity.kt` 的 5 字段编辑能力。

## What I already know

- `core/core-storage/src/book_dao.rs::upsert(&book)` 已支持全字段写入
- `core/bridge/src/api.rs::save_book(db_path, book_json)` 桥已存在，无需改 Rust
- `models.rs::Book` 字段：`name / author / kind (分类) / intro / custom_cover_path`
- `flutter_app/lib/features/bookshelf/bookshelf_page.dart` 长按 BottomSheet（批次 7）现有"移动到分组 / 删除"两项，需加"编辑书信息"
- `flutter_app/pubspec.yaml` 已有 `file_picker: ^11.0.2`，可用于选本地封面图片
- 应用 documents 目录的 `covers/` 子目录可作为 custom_cover_path 存储位置

## Decision

**实现路径**：
1. **不动 Rust 端**：`save_book` 已支持，直接复用
2. **Flutter 新增 `book_info_edit_page.dart`**：一个 ConsumerStatefulWidget，5 字段 TextField + 封面 InkWell（点击选本地图片）
3. **封面选择**：用 `file_picker` 选图片 → 复制到 `<documentsDir>/covers/<bookId>_<timestamp>.jpg` → 写 `book.custom_cover_path`
4. **入口**：bookshelf_page 长按 sheet 加"编辑信息"项 → 走 GoRouter `/book-info-edit?bookId=xxx`
5. **路由**：`flutter_app/lib/core/app_router.dart`（或类似文件）注册 `/book-info-edit`
6. **保存后**：`ref.invalidate(allBooksProvider) + booksByGroupProvider`，回退到书架

## Requirements

### Flutter 端
1. **新增 `lib/features/bookshelf/book_info_edit_page.dart`**：
   - StatefulWidget，从 routes query param 读 bookId
   - 进页时 `ref.read(allBooksProvider.future)` 拿 book，初始化 5 个 TextField controller
   - 封面区：点击 → file_picker.pickFiles(type: image) → 复制到 covers 目录 → setState 更新预览
   - 顶栏 "保存" 按钮：构造 Book JSON → `rust_api.saveBook(dbPath, bookJson)` → invalidate provider → pop
2. **`bookshelf_page.dart` 长按 sheet 加 "编辑信息" 项**（在 "移动到分组" 之后、"删除" 之前）
3. **路由注册**：`/book-info-edit` 路径接受 `bookId` query param
4. **`covers/` 目录管理**：`getApplicationDocumentsDirectory + /covers` 子目录，首次访问时 mkdir

### Rust 端
- 无改动（`save_book` 已就绪）

## Acceptance Criteria

- [ ] Flutter: `flutter analyze` 0 issue
- [ ] Flutter: `flutter test` ≥ 345 (343 baseline + 至少 2 新单测：构造 page widget / 校验"保存"调用 saveBook)
- [ ] cargo: 不动，仅验证 baseline 33 仍绿
- [ ] 实机: 长按书条 → 编辑信息 → 改名/作者/简介 → 保存 → 书架立刻刷新

## Definition of Done

- analyze 0 issue / flutter test ≥ 345
- debug APK 构建到 dist/legado-arm64-debug-batch09-book-info-edit.apk
- commit "feat: 第四十八批 — 书信息编辑页 (批次 9)" + archive

## Out of Scope

- 网络封面搜索 / 自动换封面（依赖书源 API 调用，复杂度大，留批次 19+）
- 多书批量编辑
- 自定义"分类"做下拉枚举（保持自由文本，与原 Legado 一致）
- 进度 / 阅读时长字段编辑（系统维护，不该手动改）
