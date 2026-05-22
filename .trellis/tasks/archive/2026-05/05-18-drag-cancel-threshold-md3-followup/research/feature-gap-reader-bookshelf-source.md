# Legado vs Flutter+Rust 端口 — 功能差异调研报告

> **范围**：Reader 阅读器 / Bookshelf 书架 / 进度·书签·阅读记录 / 书源管理·书源登录
> **方法**：只读对比 `legado/` (原 Kotlin/Android) 与 `legado_flutter/` (Flutter + Rust workspace)
> **生成时间**：2026-05-18
> **调研者**：read-only research 模式（不修改 codebase）

---

## 0. 仓库结构总览

| 模块 | 原 Legado (Kotlin) | Flutter+Rust 端口 |
|---|---|---|
| Reader UI | `app/.../ui/book/read/` 11 个 Activity/Dialog + `page/` 10+ Delegate/Provider | `flutter_app/lib/features/reader/` 单 Page (2552 行) + 7 个 widget + 4 个 service |
| Bookshelf UI | `app/.../ui/main/bookshelf/` style1+style2 双布局，`ui/book/group/` 4 个分组对话框 | `flutter_app/lib/features/bookshelf/bookshelf_page.dart` 单文件 (225 行) |
| 书源 UI | `app/.../ui/book/source/` manage/edit/debug + `ui/login/` 4 个文件 | `flutter_app/lib/features/source/source_page.dart` 单文件 (524 行) |
| 数据存储 | Room + 21 个 DAO + 23 个 Entity | Rust `core/core-storage/` 7 个 DAO + 8 个 struct + sqlite v10 |
| Bridge API | — | `core/bridge/src/api.rs` 共 56 个 `pub fn` |

**简化倍率粗估**（按代码量）：
- Reader: ~6000 行 → ~3700 行（约 **0.6×**），但缺多个 Activity/Dialog 入口
- Bookshelf: ~2500 行 (含 adapter/group dialog) → 225 行（约 **0.09×**）
- Source: ~3000 行 (manage+edit+debug+login) → 524 行（约 **0.17×**）

---

## 1. Reader 阅读器

### 1.1 翻页动画 — 覆盖 / 平移 / 仿真 / 淡入淡出 / 无动画 / 滚动

- **原项目**：
  - `ui/book/read/page/delegate/CoverPageDelegate.kt` / `SlidePageDelegate.kt` / `SimulationPageDelegate.kt` / `NoAnimPageDelegate.kt` / `ScrollPageDelegate.kt` / `HorizontalPageDelegate.kt` (基类)
  - `ReadBookConfig.pageAnim` 整型，0=覆盖、1=平移、2=仿真、3=滚动、4=无
  - 配置入口 `BaseReadBookActivity.kt:363 showPageAnimConfig`
- **Flutter 现状**：✅ **完全实现**（且重写了仿真翻页几何）
  - `flutter_app/lib/features/reader/page/delegate/` 完整对应：`cover_page_delegate.dart` / `slide_page_delegate.dart` / `simulation_page_delegate.dart` (1000+ 行) / `fade_page_delegate.dart` / `no_anim_page_delegate.dart` / `horizontal_page_delegate.dart`
  - `ReaderPageAnim` enum (`providers.dart:443`) 含 cover/slide/simulation/fade/noAnim/scroll，settingsVersion 已迭代到 v5
  - 额外做了 settings 迁移：v1→v4 / v2→v4 / v3→v4 / v3→v5（含 PageMode 合并）
- **细节**：Flutter 端在仿真翻页 prev 镜像、drag 取消阈值方面有最近的 follow-up 任务（如本任务前置 `05-18-drag-cancel-threshold-md3` / `05-18-simulation-prev-mirror-md3`）
- **工作量**：— (已完成)

### 1.2 自动翻页 / 自动滚动

- **原项目**：
  - `ui/book/read/page/AutoPager.kt` (单独类，含速度配置 `AppConfig.autoReadSpeed` 1..N 秒/页)
  - `config/AutoReadDialog.kt` 速度滑杆 + 暂停/恢复/退出菜单 (`runMenuOut → autoPageStop`)
  - 朗读+翻页联动：自动翻页时与 TTS 协同
- **Flutter 现状**：🟡 **部分实现 — 仅滚动模式可自动滚**
  - `services/reader_auto_scroller.dart`：硬编码 1.0 px / 50ms ≈ 20 px/s，无速度可调
  - 仅作用于 `ScrollController`（即 `pageAnim == scroll` 模式）；分页模式下 `controller()` 返回 null 后 `_step()` 直接 stop
  - 没有 `AutoReadDialog` 等 UI 入口配置
- **细节**：分页模式（cover/slide/simulation/fade/noAnim）下用户点击"自动"按钮会瞬间停止
- **工作量**：M（要给分页 5 个 delegate 加 timer-driven nextPage 调用 + 速度滑杆）

### 1.3 屏幕亮度调节

- **原项目**：
  - `ReadMenu.kt:269-300` `setScreenBrightness(value)` 写入 `window.attributes.screenBrightness`
  - `ReadMenu.kt:269` 自动亮度切换 + 滑杆调节 (0..255)
  - 持久化到 `AppConfig.readBrightness`
- **Flutter 现状**：❌ **完全缺失**
  - 全仓 `grep -rn "screenBrightness\|setBrightness"` 仅 `reader_page.dart:1683` 处用 `Brightness.light/dark` 设状态栏图标颜色，没有调节屏幕亮度的代码
  - 没有 `screen_brightness` / `flutter_screen_brightness` 包依赖
- **工作量**：S（接入 `screen_brightness` 包 + 在底栏加滑杆）

### 1.4 锁屏保持 / 屏幕常亮

- **原项目**：
  - `BaseReadBookActivity.kt:239 keepScreenOn(on: Boolean)` toggling `FLAG_KEEP_SCREEN_ON`
  - `AppConfig.screen_time_out`：永久亮屏 / 跟系统 / 自定义超时（pref 数组 `screen_time_out_value`）
  - `screenOffRunnable` (line 241) 自动延时关亮屏
