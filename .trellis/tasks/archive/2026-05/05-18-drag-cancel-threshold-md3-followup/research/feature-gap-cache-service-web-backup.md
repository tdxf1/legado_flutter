# Legado vs Flutter+Rust 端口 — 功能差异调研报告（第二批）

> **范围**：离线缓存 / 下载 / 导出 / 后台服务 / Web 服务 / 搜索 / 备份恢复
> **方法**：只读对比 `legado/` (原 Kotlin/Android) 与 `legado_flutter/` (Flutter + Rust workspace)
> **生成时间**：2026-05-18
> **配套**：见同目录 `feature-gap-reader-bookshelf-source.md`（Reader / Bookshelf / Source 篇）

---

## 0. 仓库结构对照

| 模块 | 原 Legado (Kotlin) | Flutter + Rust 端口 |
|---|---|---|
| 后台服务 | `app/.../service/` 11 个 Service（含 Audio/TTS/Cache/Download/Export/Web/CheckSource…） | Flutter 主线程 + 1 个单例 `DownloadRunner` + `flutter_local_notifications`，无 Service / Isolate |
| 缓存与下载 | `service/CacheBookService.kt`(187) + `model/CacheBook.kt`(459) + `service/DownloadService.kt`(279) + `model/Download.kt`(18) | `core/download_runner.dart`(284) + Rust `download_dao.rs`(307) + 单 fn `download_and_save_chapter` |
| 导出 | `service/ExportBookService.kt`(877) — txt / epub + 自定义脚本文件名 + WebDav 推送 | ❌ 无 |
| 本地书 | `model/localBook/` 6 个解析器（TXT/EPUB/UMD/MOBI/PDF + Base/Local）≈ 2124 行 + `import/local/` UI | Rust `core-parser/` 4 文件（cleaner/epub/txt/umd）≈ 1720 行；**未对外暴露**给 Flutter（`api.dart` 无 import/local 接口） |
| Web HTTP 服务 | `service/WebService.kt`(230) + `web/HttpServer.kt`(152) + `web/WebSocketServer.kt`(24) + 4 controllers + 3 sockets，端口 1122/1123，原生静态资源 `assets/web/` | Rust binary `core/api-server/`（独立可执行，axum）+ 8 个 routes 文件 ≈ 1601 行；**默认本机 127.0.0.1:8787，无静态资源 / Web UI / WebSocket** |
| 搜索 | `ui/book/search/` 7 文件 ≈ 1370 行（多书源并发 / SearchScope / 历史 / 范围对话框）+ `model/webBook/SearchModel.kt`(210) + `ui/book/searchContent/` 4 文件（章内全文搜）≈ 475 行 | `features/search/search_page.dart`(918) — 在线/离线 toggle、精确/模糊、20 条历史、SSE 流式、并发 search；**无章内搜索**、**无搜索范围（按分组/按源）**、**无 SearchScope dialog** |
| 备份恢复 | `help/storage/Backup.kt`(297) + `Restore.kt`(315) + `BackupConfig.kt`(144) + `BackupAES`(8) + `ImportOldData.kt`(372) + `help/AppWebDav.kt`(337) + `lib/webdav/` 4 文件 ≈ 527 行 | ❌ 无任何备份/恢复/WebDav 代码 |

> 结论：**这 5 大类是 Flutter 端口最薄弱的领域**，整体完成度估计在 15%-30%（除"基本下载链路"约 70%、"搜索基础功能"约 60% 外，其余均缺）。

---

## 1. 离线缓存 / 下载 / 导出

### 1.1 单章 / 整本下载

- **原项目**：
  - `model/CacheBook.kt`：`addDownload(start, end)` 区间下载；`stop()` / `start()` 全局；`downloadAwait()` 单章同步；`download(scope, chapter, semaphore)` 单章异步带信号量
  - `CacheBookService.kt:81` IntentAction.start 接 `bookUrl/start/end`，service 启停 by `CacheBook.start/stop/remove`
  - 入口：`CacheActivity.kt:189 menu_download_all`（全本）/ `:173 menu_download` / `:175 sureCacheBook`（弹窗确认）
  - 阅读器内：`ReadBook.downloadedChapters`、按 `durChapterIndex..lastChapterIndex` 触发缓存
- **Flutter 现状**：🟡 **基础链路通，但缺管理 UI**
  - `features/download/download_page.dart`(164)：只读列表；删除任务；**无章节区间选择**、**无开始/恢复/暂停按钮**、**无书架批量缓存**
  - `core/download_runner.dart`：`enqueue` 接 `chapters` 列表，逐章串行 `downloadAndSaveChapter`
  - 触发入口：找不到对应"下载"按钮的实现（reader/bookshelf 中也没有发现 `enqueue` 调用，需 Flutter 主代码补全或确认）
