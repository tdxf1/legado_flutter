# Legado vs Flutter+Rust 端口 — 高级内容子系统差异调研报告

> **范围**：RSS / 漫画 / 听书音频 / 字典 / 订阅源 / 内置浏览器 / 文件管理 / 字体 / 二维码 / 关于 / 其他 helper
> **方法**：只读对比 `legado/` (原 Kotlin/Android) 与 `legado_flutter/` (Flutter + Rust)
> **生成时间**：2026-05-18
> **调研者**：read-only research，只用 cat / grep / ls / Read / Glob / Grep 工具
> **配套报告**：
> - `feature-gap-reader-bookshelf-source.md`（Reader / Bookshelf / Source）
> - `feature-gap-cache-service-web-backup.md`（Cache / Service / Web / Backup）
> - 本文件聚焦原项目 7+ 个**独立大模块**，是 Flutter 端基本未实现的"长尾功能"集合

---

## 0. 仓库总览（本次调研范围）

### 0.1 原项目相关代码量（Kotlin LOC）

| 子系统 | 关键路径 | 大致 LOC |
|---|---|---|
| RSS（5 个 UI 子模块 + Dao + model + entity） | `ui/rss/` `model/rss/` `data/entities/Rss*.kt` `data/dao/Rss*Dao.kt` | **~5000** |
| 漫画 Manga | `ui/book/manga/` (UI+config+recyclerview+entities) `model/ReadManga.kt` | **~3500** |
| 听书 / 音频播放 | `service/AudioPlayService.kt` `service/BaseReadAloudService.kt` `service/HttpReadAloudService.kt` `service/TTSReadAloudService.kt` `model/AudioPlay.kt` `model/ReadAloud.kt` `help/TTS.kt` `data/entities/HttpTTS.kt` `ui/book/audio/` | **~3500** |
| 字典 Dict | `ui/dict/` `data/entities/DictRule.kt` `data/dao/DictRuleDao.kt` | **~700** |
| 订阅源 RuleSub | `ui/rss/subscription/` `data/entities/RuleSub.kt` `data/dao/RuleSubDao.kt` | **~250** |
| 内置浏览器 | `ui/browser/WebViewActivity.kt` `ui/browser/WebViewModel.kt` | **~485** |
| 文件 / 字体 / QR / About | `ui/file/` `ui/font/` `ui/qrcode/` `ui/about/` | **~2000** |
| Helper（除前面三份报告外的剩余） | `help/JsExtensions.kt` `help/rhino/` `help/glide/` `help/exoplayer/` `help/CacheManager.kt` `help/TTS.kt` `help/storage/` `help/update/` `help/AppFreezeMonitor.kt` `help/DefaultData.kt` `help/DirectLinkUpload.kt` `help/RuleBigDataHelp.kt` `help/coroutine/` `lib/webdav/` `lib/aliyun/` | **~6000+** |

合计 **~21000 行 Kotlin** 几乎全部缺失。

### 0.2 Flutter 端现状（Dart LOC）

`flutter_app/lib/` 总计 **53 个 dart 文件**，与本次调研范围相关的命中：

```bash
grep -rli "rss|manga|comic|dict|subscript|browser|webview" lib/
# → 仅 4 处命中，其中 3 处是无关用语（subscript = 流订阅；browser/webview = WebView 调用）
# → search_page.dart / reader_page.dart / core/transport.dart / core/platform_webview_executor.dart
```

**真正实现了的**：

- `lib/features/reader/services/reader_tts_manager.dart` — 198 行，仅本地 `flutter_tts`
- `lib/core/notification_service.dart` — 通知服务（前台播放无关）
- `android/app/src/main/kotlin/.../MainActivity.kt` — `legado/webview_executor` MethodChannel（**仅供书源解析用**，非用户级浏览器）

### 0.3 Rust core 端预留情况

```rust
// core/core-storage/src/models.rs:15
pub source_type: i32, // 0=小说, 1=音频, 2=图片, 3=RSS

// core/core-source/src/types.rs:16  同样定义
// core/core-source/src/types.rs:181  ContentRule.download_urls — 仅注释提到 audio/file
```

- **没有** RssSource / RssArticle / RssStar / RssReadRecord / DictRule / RuleSub / HttpTTS 等任何 entity / DAO
- BookSource.source_type 字段已预留但**无 Rust 端代码消费它**（`core-source/src/parser.rs` `lib.rs` `legado/` 全无分支处理）
- `core-parser/` 只有 epub / txt / umd 三种 Book 解析器，无 RSS / 漫画图片专用解析器
- `core-source/src/legado/import.rs` 仅 BookSource 导入，未实现 RssSource / DictRule / HttpTTS 的导入

---

## 1. RSS 订阅子系统

### 1.1 RSS 源 CRUD + 分组 + 启用切换

- **原项目**：
  - `data/entities/RssSource.kt` (182 行) — 31 个字段：sourceUrl PK / sourceName / sourceIcon / sourceGroup / sourceComment / enabled / variableComment / jsLib / enabledCookieJar / concurrentRate / header / loginUrl / loginUi / loginCheckJs / coverDecodeJs / sortUrl / singleUrl / articleStyle / ruleArticles / ruleNextPage / ruleTitle / rulePubDate / ruleDescription / ruleImage / ruleLink / ruleContent / contentWhitelist / contentBlacklist / shouldOverrideUrlLoading / style / enableJs / loadWithBaseUrl / injectJs / lastUpdateTime / customOrder
  - `data/dao/RssSourceDao.kt`
  - `ui/rss/source/manage/RssSourceActivity.kt` + `RssSourceAdapter.kt` + `RssSourceViewModel.kt` + `GroupManageDialog.kt`
  - `ui/rss/source/edit/RssSourceEditActivity.kt` + `RssSourceEditAdapter.kt` + `RssSourceEditViewModel.kt`
  - `ui/rss/source/debug/RssSourceDebugActivity.kt` + `RssSourceDebugAdapter.kt` + `RssSourceDebugModel.kt`
  - `help/source/RssSourceExtensions.kt`
