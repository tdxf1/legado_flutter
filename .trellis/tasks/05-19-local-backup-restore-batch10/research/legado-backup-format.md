# Legado 本地备份 / 恢复格式调研

> **范围**：原 Legado（Kotlin/Android）的备份导出 → zip 编排 → JSON 序列化 → AES 加密 → 恢复合并 → WebDav 同步 全链路
> **方法**：只读源码 (`legado/app/src/main/java/io/legado/app/help/storage/` + `help/AppWebDav.kt` + `lib/webdav/WebDav.kt` + `data/entities/`)
> **目标**：为 Flutter+Rust 端口（`legado_flutter`）实现"导出 / 导入 Legado 备份 zip"做字段级对账
> **生成时间**：2026-05-19
> **配套**：参见 `.trellis/tasks/05-18-drag-cancel-threshold-md3-followup/research/feature-gap-cache-service-web-backup.md` §6 "备份 / 恢复 / WebDav" 章节（更宏观的差异概览）

---

## 0. 调用关系总览

```
                    [手动备份]                     [WebDav 自动备份]
                        │                                 │
              MainViewModel / Activity            Backup.autoBack(ctx)
                        │                                 │
                        ▼                                 ▼
          Backup.backupLocked(ctx, path) ◄─── Mutex.withLock + shouldBackup()
                        │
                        ▼
          ┌─────────────────────────────────┐
          │ Backup.backup(ctx, path)        │
          │  1. 清理 backupPath 临时目录    │
          │  2. writeListToJson × 14 表     │  ← Room DAO.all → GSON.toJson → file
          │  3. servers.json (AES 加密)     │
          │  4. 4 个 config json            │  ← ReadBookConfig / ThemeConfig / DirectLinkUpload / BookCover
          │  5. config.xml (SharedPrefs)    │  ← keyIsNotIgnore 白名单 + webDavPassword 加密
          │  6. ZipUtils.zipFiles → tmp_backup.zip
          │  7. copyBackup → 用户选定目录    │
          │  8. AppWebDav.backUpWebDav      │  ← PUT 到 WebDav 根目录
          │  9. AppWebDav.upBgs(背景图)      │  ← 阅读背景批量上传
          │ 10. 删 backupPath / tmp_backup.zip
          └─────────────────────────────────┘

[恢复 / Restore]
   Restore.restore(ctx, uri)
     ├─ ZipUtils.unZipToPath(uri/file → backupPath)
     └─ Restore.restoreLocked(backupPath)
            └─ restore(path)：按文件名硬编码读取每张表
                ├─ fileToListT<Book>("bookshelf.json")  → upType + 本地书 coverPath 修复 + has? update : insert
                ├─ fileToListT<Bookmark>(...)            → 全部 insert（OnConflict 由 DAO 决定）
                ├─ fileToListT<BookGroup>(...)
                ├─ fileToListT<BookSource>(...) ?: ImportOldData.importOldSource()  ← 老格式回退
                ├─ ...（共 14 张表）
                ├─ servers.json （AES 解密 + isJsonArray 探针）
                ├─ 5 个 config json（直接 copyTo 覆盖 filesDir）
                └─ config.xml → SharedPreferences（webDavPassword AES 解密）
```

关键符号：

- `Backup.backupPath = ${filesDir}/backup`（解压/生成 json 的临时目录）
- `Backup.zipFilePath = ${externalFiles}/tmp_backup.zip`（zip 暂存）
- `Mutex` 全局串行，避免并发 backup
- 备份默认走 GSON 库（`io.legado.app.utils.GSON`），`disableHtmlEscaping + setPrettyPrinting + LONG_OR_DOUBLE`，**不会忽略 null 字段**

---

## 1. zip 文件名 + 内层文件清单

### 1.1 文件名格式（`Backup.kt:88-97`）

```kotlin
private fun getNowZipFileName(): String {
    val backupDate = SimpleDateFormat("yyyy-MM-dd").format(Date())
    val deviceName = AppConfig.webDavDeviceName
    return if (deviceName?.isNotBlank() == true) {
        "backup${backupDate}-${deviceName}.zip"   // 例：backup2026-05-19-Pixel.zip
    } else {
        "backup${backupDate}.zip"                  // 例：backup2026-05-19.zip
    }.normalizeFileName()
}
```

- 前缀**固定 `backup`**（小写无下划线，无 `legado_` / `legado-` 前缀）
- 日期 `yyyy-MM-dd`（按本地时区）
- 可选 `-deviceName` 后缀（用户在设置里填的设备别名，用于 WebDav 多端区分）
- `AppConfig.onlyLatestBackup = true` 时本地落盘**强制改名为 `backup.zip`**（覆盖旧的），WebDav 一侧仍按日期命名（`Backup.kt:211-215`）
- WebDav 列表筛选条件：`displayName.startsWith("backup")`（`AppWebDav.kt:113, 145`）

### 1.2 zip 内文件清单（`Backup.kt:62-86, backupFileNames`）

固定 21 项（无清单 / 无 manifest.json / 无 version 文件）：