- **Flutter 现状**：❌ **完全缺失**
  - 无 `wakelock_plus` 等依赖；`grep "Wakelock"` 0 命中
- **工作量**：S（接入 `wakelock_plus`）

### 1.5 字号 / 字体 / 行距 / 段距 / 边距 / 字距 / 字重

- **原项目**：
  - `ReadStyleDialog.kt` + `BgTextConfigDialog.kt` + `PaddingConfigDialog.kt`
  - 持久化字段 `ReadBookConfig.durConfig`：textSize / textBold / lineSpacing / paragraphSpacing / titleMode / titleSize / titleTopSpacing / titleBottomSpacing / textIndent / paragraphIndent / paddingLeft/Right/Top/Bottom / headerPadding / footerPadding
  - 字体选择：`ui/font/FontSelectDialog.kt` 扫描本地字体 + 内置字体
- **Flutter 现状**：🟡 **部分实现**
  - `ReaderSettings` (`providers.dart:554`) 有 fontSize / fontWeightIndex / letterSpacing / lineHeight / paragraphSpacing / horizontalPadding / verticalPadding / paragraphIndent
  - `widgets/reader_settings_sheet.dart` UI 完整覆盖上述字段
  - **缺**：`fontFamily` 字段虽存在但 settings sheet 没暴露字体选择 UI；标题字号/标题段距 (titleSize/titleTopSpacing/titleBottomSpacing) 没有；header/footer 独立 padding 没有；`textIndent` 仅用 paragraphIndent 串拟（"无/2全角/4半角"），不能精细控制
  - 字重只有 3 档（细/正常/粗），原版是 0..900 的连续字重 + bold 开关
- **工作量**：M（字体选择对话框 + titleSize/titleSpacing 三个字段 + header/footer padding 拆分）

### 1.6 主题 / 背景图 / 自定义颜色 / 夜间模式

- **原项目**：
  - `BgTextConfigDialog.kt` + `BgAdapter.kt` 自带 5 套预设 + 用户自定义；导入/导出主题（`exportConfig` / `importConfig` line 266+）
  - 内置主题文件位于 `assets/web/main/themes/`，`importNetConfig` 支持从 URL 导入
  - 夜间模式独立 `ReadBookConfig.bg/textColor`（白天）+ `ReadBookConfig.bgN/textN`（夜间），自动切换
- **Flutter 现状**：🟡 **部分实现**
  - 有 `nightMode` 切换 + 5 个预设色 `presetColors`（providers.dart:609），底栏的"日间/夜间"按钮工作
  - 背景图：`reader_settings_sheet.dart:50 _pickBackgroundImage` 可选本地图，复制到 `<docs>/reader_backgrounds/`，**但每次只一张，没有内置主题库**
  - **缺**：导入/导出主题（json）、内置主题预设（仅纯色）、网络主题导入、主题切换动画、textColor / nightTextColor 自定义 RGB 选择器
- **工作量**：M（自定义颜色选择器 + 主题导入/导出 json schema）

### 1.7 TTS 朗读

- **原项目**：
  - `services/ReadAloudService.kt` (Foreground Service) + `model/ReadAloud.kt` 引擎抽象
  - 引擎：`HttpReadAloudService.kt`（自定义 HTTP TTS）、系统 TTS、`SpeakEngineDialog.kt` 切换引擎
  - `config/ReadAloudConfigDialog.kt` 配置：忽略音频焦点 / 来电暂停 / 唤醒锁 / 媒体按钮 / 按页朗读 / 跨章节自动续读
  - `data/entities/HttpTTS.kt` + `dao/HttpTTSDao.kt` 自定义 HTTP TTS 持久化
  - `ReadAloudConfigDialog.kt:104 PreferKey.ttsEngine` 选择引擎
- **Flutter 现状**：🟡 **部分实现 — 系统 TTS only，无 HTTP TTS**
  - `services/reader_tts_manager.dart` 用 `flutter_tts` 包，仅支持系统 TTS
  - 段落切分按 `\n+` 简单切分；语速 cycle 切换；段落上下/暂停/恢复/停止
  - **完全缺**：自定义 HTTP TTS（`HttpTTS` entity + dao + 配置 dialog 全无）、引擎选择 UI、按页朗读、来电暂停、媒体按钮控制、唤醒锁、Foreground Service（朗读熄屏即停）
- **工作量**：L（HTTP TTS 引擎 + 持久化 + Foreground Service）

### 1.8 翻页方向 / 点击区域 / 音量键翻页

- **原项目**：
  - `ClickActionConfigDialog.kt`：5 区点击行为（左/中/右 × 上/下）每区独立行为 0..N（菜单 / 翻页 / 朗读 / 字典 ...）
  - `PageKeyDialog.kt` (`config/PageKeyDialog.kt:44 onKeyDown`) 自定义"上一页/下一页"键码（数字键 / 物理键）
  - `ReadBookActivity.kt:682-738 onKeyDown/onKeyUp`：音量上/下、PAGE_UP/DOWN、SPACE 翻页；`volumeKeyPage / mouseWheelPage / keyPage` 三套通道
- **Flutter 现状**：❌ **完全缺失**
  - 无音量键监听（`grep VolumeKey/RawKeyboard/HardwareKeyboard` 0 命中）
  - 无可配置点击区域：reader_page 内的 `_toggleControls` 是单一中央点击切换 menu，无方向感知
  - 无物理键自定义（PageUp/Down/Space）
- **工作量**：M（点击区域 = 5 区 GestureDetector 改造，音量键 = `flutter_volume_controller` 或 platform channel）

### 1.9 书签

- **原项目**：
  - `data/entities/Bookmark.kt`：time(主键) / bookName / bookAuthor / chapterIndex / chapterPos(章内字符 offset) / chapterName / bookText(章节当前页内容片段) / content(用户笔记)
  - `ui/book/bookmark/AllBookmarkActivity.kt` 全书签清单页 + 搜索
  - `ui/book/bookmark/BookmarkDialog.kt` 编辑（content 文本框）
  - `ui/book/toc/BookmarkFragment.kt` 当前书的书签 Tab
  - 添加入口：长按文字 → TextActionMenu menu_bookmark；阅读菜单 → menu_add_bookmark