- **缺失细节**：
  - 区间下载（"从当前章到末章" / "从头到末章"）
  - 阅读器内自动缓存后续 N 章（原项目 `AppConfig.threadCount` + 后台拉取）
  - 全书架批量下载（"缓存全部"菜单）
- **工作量**：M（UI + 触发入口需要补；Rust 单章 API 已具备）

### 1.2 后台下载 + 进度通知

- **原项目**：
  - `CacheBookService` 是 Android `BaseService` 前台服务，`ic_download` 持续通知，`isRun` 标志，`startForegroundNotification()` + 1s 轮询更新 "正在下载:X|等待中:Y|失败:Z|成功:W"
  - 杀进程后系统会因 START_STICKY 重启
  - `CacheBook.downloadSummary` 全局摘要
- **Flutter 现状**：🟡 **仅前台通知；无 Service / Isolate**
  - `core/notification_service.dart`：`flutter_local_notifications` 进度条通知，importance=low，ongoing=true，但**不是 ForegroundService**
  - 进程被杀 → 下载终止 + `DownloadRunner.resetInterruptedTasks` 把运行中任务标记为"应用意外关闭，下载中断"（仅状态修复，不会自动续）
  - 没有"等待中/失败/成功"细分，仅 `current/total/progress%`
- **缺失细节**：
  - 真正的前台 Service（Android）/ BackgroundTask（iOS）/ Linux daemon
  - 多任务进度聚合摘要（多本书并行时的全局通知）
  - Wake-Lock / WiFi-Lock（原项目 WebService 有 `useWakeLock` 选项；CacheBookService 走默认前台保活）
  - "暂停"操作通知按钮（原项目通知有 cancel action）
- **工作量**：L（Android FG-Service 要写 Kotlin/Java + MethodChannel；iOS BGTaskScheduler 要写 Swift；桌面平台无对应方案，可能直接绕过）

### 1.3 暂停 / 恢复 / 取消

- **原项目**：`CacheBook.cacheBookMap[bookUrl]?.stop()` / `addDownload` 重新加入；`cacheBookMap` 全局可恢复；前台通知有 cancel action
- **Flutter 现状**：❌ **只支持取消（删除任务），无暂停/恢复**
  - `DownloadTaskStatus.paused = 2` 状态码已定义但 UI **从不写入**
  - `download_runner.dart` for-loop 串行，无中断/恢复点
- **缺失细节**：暂停后保留已下载章节、点击恢复继续；网络中断自动暂停而非失败
- **工作量**：M

### 1.4 多章节并发限速

- **原项目**：
  - `CacheBookService`：`ExecutorService.newFixedThreadPool(min(threadCount, MAX_THREAD)).asCoroutineDispatcher()`，`AppConfig.threadCount` 用户可配
  - `CacheBook.startProcessJob`：`onEachParallel(AppConfig.threadCount)` 并发拉取
  - 单章用 `Semaphore` 限并发；`ConcurrentRateLimiter.kt`（同源全局限流，未在缓存 service 中显式调用，但 WebBook 走的 `LegadoHttpClient` 内部有源级限流）
- **Flutter 现状**：❌ **完全串行**
  - `download_runner.dart:69-77` 注释明确："这是 intentional for the current Phase 4 milestone"，无并发 / 无源级限流配置
  - 一书架 10 本 × 100 章 = 串行排队
- **缺失细节**：
  - 用户可调线程数（settings 里没有这个选项）
  - 同源限流（防止单源被 ban）
  - 跨任务的全局并发上限
- **工作量**：M（Dart 侧加 `Future.wait` + Semaphore 即可；与 Rust 端 `core-source` 已有的 rate limiting 联动）

### 1.5 失败重试

- **原项目**：`CacheBook.CacheBookModel.onPostError`：每章最多重试 3 次（`errorDownloadMap[chapter.primaryStr()] < 3`），延时 1s 后回插入 `waitDownloadSet`
- **Flutter 现状**：❌ **零重试**
  - `download_runner.dart:185-216` catch 块直接 `failCount++` 写 DB，下一章
- **工作量**：S

### 1.6 导出格式（txt / epub / mobi）

- **原项目**：
  - `ExportBookService.kt`(877)：txt 路径 `exportTxt`、epub 路径 `exportEpub` + `CustomExporter`（按章节范围切分多个 epub）
  - 依赖 `me.ag2s.epublib`（EpubWriter）+ Glide 抓封面 + `BookHelp.getImage`
  - 导出菜单 `CacheActivity:217 menu_export_type` 选 txt/epub
  - **不支持 mobi 导出**（Java 库限制；上面 LocalBook 有 mobi 解析能力，但导出仅 txt/epub）