| 文件名 | 内容来源 | DAO / 配置 | 加密 |
|---|---|---|---|
| `bookshelf.json` | 全书架 | `appDb.bookDao.all` (List\<Book\>) | 否 |
| `bookmark.json` | 全书签 | `appDb.bookmarkDao.all` (List\<Bookmark\>) | 否 |
| `bookGroup.json` | 分组 | `appDb.bookGroupDao.all` (List\<BookGroup\>) | 否 |
| `bookSource.json` | 书源 | `appDb.bookSourceDao.all` (List\<BookSource\>) | 否 |
| `rssSources.json` | RSS 源 | `appDb.rssSourceDao.all` (List\<RssSource\>) | 否 |
| `rssStar.json` | RSS 收藏 | `appDb.rssStarDao.all` (List\<RssStar\>) | 否 |
| `replaceRule.json` | 替换规则 | `appDb.replaceRuleDao.all` (List\<ReplaceRule\>) | 否 |
| `readRecord.json` | 阅读时长 | `appDb.readRecordDao.all` (List\<ReadRecord\>) | 否 |
| `searchHistory.json` | 搜索历史 | `appDb.searchKeywordDao.all` (List\<SearchKeyword\>) | 否 |
| `sourceSub.json` | 订阅源 | `appDb.ruleSubDao.all` (List\<RuleSub\>) | 否 |
| `txtTocRule.json` | 本地 TXT 目录规则 | `appDb.txtTocRuleDao.all` (List\<TxtTocRule\>) | 否 |
| `httpTTS.json` | 语音引擎 | `appDb.httpTTSDao.all` (List\<HttpTTS\>) | 否 |
| `keyboardAssists.json` | 键盘辅助 | `appDb.keyboardAssistsDao.all` (List\<KeyboardAssist\>) | 否 |
| `dictRule.json` | 词典规则 | `appDb.dictRuleDao.all` (List\<DictRule\>) | 否 |
| `servers.json` | 自定义后端服务 | `appDb.serverDao.all` (List\<Server\>) | **AES**（整个 JSON 数组字符串 base64 加密；解密时若 `isJsonArray()` 通过则视为未加密） |
| `directLinkUploadRule.json` | 直链上传规则 | `DirectLinkUpload.getConfig()` (单 Object) | 否 |
| `readConfig.json` | 阅读界面配置 | `ReadBookConfig.configList` (List\<Config\>) | 否 |
| `shareReadConfig.json` | 共享阅读配置 | `ReadBookConfig.shareConfig` (Object) | 否 |
| `themeConfig.json` | 主题列表 | `ThemeConfig.configList` (List\<ThemeConfig\>) | 否 |
| `coverRule.json` | 封面规则 | `BookCover.getConfig()` (Object) | 否 |
| `config.xml` | SharedPreferences 全量白名单 dump | `getSharedPreferences(backupPath, "config")` 反射出来的 Android 标准 prefs xml | webDavPassword 字段 AES |

**重要事实**：

- **没有 manifest / version / 元数据文件**。版本判定靠"文件存在与否"和老格式 fallback（`Restore.kt:136-142` 对 bookSource.json 的 ImportOldData fallback）。
- **空表对应的 json 不会写入 zip**（`writeListToJson`：`list.isEmpty()` 直接 return，`Backup.kt:253`）。所以新装机器备份的 zip 里**通常缺一半 json**。
- 文件名硬编码大小写敏感，恢复端 `File(path, fileName)` 直接命名查找（`Restore.kt:295-313`）。
- 每个 .json 直接是 **`JsonArray` of `Entity`**（不是 `{"data":[...], "version":...}` 包裹），可以一行 `GSON.fromJson(text, List<Book>)` 解析（`Restore.kt:fileToListT`）。
- 6 个 config 文件中 4 个是 `JsonObject`：`shareReadConfig.json` / `coverRule.json` / `directLinkUploadRule.json`（单 Object），`readConfig.json` / `themeConfig.json` 是 `JsonArray of Object`，`servers.json` 是加密的 `JsonArray` 字符串。

### 1.3 整包是否加密？

**不**对整包加密。AES 只在两处局部使用：

1. `servers.json` 整体内容 base64 加密（含解密兜底：明文也能读）
2. `config.xml` 里 `web_dav_password` 字段加密（其它 prefs 全明文）

`BackupAES.kt`：

```kotlin
class BackupAES : AES(
    MD5Utils.md5Encode(LocalConfig.password ?: "").encodeToByteArray(0, 16)
)
```

- 算法：Hutool `cn.hutool.crypto.symmetric.AES`，**默认构造 = AES/ECB/PKCS5Padding**（hutool 默认）
- 密钥：`MD5(LocalConfig.password)` 取前 16 字节 = 128-bit
- `LocalConfig.password` = 用户在 "我的 → 安全 → 备份密码" 设置的字符串（**未设置时为空串 `""`**，即用 MD5("") 当 key，等同于无加密但走一次 ECB）
- API：`encryptBase64(plain): String` 输出 base64；`decryptStr(b64): String` 解码

---

## 2. 各 .json 字段格式（截前 ~20 行）

下方仿造样例由 entity `data class` 默认值 + GSON pretty-printing 推断而来（`Backup.kt` 没有任何字段过滤，**直接序列化整个 entity**）。

### 2.1 `bookshelf.json` — `List<Book>`

完整字段见 `Book.kt:38-121`（Room `@Entity tableName = "books"`）：

```json
[
  {
    "bookUrl": "https://example.com/book/12345.html",
    "tocUrl": "https://example.com/book/12345/toc.html",
    "origin": "https://example.com",
    "originName": "示例书源",
    "name": "斗破苍穹",
    "author": "天蚕土豆",
    "kind": "玄幻",
    "customTag": null,
    "coverUrl": "https://example.com/cover.jpg",
    "customCoverUrl": null,
    "intro": "...",
    "customIntro": null,
    "charset": null,
    "type": 0,
    "group": 1,
    "latestChapterTitle": "第1641章 大结局",
    "latestChapterTime": 1731234567890,
    "lastCheckTime": 1731234567890,
    "lastCheckCount": 0,
    "totalChapterNum": 1641,
    "durChapterTitle": "第100章",
    "durChapterIndex": 99,
    "durChapterPos": 0,
    "durChapterTime": 1731234567890,
    "wordCount": "5.2M",
    "canUpdate": true,
    "order": 0,
    "originOrder": 0,
    "variable": null,
    "readConfig": {
      "reverseToc": false,
      "pageAnim": null,
      "reSegment": false,
      "imageStyle": null,
      "useReplaceRule": null,
      "delTag": 0,
      "ttsEngine": null,
      "splitLongChapter": true,
      "readSimulating": false,
      "startDate": null,
      "startChapter": null,
      "dailyChapters": 3
    },
    "syncTime": 0
  }
]
```

**31 个字段**（含嵌套 `readConfig` 的 12 子字段）。注意：

- `bookUrl` 是主键，索引唯一约束 `(name, author)`
- `type` 取值见 `BookType`：text=0, audio=1, image=2, webFile=4, image|local=18, local=4 + 0x10... 用 bitmask 组合
- `group` 是 `Long bitmask`（**注意**：原 Legado 把分组用 long bitmask 表示一本书可以同时在多个分组，与我们 Flutter 端口的 `group_id: i64`（单分组外键）**语义不同**）
- `BookType.localTag = "loc_book"` 字面量，`origin == "loc_book"` 即本地书