- **Flutter 现状**：🟡 **部分实现 — 仅"切换书签"按钮 + 章节级粒度**
  - Rust schema (`models.rs:116 Bookmark`)：id / book_id / chapter_index / paragraph_index / content / created_at — **缺 book_name / book_author / chapter_pos(字符 offset) / chapter_name / book_text(片段)**
  - `services/reader_bookmark_service.dart` 提供 list/add/remove
  - `reader_page.dart:1383 _toggleBookmark` 章节级，传入 paragraphIndex=0 + content=章节标题
  - **完全缺**：书签编辑（用户笔记 content）、字符级 offset、跨书全书签清单页、按当前页内容片段保存 bookText
- **工作量**：M（schema 加字段 + 编辑对话框 + 全书签 Activity）

### 1.10 阅读进度（章节 + 章内字符 offset）

- **原项目**：
  - `Book.kt:96-102 durChapterIndex / durChapterPos / durChapterTime / durChapterTitle` 写入 books 表
  - `data/entities/BookProgress.kt` (data class，仅做同步通讯)
  - `model/ReadBook.kt:211 saveCurrentBookProgress / 901 saveRead` 进度保存
  - `ReadBook.kt:240 syncBookProgress` 远端覆盖确认 (cover_progress menu)
- **Flutter 现状**：🟡 **部分实现 — schema 分离了 books/book_progress 两表**
  - Rust：`book_progress` 表 PK=`book_id`，含 chapter_index / paragraph_index / offset / read_time / updated_at
  - 但 `books` 表（`models.rs:61`）**没有 dur_chapter_index / dur_chapter_pos / dur_chapter_title / dur_chapter_time** —— 与原 Legado 不一致；导出 / 导入 / 数据迁移会丢
  - `reader_progress_service.dart`: chapter_index + offset + paragraphIndex 三字段，offset 字符级 ✅
  - **缺**：dur_chapter_title / dur_chapter_time 字段（用于书架"上次阅读时间"显示与排序）
- **工作量**：S（books 表加 4 个 dur_* 字段 + 写入逻辑）

### 1.11 章节列表 / 跳章

- **原项目**：
  - `ui/book/toc/TocActivity.kt` 独立 Activity，2 Tab（目录 + 书签）
  - `ChapterListAdapter.kt` 含搜索框；当前章节高亮
  - 卷宗（Volume）支持：`Chapter.isVolume` 字段，目录显示分组
- **Flutter 现状**：🟡 **部分实现**
  - `_showDirectorySheet` (reader_page.dart:1458) 是底部 sheet，2 Tab（目录 + 书签）
  - 目录列表无搜索；卷宗：Rust `Chapter.is_volume` 字段存在但 UI 不区分显示
- **工作量**：S（目录搜索框 + 卷宗分组样式）

### 1.12 章内搜索

- **原项目**：
  - `SearchMenu.kt` 全章搜索 +`ReadBookViewModel.kt:423 searchResultPositions` 在已加载章节中搜索 + 跳转命中位置（`SearchResult.indexInChapter` 字符 offset）
  - 高亮当前命中段；上一/下一/退出
- **Flutter 现状**：🟡 **部分实现**
  - `state/reader_search_controller.dart` 段落级搜索（章节 × 段落，`indexOf` 大小写不敏感）
  - **缺**：字符级 offset 跳转、命中段落内的 highlight span 着色（仅滚到段落，无字符级红框）
- **工作量**：M（段内字符 offset + RichText highlight span）

### 1.13 内容替换规则

- **原项目**：
  - `data/entities/ReplaceRule.kt` 字段：name / pattern (regex) / replacement / scope(书源 url 子串) / scopeTitle / scopeContent / excludeScope / isRegex / sortNumber / enabled
  - `help/ReplaceAnalyzer.kt` + `model/ContentProcessor.kt` 应用规则
  - `ui/replace/` 完整 ReplaceRuleActivity / EditActivity / ImportActivity
  - 章节读入时按 book.name / book.origin 匹配 scope 子串
- **Flutter 现状**：✅ **完全实现（schema 已对齐 R24）**
  - Rust `ReplaceRule` (`models.rs:134`) 字段对齐：scope / scope_title / scope_content / exclude_scope / sort_number
  - `replace_rule_dao.rs` (180 行) + bridge api `apply_replace_rules` (line 910)
  - Flutter `replace_rule_page.dart` 439 行（CRUD + 启用 + 编辑）
  - `reader_page.dart:439 _applyReplaceRulesViaRust` 调用 Rust 应用规则
- **工作量**：— (已完成)

### 1.14 复制 / 分享 / 字典 / 翻译

- **原项目** (`menu/content_select_action.xml` + `TextActionMenu.kt`)：
  - menu_replace（替换规则编辑）/ menu_copy / menu_bookmark / menu_aloud / menu_dict / menu_search_content / menu_browser / menu_share_str
  - DictRule (`data/entities/DictRule.kt` + `dao/DictRuleDao.kt`) 用户自定义查词规则
- **Flutter 现状**：❌ **完全缺失 — 没有长按选区菜单**
  - 全仓 `grep TextActionMenu/onLongPress` 在 reader 内 0 命中
  - 文字是 `Text` widget 渲染（`page/text_page.dart`），不是 `SelectableText`，无法选区
  - 没有 dict / dictionary / translate / browser 关键词在 reader 模块
- **工作量**：L（SelectableText 改造 + 自定义 ContextMenu + dict 规则系统 + 6 个动作处理器）

### 1.15 切换书源（章节级 / 整书级）

- **原项目**：
  - `ui/book/changesource/ChangeBookSourceDialog.kt` 整书换源（搜索同名书 → 替换 book.bookUrl + tocUrl + chapter list）
  - `ChangeChapterSourceDialog.kt` 单章换源（同名章节 → 替换章节内容）
  - `ReadBookViewModel.kt:270 changeTo / 293 autoChangeSource`