- **Flutter 现状**：❌ **零导出**
  - `pubspec.yaml`/`bridge/api.rs` 未发现 epub 写入或 zip 打包逻辑
  - `core-parser/epub.rs`(694) 仅"解析"，不"写入"
- **缺失细节**：txt/epub 全部、mobi 全部
- **工作量**：L（epub 写入要 zip + opf + ncx + xhtml 模板）

### 1.7 导出路径选择

- **原项目**：`HandleFileContract` SAF 选目录，路径用 `ACache` 缓存；支持 content URI 与本地文件 URI
- **Flutter 现状**：❌ **不存在**（无导出功能）
- **工作量**：S（如果有了导出，再做 file_picker 接入）

### 1.8 本地书格式支持（txt / epub / umd / mobi / pdf / cbz）

- **原项目**：`model/localBook/` 全 6 类：TextFile / EpubFile / UmdFile / MobiFile / PdfFile / BaseLocalBookParse；导入入口 `import/local/ImportBookActivity.kt`
- **Flutter 现状**：🟡 **Rust 解析器已写但未暴露**
  - `core/core-parser/src/`：txt(292) + epub(694) + umd(434) + cleaner(236) + types(36)
  - **没有 mobi**、**没有 pdf**、**没有 cbz**
  - **未暴露给 Flutter**：`bridge/src/api.rs` 56 个 fn 中**无 local_book 接口**（无 importBook、无 parseEpub、无 saveBookFile）
  - Flutter 端 `bookshelf_page.dart` 无"导入本地书"按钮
- **缺失细节**：
  - mobi / pdf / cbz 解析器
  - bridge fn：`import_local_book(file_path) -> bookId`
  - UI 入口（书架 + 号 → 选文件）
- **工作量**：L（Rust 解析器已有但接 bridge 还要做 epub 二次封装；mobi/pdf/cbz 要从零）

### 1.9 本地书 charset 检测

- **原项目**：`utils/EncodingDetect.kt`（juniversalchardet 包装）+ `Utf8BomUtils`，自动检测 UTF-8 BOM/GBK/Big5
- **Flutter 现状**：🟡 **Rust 端已实现但未对外**
  - `core-parser/src/txt.rs:detect_encoding_fallback` + `core-net::cookie` 联动；只支持 GB18030 + UTF-8 fallback
  - **不支持 Big5 / Shift-JIS / EUC-KR**（多语种小说）
- **工作量**：S（添加 chardetng 或 encoding_rs::Encoding::for_bom + 主流编码探测）

### 1.10 本地书章节切分（TxtTocRule）

- **原项目**：
  - `data/entities/TxtTocRule.kt` 表 + DAO，规则可在 settings 编辑（"目录正则"）
  - `model/localBook/TextFile.kt`：`getChapterList()` 按用户配置的正则迭代
  - 默认规则集 `help/DefaultData.kt` → `txtTocRule.json`（多种"第X章"模式）
- **Flutter 现状**：🟡 **硬编码单一正则**
  - `core-parser/src/txt.rs:30`: `r"^第?[一二三四五六七八九十百千万\d]+[章回节卷集].*$|^Chapter\s+\d+.*$"`
  - 没有 TxtTocRule 表，没有 UI 编辑
- **工作量**：M（DB 加表 + DAO + Flutter 设置页 UI）

### 1.11 缓存清理 / 容量统计

- **原项目**：`CacheActivity.kt:265 viewModel.loadCacheFiles(books)` 扫描 `BookHelp.getBookCachePath` 目录，按书展示已缓存章节数；菜单"清空"功能存在
- **Flutter 现状**：🟡 **下载列表只展示数据库中的任务**
  - `download_dao.rs:185 delete_with_files_in_root`：删除任务时同步删除磁盘文件（**已实现**，但前提是 `set_download_root` 被调用过）
  - **没有"按书统计已下载多少章"**、**没有"清空所有缓存"全局按钮**
- **工作量**：S

---

## 2. 后台服务（Service）