### 2.2 `bookmark.json` — `List<Bookmark>`

字段见 `Bookmark.kt:14-23`（**8 个字段**）：

```json
[
  {
    "time": 1731234567890,
    "bookName": "斗破苍穹",
    "bookAuthor": "天蚕土豆",
    "chapterIndex": 99,
    "chapterPos": 1234,
    "chapterName": "第100章",
    "bookText": "选中的文本片段...",
    "content": "用户写的笔记..."
  }
]
```

- 主键 = `time`（毫秒时间戳）。所以恢复时同毫秒会被 OnConflict 覆盖。
- 索引：`(bookName, bookAuthor)`（**不唯一**），书签关联书是按 (书名, 作者) 软关联，不是 bookUrl。

### 2.3 `bookGroup.json` — `List<BookGroup>`

字段见 `BookGroup.kt:15-27`（**7 个字段**）：

```json
[
  {
    "groupId": 1,
    "groupName": "玄幻",
    "cover": null,
    "order": 0,
    "enableRefresh": true,
    "show": true,
    "bookSort": -1
  }
]
```

- `groupId` 是 `Long`，**bitmask** 编码：默认起始值 `0b1=1`，下一个分组 `0b10=2`，再下一个 `0b100=4`，... 这样 `Book.group` 字段可以多个 bit OR 在一起表示"本书在多个分组"。
- 系统保留 ID（`BookGroup.kt:29-37`）：`IdRoot=-100`, `IdAll=-1`, `IdLocal=-2`, `IdAudio=-3`, `IdNetNone=-4`, `IdLocalNone=-5`, `IdError=-11`（这些**不会**写入备份，是 UI 虚拟分组）
- `bookSort=-1` 表示用全局默认排序

### 2.4 `bookSource.json` — `List<BookSource>`

字段见 `BookSource.kt:31-98`（**26 个顶层字段** + 6 个嵌套规则对象）：

```json
[
  {
    "bookSourceUrl": "https://example.com",
    "bookSourceName": "示例书源",
    "bookSourceGroup": "玄幻,精品",
    "bookSourceType": 0,
    "bookUrlPattern": "https://example.com/book/\\d+\\.html",
    "customOrder": 0,
    "enabled": true,
    "enabledExplore": true,
    "jsLib": null,
    "enabledCookieJar": true,
    "concurrentRate": "1000/3000",
    "header": "{\"User-Agent\":\"...\"}",
    "loginUrl": null,
    "loginUi": null,
    "loginCheckJs": null,
    "coverDecodeJs": null,
    "bookSourceComment": "",
    "variableComment": null,
    "lastUpdateTime": 1731234567890,
    "respondTime": 180000,
    "weight": 0,
    "exploreUrl": null,
    "exploreScreen": null,
    "ruleExplore": { "url": "...", "bookList": "...", "name": "...", ... },
    "searchUrl": "...",
    "ruleSearch": { ... },
    "ruleBookInfo": { ... },
    "ruleToc": { ... },
    "ruleContent": { ... },
    "ruleReview": null
  }
]
```

- 主键 = `bookSourceUrl`
- 6 大规则对象（ExploreRule / SearchRule / BookInfoRule / TocRule / ContentRule / ReviewRule）每个内部 10-30 个字段，**通过 GSON 自定义 JsonDeserializer 反序列化**（`GsonExtensions.kt:44-49`），允许字段类型自动转换（如 String/Array 互转）
- `bookSourceType`: 0=文本, 1=音频, 2=图片, 3=文件
- 老格式回退：如果 fromJsonArray 失败（旧版 Legado 格式），走 `ImportOldData.importOldSource()`

### 2.5 `rssSources.json` — `List<RssSource>`

样式同 BookSource，但更简单（约 15 字段）。主键 `sourceUrl`。

### 2.6 `rssStar.json` — `List<RssStar>`

RSS 收藏文章。字段：origin / sort / title / pubDate / image / variable 等，主键 `(origin, link)`。

### 2.7 `replaceRule.json` — `List<ReplaceRule>`

字段见 `ReplaceRule.kt:24-59`（**12 个字段**）：

```json
[
  {
    "id": 1731234567890,
    "name": "去广告",
    "group": "通用",
    "pattern": "广告.*?$",
    "replacement": "",
    "scope": "示例书源",
    "scopeTitle": false,
    "scopeContent": true,
    "excludeScope": null,
    "isEnabled": true,
    "isRegex": true,
    "timeoutMillisecond": 3000,
    "sortOrder": 0
  }
]
```

- 主键 `id` 自动生成 = `System.currentTimeMillis()`
- 列名映射：`@ColumnInfo(name = "sortOrder")` 字段名是 `order`，**Room 列名是 `sortOrder`**，但 GSON 序列化用的是 Kotlin 属性名 `order`（**不是** `sortOrder`）—— 注意：这里 GSON 走属性名，Room 走列名，两者不一致。从 zip 角度看，**JSON 里的 key 是 `order`**（GSON 不读 Room 注解）。

### 2.8 `readRecord.json` — `List<ReadRecord>`

字段见 `ReadRecord.kt:7-13`（**4 个字段**）：

```json
[
  {
    "deviceId": "android_id_xxx",
    "bookName": "斗破苍穹",
    "readTime": 36000000,
    "lastRead": 1731234567890
  }
]
```

- 复合主键 `(deviceId, bookName)`
- `deviceId = AppConst.androidId`（设备 SSAID，不是用户级 UUID）
- 恢复逻辑特殊（`Restore.kt:170-183`）：**本机 deviceId 的记录**取 max(本地, 备份) 时长；**其它设备的记录**直接 insert。

### 2.9 `searchHistory.json` — `List<SearchKeyword>`

主键 `word`，字段 `(word, usage, lastUseTime)`，3 个字段。

### 2.10 其它表（信息密度较低，列字段名）

- `sourceSub.json` — `RuleSub`：`(id, name, url, type, customOrder, ...)`
- `txtTocRule.json` — `TxtTocRule`：`(id, name, rule, example, serialNumber, enable)`
- `httpTTS.json` — `HttpTTS`：`(id, name, url, header, isEnabled, loginUrl, loginUi, loginCheckJs, ...)`
- `keyboardAssists.json` — `KeyboardAssist`：键值对
- `dictRule.json` — `DictRule`：`(name, url, header, urlOptions, isEnabled, sortNumber)`
- `servers.json` — `Server`：**整体 AES 加密**