- **Flutter 现状**：🟡 **部分实现 — 整书换源 only**
  - `change_source_dialog.dart` (447 行) 整书换源：并发搜索所有书源 → 选源 → 加载 toc
  - **缺**：单章换源（用户当前章节读不出来时只换该章节内容来源）
- **工作量**：M（章节级换源对话框 + 替换 chapter content 流程）

### 1.16 屏幕方向 / 全屏 / 沉浸式

- **原项目**：
  - `BaseReadBookActivity.kt:148 setOrientation()` 5 模式 (跟随系统/竖/横/感应/反向)
  - `BaseReadBookActivity.kt:161 upSystemUiVisibility` 状态栏/导航栏隐藏
  - `pref_config_read.xml` 包含 `hideStatusBar` / `hideNavigationBar` / `readBodyToLh` / `paddingDisplayCutouts` 全屏 + 刘海适配
- **Flutter 现状**：❌ **完全缺失**
  - 没有 `SystemChrome.setPreferredOrientations` 调用
  - 没有 `SystemUiMode.immersive` 调用
  - `reader_page.dart:1683` 仅设状态栏图标颜色
- **工作量**：M（屏幕方向 5 选项 + 沉浸式 / 全屏 / 刘海 4 个开关）

### 1.17 鼠标滚轮翻页

- **原项目**：`ReadBookActivity.kt:662 onGenericMotionEvent` 监听 SOURCE_CLASS_POINTER + AXIS_VSCROLL → mouseWheelPage
- **Flutter 现状**：❌ 缺失（移动端较少用，桌面端会有体感差异）
- **工作量**：S

### 1.18 长截图（连续滚动截图）

- **原项目**：`ReadBookActivity.kt:816 onLongScreenshotTouchEvent`，`ContentTextView.kt` 大量长截图绘制逻辑
- **Flutter 现状**：❌ 缺失
- **工作量**：M

### 1.19 章节内容编辑（在线书籍）

- **原项目**：`ContentEditDialog.kt` 直接修改当前章节正文并入库（绕过书源 rule）
- **Flutter 现状**：❌ 缺失（reader 顶栏菜单只有"刷新"无"编辑内容"）
- **工作量**：S

### 1.20 章节倒序（阅读方向）

- **原项目**：`ReadBookViewModel.kt:406 reverseContent` (倒置整本章节顺序)；菜单 menu_reverse_content
- **Flutter 现状**：❌ 缺失
- **工作量**：S

### 1.21 同标题去重 / 重新分段

- **原项目**：`menu_same_title_removed` + `menu_re_segment` 配合 `ContentProcessor`
- **Flutter 现状**：❌ 缺失
- **工作量**：S

### 1.22 EPUB 标签处理（删除 ruby/h-tag）

- **原项目**：`menu_del_ruby_tag` / `menu_del_h_tag` (`ReadBookActivity.kt:540-560`)
- **Flutter 现状**：🟡 部分（Rust `core-parser/epub.rs` 解析 EPUB，但没有 ruby/h tag 删除选项暴露给 UI）
- **工作量**：S

### 1.23 漫画模式 / 图片模式

- **原项目**：`MangaMenu.kt` + `Book.kt:386-389 imgStyleDefault/Full/Text/Single` 图片样式
- **Flutter 现状**：❌ 完全缺失
- **工作量**：L

### 1.24 字符集设置

- **原项目**：`BaseReadBookActivity.kt:346 showCharsetConfig` (本地 txt/epub 编码切换 utf-8/gbk/big5)
- **Flutter 现状**：❌ 缺失（grep "encoding\|charset\|gbk" reader 0 命中）
- **工作量**：S

### 1.25 阅读提示信息（顶/底栏 6 槽位文字）

- **原项目**：`config/TipConfigDialog.kt` 6 槽位（左上/中上/右上 × 左下/中下/右下）每槽可选：无/章节/书名/时间/进度/电池/页码 ...
- **Flutter 现状**：🟡 部分（仅 4 个布尔：showReadingInfo / showChapterTitle / showClock / showProgress 全开关）
- **工作量**：M

### 1.26 模拟翻书 / 翻页测试

- **原项目**：`BaseReadBookActivity.kt:290 showSimulatedReading` (menu_simulated_reading)
- **Flutter 现状**：❌ 缺失（开发者向功能可放最低优先）
- **工作量**：S

### 1.27 失效替换规则查看

- **原项目**：`EffectiveReplacesDialog.kt` 显示当前章节实际命中的替换规则
- **Flutter 现状**：❌ 缺失
- **工作量**：S

---

## 2. Bookshelf 书架

### 2.1 列表 / 网格 / 卡片视图

- **原项目**：
  - `style1/BookshelfFragment1.kt` (Tab 风格按分组切换) + `style2/BookshelfFragment2.kt` (单页搜索)
  - `style2/BooksAdapterGrid.kt` + `BooksAdapterList.kt` 双布局
  - `pref_main.xml` `bookshelfLayout` (0/1/2 列表/网格/卡片) + `bookshelfStyle` (0/1)
- **Flutter 现状**：🟡 **部分**
  - `bookshelf_page.dart` 仅"列表 / 网格"双切换（顶栏 IconButton），无"卡片"
  - 没有 style1 多 Tab 分组切换
  - `_isGridView` 用 `loadBookshelfGridViewFromDisk` 持久化
- **工作量**：S（"卡片"布局新增）

### 2.2 书籍分组

- **原项目**：
  - `data/entities/BookGroup.kt`：groupId(主键，bitmask 设计) / groupName / cover / order / enableRefresh / show / bookSort
  - `BookGroup.IdAll/IdLocal/IdAudio/IdNetNone/IdLocalNone` 5 个特殊分组（位掩码）
  - `ui/book/group/GroupManageDialog.kt` + `GroupEditDialog.kt` + `GroupSelectDialog.kt`
  - `Book.kt:77 group: Long` (位与计算属于哪几个组)
  - DAO `BookGroupDao.kt` + 8 个 `flowGroup*` 查询
- **Flutter 现状**：❌ **完全缺失**
  - Rust `models.rs` 没有 BookGroup struct；schema 没有 book_groups 表
  - Book struct 没有 group 字段
  - bookshelf_page.dart 平铺所有书，无分组 Tab/UI
