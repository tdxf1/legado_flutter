# BATCH-21b: RSS detail page FRB 桥优化

**Stage**: P1 (follow-up of BATCH-21)
**Slug**: `rss-detail-frb-bridge`
**Effort**: S (~150 行)
**Depends on**: BATCH-21 ✅（detail _bootstrap 已并行化，仅缺 FRB 桥消除全数组遍历）

## 1. 范围

加 FRB 桥 `rss_article_get_by_origin_link`，把 RSS detail 页的"全数组遍历找 widget.link"（rust_api.rssListArticles → jsonDecode → for 找 link）替换为单条 SQL 查询。

dao + 单测已就绪（`rss_article_dao::get_by_origin_link` line 147 + line 464 测试 3 case），仅需手动 wire FRB pub fn + binding regen + caller 改 1 处。

## 2. 包含的 finding

| Finding | 当前行号 | 实施 |
|---------|---------|------|
| F-W2B-009 (FRB 桥部分) | `rss_article_detail_page.dart:160-171`（articleFuture 内 rssListArticles + for 找 link） | 加 FRB pub fn `rss_article_get_by_origin_link` + 手动 wire + dart caller 替换 |

## 3. 影响文件

### `core/bridge/src/api.rs`
- 在 line 1993 `rss_list_articles` 后新增：
  ```rust
  /// 按 (origin, link) 取单条 RSS 文章，返回 JSON 或 "null"。
  pub fn rss_article_get_by_origin_link(
      db_path: String,
      origin: String,
      link: String,
  ) -> Result<String, String> {
      let conn = open_db(&db_path)?;
      let dao = core_storage::rss_article_dao::RssArticleDao::new(&conn);
      let article = dao
          .get_by_origin_link(&origin, &link)
          .map_err(|e| format!("查询 RSS 文章失败: {}", e))?;
      match article {
          Some(a) => serde_json::to_string(&a).map_err(|e| format!("序列化失败: {}", e)),
          None => Ok("null".into()),
      }
  }
  ```

### `core/bridge/src/frb_generated.rs`（手动 wire，funcId 110）
- 在 line 1797 `wire__crate__api__rss_list_articles_impl` 末尾后新增 `wire__crate__api__rss_article_get_by_origin_link_impl`，签名按 line 1763-1797 模板，3 个 String 入参。
- 在 line 4253 `109 => wire__crate__api__validate_source_live_impl(...)` 之后加 `110 => wire__crate__api__rss_article_get_by_origin_link_impl(port, ptr, rust_vec_len, data_len),`

### `core/bridge/build.rs`
- `REQUIRED_WIRE_FN_FRAGMENTS`（line 26-129）末加 funcId 110 entry：
  ```rust
  // 批次 22 (RSS detail FRB 桥) — 1 个 wire fn (funcId 110)
  "wire__crate__api__rss_article_get_by_origin_link_impl",
  ```
- `REQUIRED_DISPATCHER_FRAGMENTS`（line 131-209）末加：
  ```rust
  // 批次 22 (RSS detail FRB 桥) 手动 dispatch 注册
  "        110 =>",
  ```

### `flutter_app/lib/src/rust/api.dart`
- 在 line 702 `rssListArticles` 后新增（约 8 行）：
  ```dart
  /// 按 (origin, link) 单条查询 RSS 文章，返回 JSON 或 "null"。
  /// detail 页打开走这个，避免全数组遍历。
  Future<String> rssArticleGetByOriginLink(
          {required String dbPath, required String origin, required String link}) =>
      RustLib.instance.api.crateApiRssArticleGetByOriginLink(
          dbPath: dbPath, origin: origin, link: link);
  ```

### `flutter_app/lib/src/rust/frb_generated.dart`（手动 wire dart 端 callFfi）
- 在 abstract class `RustLibApi`（line 478 附近 `crateApiValidateSourceLive` 声明前/后）加：
  ```dart
  Future<String> crateApiRssArticleGetByOriginLink(
      {required String dbPath, required String origin, required String link});
  ```
- 在 `class RustLibApiImpl`（line 3486 附近，`crateApiValidateSourceLive` 后）加 callFfi 实现（参考 `crateApiRssListArticles` 模板 line 3009-3033），funcId: 110。