### 2.11 `readConfig.json` / `shareReadConfig.json`

`ReadBookConfig.configList` 是 `List<Config>`，每个 Config 大约 50+ 字段（颜色、字号、行间距、padding、bgImg 路径...）。`shareReadConfig.json` 是单 Object（共享给所有 config 的"全局开关"，如 hideStatusBar, autoReadSpeed 等）。

### 2.12 `themeConfig.json`

`ThemeConfig.configList` = `List<Config>`，每个 = `(themeName, isNightTheme, primaryColor, accentColor, backgroundColor, ...)`。

### 2.13 `coverRule.json` / `directLinkUploadRule.json`

单 Object 结构：

- `coverRule.json` — `BookCover.CoverConfig(downloadUrl, searchUrl, sourceRule, ...)`
- `directLinkUploadRule.json` — `DirectLinkUpload.Rule(uploadUrl, uploadHeaders, uploadFileBody, downloadUrlRule, summary)`

### 2.14 `config.xml` — Android SharedPreferences 标准格式

由反射 `Context.getSharedPreferences(dir, "config")` 写出，**标准 Android prefs xml**：

```xml
<?xml version='1.0' encoding='utf-8' standalone='yes' ?>
<map>
    <int name="thread_count" value="9" />
    <boolean name="syncBookProgress" value="true" />
    <string name="web_dav_url">https://dav.jianguoyun.com/dav/</string>
    <string name="web_dav_password">{AES base64 字符串}</string>
    <long name="lastBackup" value="1731234567890" />
    <float name="textZoom" value="1.0" />
    ...
</map>
```

写入逻辑（`Backup.kt:180-202`）：

1. 反射拿到自定义路径的 `SharedPreferences`（`PreferencesExtensions.kt:23-50`）
2. 遍历 `defaultSharedPreferences.all`
3. 调 `BackupConfig.keyIsNotIgnore(key)` 过滤
4. `webDavPassword` 加密后存；其它原值
5. `edit.commit()`（同步写盘，区别于 `apply()`）

---

## 3. SharedPreferences 备份白名单 / 黑名单 (`BackupConfig.kt`)

### 3.1 始终忽略（硬编码黑名单 `ignorePrefKeys`，`BackupConfig.kt:53-64`）

```kotlin
PreferKey.defaultCover           // 默认封面路径（设备本地）
PreferKey.defaultCoverDark       // 默认封面（夜间）
PreferKey.backupPath             // 备份目录（每台设备不同）
PreferKey.defaultBookTreeUri     // 本地书架根目录 SAF Uri
PreferKey.webDavDeviceName       // 设备别名
PreferKey.launcherIcon           // 桌面图标变体
PreferKey.bitmapCacheSize        // 图片缓存上限（设备相关）
PreferKey.webServiceWakeLock     // 网页服务唤醒锁
PreferKey.readAloudWakeLock      // 朗读唤醒锁
PreferKey.audioPlayWakeLock      // 音频唤醒锁
```

### 3.2 用户可勾选忽略（动态黑名单 `ignoreConfig` map，`BackupConfig.kt:17-21`）

存在 `${filesDir}/restoreIgnore.json` 里的 `HashMap<String, Boolean>`，恢复时若 key=true 则跳过这一组。可勾选项 (`BackupConfig.kt:29-50`)：

| key | 勾选时跳过的 prefs |
|---|---|
| `readConfig` | `readPrefKeys`（14 个，readStyleSelect / autoReadSpeed / clickActionTL/TC/TR/ML/MC/MR/BL/BC/BR / shareLayout / hideStatusBar / hideNavigationBar / comicStyleSelect） + `readConfig.json` + `shareReadConfig.json` 文件 |
| `themeMode` | `theme_mode` 单 key |
| `themeConfig` | `themePrefKeys`（12 个：cPrimary / cAccent / cBackground / cBBackground / bgImage / bgImageBlurring + 夜间各 6 个） |
| `coverConfig` | `coverPrefKeys`（6 个：useDefaultCover / loadCoverOnlyWifi / coverShowName / coverShowAuthor / coverShowNameN / coverShowAuthorN） |
| `bookshelfLayout` | `bookshelfLayout` 单 key |
| `showRss` | `showRss` 单 key |
| `threadCount` | `threadCount` 单 key |
| `localBook` | 备份时不影响；恢复时跳过本地书（`Restore.kt:111-114`）— `book.isLocal` 整本忽略 |

### 3.3 决策函数 `keyIsNotIgnore(key)` (`BackupConfig.kt:109-121`)

```kotlin
when {
    ignorePrefKeys.contains(key) -> false             // 始终忽略（黑名单）
    ignoreReadConfig && readPrefKeys.contains(key) -> false
    ignoreThemeConfig && themePrefKeys.contains(key) -> false
    ignoreCoverConfig && coverPrefKeys.contains(key) -> false
    PreferKey.themeMode == key && ignoreThemeMode -> false
    PreferKey.bookshelfLayout == key && ignoreBookshelfLayout -> false
    PreferKey.showRss == key && ignoreShowRss -> false
    PreferKey.threadCount == key && ignoreThreadCount -> false
    else -> true                                       // 默认全部备份（白名单 = 除上面之外的所有 key）
}
```

**结论**：`config.xml` 默认包含 `defaultSharedPreferences.all` 减去 ~10 个绝对忽略 + 用户勾选的可选忽略。所以 zip 里的 `config.xml` **可能有几十甚至上百个 key**（多年用户的累积）。

---

## 4. 恢复流程的容错策略

### 4.1 字段缺失 / 类型不匹配（`Restore.fileToListT`，`Restore.kt:295-313`）

```kotlin
private inline fun <reified T> fileToListT(path: String, fileName: String): List<T>? {
    try {
        val file = File(path, fileName)
        if (file.exists()) {
            FileInputStream(file).use {
                return GSON.fromJsonArray<T>(it).getOrThrow()
            }
        }
    } catch (e: Exception) {
        AppLog.put("$fileName\n读取解析出错\n${e.localizedMessage}", e)
        appCtx.toastOnUi("$fileName\n读取文件出错\n${e.localizedMessage}")
    }
    return null
}
```