- **工作量**：L（schema 加 book_groups 表 + Book.group 字段 + 完整分组对话框 3 套 + Tab UI）

### 2.3 排序（手动 / 时间 / 名称 / 阅读时间）

- **原项目**：
  - `BookSourceSort.kt` enum + `AppConfig.bookshelfSort` (0/1/2/3 ...)
  - 排序：默认 / 名称 / 作者 / 加入时间 / 上次阅读 / 章节数 / 自定义 order
  - `BookGroup.bookSort` 每分组独立排序
- **Flutter 现状**：❌ **完全缺失**
  - bookshelf_page.dart 无排序按钮，按 Rust `getAllBooks` 默认顺序展示
  - Rust `book_dao.rs:get_all_books` 没有 ORDER BY 参数化
- **工作量**：M（排序选择菜单 + Rust DAO 加 sort 参数）

### 2.4 长按菜单 — 删除 / 移动分组 / 编辑信息 / 缓存

- **原项目**：`style2/BookshelfFragment2.kt:221 onItemLongClick` → `BookInfoEditActivity` / `GroupSelectDialog` / 删除 / 缓存
- **Flutter 现状**：🟡 **仅"删除"**
  - `bookshelf_page.dart:73 onLongPress: _deleteBook` 仅一项确认对话
  - **缺**：移动分组、编辑书名/作者/分类/封面、批量缓存
- **工作量**：M（多动作底栏 + 编辑书信息页）

### 2.5 自定义封面 / 网络封面 / 默认封面

- **原项目**：
  - `Book.kt:65 customCoverUrl: String?`（用户自定义封面 URL）
  - `BookCover.kt` 加载逻辑：customCoverUrl → coverUrl → defaultCover
  - `BookInfoEditActivity` 选本地图片 → 复制到 cache → 写 customCoverUrl
- **Flutter 现状**：🟡 **部分**
  - `models.rs:80 custom_cover_path` 字段存在
  - `bookshelf_page.dart:149 _buildCover`：先读 custom_cover_path 文件，否则 CachedNetworkImage(coverUrl)，再否则灰底图标
  - **缺**：UI 入口设置 custom_cover_path（书架上没有"换封面"动作）；`upDefaultCover` 自定义默认封面规则；`searchCover` 自动搜索封面
- **工作量**：S（书信息编辑里加封面选择项）

### 2.6 阅读时长 / 上次阅读时间显示

- **原项目**：
  - `Book.kt:102 durChapterTime: Long`（上次阅读时间，写入书架右下角）
  - `data/entities/ReadRecord.kt` (deviceId+bookName 联合主键，readTime / lastRead)
  - `BookshelfFragment2.kt` BooksAdapterList 副标题显示"已读 3h / 上次 2h 前"
- **Flutter 现状**：❌ **完全缺失**
  - Rust `Book` 无 dur_chapter_time；`book_progress.read_time` 字段存在但书架 UI 没用
  - `models.rs` 没有 ReadRecord struct，无 read_records 表
- **工作量**：M（schema 加表 + 累计时长 ticker + UI 显示）

### 2.7 书籍信息编辑

- **原项目**：`ui/book/info/edit/BookInfoEditActivity.kt`（书名、作者、分类、简介、封面 5 字段编辑）
- **Flutter 现状**：❌ **完全缺失**
  - 没有书信息编辑页
  - Rust `book_dao.rs` 有 update 但 Flutter 端没调用 UI
- **工作量**：S（一个新 page）

### 2.8 离线缓存（章节批量下载）

- **原项目**：
  - `BaseReadBookActivity.kt:266 showDownloadDialog` 选起始/结束章节 → 进入 `service/CacheBookService.kt`
  - 通知栏进度 + 后台 service
- **Flutter 现状**：🟡 **部分**
  - `core/download_runner.dart` 存在
  - `features/download/download_page.dart` (164 行) 显示任务列表
  - Rust `download_dao.rs` (307 行) 完整任务/章节表
  - **缺**：reader 顶栏"缓存"按钮 (`_startDownload`) 后续 — 需确认是否能选范围
- **工作量**：S（如已基本覆盖只需补 UX）

### 2.9 添加书籍方式

- **原项目** (`main_bookshelf.xml`)：
  - menu_add_local（本地导入 txt/epub/umd/mobi）
  - menu_remote（WebDAV 远端书库）
  - menu_add_url（粘 URL 添加）
  - menu_search 搜索添加
  - menu_import_bookshelf（导入书架 json）
- **Flutter 现状**：❌ **多数缺失**
  - 没有"添加本地书"按钮（虽然 `core-parser/{epub,txt,umd}.rs` 解析器存在）
  - 没有 URL 添加书
  - 没有 WebDAV 远端
  - 仅"搜索 → 加书"路径（`features/search/search_page.dart` 918 行）
- **工作量**：M（本地导入入口 + URL 加书 dialog）

### 2.10 书籍更新（toc 刷新）

- **原项目**：`menu_update_toc` 全量刷新所有书的目录（找到新章节）
- **Flutter 现状**：❌ 缺失（书架顶栏没有刷新按钮）
- **工作量**：S

### 2.11 书架管理 / 书架导入导出

- **原项目**：menu_bookshelf_manage / menu_export_bookshelf / menu_import_bookshelf；`BookshelfViewModel.kt:102 exportBookshelf`
- **Flutter 现状**：❌ 缺失
- **工作量**：S

---

## 3. 阅读进度 / 书签 / 阅读记录


### 3.1 进度恢复粒度

- **原项目**：
  - `Book.kt:96-102 durChapterIndex / durChapterPos / durChapterTime / durChapterTitle`（章节 index + 章内字符 offset，精确字符级恢复）
  - 段落级粒度也支持：`TextChapter.getPageByReadPos(readPos)`