| 原 Service | 行数 | Flutter 等价 | 状态 |
|---|---|---|---|
| `AudioPlayService.kt` | 658 | ❌ 无 | 🟥 **缺失**（无 ExoPlayer / MediaSession / AudioFocus） |
| `BaseReadAloudService.kt` | 784 | `features/reader/services/reader_tts_manager.dart`(198) | 🟡 **30% 完成** |
| `TTSReadAloudService.kt` | 265 | 同上（`flutter_tts` 包装） | 🟡 部分 |
| `HttpReadAloudService.kt` | 617 | ❌ 无 | 🟥 **缺失**（无在线 TTS / 边缘合成 / 缓存音频） |
| `CacheBookService.kt` | 187 | `core/download_runner.dart`(284) | 🟡 见 §1 |
| `CheckSourceService.kt` | 260 | ❌ 无 | 🟥 **缺失**（书源批量校验） |
| `DownloadService.kt` | 279 | `core/download_runner.dart` | 🟡 仅章节下载，**无文件下载**（升级包/封面/字体） |
| `ExportBookService.kt` | 877 | ❌ 无 | 🟥 见 §1.6 |
| `WebService.kt` | 230 | `core/api-server/`（独立 binary） | 🟡 见 §3 |
| `WebTileService.kt` | 78 | ❌ 无 | 🟥（QuickSettings 磁贴） |

### 2.1 AudioPlayService（音频播放）

- **原项目**：
  - ExoPlayer / Media3 + MediaSessionCompat + AudioFocusRequest
  - 通知栏播放控件、锁屏控件、媒体按键 (`MediaButtonReceiver`)
  - WakeLock + WifiLock 防熄屏断流
  - 解析音频播放规则（`AnalyzeUrl.getMediaItem`）从书源拿 audio URL
  - 进度持久化、自动下一章
- **Flutter 现状**：❌ **完全未实现**
  - `pubspec.yaml` 无 `just_audio` / `audio_service` 等依赖（基于 grep 结果）
  - `core-source` 端也没有 `audio_url` 解析路径
- **工作量**：L（音频书是次要功能，但 UI + Service 都得写）

### 2.2 BaseReadAloudService / TTSReadAloudService（朗读）

- **原项目**：
  - 独立前台 Service，控件覆盖锁屏 / 媒体按键 / 通知
  - 段落进度精细控制（`pageIndex` / `paragraphIndex` / `pos`）
  - 与翻页 `AutoPager` 联动
  - 多种语速 / 语调 / 后台引擎切换
  - "继续朗读到下一章" + 链路化朗读（`HttpReadAloudService` 走 SSML 在线合成）
- **Flutter 现状**：🟡
  - `reader_tts_manager.dart`：`flutter_tts` 包装，最小回调 API
  - 仅段落级（按 `\n+` 分），无字符级 highlight
  - 仅 setLanguage("zh-CN") fallback；语速可调
  - **无后台 Service**（应用切到后台 / 锁屏 / 来电会被打断）
  - **无媒体按键 / 通知控件**
  - **无音频缓存**
- **工作量**：L（后台 Service + AudioFocus + 字符级 highlight）

### 2.3 HttpReadAloudService（HTTP 朗读 / 自定义 TTS）

- **原项目**：可配置 HTTPTTS（自定义合成接口，比如 Edge TTS），有 SSML、有缓存
- **Flutter 现状**：❌
- **工作量**：M

### 2.4 CheckSourceService（书源校验）

- **原项目**：
  - `service/CheckSourceService.kt`(260) 并发校验 N 个书源（`exploreKinds` + `searchBookAwait` + `getChapterListAwait`）
  - 通知栏显示进度 X/N
  - 失败的源 `BookSource.respondTime` / `enabled` 自动调整
- **Flutter 现状**：🟡 **Rust 端有"单源校验" fn**
  - `bridge/api.rs:777 validate_source_from_db` 校验单源
  - **没有批量校验**、**没有进度通知**、**没有 UI 入口**
- **工作量**：M

### 2.5 触发场景 / iOS / Desktop 兼容性

| 场景 | 原项目 | Flutter |
|---|---|---|
| 应用切后台 | Foreground Service 持续 | 通知保活 + Dart timer 继续，但 Android Doze 模式会被 freeze |
| 锁屏 | WakeLock 保活 | 无 |
| 来电 | AudioFocusManager 自动暂停朗读 | 无 |
| 杀进程 | START_STICKY 重启 | 直接终止；下次启动 `resetInterruptedTasks` 标记失败 |
| iOS | — | 完全没考虑 |
| 桌面 (Linux) | — | 通知通过 notify-send，下载继续；但所有"Service"概念无对应 |

---

## 3. Web 服务（HTTP server）

### 3.1 启动 / 停止 / 端口

- **原项目**：
  - `WebService.kt:42 start(context)` / `:51 stop(context)` 系统服务
  - 端口 `getPort()` 默认 1122（HTTP）+ 1123（WebSocket）
  - 网络变化自动 `upWebServer()` 重启
  - `WebTileService` 状态栏磁贴一键切换