- **整文件级 try-catch**：单个 .json 解析失败仅丢失这一张表，其它继续
- **GSON 列表级 null 检测**（`GsonExtensions.kt:70-82`）：列表中存在 null 元素时报错 "json 格式错误"
- **缺字段 = null/默认值**（GSON 默认行为，data class 默认值生效）；**多字段 = 静默忽略**
- **类型不匹配**（如 String 写成 Number）：GSON 自定义反序列化器（`StringJsonDeserializer` / `IntJsonDeserializer`）做了一层兼容（GsonExtensions.kt:34-35）

### 4.2 合并策略（**关键差异**：每张表策略不同）

| 表 | 策略 | 实现 (`Restore.kt`) |
|---|---|---|
| `Book` | **upsert**：`bookDao.has(bookUrl)` ? `update(book)` : `insert`，捕获 `SQLiteConstraintException` 失败时 fallback insert | L116-126 |
| `Bookmark` | **insert**（依赖 DAO `OnConflict.REPLACE` / `IGNORE` 的默认行为，主键 = time 毫秒级） | L128-130 |
| `BookGroup` | insert（同上） | L131-133 |
| `BookSource` | insert（PK = bookSourceUrl，OnConflict 行为决定覆盖还是丢弃） | L134-142 |
| `RssSource / RssStar / ReplaceRule / SearchKeyword / RuleSub / TxtTocRule / HttpTTS / DictRule / KeyboardAssist` | insert（同上） | L143-169 |
| `ReadRecord` | **手动 merge**：本机记录取 max readTime；他机记录直接 insert | L170-183 |
| `Server` | insert（先尝试 isJsonArray 探针，是明文则跳过解密） | L184-196 |
| `directLinkUploadRule.json` | **缓存层 ACache 写入**（不入 DB） | L197-204 |
| `themeConfig.json` | **直接 copyTo** 覆盖 `${filesDir}/themeConfig.json` + 调 `ThemeConfig.upConfig()` 重载 | L206-214 |
| `coverRule.json` | 调 `BookCover.saveCoverRule(json)` | L215-222 |
| `readConfig.json` / `shareReadConfig.json` | **直接 copyTo** 覆盖（除非 `ignoreReadConfig=true`） | L223-243 |
| `config.xml` | 遍历每个 key，按 `keyIsNotIgnore` 过滤后 `edit.put*`；webDavPassword 解密失败时只在本地未设置时才 fallback 用密文 | L245-276 |

**所以原 Legado 的恢复 = "覆盖+合并混合体"**：DB 表用 upsert/insert（OnConflict 决定细节），文件配置用整文件覆盖，Prefs 用 key 级覆盖。**没有"清空再恢复"的选项**——备份的内容是叠加到已有库。

### 4.3 特殊处理：本地书的 cover 路径修复 (`Restore.kt:107-109`)

```kotlin
it.filter { book -> book.isLocal }
    .forEach { book ->
        book.coverUrl = LocalBook.getCoverPath(book)
    }
```

本地书的 `coverUrl` 在原备份中可能指向另一台设备的本地路径，恢复时强制重算成本机 `${cacheDir}/covers/<bookHash>.jpg`。

### 4.4 `book.upType()` 调用 (`Restore.kt:103-105`)

```kotlin
it.forEach { book -> book.upType() }
```

老格式 Book 没有 type 字段（或 type 缺失），通过 `BookHelpExt.upType()` 根据 `origin` 重算（loc_book → text+local，audio prefix → audio 等）。

---

## 5. WebDav 同步（备份的远端通道，下批次会用）

### 5.1 URL 结构 (`AppWebDav.kt:41-72`)

```
{rootWebDavUrl}                          ← https://dav.jianguoyun.com/dav/  +  AppConfig.webDavDir 子目录
  ├── backup2026-05-19-Pixel.zip         ← 备份（PUT，扁平存放，按 displayName.startsWith("backup") 列表）
  ├── backup2026-05-18.zip
  ├── ...
  ├── bookProgress/                      ← 阅读进度（每书一文件）
  │   ├── 斗破苍穹_天蚕土豆.json
  │   └── ...
  ├── books/                             ← 导出 txt/epub 的目录
  │   └── ...
  └── background/                        ← 阅读背景图
      └── bg1.jpg
```

### 5.2 HTTP 方法（`WebDav.kt`）

| 方法 | 路径示例 | 触发场景 | Headers |
|---|---|---|---|
| `PROPFIND` (Depth=1) | `{root}` | `listFiles()` 列备份/进度/背景 | `Depth: 1`, body=XML 指定返回属性 |
| `PROPFIND` (Depth=0) | `{root}{file}` | `exists()` / `check()` 探活 | `Depth: 0`, body=`<propfind><prop><resourcetype/>` |
| `MKCOL` | `{root}` / `{root}books/` / `{root}bookProgress/` / `{root}background/` | `makeAsDir()` 初始化目录 | 无 body |
| `PUT` | `{root}backup2026-05-19.zip` | `upload()` 备份 zip / 阅读进度 / 背景图 | Content-Type=application/octet-stream（默认）或 application/json / text/plain |
| `GET` | `{root}backup2026-05-19.zip` | `downloadInputStream()` | 无 |
| `DELETE` | `{root}{file}` | `delete()` | 无 |

- 鉴权：`Authorization: Basic base64(account:password)`（`Authorization.kt`）
- 自定义 scheme：URL 支持 `davs://` / `dav://`（替换为 https/http）和 `serverID://` 解析（`WebDav.kt:84-92`）
- XML 解析：`Jsoup.parse(body, Parser.xmlParser())`，提取 `<DAV:response>` 数组

### 5.3 备份 zip 的 PUT 路径 (`AppWebDav.kt:163-169`)

```kotlin
suspend fun backUpWebDav(fileName: String) {
    if (!NetworkUtils.isAvailable()) return
    authorization?.let {
        val putUrl = "$rootWebDavUrl$fileName"
        WebDav(putUrl, it).upload(Backup.zipFilePath)   // PUT zip 整包
    }
}
```

**关键事实**：zip 文件**直接 PUT**，不分片、不增量、不版本号 ——  WebDav 服务器若已存在同名 zip 直接覆盖。多设备同步靠 `-${deviceName}` 后缀避免冲突。