- **Flutter 现状**：🟡 **三粒度都有但 books 表字段不齐**
  - Rust `book_progress` 表：chapter_index ✅ / paragraph_index ✅ / offset ✅（字符级）
  - **缺**：dur_chapter_title（书架"上次阅读章节"显示）+ dur_chapter_time（书架排序"按上次阅读"）
  - 恢复时机：`reader_progress_service.dart:55 load`，但 `_consumeRestoreCharOffsetIfNeeded` (reader_page.dart:1983) 显示恢复路径还在迭代
- **工作量**：S（books 表 schema + dao + UI 显示）

### 3.2 跨设备进度同步（WebDAV / 服务器）

- **原项目**：
  - `help/AppWebDav.kt`：upConfig / restoreWebDav / backUpWebDav / **uploadBookProgress / getBookProgress / downloadAllBookProgress**
  - 进度文件路径 `${webDavUrl}/legado/bookProgress/${bookName}_${author}.json`
  - `ReadBook.kt:237 uploadProgress` + `ReadBook.kt:253 syncProgress` 自动 / 手动同步
  - menu_get_progress (取远端进度) / menu_cover_progress (覆盖远端进度)
- **Flutter 现状**：❌ **完全缺失**
  - 全仓 `grep WebDav/webdav/dio_webdav` 0 命中
  - Rust `core-net/` 仅 client/cookie/downloader/encoding/proxy/retry，无 webdav 客户端
- **工作量**：L（WebDAV 客户端 + 自动 / 手动同步 UI + 冲突处理）

### 3.3 书签增删改查 + 同步

- **原项目**：
  - DAO `BookmarkDao.kt` 完整 CRUD
  - `AllBookmarkActivity.kt` 跨书全书签查询（按时间 / 按书）+ 搜索
  - `BookmarkDialog.kt` 编辑 content 字段（用户笔记）
  - WebDAV 同步：`AppWebDav` 备份/恢复时一并打包
- **Flutter 现状**：🟡 **基本 CRUD，无同步无编辑**
  - bridge api 有 get/add/delete，无 update（`api.rs:283 add_bookmark / 299 delete_bookmark` only）
  - reader 内 `_buildBookmarkTab` 显示当前书的书签，**无编辑笔记功能**
  - 无 AllBookmark 页（路由 `/bookmarks` 不存在）
  - 无同步
- **工作量**：M（编辑书签笔记对话框 + 全书签页 + Rust update_bookmark）

### 3.4 阅读时长统计 / 阅读记录看板

- **原项目**：
  - `data/entities/ReadRecord.kt` + `data/entities/ReadRecordShow.kt`
  - `data/dao/ReadRecordDao.kt`
  - `app/src/main/res/menu/book_read_record.xml` 阅读记录入口
  - `ReadBook.kt:285 upReadTime` 每秒累计 + `ReadRecordDao.insert`
  - 看板显示：每本书阅读时长、最后阅读时间；总时长统计；按周 / 月图表（部分版本）
- **Flutter 现状**：❌ **完全缺失**
  - Rust 无 ReadRecord struct / read_records 表
  - `book_progress.read_time` 字段存在但 reader 没写入逻辑（grep 仅 schema 定义）
  - 无看板页
- **工作量**：M（schema 加表 + ticker 累计 + 看板页）

### 3.5 远程进度同步（与他人共享 / 多设备同步）

- **原项目**：通过 WebDAV，多设备登录同一 WebDAV 即同步
- **Flutter 现状**：❌ 缺失（依赖 3.2 实现）
- **工作量**：— (等 3.2)

---

## 4. 书源管理 / 书源登录

### 4.1 书源 CRUD

- **原项目**：`ui/book/source/manage/BookSourceActivity.kt` (780 行) + `edit/BookSourceEditActivity.kt`（按 6 个 tab 编辑：source / search / explore / info / toc / content）
- **Flutter 现状**：🟡 **部分 — 仅"添加 name+url"和删除**
  - `source_page.dart:150 _showAddSourceDialog` 只填 name + url，无规则编辑界面
  - 无规则编辑：searchUrl / ruleSearch / ruleBookInfo / ruleToc / ruleContent / ruleExplore 6 类规则用户无从配置
  - Rust `core-source/legado/rule.rs` 解析能力存在，但 UI 完全没暴露编辑
- **工作量**：L（一个完整的多 Tab 规则编辑页，每个 Rule 至少 5-10 字段 × 6 类规则）

### 4.2 书源导入（本地文件 / URL / QRCode）

- **原项目**：
  - `BookSourceActivity.kt:178 menu_import_local` 选 txt/json 文件
  - `menu_import_qr` 扫码（`qrResult` ActivityResult）
  - `menu_import_onLine` 输入 URL 在线导入
  - `OnLineImportActivity.kt` + `ImportBookSourceDialog.kt` 整套
- **Flutter 现状**：🟡 **部分**
  - 本地文件 ✅：`source_page.dart:404 _importFromFile`（FilePicker）
  - 粘贴 JSON ✅：`_showImportDialog`
  - **缺**：URL 导入（输入 URL 抓 json）、QRCode 扫码导入
- **工作量**：S（接 `mobile_scanner` 包 + 一个 URL 导入对话框）

### 4.3 书源校验 / 调试 / 排序 / 启用禁用

- **校验**：
  - 原项目：`model/CheckSource.kt` Service，多线程并发校验所有书源（搜索测试关键字 → 走 ruleSearch + ruleBookInfo + ruleToc + ruleContent 全链路）；`BookSourceActivity` 可单源/批量校验
  - Flutter：🟡 部分。`source_page.dart:298 _showValidateDialog` 调用 `validateSourceFromDb` (Rust)，校验**规则字段格式**而非实际抓取；不发起搜索测试
  - 工作量：M（接入实际 search 测试，复用 `search_with_source_from_db_v2`）
- **调试**：
  - 原项目：`ui/book/source/debug/BookSourceDebugActivity.kt` (含 `BookSourceDebugAdapter` 流式输出 log)；输入关键字逐步打印 search→info→toc→content 阶段日志
  - Flutter：❌ 完全缺失
  - 工作量：M