- **Flutter 现状**：❌ **完全缺失**
  - `lib/features/rss/` 目录不存在
  - rust core 端 entity / dao 全无
- **细节**：BookSource 已有完整端口，RssSource 走相似但独立的 schema（不能复用 BookSource 表）
- **复杂度**：**L**（一整套 CRUD + edit + debug，与 BookSource 同等量级，约 **15-25 工日**）

### 1.2 RSS 源导入（QR / URL / Local file / Subscription）

- **原项目**：
  - `ui/association/ImportRssSourceDialog.kt` + `ImportRssSourceViewModel.kt`
  - `ui/association/OnLineImportActivity.kt` 走 `legado://import/rssSource?src=...` 协议
  - `model/Debug.kt` debug 输出
- **Flutter 现状**：❌ **完全缺失**
- **复杂度**：**M**（参考已有 BookSource 导入流程）

### 1.3 文章列表 / 分类 Tab

- **原项目**：
  - `ui/rss/article/RssSortActivity.kt` — Tab + ViewPager2（多个 sortUrl）
  - `ui/rss/article/RssArticlesFragment.kt` + `RssArticlesViewModel.kt` + `RssArticlesAdapter.kt`（3 种 layout：默认 / Adapter1 / Adapter2，对应 `articleStyle: 0/1/2`）
  - `ui/rss/article/BaseRssArticlesAdapter.kt`
- **Flutter 现状**：❌ **完全缺失**
- **复杂度**：**L**（包含拉取、分页、3 种列表样式）

### 1.4 文章详情阅读（WebView 渲染）

- **原项目**：
  - `ui/rss/read/ReadRssActivity.kt` (含 WebView + JS Interface + addJavascriptInterface) + `ReadRssViewModel.kt` + `RssJsExtensions.kt` + `VisibleWebView.kt`
  - 支持 `injectJs` / `style` / `enableJs` / `loadWithBaseUrl` / `shouldOverrideUrlLoading` 等高级配置
- **Flutter 现状**：❌ **完全缺失**
  - 现有 `webview_flutter: ^4.8.0` 依赖（pubspec.yaml）但仅供 `core/platform_webview_executor.dart` 走书源 webJs 解析使用
- **复杂度**：**L**（WebView + JS Bridge + 自定义 JS 注入 + 链接拦截）

### 1.5 文章收藏（RssStar）

- **原项目**：
  - `data/entities/RssStar.kt` (49 行) + `data/dao/RssStarDao.kt`
  - `ui/rss/favorites/RssFavoritesActivity.kt` + `RssFavoritesAdapter.kt` + `RssFavoritesDialog.kt` + `RssFavoritesFragment.kt` + `RssFavoritesViewModel.kt`
  - `RssArticle.toStar()` 转换函数
- **Flutter 现状**：❌ **完全缺失**
- **复杂度**：**M**

### 1.6 文章已读标记 / 阅读记录

- **原项目**：
  - `data/entities/RssReadRecord.kt` (12 行) + `data/dao/RssReadRecordDao.kt`
  - `ui/rss/article/ReadRecordDialog.kt`
  - SQL 已读 left join：`flowByOriginSort` 联表 `rssReadRecords`
- **Flutter 现状**：❌
- **复杂度**：**S**（数据层简单）

### 1.7 RSS 拉取 / 解析

- **原项目**：
  - `model/rss/Rss.kt` (102 行) — 入口对象，提供 `getArticles` / `getContent`
  - `model/rss/RssParserDefault.kt` (149 行) — 标准 RSS 2.0 / Atom XML 解析
  - `model/rss/RssParserByRule.kt` (131 行) — 按规则解析（用 `AnalyzeRule` + `AnalyzeUrl`）
  - 自动通过 `singleUrl` 区分单 URL 模式 / 多分类模式
- **Flutter 现状**：❌
  - rust 端 `core-parser/src/` 无 rss.rs；`core-source/src/parser.rs` 仅 BookSource 的搜索 / 详情 / 章节 / 内容
- **复杂度**：**L**（XML 解析 + 规则解析 + 与 AnalyzeRule 整合）

### 1.8 RSS 数据本地清理

- **原项目**：`help/RuleBigDataHelp.kt` 同时清理 `ruleData/book/` 和 `ruleData/rss/` 子目录
- **Flutter 现状**：❌

### RSS 子系统小结

| 模块 | 复杂度 | 优先级 | 用户感知 |
|---|---|---|---|
| 源 CRUD | L | 中 | 低 — 装机用户不一定用 RSS |
| 源导入 | M | 中 | 低 |
| 文章列表 | L | 中 | 低 |
| 文章详情 WebView | L | 中 | 低 |
| 收藏 | M | 低 | 低 |
| 已读 | S | 低 | 低 |
| 解析器 | L | 中 | 低（依赖项） |

**RSS 整体属于"小众但功能闭环复杂"的子系统**，原项目用户里只有少数高阶用户用。先做不做都不影响主流阅读体验。

---

## 2. 漫画阅读 Manga

### 2.1 漫画书源标识 / 类型路由

- **原项目**：
  - `Book.type` bit flag 中 `BookType.image = 1 shl 1` 标记漫画
  - `BookType.kt` 还有 `audio = 1 shl 0` 标记音频
  - 进入阅读时根据 `book.isImage`/`book.isAudio` 路由到 `ReadMangaActivity` / `AudioPlayActivity` / `ReadBookActivity`