### 5.4 自动备份触发 (`Backup.kt:104-121`)

- `Backup.autoBack(ctx)`：每天最多一次（`shouldBackup() = lastBackup + 24h < now`）
- 检查 WebDav 上是否已有今日 zip（`AppWebDav.hasBackUp(name)`），有则跳过实际备份只更新本地时间戳。
- 使用 `Mutex` 保证同一时刻只一个备份线程。

---

## 6. Flutter+Rust 端口的字段映射表

### 6.1 Book 字段映射（**需要重点关注，差异最大**）

原 Legado `Book.kt` 共 31 字段（含 `readConfig` 嵌套 12 子字段），Flutter `core-storage::models::Book` 共 26 字段（`models.rs:73-111`）。

| 原 Legado 字段 | Flutter 端口对应 | 映射关系 | 缺失/转换 |
|---|---|---|---|
| `bookUrl` (PK) | `book_url: Option<String>` | 直接映射；Flutter 端 PK 是 UUID `id`，需另存 | ⚠️ 主键不一致：导入时新生成 UUID，把原 bookUrl 存到 book_url 字段，并用 (book_url) 唯一索引去重 |
| `tocUrl` | `toc_url: Option<String>` | 1:1 | — |
| `origin` | `source_id: String` | **语义不同**：原 = 书源 URL；新 = 书源 UUID。导入时 lookup `book_sources WHERE url=?` 拿 source_id，找不到时存原 URL |
| `originName` | `source_name: Option<String>` | 1:1 | — |
| `name` | `name: String` | 1:1 | — |
| `author` | `author: Option<String>` | 1:1（原是非空 String，新是 Option） | — |
| `kind` | `kind: Option<String>` | 1:1 | — |
| `customTag` | — | ❌ **缺失** | 丢弃或塞 `custom_info_json` |
| `coverUrl` | `cover_url: Option<String>` | 1:1（本地书要用 `LocalBook.getCoverPath` 重算，端口暂未实现） | — |
| `customCoverUrl` | `custom_cover_path: Option<String>` | 名字差但语义同 | — |
| `intro` | `intro: Option<String>` | 1:1 | — |
| `customIntro` | — | ❌ **缺失** | 塞 `custom_info_json` |
| `charset` | — | ❌ 缺失（本地书相关） | 塞 `custom_info_json` |
| `type` | — | ❌ **缺失**：原是 BookType bitmask（0=text, 1=audio, 2=image, ...） | 重要：**导入本地书 / 音频 / 漫画时此字段决定阅读器形态**，建议存 `custom_info_json`，未来加专门列 |
| `group` (Long bitmask) | `group_id: i64` | ⚠️ **语义破坏**：原 bitmask = 多分组；新 = 单分组外键 | 建议导入时取 lowest set bit 作为单分组 ID，记录警告 |
| `latestChapterTitle` | `latest_chapter_title: Option<String>` | 1:1 | — |
| `latestChapterTime` | `latest_chapter_time: Option<i64>` | 1:1（毫秒 → 秒？需确认；新端口注释说"批次 6"未明，**原 Legado 是毫秒**） | ⚠️ 单位转换：原 ms，新如果存 ms 直接拷；如果存秒要除 1000 |
| `lastCheckTime` | `last_check_time: Option<i64>` | 同上单位问题 | — |
| `lastCheckCount` | `last_check_count: i32` | 1:1 | — |
| `totalChapterNum` | `chapter_count: i32` | 改名 | — |
| `durChapterTitle` | `dur_chapter_title: Option<String>` | 1:1（批次 6 已加） | — |
| `durChapterIndex` | `dur_chapter_index: i32` | 1:1（批次 6 已加） | — |
| `durChapterPos` | `dur_chapter_pos: i32` | 1:1（批次 6 已加） | — |
| `durChapterTime` | `dur_chapter_time: i64` | 1:1，单位问题同上 | — |
| `wordCount` | `total_word_count: i32` | ⚠️ 类型不同：原是 String（如 "5.2M"），新是 int。导入时需要解析 K/M/万 后缀 | ⚠️ 解析或丢弃 |
| `canUpdate` | `can_update: bool` | 1:1 | — |
| `order` | `order_time: i64` | ❌ **语义不同**：原 = Int 手动排序号；新 = i64 时间戳？新字段名 order_time 暗示时间戳。建议把原 order 存到 custom_info_json | ⚠️ |
| `originOrder` | — | ❌ 缺失 | 塞 custom_info_json |
| `variable` | — | ❌ 缺失（书源 JS 用） | 塞 custom_info_json |
| `readConfig` (nested) | — | ❌ **整个嵌套对象都缺失** | 整 JSON 序列化后塞 custom_info_json |
| `syncTime` | — | ❌ 缺失 | 塞 custom_info_json |
| — | `id: String (UUID)` | 端口新加 | 导入时 `uuid::Uuid::new_v4()` |
| — | `created_at` / `updated_at` | 端口新加 | 导入时 `now_timestamp()` |

**总结：**

- **直接 1:1 映射的字段**：bookUrl, tocUrl, originName→source_name, name, kind, coverUrl, customCoverUrl→custom_cover_path, intro, latestChapterTitle, lastCheckCount, durChapterTitle/Index/Pos, canUpdate, totalChapterNum→chapter_count
- **需要语义转换的字段**：origin（URL → source_id 查表）、group（bitmask → 单 ID）、wordCount（String → int 解析）、order（Int → i64）、所有时间戳（确认 ms vs s）
- **完全丢失到 custom_info_json 的字段**：customTag, customIntro, charset, type, originOrder, variable, readConfig（整体）, syncTime → 7 字段
- **完全新增、备份没有的字段**：id（UUID）、created_at、updated_at → 导入时填默认

### 6.2 BookGroup 字段映射

| 原 Legado | Flutter | 备注 |
|---|---|---|
| `groupId: Long` (bitmask) | `id: i64` (auto increment) | ⚠️ **bitmask → 自增 ID 转换**：导入时按 groupId 升序处理，给每个一个新自增 ID，建立旧 bitmask → 新 id 映射表，再用映射表把 `Book.group` 转成 `Book.group_id` |
| `groupName` | `name: String` | 1:1 |
| `cover` | `cover: Option<String>` | 1:1 |
| `order` | `sort_order: i32` | 改名 |
| `enableRefresh` | — | ❌ 缺失 |
| `show` | `show: bool` | 1:1 |
| `bookSort` | `book_sort: i32` | 1:1 |
| — | `created_at`/`updated_at` | 新增 |