- **Flutter 现状**：🟡
  - `core/api-server/src/main.rs`：独立可执行 binary，**不是 in-process**
  - 默认 `127.0.0.1:8787`（**仅 loopback**，原项目对外暴露所有 IP）
  - `LEGADO_HOST` / `LEGADO_PORT` 环境变量配置
  - **无网络变化监听**（IP 改了不会自动 rebind）
  - **无磁贴 / Tile / 一键启停 UI**（Flutter 端无控件）
- **工作量**：M（in-process 集成 + Flutter 启停按钮）

### 3.2 局域网发现

- **原项目**：`NetworkUtils.getLocalIPAddress()` 列出所有 IP，写到通知 "http://{ip}:{port}"
- **Flutter 现状**：❌（默认 loopback；用户改 host 后还得自己看 ifconfig）
- **工作量**：S（Rust 侧 enum 网络接口）

### 3.3 API 路由清单（核心差异）

#### 原项目（NanoHTTPD `HttpServer.kt`）

**GET：**
| 路径 | 说明 |
|---|---|
| `/getBookSource?url=` | 获取单书源 |
| `/getBookSources` | 全部书源 |
| `/getBookshelf` | 书架（按 `bookshelfSort` 排序） |
| `/getChapterList?url=` | 目录（按需拉网络） |
| `/refreshToc?url=` | 强制刷新目录 |
| `/getBookContent?url=&index=` | 单章内容 |
| `/cover?path=` | 封面图（PNG 二进制） |
| `/image?url=&path=&width=` | 正文嵌图（按宽缩） |
| `/getReadConfig` | Web 阅读器配置（读自 CacheManager） |
| `/getRssSource?url=` | 单 RSS 源 |
| `/getRssSources` | 全部 RSS 源 |
| `/getReplaceRules` | 全部替换规则 |
| `/{*}` 静态文件 | `assets/web/` 下的 HTML/JS/CSS（Vue 阅读器） |

**POST：**
| 路径 | 说明 |
|---|---|
| `/saveBookSource` | 保存单书源 |
| `/saveBookSources` | 批量保存书源 |
| `/deleteBookSources` | 批量删除书源 |
| `/saveBook` | 保存书籍（含 WebDav 同步进度） |
| `/deleteBook` | 删除书籍 |
| `/saveBookProgress` | 保存阅读进度（含 WebDav 同步） |
| `/addLocalBook` | 上传本地书文件（multipart） |
| `/saveReadConfig` | 保存 Web 阅读配置 |
| `/saveRssSource` | 单 RSS 保存 |
| `/saveRssSources` | 批量 RSS |
| `/deleteRssSources` | 批量删 RSS |
| `/saveReplaceRule` | 单替换规则 |
| `/deleteReplaceRule` | 删替换规则 |
| `/testReplaceRule` | 测试替换规则 |

**WebSocket（端口 +1）**：
| 路径 | 说明 |
|---|---|
| `/searchBook` | 多书源并发搜索流式 |
| `/bookSourceDebug` | 书源调试日志推送 |
| `/rssSourceDebug` | RSS 源调试日志推送 |

**OPTIONS**：CORS preflight；`Access-Control-Allow-Origin` = 请求 origin（**几乎裸奔**）

#### Flutter+Rust（axum）

| 已实现路径 | 方法 | 对应原 API |
|---|---|---|
| `/health` | GET | — |
| `/api/sources` | GET, POST | `/getBookSources` + `/saveBookSource` |
| `/api/sources/enabled` | GET | （部分）`/getBookSources` |
| `/api/sources/:id` | DELETE | (单条) `/deleteBookSources` |
| `/api/sources/:id/enabled` | PUT | ❌ 原项目无单独 enable 路径，靠 saveBookSource |
| `/api/sources/import` | POST | ✅ 大致对应批量导入 |
| `/api/sources/export/legado` | GET | ❌ 原项目无 |
| `/api/search` | POST | 类似 WS `/searchBook`（但用 HTTP 不是流式） |
| `/api/search/sse` | GET | SSE 流式（**新设计**，比原 WS 简单） |
| `/api/logs/sse` | GET | 类似 `/bookSourceDebug` 但通用 |
| `/api/bookshelf` | GET, POST | `/getBookshelf` + `/saveBook` |
| `/api/bookshelf/:book_id` | DELETE | `/deleteBook` |
| `/api/books/:book_id` | GET | （新增） |
| `/api/books/:book_id/refresh-chapters` | POST | `/refreshToc` |
| `/api/books/:book_id/chapters` | GET | `/getChapterList` |
| `/api/books/:book_id/chapters/content` | GET | `/getBookContent` |
| `/api/books/:book_id/chapters/content/save` | POST | （新增，用于本地缓存编辑） |
| `/api/books/:book_id/progress` | GET, PUT | `/saveBookProgress` |
| `/api/replace-rules` | GET, POST | `/getReplaceRules` + `/saveReplaceRule` |
| `/api/replace-rules/enabled` | GET | (新增) |
| `/api/replace-rules/:id` | DELETE | `/deleteReplaceRule` |
| `/api/explore` | GET, POST | （新增）发现页 |

