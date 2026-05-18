> # Task 1 — 搜索精确模式

**MD3 体感复刻 7 任务序列的最后一个独立功能**。

## Goal

搜索页 AppBar 加 toggle 按钮，开启时对搜索结果做客户端"精确模式"过滤：丢弃既不包含书名又不包含作者关键词的条目，按 equal/contains 三档排序。默认关闭。持久化偏好。

跟 Legado MD3 行为对齐。**Rust 端零改动**——纯 Flutter UI + 客户端过滤。

## Background

### 用户原话

"搜索建议增加精确搜索功能 默认搜索模式为调用书源搜索"

### Legado MD3 做法 (前期研究已确认)

- options menu / TopBar action 切 PreferKey.precisionSearch boolean
- SearchModel.startSearch 用 filter lambda 在网络抓取层丢弃
  `!precision || name.contains(searchKey) || author.contains(searchKey)`
- mergeItems 排序：equalData (name == query / author == query) → containsData → otherData (precision 模式丢弃)

### Flutter 现状 (search_page.dart)

- `_doSearch` (line 223) / `_doSearchViaSse` (line 297) 是搜索入口
- `_results.value = deduped` (line 267) 把结果灌进 ValueNotifier
- AppBar 当前 `title: const Text('搜索')`，没 actions

### 实现策略

**纯客户端过滤 + 排序**（不动 Rust）：
- 在 `_doSearch` / `_doSearchViaSse` 结果聚合后 if precision 走过滤+重排
- 排序：先 equalData (name == kw OR author == kw)，再 containsData，丢弃其余

## Requirements

- **N1.1**：SharedPreferences 加 key `search_precision_enabled` (bool, 默认 false)
- **N1.2**：load/save helper：`loadSearchPrecisionFromDisk` / `saveSearchPrecisionToDisk`（参考 search_history 已有同模式）
- **N1.3**：search_page.dart `initState` 调 load
- **N1.4**：AppBar 加 IconButton toggle —— icon `Icons.youtube_searched_for` (开) / `Icons.search` (关)，tooltip "精确搜索 / 模糊搜索"，onPressed 切 `_precisionMode` 状态 + 保存 + 如果当前 `_searchCtrl.text` 非空，立即重跑 `_doSearch`
- **N1.5**：结果聚合后客户端过滤+排序：
  ```
  if precision:
    final equalData = results.where((r) =>
      r['name'] == kw || r['author'] == kw).toList();
    final containsData = results.where((r) =>
      r != /* not in equal */ && (r['name'].contains(kw) || r['author'].contains(kw))).toList();
    final filtered = [...equalData, ...containsData];
    _results.value = filtered;  // otherData 丢弃
  ```
- **N1.6**：空结果引导 dialog："精确搜索无结果，是否切回模糊搜索？" → 用户选"是"则 toggle off + 重跑搜索
- **N1.7**：测试覆盖（unit）：
  - 默认 prefs 值 false
  - load/save round-trip
  - 过滤函数：name == kw 优先，author == kw 次之，contains 第三档
  - 全不匹配丢弃

## Acceptance Criteria

- [ ] SharedPreferences key + load/save
- [ ] AppBar toggle 按钮工作 + 持久化
- [ ] _doSearch / _doSearchViaSse 结果链路加过滤
- [ ] 空结果引导 dialog
- [ ] 单测 ≥ 5 用例
- [ ] flutter analyze 0 issue
- [ ] xvfb-run flutter test 全绿（188 baseline + 新增）

## Definition of Done

- 单一 commit "第二十八批 — 搜索精确模式"
- libbridge.so / Rust / FRB 零改动

## Technical Approach

### 1. providers.dart 加 helper

```dart
// 参考已有 loadSearchHistoryFromDisk pattern
const String _kSearchPrecisionKey = 'search_precision_enabled';

Future<bool> loadSearchPrecisionFromDisk() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool(_kSearchPrecisionKey) ?? false;
}

Future<void> saveSearchPrecisionToDisk(bool enabled) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool(_kSearchPrecisionKey, enabled);
}
```