- **Flutter 现状**：❌ **完全缺失**
  - `core-storage/src/models.rs` Book struct 没有 type 字段，没有任何 bit-flag 路由
  - flutter `bookshelf_page.dart` 唯一路由就是 `reader_page.dart`，从来不分小说/漫画/音频
- **复杂度**：**S**（添加 type 字段 + 路由分支）

### 2.2 漫画阅读 UI（Webtoon RecyclerView + 缩放 + 长按）

- **原项目**：
  - `ui/book/manga/ReadMangaActivity.kt` (855 行)
  - `ui/book/manga/ReadMangaViewModel.kt` (297 行)
  - `ui/book/manga/recyclerview/`：
    - `MangaAdapter.kt` — Glide 加载图片
    - `MangaLayoutManager.kt` — `LinearLayoutManager` 加 `extraLayoutSpace = 屏幕高 * 3/4` 增强预加载
    - `MangaVH.kt`
    - `ScrollTimer.kt` — 自动滚动
    - `WebtoonRecyclerView.kt` — 双指缩放 / 单指拖动 / 双击放大 / 长按 / 嵌套滑动；`zoom(fromRate, toRate, fromX, toX, fromY, toY)` `currentScale` `disableMangaScale` 等
    - `WebtoonFrame.kt`
    - `GestureDetectorWithLongTap.kt` — 长按手势
  - `ui/book/manga/entities/`：
    - `BaseMangaPage.kt` / `MangaChapter.kt` / `MangaContent.kt` / `MangaPage.kt` / `ReaderLoading.kt`
    - `EpaperTransformation.kt` / `GrayscaleTransformation.kt` — Glide Transformation（电子纸效果 / 灰度）
  - `ui/book/manga/config/`：
    - `MangaColorFilterConfig.kt` / `MangaColorFilterDialog.kt` — RGB 颜色滤镜
    - `MangaEpaperDialog.kt` — 电子纸模式
    - `MangaFooterConfig.kt` / `MangaFooterSettingDialog.kt` — 底部信息栏配置
- **Flutter 现状**：❌ **完全缺失**
  - 没有任何 manga 相关 widget；reader 完全是文本 + 翻页
- **复杂度**：**XL**（Webtoon 滚动 + 缩放手势 + 颜色滤镜 + 电子纸 + 底栏 + 章节连续滚动 + Glide 替代品 = 需用 `photo_view` / `extended_image` / 自定义手势）

### 2.3 ReadManga model（章节加载 / 预下载 / 限流）

- **原项目**：
  - `model/ReadManga.kt` (639 行) — 三章节窗口（prevMangaChapter / curMangaChapter / nextMangaChapter）+ `preDownloadSemaphore = Semaphore(2)` + `ConcurrentRateLimiter` + `downloadedChapters` / `downloadFailChapters` 双 set
  - `simulatedChapterSize` 与 `simulatedTotalChapterNum` 联动（滞后章节模拟）
  - 用 `globalExecutor` 调度
- **Flutter 现状**：❌
- **复杂度**：**L**（reader 现有"三章节窗口"在文本场景已有，但漫画的图片预加载语义不同）

### 2.4 漫画图片网络加载 / 缓存

- **原项目**：用 Glide + `OkHttpModelLoader` + `LegadoDataUrlLoader` + `OkHttpStreamFetcher` + `GlideHeaders`，统一从书源 cookie / header 拉图
- **Flutter 现状**：❌
  - 已有 `cached_network_image: ^3.4.0` 但不带 cookie / header / 限流
- **复杂度**：**M**（接入 dio + 自定义 ImageProvider + 复用现有 cookie store）

### 2.5 漫画手势（双指缩放 / 双击 / 长按 / 翻页）

- **原项目**：`WebtoonRecyclerView` 自定义 `Detector` + `GestureListener`，含 `doubleTapZoom` `tapListener` `longTapListener`
- **Flutter 现状**：❌
- **复杂度**：**M**（用 `InteractiveViewer` + `GestureDetector` 组合，但要正确处理嵌套滚动）

### Manga 子系统小结

| 模块 | 复杂度 | 优先级 | 用户感知 |
|---|---|---|---|
| 类型路由 | S | 高 | 高（不做漫画用户没法看） |
| Webtoon UI | XL | 高 | 高 |
| ReadManga model | L | 高 | 中（直接影响流畅度） |
| 图片缓存 | M | 高 | 中 |
| 手势缩放 | M | 中 | 高 |
| 颜色滤镜 / 电子纸 | M | 低 | 低（高阶玩家） |
| 底栏配置 | S | 低 | 低 |

**Manga 是日常会用到的子系统**：很多人用 legado 装漫画书源看本子或追漫画。Flutter 端目前**完全无法显示任何漫画书**，是一个明显阻塞的功能缺口。

---

## 3. 听书 / 音频播放子系统

### 3.1 系统 TTS（Android TextToSpeech）

- **原项目**：
  - `service/TTSReadAloudService.kt` (265 行) — 继承 `BaseReadAloudService` + Android 系统 TTS
  - `help/TTS.kt` (144 行) — `TextToSpeech` 包装类，含 `InitListener` / `TTSUtteranceListener` / `clearTtsRunnable` 释放策略
- **Flutter 现状**：🟡 **部分实现**
  - `lib/features/reader/services/reader_tts_manager.dart` (198 行) — 用 `flutter_tts` 包，仅前台播放
  - 不分段（按 `\n+` split）、无 `UtteranceProgressListener` 句子级进度回调（包内做了 completion handler 但简陋）、无音色 / pitch 配置
  - **不持久化播放状态**（应用切走 / TTS 暂停后无法 resume 到精确字符）