### 6.3 Bookmark 字段映射

| 原 Legado | Flutter | 备注 |
|---|---|---|
| `time: Long` (PK) | `id: String (UUID)` | ⚠️ PK 不同；导入新生成 UUID，把 time 存到 created_at |
| `bookName` | `book_name: Option<String>` | 1:1（批次 6 已加） |
| `bookAuthor` | `book_author: Option<String>` | 1:1（批次 6 已加） |
| `chapterIndex` | `chapter_index: i32` | 1:1 |
| `chapterPos` | `chapter_pos: i32` | 1:1（批次 6 已加） |
| `chapterName` | `chapter_name: Option<String>` | 1:1（批次 6 已加） |
| `bookText` | `book_text: Option<String>` | 1:1（批次 6 已加） |
| `content` | `content: Option<String>` | 1:1 |
| — | `book_id: String` | ⚠️ Flutter 必填外键，但备份只有 (bookName, bookAuthor)。导入时 lookup `books WHERE name=? AND author=?` 拿 book_id；查不到则书签丢失或软关联 |
| — | `paragraph_index: i32` | ❌ 备份没有；填 0 |
| — | `created_at` | = `time` 毫秒转秒 |

### 6.4 ReplaceRule 字段映射

| 原 Legado | Flutter | 备注 |
|---|---|---|
| `id: Long` | `id: String (UUID)` | 新生成 |
| `name` | `name` | 1:1 |
| `group` | — | ❌ 缺失 |
| `pattern` | `pattern` | 1:1 |
| `replacement` | `replacement` | 1:1 |
| `scope` | `scope` | 1:1（已对齐 R24） |
| `scopeTitle` | `scope_title` | 1:1 |
| `scopeContent` | `scope_content` | 1:1 |
| `excludeScope` | `exclude_scope` | 1:1 |
| `isEnabled` | `enabled` | 改名 |
| `isRegex` | — | ❌ Flutter 端假设全是正则？需要确认，否则导入时丢失"非正则字符串替换"语义 |
| `timeoutMillisecond` | — | ❌ 缺失 |
| `order` (json key) | `sort_number` (改名) | 1:1 |

### 6.5 ReadRecord 字段映射

| 原 Legado | Flutter | 备注 |
|---|---|---|
| `deviceId` (PK 一半) | — | ❌ 端口已弃；导入时只取本机记录或合并 |
| `bookName` (PK 一半) | `book_name: String` | 1:1 |
| `readTime` | `read_time: i64` | 1:1（毫秒？秒？确认） |
| `lastRead` | `last_read_at: i64` | 1:1（同上） |
| — | `id: String (UUID)` | 新生成 |
| — | `book_id: String` | lookup books WHERE name=? |

### 6.6 BookSource 字段映射

差异**很大**（原 26 字段 vs 端口 ~30 字段，但布局不同）。**关键陷阱**：原 Legado PK 是 `bookSourceUrl`（URL 字符串），端口 PK 是 `id` (UUID)。所有 `Book.origin / scope` 引用 URL 的字段都需要在导入完所有书源后做二次 patch 把 URL → UUID。

| 原 Legado | Flutter | 备注 |
|---|---|---|
| `bookSourceUrl` (PK) | `url: String` + `id` 新生成 UUID | 用 (url) 唯一索引 |
| `bookSourceName` | `name` | 1:1 |
| `bookSourceGroup` | `group_name: Option<String>` | 1:1 |
| `bookSourceType` | `source_type: i32` | 1:1 |
| `bookUrlPattern` | `book_url_pattern` | 1:1 |
| `customOrder` | `custom_order: i32` | 1:1 |
| `enabled` | `enabled: bool` | 1:1 |
| `enabledExplore` | `enabled_explore: bool` | 1:1 |
| `jsLib` | `js_lib` | 1:1 |
| `enabledCookieJar` | — | ❌ 缺失 |
| `concurrentRate` | `concurrent_rate` | 1:1 |
| `header` | `header` | 1:1 |
| `loginUrl` | `login_url` | 1:1 |
| `loginUi` | `login_ui` | 1:1 |
| `loginCheckJs` | `login_check_js` | 1:1 |
| `coverDecodeJs` | `cover_decode_js` | 1:1 |
| `bookSourceComment` | `book_source_comment` | 1:1 |
| `variableComment` | `variable_comment` | 1:1 |
| `lastUpdateTime` | `last_update_time: i64` | 1:1 |
| `respondTime` | — | ❌ 缺失 |
| `weight` | `weight: i32` | 1:1 |
| `exploreUrl` | `explore_url` | 1:1 |
| `exploreScreen` | `explore_screen: Option<i32>` | ⚠️ 类型不同：原 String，新 i32。导入需 parseInt |
| `ruleExplore`(嵌套对象) | `rule_explore: Option<String>` | ⚠️ 原是嵌套 Object，新是 JSON 字符串。导入时 `serde_json::to_string(&rule_explore)` |
| `searchUrl` + `ruleSearch` | `rule_search: Option<String>` | 嵌套→字符串 + searchUrl 缺失（需塞进 rule_search JSON 或新加列） |
| `ruleBookInfo` | `rule_book_info` | 嵌套→字符串 |
| `ruleToc` | `rule_toc` | 嵌套→字符串 |
| `ruleContent` | `rule_content` | 嵌套→字符串 |
| `ruleReview` | — | ❌ 缺失（段评功能） |

### 6.7 缺失字段的统一处理建议

原 Legado 端口已经有 `Book.custom_info_json` 字段（`models.rs:93`），可以把所有"丢失字段"作为 JSON 对象塞这里：

```json
{
  "_legado_backup": {
    "type": 0,
    "customTag": null,
    "customIntro": null,
    "charset": null,
    "originOrder": 0,
    "variable": null,
    "readConfig": { ... },
    "syncTime": 0,
    "originalGroupBitmask": 7
  }
}
```

这样未来恢复 / 二次导出回 Legado zip 时还能保住信息。

---