#### 缺失的路由列表（Flutter 端 vs 原 NanoHTTPD）

| 原 API | Flutter 状态 | 说明 |
|---|---|---|
| `/cover?path=` | ❌ | 没有按路径返回封面图二进制（Flutter 不需要因为有 `cached_network_image`，但**第三方 Web 客户端依赖此 API**） |
| `/image?url=&path=&width=` | ❌ | 正文嵌图的服务端缩放（原项目用于阅读器图片裁剪，Flutter 端走 widget 自己处理） |
| `/getReadConfig` `/saveReadConfig` | ❌ | Web 阅读器配置（**WEB UI 缺失**，所以这俩也无意义） |
| `/getRssSource(s)` `/saveRssSource(s)` `/deleteRssSources` | ❌ | RSS 全套（Flutter 端没有 RSS 模块） |
| `/addLocalBook` (multipart) | ❌ | 上传本地书 |
| `/testReplaceRule` | ❌ | 测试替换规则 |
| `/saveBookSources` (批量) | 🟡 | `import` 接近但语义不同 |
| `/deleteBookSources` (批量) | ❌ | 必须逐条 DELETE |
| WebSocket `/searchBook` | 🟡 用 SSE 替代 | 协议不同；老 Web UI 不兼容 |
| WebSocket `/bookSourceDebug` | 🟡 用 SSE `/logs/sse` 替代 | 协议不同 |
| WebSocket `/rssSourceDebug` | ❌ | 无 |
| 静态资源 `assets/web/` (Vue 阅读器) | ❌ | **核心缺失** —— 没有 web UI，浏览器打开就一片空白 |

### 3.4 Web UI（reader.html / 在线阅读器）

- **原项目**：`assets/web/` 完整 Vue 单页应用，可以远程读书 / 管理书源
  - `index.html` + `vue/index.html` + `uploadBook/index.html` + `help/index.html`
  - 上传本地书也支持
- **Flutter 现状**：❌ **完全没有 Web UI**（api-server 是纯 JSON API）
- **工作量**：L（Vue/React 应用 + 资源打包嵌入 binary）

### 3.5 跨域 / CORS

- **原项目**：万能 CORS — `Access-Control-Allow-Origin` 回填请求 origin（任何域都能访问，仅靠局域网隔离）
- **Flutter 现状**：✅ **有更严格的 origin allow-list**（`main.rs:46 origin_allowed`）+ Bearer token 强制鉴权
- **工作量**：— （比原项目更安全）

### 3.6 鉴权 token

- **原项目**：❌ **无 token**（裸奔）
- **Flutter 现状**：✅ **强制 Bearer token**（`LEGADO_API_TOKEN` 环境变量；不设则启动时随机生成 UUID 写日志），`subtle::ConstantTimeEq` 防时序攻击
- **工作量**：— （这是 Flutter 端的优势）

---

## 4. 搜索

### 4.1 多书源并发搜索 + 限流

- **原项目**：
  - `model/webBook/SearchModel.kt`：`Executors.newFixedThreadPool(min(threadCount, MAX_THREAD))` 自定义并发；`workingState` flow 控制暂停/恢复
  - 单源 `withTimeout(30000L)` 超时
  - 增量 `mergeItems`（同名同作者多源合并 `addOrigin`）
- **Flutter 现状**：✅ **类似实现**
  - 离线模式 + 在线两套
  - 在线 FRB 模式：Dart `Future.wait(...)` + 单源 15s 超时
  - 在线 HTTP/SSE 模式：服务端 `core/api-server/routes/search.rs:23 SEARCH_FANOUT=16` semaphore
  - **没有暂停/恢复**（原项目 `workingState.first { it }` 可暂停） 
  - **没有同名书源合并**（Dart 仅按 `name_author` 去重，没有 `addOrigin` 字段把多源合到一条）
- **缺失细节**：暂停/恢复、`origins` 字段聚合、用户配置 `threadCount`
- **工作量**：M

### 4.2 精确 / 模糊匹配

- **原项目**：`AppConfig.searchScope` + `precision` 标志，`SearchModel.startSearch` 的 `filter` 在 Rust 抓取层早过滤；`mergeItems` 三档分桶（`equalData`/`containsData`/`otherData`）
- **Flutter 现状**：✅ **三档过滤已实现**
  - `SearchPage.applyPrecisionFilter`：`equalName` / `equalAuthor` / `contains` 三桶
  - 客户端过滤而不是服务端（小数据集 OK，大数据集略浪费带宽）