- **细节**：
  - Flutter 版可用度：把章节朗读完后能跨章；但远没达到原项目那种长期稳定后台播放的水平
  - Flutter 版用 widget 持有 manager，应用一关 TTS 立刻停
- **复杂度**：**M**（接入 audio_service 包 + 后台 service + 句子级进度回调）

### 3.2 HTTP TTS（自定义引擎，POST URL）

- **原项目**：
  - `service/HttpReadAloudService.kt` (617 行) — 用 ExoPlayer 流式播放、`InputStreamDataSource`、缓存（`MD5Utils.md5Encode16` 命名）、`Channel` + `Mutex` 并发控制
  - `data/entities/HttpTTS.kt` (84 行) — id / name / url / contentType / concurrentRate / header / loginUrl / loginUi / loginCheckJs / jsLib / enabledCookieJar / lastUpdateTime
  - `data/dao/HttpTTSDao.kt`
  - `model/ReadAloud.kt` (137 行) — 引擎切换：`ttsEngine.isNullOrBlank()` 用系统 TTS，否则查 `httpTTSDao.get(id)` 用 HTTP TTS
  - `ui/association/ImportHttpTtsDialog.kt` + `ImportHttpTtsViewModel.kt`
  - `help/DefaultData.kt` — 启动时从 `defaultData/httpTTS.json` 导入默认 HTTP TTS 引擎
- **Flutter 现状**：❌ **完全缺失**
  - rust core 端无 HttpTTS entity / dao；flutter 端 reader_tts_manager 不支持自定义 URL
- **复杂度**：**L**（HTTP TTS 数据模型 + 导入 + ExoPlayer 等价方案 + 按段缓存 + 并发限流）

### 3.3 音频书播放（mp3 / m4a 在线流）

- **原项目**：
  - `service/AudioPlayService.kt` (658 行) — ExoPlayer + `MediaSessionCompat` + 音频焦点 + WiFi/PowerLock + 通知栏控制 + 锁屏控制
  - `model/AudioPlay.kt` (433 行) — 章节调度 / `loadOrUpPlayUrl` / 4 种 PlayMode（LIST_END_STOP / SINGLE_LOOP / RANDOM / LIST_LOOP）/ `setTimer` / `addTimer` / `adjustSpeed`
  - `ui/book/audio/AudioPlayActivity.kt` (313 行) — UI（播放/暂停/进度条/速度调节）
  - `ui/book/audio/TimerSliderPopup.kt` — 倒计时滑块（0-180 分钟）
- **Flutter 现状**：❌ **完全缺失**
  - 无 `audio_service` / `just_audio` / `audioplayers` 依赖
  - bookshelf 没有"音频书"识别，audio 类型 BookSource 在 Flutter 端无法 expose 给用户播放
- **复杂度**：**XL**（前台 service + ExoPlayer 等价 + 通知栏 + 锁屏 + 音频焦点 + 倒计时 + 4 种播放模式）

### 3.4 后台播放 / 通知栏 / 锁屏 / 蓝牙耳机控制

- **原项目**：
  - `BaseReadAloudService.kt` (784 行) — 抽象基类，定义全部公共逻辑
  - 含 `MediaSessionCompat` / `MediaButtonReceiver`（`receiver/MediaButtonReceiver.kt`）/ `AudioFocusRequestCompat` / `PhoneStateListener`（来电自动暂停）/ `WifiManager` 高功率模式 / `PowerManager` wake lock
- **Flutter 现状**：❌
- **复杂度**：**XL**（需 platform-channel 写一份等效的前台 service）

### 3.5 倒计时 / 定时停止

- **原项目**：`AudioPlay.setTimer(minute)` / `addTimer()` / `AudioPlayService.timeMinute`，180 分钟 max（slider）；ReadAloud 走 `BaseReadAloudService` 同样接口
- **Flutter 现状**：❌

### 3.6 播放速度调节

- **原项目**：`AudioPlay.adjustSpeed(adjust: Float)` 把增量传给 service，service 写 ExoPlayer `playbackParameters`；ReadAloud 走 `upTtsSpeechRate`
- **Flutter 现状**：🟡 **仅 TTS 分级速度**
  - `reader_tts_manager.setRate(rate)` 调 `flutter_tts.setSpeechRate`
  - 没有音频书播放速度

### 3.7 跨章节连续播放

- **原项目**：
  - TTS 段读完通过 `ReadBook.moveToNextChapter` 自动续章
  - Audio 通过 `AudioPlay.next()` 按 PlayMode 路由（LIST_END_STOP 等）
- **Flutter 现状**：🟡 **仅 TTS 跨章**（reader_tts_manager 的 `_onChapterEndReached` 回调）

### 3.8 音色 / pitch 选择

- **原项目**：TTS 有 voice 选择（系统 voice list）；HttpTTS 通过 URL 模板参数化
- **Flutter 现状**：❌ — `flutter_tts` 包支持但 manager 未暴露

### 3.9 HttpTTS 多引擎管理 / 测试 / 导入

- **原项目**：
  - `ui/book/read/config/SpeakEngineDialog.kt`（不在调研列表，但相关）+ `ImportHttpTtsDialog.kt`
  - 默认引擎（`assets/defaultData/httpTTS.json`）启动时按 LocalConfig.versionCode 检测后导入
- **Flutter 现状**：❌

### Audio / TTS 子系统小结

| 模块 | 复杂度 | 优先级 | 用户感知 |
|---|---|---|---|
| 系统 TTS（基础） | M | 高 | 中（已部分） |
| 后台播放 + 通知栏 | XL | 高 | 高 |
| HTTP TTS | L | 高 | 高（很多人用） |
| 音频书 ExoPlayer | XL | 高 | 高 |
| 倒计时 / 定时 | M | 中 | 中 |
| 速度调节 | S | 中 | 中 |
| 跨章节 | S | 高 | 高 |
| 音色选择 | S | 低 | 低 |
| 引擎管理 / 导入 | M | 中 | 中 |