## 7. Flutter 端导入 / 导出工作量速估

### 7.1 导出（Flutter → Legado zip）

| 步骤 | 涉及表 | 难度 |
|---|---|---|
| books → bookshelf.json | `books` | M（字段映射 + 单位转换 + group_id → bitmask 反向映射） |
| book_groups → bookGroup.json | `book_groups` | S（自增 id → bitmask 1<<i） |
| bookmarks → bookmark.json | `bookmarks` | M（book_id → 反查 name+author） |
| book_sources → bookSource.json | `book_sources` | L（rule_search 等字符串 → 嵌套 Object 反序列化） |
| replace_rules → replaceRule.json | `replace_rules` | S |
| read_records → readRecord.json | `read_records` | S（deviceId 用 androidId 或新 UUID） |
| 其它表 | 大部分缺数据，写空 list 或不写 | S |
| 6 个 config json | 端口暂无对应概念，**写空对象或不写** | — |
| config.xml | 端口用 sled / sqlite kv，**重新映射 PreferKey 名字** | L |
| AES 加密 webDavPassword | 用户输的备份密码 + Hutool 兼容（**Rust 侧需要找 AES/ECB/PKCS5 + MD5("") 取前 16 字节**） | M |
| zip 打包 | Rust crate `zip` | S |

### 7.2 导入（Legado zip → Flutter DB）

倒过来。同样难度：S~M。**额外**注意：

- **bookSource.json 必须先导**：books / replace_rules 都引用 source_id，需要先建好 (url → uuid) 映射表
- **bookGroup.json 必须先导**：books 引用 group_id，需要 (bitmask → uuid) 映射表
- **本地书 (origin = "loc_book")**：cover 路径要重算；book 文件本身**不在 zip 里**（备份不含原始 epub/txt 文件，只有元数据），导入后要用户手动重新 import 文件
- **加密兜底**：servers.json 先 isJsonArray 探针，失败再 AES 解密；config.xml 里 webDavPassword 同理
- **失败容错**：每张表单独 try-catch，失败只丢这一张
- **空 json 跳过**：zip 里如果某 .json 不存在（空表），import 直接跳过

---

## 8. 注意事项 / 暗坑清单

1. **GSON 对 null 的处理**：`disableHtmlEscaping + setPrettyPrinting`，**默认序列化 null**（不是 omit）。所以原 zip 里 `"customTag": null` 这种 key 一定存在。Flutter 端用 `serde_json` 默认 `skip_serializing_if = "Option::is_none"` 时，如果想生成"长得像 Legado"的 zip 需要去掉 skip。

2. **时间戳单位**：原 Legado 全部 **毫秒**（`System.currentTimeMillis()`），Flutter `core-storage` 注释（`models.rs:286`）写 `read_time: i64 // 累计阅读时长（秒）`。两边单位**不一致**，转换必须做。

3. **GSON.LONG_OR_DOUBLE**：原 Legado 数字反序列化时全部 Long 优先，整数 "0" 会变成 Long(0) 而不是 Int(0)。Rust 用 `serde_json` 默认 i64 OK。

4. **ReplaceRule.order vs sortOrder**：Room 列名 `sortOrder`，Kotlin 字段 `order`，**zip JSON 用的是 `order`**（GSON 不读 Room 注解）。Flutter 的 `sort_number` 改了名，导入导出时需要 `#[serde(rename = "order")]`。

5. **本地书 (`isLocal`) 的 coverUrl**：原 `Book.kt` 备份的 coverUrl 可能是设备相关 path；恢复时强制重算。Flutter 端导入时如果本地书不导入文件，cover 直接置 null 比较安全。

6. **`config.xml` 不是 JSON**：是 Android `SharedPreferences.xml` 标准格式，Rust 侧需要 XML 解析（`<int>/<string>/<long>/<float>/<boolean>` 标签）+ 写入也要按这个格式。Flutter 端没有 SharedPreferences 概念，需要把 PreferKey 映射到自己的设置 schema（很多 key 大概率没意义会被丢弃）。

7. **ImportOldData 老格式回退**：`Restore.kt:136-142` 在 `bookSource.json` 解析失败时调用 `ImportOldData.importOldSource()`，处理的是更老（v2.x）的备份格式。Flutter 端**不需要**支持这个回退（v3.x 之前的备份基本绝迹）。

8. **WebDav AES 加密 webDavPassword 的兼容**：Hutool `AES()` 默认 `AES/ECB/PKCS5Padding`。Rust 需用 `aes` + `block-modes` crate，padding 用 PKCS7（PKCS5/PKCS7 等价）。Key = `MD5(密码字符串).bytes()[0..16]`，**密码空串时 = MD5("")[0..16] = `D41D8CD98F00B204E9800998` 的前 16 字节**。

9. **bookGroup.bitmask 上限**：Long 64 位，所以原 Legado 最多 64 个分组。Flutter 端 i64 自增，如果用户原有 70 个分组无法保留多重分组语义。

10. **Mutex 与 Flutter**：原 Legado 用 `kotlinx.coroutines.sync.Mutex`，Flutter 端导入导出操作建议也加全局 lock 防止并发损坏。

---

## 9. 不在本调研范围 / 未深入

- `ImportOldData.kt` (372 行)：老 v2.x 格式回退，只在 bookSource fallback 用一次。**Flutter 端口可不实现**。
- 自定义 Json 反序列化器（`ExploreRule.jsonDeserializer` 等）：复杂的字符串 / 数组类型双兼容，**只在 bookSource.json 里 6 个 rule 嵌套对象内部**，Flutter 端如果决定把整个 rule_search 当 String 不展开则不需要管。
- WebDav 之外的导出通道（`exportsWebDavUrl` 用于 txt/epub 导出，不是 zip 备份相关，已在第二批 feature-gap 报告涵盖）。
- `RemoteBookWebDav.kt`：远程书架（直接读 WebDav 上的 epub），与本地备份链路无关。
- `LocalConfig.password`：备份密码 UI / 持久化，原项目存在 prefs，端口需要新加 settings 项。
- `androidId` / `deviceId` 的端口替代：原项目 `AppConst.androidId = Settings.Secure.ANDROID_ID`，Flutter 端可用 `device_info_plus` 或自生成 UUID（影响 ReadRecord 表迁移策略）。