- **排序**：
  - 原项目 `BookSourceSort` enum 7 种（Default/Weight/Name/Url/Update/Respond/Enable）+ asc/desc
  - Flutter：❌ 无任何排序入口（按 Rust 默认顺序）
  - 工作量：S（顶栏菜单 + Rust DAO 加 ORDER BY）
- **启用禁用**：
  - 原项目：单源 + 批量启用/禁用（select_action_bar）
  - Flutter：✅ 单源 Switch + 批量删除 ✓，但**无批量启用/禁用**
  - 工作量：S

### 4.4 书源分组

- **原项目**：
  - `BookSource.bookSourceGroup: String?` (字段存在)
  - `manage/GroupManageDialog.kt` 分组管理对话
  - `BookSourceActivity` 顶栏 SearchView 支持 `group:xxx` 查询
  - 自动按域名聚合 (`groupSourcesByDomain`)
- **Flutter 现状**：❌ **完全缺失**
  - Rust `BookSource.group_name` 字段存在但 UI 不展示，不能编辑
  - source_page 没有按分组显示 / 切分组 / 按域名聚合
- **工作量**：M（分组 Tab + 编辑 + 自动聚合算法）

### 4.5 订阅源 RuleSub 自动更新

- **原项目**：
  - `data/entities/RuleSub.kt` + `RuleSubDao.kt`
  - 订阅源 = 一个 URL，定期自动拉取最新书源 json 列表合并入库
  - 配置入口：`pref_main.xml` 的"订阅源管理"
- **Flutter 现状**：❌ **完全缺失**
- **工作量**：M（数据表 + 定时任务 + 管理 UI）

### 4.6 书源登录（账号密码 / cookie / WebView 登录）

- **原项目**：
  - `BookSource` 字段：`loginUrl` / `loginUi`（json 表单 schema）/ `loginCheckJs`（登录后校验 JS）
  - `ui/login/SourceLoginActivity.kt` 路由：有 `loginUi` → `SourceLoginDialog` 表单登录；否则 → `WebViewLoginFragment` WebView 登录
  - `WebViewLoginFragment.kt:67 initWebView` 完整 webview，监听 cookies → 写 `data/entities/Cookie.kt` 表
  - `help/source/SourceVerificationHelp.kt` 校验码 / 二次验证
- **Flutter 现状**：❌ **完全缺失**
  - Rust `BookSource.login_url / login_ui / login_check_js` 字段存在
  - 但 Flutter UI 无任何 SourceLoginPage；`platform_webview_executor.dart` 是为执行 JS 用的，不是登录用
  - 无 cookie 持久化（Rust schema 没有 cookies 表）
  - `core-net/cookie.rs` 是 in-memory cookie，重启即丢
- **工作量**：L（SourceLoginPage + WebView 登录 + cookie 表 + 表单 schema 渲染 + verification dialog）

### 4.7 HTTP 替换规则 / Cookie / Header 自定义

- **原项目**：
  - `BookSource.header: String?` (json header)
  - `BookSource.concurrentRate: String?`（"3/1000" = 3 次/秒）
  - `data/entities/Cookie.kt` + `CookieDao.kt` 持久化
  - `help/http/` 完整 OkHttp 拦截器栈
- **Flutter 现状**：🟡 **基本支持**
  - Rust `BookSource.header / concurrent_rate` 字段都在
  - `core-net/client.rs` 应该在使用 header（未细查实现）
  - **缺**：cookie 持久化 (cookie.rs 是内存)，无 cookies 表
- **工作量**：S-M（cookies 表）

### 4.8 书源 JS 评估

- **原项目**：
  - `help/JsExtensions.kt` + `help/rhino/RhinoScriptEngine.kt`（Rhino JS 引擎）
  - `BookSource.jsLib: String?`（共享 JS 库代码）
  - 规则中 `<js>...</js>` 标签触发 JS 求值
  - 完整支持：encrypt / md5 / base64 / cache / DOM 操作 / 网络请求 / cookie 读写
- **Flutter 现状**：🟡 **部分 — Rust 自研 + WebView 兜底**
  - Rust `core-source/legado/js_runtime.rs` + `js_shim.rs`（自研 JS 引擎或 boa/quickjs 包装）
  - `flutter_app/lib/core/platform_webview_executor.dart` WebView 兜底执行
  - **缺**：JsExtensions 等价函数大部分（cache / cookie / debug / log / setTimeout / setInterval / md5 / sha256 / aes / base64 ...）
  - jsLib 作用域共享支持程度未明
- **工作量**：M-L（看 js_runtime 当前覆盖率，可能需补 30+ 个 JsExtensions）

### 4.9 自定义书源类型

- **原项目**：`BookSource.bookSourceType: Int` (0=文本, 1=音频, 2=图片, 3=漫画)
- **Flutter 现状**：🟡 字段存在 (`models.rs:15 source_type: i32`)，但 UI 不区分类型显示，**音频/图片/漫画类型 reader 流程未实现**（仅 text 路径走通）
- **工作量**：L（音频 = ExoPlayer 等价 + UI；漫画 = 图片 reader 模式）

### 4.10 RSS 源（Rss Source / Rss Article / Rss Star）

- **原项目**：完整模块：`ui/rss/article/` / `read/` / `favorites/` / `subscription/` / `source/`
- **Flutter 现状**：❌ **完全缺失**（项目定位是阅读 → 暂不上 RSS 也合理）
- **工作量**：L（如果要做）

### 4.11 字典规则 (DictRule)

- **原项目**：`data/entities/DictRule.kt` + `DictRuleDao.kt`，长按选词查词
- **Flutter 现状**：❌ 缺失（依赖 1.14 文字选区菜单）

### 4.12 TXT 目录规则 (TxtTocRule)

- **原项目**：`data/entities/TxtTocRule.kt` + `TxtTocRuleDao.kt`，本地 txt 章节切分正则
- **Flutter 现状**：❌ 缺失（影响 1.23 本地导入）

---

## 5. 数据存储层 schema 缺口（汇总）

下面列出 Rust `core-storage` 相对原 Legado Room 缺失或字段不对齐的部分（开发任何上述功能前的依赖路径）：