**听书 / 音频是 legado 用户的核心使用场景之一**：通勤场景靠后台 TTS 听书。Flutter 端目前只能"前台 + 同章" TTS，**几乎没法用**。

---

## 4. 字典 Dict

### 4.1 字典规则 CRUD

- **原项目**：
  - `data/entities/DictRule.kt` (49 行) — name PK / urlRule / showRule / enabled / sortNumber + `search(word)` 函数（直接调 AnalyzeUrl + AnalyzeRule）
  - `data/dao/DictRuleDao.kt`
  - `ui/dict/rule/DictRuleActivity.kt` + `DictRuleAdapter.kt` + `DictRuleEditDialog.kt` + `DictRuleViewModel.kt`
  - `ui/association/ImportDictRuleDialog.kt` + `ImportDictRuleViewModel.kt`
  - `help/DefaultData.kt` — 启动从 `defaultData/dictRules.json` 导入
- **Flutter 现状**：❌ **完全缺失**
- **复杂度**：**M**

### 4.2 多字典查询 + 长按文字呼出查词

- **原项目**：
  - `ui/dict/DictDialog.kt` + `DictViewModel.kt` — 阅读器中长按选词触发，TabLayout 多字典源切换
  - 阅读器 `TextActionMenu` 中的"字典"按钮调用 `showDialogFragment(DictDialog(word))`
- **Flutter 现状**：❌
- **复杂度**：**M**

### Dict 子系统小结

| 模块 | 复杂度 | 优先级 | 用户感知 |
|---|---|---|---|
| 规则 CRUD + 导入 | M | 低 | 低 |
| 长按查词 + 多字典 Tab | M | 低 | 低 |

**Dict 是边缘功能**：英语阅读用户偶尔用，普通中文小说阅读完全不需要。

---

## 5. 订阅源 RuleSub

### 5.1 订阅源 CRUD + 自动更新

- **原项目**：
  - `data/entities/RuleSub.kt` (16 行) — 极简：id / name / url / type (0=书源 1=RSS 源 2=替换规则) / customOrder / autoUpdate / update
  - `data/dao/RuleSubDao.kt`
  - `ui/rss/subscription/RuleSubActivity.kt` + `RuleSubAdapter.kt`（注意位置在 `ui/rss/subscription/` 但功能是订阅源，不是 RSS 订阅）
  - 订阅触发后调 `ImportBookSourceDialog` / `ImportRssSourceDialog` / `ImportReplaceRuleDialog`
- **Flutter 现状**：❌ **完全缺失**
- **复杂度**：**S**（数据模型简单，逻辑就是定时拉取 URL → 走已有 import）

### RuleSub 小结

| 模块 | 复杂度 | 优先级 | 用户感知 |
|---|---|---|---|
| 订阅 CRUD | S | 中 | 中（高阶用户必备 — 一键同步全部规则） |
| 自动更新 | S | 中 | 中 |

**RuleSub 工作量小但用户价值高**：高阶玩家用它一键同步上百个书源，是 legado 圈子里的"配置标准做法"。

---

## 6. 内置浏览器 / WebView 配置

### 6.1 内置浏览器（用户级）

- **原项目**：
  - `ui/browser/WebViewActivity.kt` (344 行) + `WebViewModel.kt` (141 行)
  - 支持登录、Cookie 自动保存、自定义 UA、JS 注入、SSL 错误处理、Cloudflare 挑战识别 (`isCloudflareChallenge`)、保存图片、自定义 WebChromeClient（视频全屏）、文件下载（`Download`）
  - `lib/webdav/` (4 个文件) — WebDAV 客户端
  - `help/source/SourceVerificationHelp.kt` — 通过 WebView 解决书源人机验证 / 登录
- **Flutter 现状**：🟡 **仅书源解析用 WebView**
  - `core/platform_webview_executor.dart` + `MainActivity.kt:executeWebViewRequest` 走 `legado/webview_executor` MethodChannel —**纯后台 headless WebView**，用于书源 webJs 解析图片 URL，**不暴露给用户**
  - 没有用户级浏览器入口
  - 没有 WebDAV 客户端代码
- **复杂度**：**L**（WebViewActivity 等价 + JS Bridge + 文件下载）

### 6.2 WebView 登录（书源登录）

- **原项目**：
  - `ui/login/SourceLoginActivity.kt` + `SourceLoginDialog.kt` + `SourceLoginViewModel.kt`
  - `ui/login/WebViewLoginFragment.kt` — WebView 登录后捕获 Cookie 写回 `CookieStore`
- **Flutter 现状**：❌ **完全缺失**
  - 现有 `lib/features/source/source_page.dart` 没有登录入口；rust core 端 `BookSource.login_url` 字段已有但无消费者
- **复杂度**：**L**（WebView + Cookie 拦截 + 写回 source 表）

### 6.3 Cookie 管理 / 自定义 UA / JS 注入

- **原项目**：
  - `data/entities/Cookie.kt` + `data/dao/CookieDao.kt` + `help/http/CookieStore.kt` + `help/http/CookieManager.kt`
  - 阅读器底部的"自定义 UA"配置（在 OtherConfigFragment 中）
- **Flutter 现状**：🟡 **部分**
  - `core/transport.dart` 有 cookie 处理（HTTP 层），但**没有 cookie 表 / dao**
  - 没有用户可见的 cookie 管理 UI
- **复杂度**：**M**（cookie 表 + UI + 与 transport 整合）

### Browser / WebView 子系统小结