- **工作量**：— (已对齐)

### 4.3 搜索历史

- **原项目**：
  - `data/entities/SearchKeyword.kt` 表 + `searchKeywordDao`
  - `HistoryKeyAdapter` UI 显示
  - 历史关键词点击 / 长按删除单条
- **Flutter 现状**：🟡 **本地存盘但不是 DB**
  - `SearchPage._searchHistory` (List<String>) ；`saveSearchHistoryToDisk` / `loadSearchHistoryFromDisk` (`SharedPreferences` 或 Hive，需查 transport.dart)
  - 上限 20 条
  - 单条删除 ❌（仅"清除全部"）
- **工作量**：S（点长按删除 + 迁到 sqlite 表）

### 4.4 历史关键词建议

- **原项目**：✅ 输入时下拉建议（基于 SearchKeyword.usage）
- **Flutter 现状**：❌ 仅展示历史列表，输入框不会提示
- **工作量**：S

### 4.5 章内搜索（章节内容全文）

- **原项目**：`ui/book/searchContent/SearchContentActivity.kt`(257) + Adapter + ViewModel + Result 数据类
  - 输入关键字在当前书"已下载章节"全文搜
  - 高亮匹配项 + 跳转章节定位
- **Flutter 现状**：❌ **完全无章内搜索功能**
- **工作量**：M（reader 加搜索栏 + 全章 substring 扫描 + ScrollController 跳转）

### 4.6 排序

- **原项目**：按 `name`/`time`/`source`/`equal-first` 多级排序
- **Flutter 现状**：🟡 **仅 equalName/equalAuthor/contains 三档**；不能按时间或来源排序
- **工作量**：S

### 4.7 搜索结果分组（同名不同源）

- **原项目**：`SearchBook.origins: HashSet<String>` 同名书的所有可换源 origin；UI 显示 "X 个来源"
- **Flutter 现状**：❌ 仅 `name_author` 去重（**保留首条丢弃其余**），用户看不到这本书有多少备用源
- **工作量**：M（DTO 加 origins 字段 + 后端聚合 + UI badge）

### 4.8 搜索建议（拼音 / 汉字混合）

- **原项目**：❌ **原项目也没有**（依赖输入法）
- **Flutter 现状**：❌ 同
- **工作量**：— 不需要做

### 4.9 SearchScope（搜索范围）

- **原项目**：`SearchScopeDialog.kt`(254) + `SearchScope.kt`(153)
  - 三种范围：所有源 / 指定分组 / 单个源
  - 弹窗选择，UI 顶部显示当前范围 chip
- **Flutter 现状**：❌ **完全没有"搜索范围"概念**，只有"在线/离线"切换
- **工作量**：M

---

## 5. 备份 / 恢复 / WebDAV / 导入旧数据

### 5.1 本地备份（zip）

- **原项目**：
  - `Backup.kt:62 backupFileNames`：21 个 JSON 文件 + `config.xml` 打包成 zip
  - 文件名 `backupYYYY-MM-DD-{deviceName}.zip`
  - 可选 `AppConfig.onlyLatestBackup` → 命名固定 `backup.zip`
- **Flutter 现状**：❌ **零备份功能**
- **工作量**：L（要导出 13+ 个 DB 表 → JSON → zip）

### 5.2 加密备份（AES）

- **原项目**：`BackupAES.kt`(8) 用 AES 加密 `servers.json` 与 `webDavPassword`（防 zip 直接看到 webdav 密码）
- **Flutter 现状**：❌
- **工作量**：S（已有加密备份后再做）

### 5.3 WebDAV 自动备份

- **原项目**：
  - `AppWebDav.kt`(337)：jianguoyun.com 默认地址，`upConfig` / `backUpWebDav(fileName)` / `restoreWebDav(name)` / `getBackupNames()` / `lastBackUp()` / `hasBackUp(name)`
  - `Backup.autoBack`：每天最多一次，自动 zip + 上传
  - 进度同步：`uploadBookProgress(book)` / `downloadAllBookProgress` 每本书一个 .json 文件
  - `lib/webdav/WebDav.kt`(457)：自实现 PROPFIND / MKCOL / PUT / GET / DELETE，带 Authorization
- **Flutter 现状**：❌ **零 WebDAV**
- **工作量**：L（自实现或用 webdav_client_dart）

### 5.4 多个备份文件管理

- **原项目**：`getBackupNames()` 列出云端所有 `backup*.zip`，UI 选择哪个恢复
- **Flutter 现状**：❌
- **工作量**：S（基于 §5.3 之后）

### 5.5 增量备份