| 表/Entity | 状态 | 缺失字段 / 说明 |
|---|---|---|
| `book_groups` | ❌ 缺表 | 整张 BookGroup 表不存在 |
| `read_records` | ❌ 缺表 | ReadRecord (deviceId+bookName 联合主键) 不存在 |
| `cookies` | ❌ 缺表 | 持久化 Cookie 表不存在（仅内存） |
| `rule_subs` | ❌ 缺表 | 订阅源表不存在 |
| `dict_rules` | ❌ 缺表 | 词典规则表不存在 |
| `http_tts` | ❌ 缺表 | HTTP TTS 引擎规则表不存在 |
| `txt_toc_rules` | ❌ 缺表 | 本地 TXT 目录规则不存在 |
| `search_keywords` | ❌ 缺表 | 搜索历史不存在 |
| `rss_sources` / `rss_articles` / `rss_stars` | ❌ 缺表 | RSS 整套不存在 |
| `cache` | 🟡 仅 legacy_cache | 通用 KV cache 简化 |
| `books` | 🟡 字段缺失 | dur_chapter_index / dur_chapter_pos / dur_chapter_title / dur_chapter_time / origin / origin_name / type / **group** / custom_intro / custom_tag / custom_cover_url / charset / read_config / sync_time / variable / order / origin_order / can_update / lastest_chapter_time |
| `bookmarks` | 🟡 字段缺失 | book_name / book_author / chapter_pos (字符 offset) / chapter_name / book_text |
| `book_sources` | 🟡 字段缺失 | enabled_explore (有但与原版默认值差异) / weight / login_check_js (有) / cover_decode_js (有) / variable_comment (有) / explore_screen (有，但类型 i32 vs Kotlin String) / **respond_time / search_url / rule_review** |
| `chapters` | 🟡 字段缺失 | tag / variable / volume_name / vip / pay / start_fragment_id / end_fragment_id / book_url / use_replace_rule |

---

## 6. 优先级建议

按"对用户可见度 / 实现难度 / 依赖深度"三维评分（高=5/低=1）。

### Tier S — 关键缺口，强烈建议先做（影响日常使用）

1. **屏幕亮度调节 + 锁屏保持 (1.3 + 1.4)** — 工作量 S，体感差异极大；接 `screen_brightness` + `wakelock_plus` 即可
2. **音量键翻页 + 5 区点击区域 (1.8)** — 工作量 M，长篇阅读必需
3. **TTS 跨章自动续读 (1.7 部分)** — 工作量 S，当前到章节末就停
4. **书签编辑笔记 + 字符级 offset (1.9)** — 工作量 M，schema 字段补齐顺手做
5. **阅读时长统计 (3.4)** — 工作量 M，书架排序"上次阅读"靠它
6. **dur_chapter_* 4 字段补齐 (3.1 + 2.6)** — 工作量 S，书架"上次阅读章节"显示靠它

### Tier A — 重要但可分批

7. **书架分组 (2.2)** — 工作量 L，长期重度用户必需
8. **书架排序 (2.3)** — 工作量 M，依赖 dur_chapter_time
9. **书源完整规则编辑 (4.1)** — 工作量 L，进阶用户的刚需；目前只能粘 json 改不了规则
10. **书源登录 (4.6)** — 工作量 L，付费源 / VIP 源完全不可用
11. **WebDAV 多设备同步 (3.2)** — 工作量 L，多设备党刚需
12. **章节内长按文字菜单 (1.14)** — 工作量 L，触达 6 个高频动作（复制/分享/朗读/查词/搜索/翻译）
13. **书源调试模式 (4.3)** — 工作量 M，开发新书源刚需
14. **沉浸式 / 屏幕方向 / 全屏 (1.16)** — 工作量 M

### Tier B — 体验完整度

15. 字体选择 (1.5) S
16. 主题导入导出 (1.6) M
17. 自动翻页速度可调 + 分页模式生效 (1.2) M
18. 书源分组 + 按域名聚合 (4.4) M
19. 单章换源 (1.15) M
20. 章内搜索字符级 + 高亮 (1.12) M
21. 添加本地书 + URL 加书 (2.9) M
22. 章节列表搜索 + 卷宗分组 (1.11) S
23. 长按选词查词 — DictRule (4.11) M
24. 字符集设置 (1.24) S
25. 内容编辑 (1.19) S

### Tier C — 锦上添花 / 开发者向

26. 章节倒序 (1.20) S
27. 同标题去重 / 重新分段 (1.21) S
28. EPUB ruby/h-tag 删除 (1.22) S
29. 鼠标滚轮翻页 (1.17) S
30. 长截图 (1.18) M
31. 模拟翻书 (1.26) S
32. 失效替换规则查看 (1.27) S
33. 漫画模式 (1.23) L
34. RSS 整套 (4.10) L
35. HTTP TTS 引擎 (1.7 完整) L

---

## 7. 总结一句话

**Reader 阅读器**：翻页动画 / 替换规则 / 基本配色 / 滚动模式做得很好（已有专门的 follow-up 任务在打磨细节）；**长按文字、亮度、唤醒、音量键、自定义点击区、HTTP TTS、漫画、字典、字体、主题导入导出、屏幕方向 / 沉浸式**等周边功能仍是裸状态。

**Bookshelf 书架**：极度简化版，**完全没有分组 / 排序 / 阅读时长 / 书信息编辑 / 添加本地书 / 添加 URL / WebDAV** 等核心管理功能；几乎是 MVP 级别。

**进度·书签·阅读记录**：进度恢复粒度对了（章节+段落+字符），但 `books` 表 schema 缺 `dur_*` 字段；书签 schema 缺多个字段且无编辑笔记；**WebDAV 多设备同步、阅读时长统计完全缺失**。

**书源管理 / 书源登录**：导入 / 启用 / 删除 / 简单校验 OK；**完整规则编辑、调试模式、登录（含 WebView 登录 + Cookie 持久化）、订阅源、JS 引擎能力、分组 / 排序** 全部缺失或薄弱。

最大的"用户可见性 vs 工作量比"是 **Tier S 的 1-6 项**，约 1-3 周可全部交付，能从根本上改善日常体验。