| 模块 | 复杂度 | 优先级 | 用户感知 |
|---|---|---|---|
| 内置浏览器 | L | 低 | 低（备用工具） |
| 书源登录 WebView | L | 高 | 高（VIP 书源必需） |
| Cookie 管理 | M | 中 | 中 |
| 自定义 UA | S | 低 | 低 |
| WebDAV | M | 中 | 中（备份依赖） |

---

## 7. 文件管理 / 字体 / QR / 关于

### 7.1 文件选择 / SAF（Storage Access Framework）

- **原项目**：
  - `ui/file/FileManageActivity.kt` + `FileManageViewModel.kt` — 用户级文件管理器
  - `ui/file/FilePickerDialog.kt` + `FilePickerViewModel.kt` — 内部文件选择器
  - `ui/file/HandleFileActivity.kt` + `HandleFileContract.kt` + `HandleFileViewModel.kt` — `ActivityResultContract` 包装，统一 SAF 调用入口
  - `ui/file/utils/FilePickerIcon.java`（仅 Java 文件）
  - 在多处使用：QR 选图 / 字体选择 / 备份恢复 / 头像上传 / 本地书导入
- **Flutter 现状**：🟡 **使用了 file_picker 包**
  - `pubspec.yaml`: `file_picker: ^11.0.2`
  - 仅在 `features/reader/widgets/reader_settings_sheet.dart` 选阅读背景图、`features/source/source_page.dart` 选书源 JSON
  - 无统一入口 dialog；无自定义文件管理器
- **复杂度**：**S**（够用，缺统一封装）

### 7.2 自定义字体安装

- **原项目**：
  - `ui/font/FontSelectDialog.kt` (159 行) — 字体目录扫描 + 选择 + .ttf/.otf 过滤 + SAF 选目录
  - `ui/font/FontAdapter.kt`
  - 在 `ReadStyleDialog` 中点击"字体"按钮触发
- **Flutter 现状**：❌ **完全缺失**
  - reader settings 中无字体选择入口；可设 `fontFamily` 但只能填系统字体名
- **复杂度**：**M**（用 file_picker 选 ttf 文件 → 注册 Flutter `FontLoader`）

### 7.3 QR Code 扫描 / 生成（书源分享）

- **原项目**：
  - `ui/qrcode/QrCodeActivity.kt` + `QrCodeFragment.kt` + `QrCodeResult.kt` + `ScanResultCallback.kt`
  - 用 ZXing (`com.google.zxing.Result`) — 支持扫码 + 从相册识图
  - 在书源管理 / RSS 源管理 / 替换规则管理菜单都有"扫码导入"入口
- **Flutter 现状**：❌ **完全缺失**
  - 无 `mobile_scanner` / `qr_code_scanner` 依赖
- **复杂度**：**S**（接 `mobile_scanner` 包）

### 7.4 关于页 / 版本检查 / 更新下载

- **原项目**：
  - `ui/about/AboutActivity.kt` + `AboutFragment.kt` (preference XML) + `UpdateDialog.kt` + `AppLogDialog.kt` + `CrashLogsDialog.kt` + `ReadRecordActivity.kt`
  - `help/update/AppUpdate.kt` + `AppUpdateGitHub.kt` + `AppReleaseInfo.kt` — GitHub Releases API 拉版本号 + 弹窗 + 下载 APK
- **Flutter 现状**：🟡 **极简**
  - `settings_page.dart` 关于段：硬编码 `Text('版本 0.1.0')` 和"技术栈"，**无版本检查**
- **复杂度**：**S**（拉 GitHub Releases API + 显示 release notes）

### 7.5 阅读记录展示（按书统计）

- **原项目**：`ui/about/ReadRecordActivity.kt` — `ReadRecord` 表统计（每本书累计阅读时长）
- **Flutter 现状**：🟡 **数据有但无 UI**
  - rust core 端 BookProgress.read_time 字段已有，但 flutter 端没有展示页面
- **复杂度**：**S**

### 7.6 崩溃日志 / 应用日志查看

- **原项目**：`AppLogDialog.kt` + `CrashLogsDialog.kt` + `help/CrashHandler.kt`
- **Flutter 现状**：❌
- **复杂度**：**S**

### File / Font / QR / About 小结

| 模块 | 复杂度 | 优先级 | 用户感知 |
|---|---|---|---|
| 统一文件选择 | S | 低 | 低 |
| 自定义字体 | M | 中 | 中（很多人想用思源宋等） |
| QR 扫码 | S | 中 | 中（一键导入书源） |
| 版本检查 | S | 低 | 低 |
| 阅读记录页 | S | 中 | 中（成就感） |
| 崩溃日志 | S | 低 | 低 |

---

## 8. 其他 helper / model（非前面三份报告涵盖的）

### 8.1 JsExtensions + Rhino JS 引擎扩展

- **原项目**：
  - `help/JsExtensions.kt` — 上千行 Java 端可被 JS 调用的扩展函数（HTTP / Cookie / 文件 / 加解密 / Base64 / MD5 / 时间格式化 / 字体替换 / setContent + getString / 解压 / 等等）
  - `help/rhino/NativeBaseSource.kt` — 把 BaseSource 对象暴露给 Rhino JS
  - `help/JsEncodeUtils.kt`
- **Flutter 现状**：🟡 **部分实现于 Android-side LegadoJsBridge**
  - `MainActivity.kt:LegadoJsBridge` 已实现 ~40 个 JS 桥方法（http / cache / md5 / base64 / aes / setContent / getString / queryTtf / replaceFont / unzipFile 等）
  - 但 **rust 端 core-source/src/legado/js_runtime.rs 也独立实现了一份 JS 运行时**（QuickJS）
  - 两份桥**不完全对齐**，可能存在功能差异
- **复杂度**：**M**（梳理 + 对齐两份桥）