### 2. search_page.dart 加 state + UI

```dart
bool _precisionMode = false;

@override
void initState() {
  super.initState();
  _loadHistory();
  _loadPrecisionMode();  // ← 新增
}

Future<void> _loadPrecisionMode() async {
  final v = await loadSearchPrecisionFromDisk();
  if (mounted) setState(() => _precisionMode = v);
}

void _togglePrecisionMode() {
  setState(() => _precisionMode = !_precisionMode);
  saveSearchPrecisionToDisk(_precisionMode);
  if (_searchCtrl.text.trim().isNotEmpty) {
    _doSearch();  // 重跑
  }
}

// build：AppBar 加 actions
appBar: AppBar(
  title: const Text('搜索'),
  actions: [
    IconButton(
      icon: Icon(_precisionMode
          ? Icons.youtube_searched_for
          : Icons.search),
      tooltip: _precisionMode ? '精确搜索（已开启）' : '模糊搜索',
      onPressed: _togglePrecisionMode,
    ),
  ],
),
```

### 3. 过滤函数

```dart
// 加 static 工具函数让单测能直接调
@visibleForTesting
static List<Map<String, dynamic>> applyPrecisionFilter(
    List<Map<String, dynamic>> results, String keyword) {
  final equalName = <Map<String, dynamic>>[];
  final equalAuthor = <Map<String, dynamic>>[];
  final contains = <Map<String, dynamic>>[];
  for (final r in results) {
    final name = r['name'] as String? ?? '';
    final author = r['author'] as String? ?? '';
    if (name == keyword) {
      equalName.add(r);
    } else if (author == keyword) {
      equalAuthor.add(r);
    } else if (name.contains(keyword) || author.contains(keyword)) {
      contains.add(r);
    }
    // 不匹配的丢弃
  }
  return [...equalName, ...equalAuthor, ...contains];
}
```

### 4. _doSearch / _doSearchViaSse 调用过滤

```dart
// _doSearch 路径 (line 256-267 附近)
final flatResults = allResults.expand((r) => r).toList();
final seen = <String>{};
final deduped = <Map<String, dynamic>>[];
for (final r in flatResults) {
  final key = '${r['name']}_${r['author']}';
  if (seen.add(key)) deduped.add(r);
}
final finalResults = _precisionMode
    ? SearchPage.applyPrecisionFilter(deduped, keyword)
    : deduped;
_results.value = finalResults;

if (_precisionMode && finalResults.isEmpty && deduped.isNotEmpty) {
  _showPrecisionEmptyDialog();
}
```

`_doSearchViaSse` 同样在每次 SSE event 累积后过滤。

### 5. 空结果引导

```dart
void _showPrecisionEmptyDialog() {
  if (!mounted) return;
  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('精确搜索无结果'),
      content: const Text('当前精确搜索模式无匹配结果，是否切换到模糊搜索？'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('保持精确'),
        ),
        FilledButton(
          onPressed: () {
            Navigator.of(ctx).pop();
            _togglePrecisionMode();
          },
          child: const Text('切换到模糊'),
        ),
      ],
    ),
  );
}
```

## Out of Scope

- 不改 Rust search API 签名（保持 keyword 单参数）
- 不动书源解析层
- 不加搜索建议下拉浮层
- 不加 SearchScope 多选范围
- 不动 _searchHistory 已有逻辑

## Technical Notes

### 关键 file:line

- `flutter_app/lib/features/search/search_page.dart:22-49` — _searchHistory state
- `flutter_app/lib/features/search/search_page.dart:223-282` — _doSearch
- `flutter_app/lib/features/search/search_page.dart:297-355` — _doSearchViaSse
- `flutter_app/lib/features/search/search_page.dart:401-432` — build AppBar / TextField
- `flutter_app/lib/core/providers.dart` — loadSearchHistoryFromDisk pattern