- **原项目**：❌ **原项目也是全量**（每天一个 zip 完整）
- **Flutter 现状**：❌ 同
- **工作量**：— 不需要

### 5.6 自定义备份内容

- **原项目**：`BackupConfig.kt`(144) 维护 `keyIsNotIgnore` 黑名单 + UI 在 settings 勾选要备份的项
- **Flutter 现状**：❌
- **工作量**：S（基于 §5.1 之后）

### 5.7 导入旧数据（Legado 老版本格式）

- **原项目**：`ImportOldData.kt`(372)：把老版本 v1 数据库 / 旧字段名导入到新表
- **Flutter 现状**：❌ **无对接**（且因为 schema 不同，意义不大；需要先做"导入 Legado JSON 备份"代替）
- **工作量**：M（导入 Legado 备份 zip 到 Flutter SQLite）

### 5.8 跨平台备份兼容

- **原项目**：Android only
- **Flutter 现状**：— Flutter 多平台但**无备份**
- **工作量**：— （备份做了之后，跨平台格式天然兼容）

---

## 6. 优先级建议

按"日常用户出现的频率 × 缺失带来的损失" 排序：

### P0 — 立刻做

1. **下载暂停/恢复 + 失败重试**（§1.3 §1.5）— 没有它一断网整本书要全部重下，体验断崖
2. **WebDAV 备份/恢复**（§5.3）— 用户切换设备最常用功能；没有就等于"用一次扔一次"
3. **本地书导入（至少 txt + epub）**（§1.8）— 现有 Rust 代码要做的就剩 bridge fn + UI 入口；最低成本最大收益
4. **导出 txt**（§1.6 子集）— 用户备份"已下载内容"刚需

### P1 — 这周/下周

5. **章内搜索**（§4.5）— 长篇书必须功能
6. **后台前台 Service（Android）下载续传**（§1.2）— 防被系统 kill；现状是切后台 5 分钟下载就断了
7. **多章节并发下载**（§1.4）— 现状串行 1 本书 1000 章纸面也能下到当前章节超时
8. **搜索范围（按分组/按源）**（§4.9 §4.7）— 重度用户需要"只在我的精选源里搜"
9. **缓存清理 / 全局已下载统计**（§1.11）— 占空间但用户看不到入口

### P2 — 中期

10. **导出 epub**（§1.6）— 高级用户需要
11. **TTS 后台播放（含锁屏）**（§2.2）— 需要原生通道，量大；现状 reader_tts_manager 只是雏形
12. **CheckSourceService 批量校验**（§2.4）— 重度书源用户需要
13. **Web UI（Vue 阅读器嵌入 api-server）**（§3.4）— 桌面/家庭服务器场景刚需
14. **WebSocket /searchBook 兼容**（§3.3）— 配套 §3.4

### P3 — 可选 / 长期

15. **AudioPlayService 音频书**（§2.1）— 用户基数小
16. **HttpReadAloudService 在线 TTS**（§2.3）— Edge TTS 等
17. **mobi / pdf / cbz 解析**（§1.8）— 长尾格式
18. **WebTileService 磁贴**（§2 整体）— 对齐快捷启停
19. **加密备份**（§5.2）— 在 §5.3 后做

---

## 7. 工作量总计粗估

| 优先级 | 任务数 | 总工作量（pe = person-day） |
|---|---|---|
| P0 | 4 | 约 8-12 pe（其中 WebDAV 4-5pe） |
| P1 | 5 | 约 10-15 pe |
| P2 | 5 | 约 18-25 pe |
| P3 | 5 | 约 12-18 pe |
| **合计** | **19** | **48-70 pe** |

> 假设：单人；包括 Rust + Flutter + UI + 测试，但不含跨 iOS/桌面平台的额外适配。

---

## 8. 跨域风险提示

- **Service / Foreground Notification 在 iOS / 桌面平台都没有原生对应物**。Android FG-Service 写完后，iOS 必须改用 `BGTaskScheduler` + 短时任务（最多 30s × N 次），桌面平台基本依赖 in-process。功能行为差异需要在 PRD 里写清"哪个平台不支持后台续传"。
- **Web UI 资源嵌入二进制**会让 api-server binary 大小膨胀（目前 Vue 包约 2-3 MB）。
- **WebDAV 大文件分块上传**：原项目用了 jianguoyun，单文件限制 100MB；Flutter 实现要至少分块 + 进度回调。
- **api-server token 自动生成**对 Web UI 自助登录是不友好的（每次重启 token 变）。如果加 Web UI，需要 cookies / session 机制。
- **DB schema 与原 Legado 不一致**（Flutter 的 `core-storage::models` 简化了字段），导入原 Legado JSON 备份要写**字段映射层**。