### 8.2 CacheManager / AppCacheManager（Cache 表 + memoryLruCache）

- **原项目**：
  - `help/CacheManager.kt` — `LruCache<String, Any>(50MB)` + `Cache` 表持久化 + QueryTTF 字体缓存
- **Flutter 现状**：🟡
  - rust core 端 `core-storage/src/cache_dao.rs` 已有 cache 表实现
  - flutter 端 `core/cover_cache.dart` 仅封面缓存（基于 `cached_network_image`）
  - 没有通用 KV 缓存 API 暴露给 dart
- **复杂度**：**S**（在 bridge 中暴露 cache_dao 接口）

### 8.3 ConcurrentRateLimiter（并发限流）

- **原项目**：
  - `help/ConcurrentRateLimiter.kt` — 按 BaseSource.concurrentRate 限流（"1000" = 间隔 ms / "5/1000" = 5 次每 1000ms）
  - 在 `WebBook` / `Rss` / `ReadManga` / `AudioPlay` 都用到
- **Flutter 现状**：🟡 **仅在 rust 内部限流**
  - rust core 端 `core-net/src/retry.rs` / 各 dao 内部用 tokio semaphore，但**没读取 BookSource.concurrent_rate 字段**
- **复杂度**：**M**（按字段动态限流）

### 8.4 coroutine（Coroutine.kt + CompositeCoroutine + CoroutineContainer）

- **原项目**：`help/coroutine/Coroutine.kt` — CoroutineScope 包装 + onSuccess / onError / onFinally / onCancel 回调链
- **Flutter 现状**：N/A — Dart 不需要等价物，`Future` + `try/catch` 已够

### 8.5 DefaultData（默认书源 / RSS 源 / HttpTTS / 字典 / TocRule 导入）

- **原项目**：
  - `help/DefaultData.kt` — 启动时（按 `LocalConfig.versionCode`）从 `assets/defaultData/*.json` 导入：bookSources / rssSources / httpTTS / dictRules / txtTocRules / replaceRules / readRecord
- **Flutter 现状**：❌ **完全缺失**
  - flutter assets 目录无 `defaultData/`
  - rust 端无导入逻辑
- **复杂度**：**S**（assets + 启动时一次性导入）

### 8.6 DirectLinkUpload（直链上传，备份用）

- **原项目**：`help/DirectLinkUpload.kt` — 把备份压缩 zip 后 POST 到用户配置的 URL 拿回直链
- **Flutter 现状**：❌
- **复杂度**：**M**

### 8.7 exoplayer / glide

- **原项目**：
  - `help/exoplayer/ExoPlayerHelper.kt` + `InputStreamDataSource.kt` — HTTP TTS / 音频书播放
  - `help/glide/` 9 个文件 — 图片加载（含 Cookie / Header / 进度回调 / RecycleBitmapPool）
- **Flutter 现状**：❌（无 ExoPlayer 等价；用 cached_network_image 替代了 Glide 但 feature 不全）
- **复杂度**：见 §3 / §2

### 8.8 storage（Backup / Restore / BackupAES / BackupConfig / ImportOldData）

- **原项目**：5 个文件，备份 / 恢复 / AES 加密备份
- **Flutter 现状**：❌（`feature-gap-cache-service-web-backup.md` 已详述）
- **复杂度**：**XL**

### 8.9 update（AppUpdate + AppUpdateGitHub + AppReleaseInfo）

- **原项目**：见 §7.4
- **Flutter 现状**：❌

### 8.10 AppFreezeMonitor

- **原项目**：`help/AppFreezeMonitor.kt` — Handler 检测主线程卡死 > 3s 写日志
- **Flutter 现状**：N/A — Flutter 自带 `FrameTiming` 等监控，不需要等价物
- **复杂度**：N/A

### 8.11 RuleBigDataHelp

- **原项目**：清理 `ruleData/book/` `ruleData/rss/` 子目录中已删除 source 的残留数据
- **Flutter 现状**：❌
- **复杂度**：**S**

### Helper 小结

| 模块 | 复杂度 | 优先级 | 用户感知 |
|---|---|---|---|
| JsExtensions / Rhino | M | 高 | 高（书源跑不动直接卡死） |
| CacheManager（暴露） | S | 中 | 低 |
| ConcurrentRateLimiter（按 source） | M | 中 | 中 |
| DefaultData | S | 中 | 高（首次启动空白） |
| DirectLinkUpload | M | 低 | 低 |
| ExoPlayer / Glide | 见 §3/§2 | 高 | 高 |
| Storage Backup | XL | 高 | 高 |
| AppUpdate | S | 低 | 低 |
| RuleBigDataHelp | S | 低 | 低 |

---

## 9. Rust core 端预留 vs 实际消费

### 9.1 已预留但未消费的字段

```rust
// core/core-storage/src/models.rs:15
pub source_type: i32, // 0=小说, 1=音频, 2=图片, 3=RSS

// core/core-source/src/types.rs:181
ContentRule.download_urls: Option<String>  // for audio/file sources
```

- 检查：`grep -rn "source_type" core/` — 仅 schema 定义；**没有任何分支处理**逻辑
- 检查：`grep -rn "download_urls" core/` — 仅类型定义；解析路径未消费

### 9.2 完全没有的 entity / dao

- `RssSource` / `RssArticle` / `RssStar` / `RssReadRecord`
- `DictRule`
- `RuleSub`
- `HttpTTS`
- `Cookie`
- `KeyboardAssist`
- `Server`
- `SearchKeyword`
- `TxtTocRule`（部分功能）
- `BookGroup`（书架分组）
- `BookChapterReview`

### 9.3 完全没有的解析器