### `flutter_app/lib/features/rss/rss_article_detail_page.dart`
- line 158-171 `articleFuture`：把 `rust_api.rssListArticles` + `jsonDecode + for` 整个 IIFE 替换为：
  ```dart
  final articleFuture = widget.articleOverride != null
      ? Future<Map<String, dynamic>?>.value(widget.articleOverride)
      : (() async {
          final raw = await rust_api.rssArticleGetByOriginLink(
              dbPath: dbPath, origin: widget.sourceUrl, link: widget.link);
          if (raw.isEmpty || raw == 'null') return null;
          return jsonDecode(raw) as Map<String, dynamic>?;
        })();
  ```
- 删 line 145-146 的 BATCH-21 留言注释（"FRB 桥 ... 留 BATCH-21b 加"）。

### test
- `flutter_app/test/rss_article_detail_test.dart`（如已存在 detail page test）：核实 `articleOverride` 路径不受影响，原 test 用 override 跑过去就行。
- `core/bridge` 没有专门的 FRB pub fn 单测（dao 已有 3 case `test_get_by_origin_link`）；本批不强求加新单测。

## 4. 测试策略

- `cargo build -p bridge`：build.rs 的 funcId guard 必须通过（这是 FRB 桥的硬约束）
- `cargo test --workspace`：dao 现有 3 case 必须 PASS（baseline 421 不掉）
- `cd flutter_app && flutter analyze`：0 issue
- `cd flutter_app && flutter test`：baseline 523 必须 PASS（新 caller 走相同 override 路径，原 detail test 不挂）
- **不在范围**：触发 `build_android_debug.sh` 重打包 .so（dev 端跑 flutter test 用 dart-vm，不依赖 .so；用户端要重 build）

## 5. 验收

- [ ] `pub fn rss_article_get_by_origin_link` 加在 `core/bridge/src/api.rs`
- [ ] `wire__crate__api__rss_article_get_by_origin_link_impl` 手动加在 `core/bridge/src/frb_generated.rs`
- [ ] dispatcher arm `110 =>` 加在 frb_generated.rs
- [ ] build.rs 的 REQUIRED_WIRE_FN_FRAGMENTS + REQUIRED_DISPATCHER_FRAGMENTS 各加 1 entry
- [ ] dart `api.dart::rssArticleGetByOriginLink` + `frb_generated.dart::crateApiRssArticleGetByOriginLink` (abstract + impl) 加好
- [ ] `rss_article_detail_page.dart` _bootstrap 内 articleFuture 改用新 FRB 桥
- [ ] cargo build -p bridge 0 error；cargo test --workspace PASS；flutter analyze 0；flutter test 523 PASS
- [ ] master finding F-W2B-009 标 Resolved by BATCH-21b（路线图 follow-up 收尾）

## 6. 不在范围

- 自动 codegen（FRB 在本仓 codegen 屡次超时，所有新 fn 都手动 wire；本批跟随）
- detail rollback 通信机制（BATCH-21c future work，需要 GoRouter / Riverpod 通信）
- list_page 的 listArticles 路径（list page 本来就需要全数组渲染，不优化）
- 用户端 .so 重打包（build_android_release.sh 在 release 时统一处理）

## 7. 风险点

- **funcId 同步**：build.rs guard + frb_generated.rs dispatcher + frb_generated.dart funcId 三处必须同步加 110；漏一处 cargo build 会 fail。按 PRD §3 顺序实施。
- **wire fn 模板**：`wire__crate__api__rss_article_get_by_origin_link_impl` 必须严格按 `wire__crate__api__rss_list_articles_impl` 模板（3 String 入参 → Result<String, String>）抄；多/少一个 sse_decode 调用会让 dart 端反序列化错乱。
- **dart 端 RustLibApi abstract method**：`crateApiRssArticleGetByOriginLink` 必须在 abstract class 声明 + impl class 实现两处都加，否则 dart 编译挂。
- **null 处理**：dao 返回 `Option<RssArticle>`，None 时 FRB pub fn 返回 `Ok("null".into())`，dart 端检查 `raw == 'null'`。这与 `rss_source_get` 现有 null 模式一致。