- `core-parser/src/`：仅 epub / txt / umd
  - 无 `rss.rs`（RSS XML / Atom 解析）
  - 无 `manga.rs`（漫画图片列表解析）
  - 无 `audio.rs`（音频 URL 解析）

### 9.4 source-type 分流缺失影响

`core-source/src/parser.rs` 的 `getSearchResults` / `getBookInfo` / `getChapterList` / `getChapterContent` 全部按"小说"路径走。结果：

- type=1（音频）BookSource 解析后拿到的字段是文本，但缺 `download_urls`
- type=2（漫画）BookSource 解析后拿到 ContentRule.content（图片 URL 列表），但 flutter 端 reader 把它当文本渲染
- type=3（RSS）完全无对应路径

---

## 10. 用户视角优先级总结

### 🔴 高优先级（日常会用到，不做则功能残缺）

1. **音频书 + 后台 TTS 听书**（§3.1-3.4 / §3.7）— 通勤场景核心；现有 TTS 只能前台同章用，**几乎不可用**
2. **漫画类型路由 + Webtoon 阅读 UI**（§2.1-2.5）— 装机用户里有相当一部分要看漫画；**完全无法读漫画**
3. **HTTP TTS 自定义引擎**（§3.2 / §3.9）— 无法用主流的微软 / 阿里云 TTS，体验和系统自带 TTS 差距巨大
4. **WebView 书源登录**（§6.2）— VIP 书源 / 起点系列必需
5. **DefaultData 默认数据导入**（§8.5）— 首次启动空白书架，劝退新用户
6. **JsExtensions 与 Android/Rust JS 桥对齐**（§8.1）— 大量书源跑不动 = 无内容可读

### 🟡 中优先级（高阶用户必备 / 影响信任度）

7. **RuleSub 订阅源**（§5）— 一键同步全部规则的标准做法，工作量小价值高
8. **WebDAV / Backup / Restore**（§8.8）— 换机迁移阅读记录
9. **自定义字体安装**（§7.2）— 思源宋 / 方正悠黑 等
10. **QR 扫码导入书源**（§7.3）— 工作量小、用户感知强
11. **倒计时 / 定时停止**（§3.5）— 睡前听书必备
12. **阅读记录页**（§7.5）— 成就感 / 用户黏性
13. **Cookie 管理**（§6.3）

### 🟢 低优先级（边缘 / 高阶玩家偶尔用）

14. **RSS 订阅整套**（§1）— 装机用户里只有少数高阶用户用
15. **字典 Dict**（§4）— 英语书 / 学术阅读偶尔用
16. **内置浏览器**（§6.1）— 更像是开发者工具
17. **版本检查**（§7.4）— Flutter 现已有版本号显示
18. **DirectLinkUpload**（§8.6）— WebDAV 替代品
19. **崩溃日志查看**（§7.6）— 开发期才用
20. **漫画颜色滤镜 / 电子纸**（§2.2 末端）— 高阶玩家专属

### 🔵 不优先（Flutter 不需要 / 已有等价物）

- **AppFreezeMonitor**（§8.10）— Flutter 自带 FrameTiming
- **Coroutine 包装**（§8.4）— Dart Future 已够

---

## 11. 工作量估算（粗）

| 子系统 | 复杂度合计 | 工日估算（单人）|
|---|---|---|
| 听书 / 音频（§3） | 1×XL + 1×L + 4×M + 3×S | **40-60** |
| 漫画 Manga（§2） | 1×XL + 2×L + 3×M + 1×S | **30-50** |
| RSS 整套（§1） | 4×L + 2×M + 1×S | **30-45** |
| WebView / 书源登录（§6.2-6.3） | 2×L + 1×M + 1×S | **15-25** |
| RuleSub（§5） | 2×S | **2-3** |
| Dict（§4） | 2×M | **6-10** |
| File / Font / QR / About（§7） | 2×M + 4×S | **8-15** |
| Helper 对齐（§8） | 1×XL + 4×M + 4×S | **20-30** |
| Rust core 端 entity / 解析器补全 | — | **15-25** |
| **总计** | — | **160-260 工日** |

注：估算基于"对照已有 BookSource / Reader 端口的工作量比例"推断；"workman quote"未含设计 / 测试 / debug 时间。

---

## 12. 给开发者的提议（可选）

由调研者基于"用户视角优先级"给出的非强制建议：

### 第一阶段（30 工日，撑起基本可用性）

1. **DefaultData 导入** — 1 周内可做
2. **HTTP TTS + 后台 TTS service** — 解决"通勤听书"核心场景
3. **WebView 书源登录** — 打开 VIP 书源闸门
4. **RuleSub 订阅源** — 工作量小，价值高
5. **JsExtensions 桥对齐** — 修复"书源跑不动"问题

### 第二阶段（60 工日，扩展深度）

6. **漫画 Webtoon UI + 路由** — 让用户能看漫画
7. **音频书 ExoPlayer 等价** — 完整音频播放
8. **WebDAV Backup / Restore** — 换机迁移
9. **自定义字体 + QR 扫码** — 用户体验提升

### 第三阶段（70+ 工日，长尾）

10. **RSS 整套**
11. **Dict 字典**
12. **内置浏览器 / 版本检查 / 阅读记录页 / Cookie 管理**

---

> **报告说明**：所有路径与 LOC 引用经 cat / wc -l 直接验证，未做任何代码修改。详细文件级证据见报告内引用的具体行号。
> **遗漏可能**：少量未列出的小工具类（如 `lib/icu4j/` `lib/cronet/` `lib/mobi/` `lib/aliyun/ALiYun.kt` 等）若用户后续要继续推进可单独调研。
> **配套报告**：本份与 `feature-gap-reader-bookshelf-source.md` / `feature-gap-cache-service-web-backup.md` 三份 research 联合覆盖原项目核心子系统。
