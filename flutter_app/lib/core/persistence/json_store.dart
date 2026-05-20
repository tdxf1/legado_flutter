import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// `settings.json` 的 IO helper —— 把 `core/providers.dart` 里 17 个
/// load/save/clear 函数共享的 read-modify-write 模板抽到一处。
///
/// ## 用法
///
/// ```dart
/// // 读：传入 key、parse fn 与 default。文件 / key 不存在 / parse 抛异常
/// // 全部 fallback 到 default。
/// final fontSize = await readJsonKey<double>(
///   'fontSize',
///   (raw) => raw is num ? raw.toDouble().clamp(14.0, 28.0) : 18.0,
///   18.0,
/// );
///
/// // 写：value 必须是 jsonEncode 可序列化类型。errorTag 用于失败时的
/// // debugPrint 文案（'Failed to save $errorTag: $e'）；传 null 则静默吞异常。
/// await writeJsonKey('fontSize', 20.0, errorTag: 'font size');
///
/// // 删：key 不存在静默 no-op。
/// await deleteJsonKey('pendingRoute');
/// ```
///
/// ## 并发模型
///
/// - **read 无锁**：`readJsonKey` 直接 `File.readAsString`，并发安全（Dart File
///   IO 的写本身用 `writeAsString` 整文件原子覆盖；read 读到的要么是旧版要么是
///   新版完整内容，不会读到撕裂）。
/// - **write 串行**：所有 `writeJsonKey` / `deleteJsonKey` 走 module-level
///   [_Mutex]。这是为了堵住 read-modify-write race —— 同时切多个 settings
///   时，前一个 write 还在 `readAsString` 阶段，后一个 write 从同一份旧文件
///   读起，写时彼此覆盖。串行后保证每个 write 看到的都是上一个 write 的结果。
///
/// ## 测试兼容性
///
/// 三种测试路径都能透明工作：
/// 1. **传 `directory` 参数** — `widget_test.dart` 走这条路，把 tempDir 直接
///    传给 helper 绕开 path_provider mock。
/// 2. **mock `PathProviderPlatform.instance`** — `search_precision_test.dart`
///    走这条路，不传 directory 时 helper 调 `getApplicationDocumentsDirectory()`
///    被 mock 返回 tempDir。
/// 3. **不传 directory 也不 mock** — 走真实 path_provider（生产路径）。
///
/// 三者的解析顺序：caller 显式传入 > path_provider mock > 真实 path_provider。

/// 串行化所有 settings.json 写操作的 module-level mutex。
final _Mutex _writeLock = _Mutex();

/// 解析持久化目录：caller 显式传入优先，否则按平台走 path_provider。
///
/// Android 用 `getApplicationDocumentsDirectory`（外置可备份），其它平台用
/// `getApplicationSupportDirectory`（用户配置范畴）。这层平台分裂是历史
/// 遗留，沿用原 17 个函数的策略以保证 caller 行为一致。
///
/// 公开此函数是为了让 `core/providers.dart` 里的 `dbDirProvider`（解析
/// SQLite 路径用同一份目录约定）也走同一处实现，避免 `Platform.isAndroid`
/// + path_provider 拼装在多个地方重复。
Future<String> resolvePersistenceDir({String? directory}) async {
  if (directory != null) return directory;
  return Platform.isAndroid
      ? (await getApplicationDocumentsDirectory()).path
      : (await getApplicationSupportDirectory()).path;
}

File _settingsFile(String dir) => File('$dir/settings.json');

File _jsonFile(String dir, String fileName) => File('$dir/$fileName');

/// 读取 `settings.json` 中 [key] 对应的值，并通过 [parse] 转成 [T]。
///
/// 任一异常路径（文件不存在 / key 缺失 / JSON 损坏 / [parse] 抛异常 / IO 错误）
/// 都 fallback 到 [defaultValue]，不向上抛。
Future<T> readJsonKey<T>(
  String key,
  T Function(dynamic raw) parse,
  T defaultValue, {
  String? directory,
}) async {
  try {
    final dir = await resolvePersistenceDir(directory: directory);
    final file = _settingsFile(dir);
    if (!await file.exists()) return defaultValue;
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    if (!json.containsKey(key)) return defaultValue;
    return parse(json[key]);
  } catch (_) {
    return defaultValue;
  }
}

/// 把 [value] 写入 `settings.json` 的 [key] 字段。
///
/// 串行化保证：本调用对前一个 write/delete 完全可见，不会与并发 write race。
/// [value] 必须是 `jsonEncode` 可序列化的类型（num / String / bool / List /
/// Map<String, dynamic>）。失败时根据 [errorTag] 决定是否 debugPrint：
/// 非 null 输出 `'Failed to save $errorTag: $e'`，null 时静默（沿用原
/// `savePendingRoute` 的空 catch 行为）。
Future<void> writeJsonKey(
  String key,
  Object? value, {
  String? directory,
  String? errorTag,
}) {
  return _writeLock.run(() async {
    try {
      final dir = await resolvePersistenceDir(directory: directory);
      final file = _settingsFile(dir);
      final Map<String, dynamic> data = await file.exists()
          ? jsonDecode(await file.readAsString()) as Map<String, dynamic>
          : <String, dynamic>{};
      data[key] = value;
      await file.writeAsString(jsonEncode(data));
    } catch (e) {
      if (errorTag != null) {
        debugPrint('Failed to save $errorTag: $e');
      }
    }
  });
}

/// 从 `settings.json` 中删除 [key]。文件 / key 不存在均静默 no-op。
///
/// 与 [writeJsonKey] 共享同一把 [_writeLock]，保证 delete 与 write 之间
/// 不会出现 read-modify-write 撕裂。
Future<void> deleteJsonKey(String key, {String? directory}) {
  return _writeLock.run(() async {
    try {
      final dir = await resolvePersistenceDir(directory: directory);
      final file = _settingsFile(dir);
      if (!await file.exists()) return;
      final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      if (!json.containsKey(key)) return;
      json.remove(key);
      await file.writeAsString(jsonEncode(json));
    } catch (_) {
      // 沿用原 clearPendingRoute 静默策略
    }
  });
}

// ─────────────────────────────────────────────────────────────────────────
// 整文件 JSON IO（一个 fileName = 一个顶级 JSON 对象）
//
// 与上方 [readJsonKey]/[writeJsonKey]/[deleteJsonKey] 区别：
// - key-based 一组：多个 key 共享 settings.json 单文件，read-modify-write
//   只动指定 key、不动其它 key；写失败被 helper 吞掉（[errorTag] 控制 log）。
// - file-based 一组（本组）：每个文件存一个独立顶级对象（webdav.json /
//   未来扩展）；写为整覆盖，**不**与既有内容合并；写失败 rethrow 让
//   caller 决定是否给用户 SnackBar。
//
// **约定**：settings.json **不要混用** [writeJsonFile] —— 整覆盖会清掉
// [writeJsonKey] 写过的所有 key。本约定靠 doc 提示 + 单元测试文档化（见
// `test/json_store_test.dart` 内 'settings.json must not be used with
// whole-file API' 用例），代码不强制拦截。
//
// 引入于 BATCH-18g（F-W2A-058）— webdav.json read-modify-write 模板在
// webdav_config_page + backup_page 重复，提取到此处。
// ─────────────────────────────────────────────────────────────────────────

/// 读取 [fileName] 的整个 JSON 顶级对象。
///
/// 文件不存在 / 内容损坏 / IO 异常一律 fallback 到 `null`（不抛）—— 与
/// [readJsonKey] 的"fallback 到 default"策略一致，让 caller 用 null check
/// 判断"未配置"。
///
/// caller 自己负责字段提取与默认值（webdav.json 4 个 String 字段较简单，
/// 未引入数据类；未来如有更复杂 schema 可在 caller 一侧抽 fromJson）。
Future<Map<String, dynamic>?> readJsonFile(
  String fileName, {
  String? directory,
}) async {
  try {
    final dir = await resolvePersistenceDir(directory: directory);
    final file = _jsonFile(dir, fileName);
    if (!await file.exists()) return null;
    return jsonDecode(await file.readAsString()) as Map<String, dynamic>;
  } catch (_) {
    return null;
  }
}

/// 把 [data] 整体覆盖写入 [fileName]（不是 read-modify-write）。
///
/// 串行化保证：与 [writeJsonKey] / [deleteJsonKey] / [deleteJsonFile] 共享
/// 同一把 [_writeLock]，保证不与其它写并发撕裂（即使是不同 fileName）。
///
/// **错误策略与 [writeJsonKey] 不同**：本函数在 IO 失败时 **rethrow**，
/// 让 caller 外层 try-catch 决定是否给用户 SnackBar。理由是 webdav 配置
/// 等场景的写失败需要可见反馈，而非 settings.json 那种静默吞错。
Future<void> writeJsonFile(
  String fileName,
  Map<String, dynamic> data, {
  String? directory,
}) {
  return _writeLock.run(() async {
    final dir = await resolvePersistenceDir(directory: directory);
    final file = _jsonFile(dir, fileName);
    await file.writeAsString(jsonEncode(data));
  });
}

/// 删除 [fileName]。文件不存在静默 no-op；其它 IO 异常静默吞掉
/// （与 [deleteJsonKey] 对齐，删除场景通常不需要可见反馈）。
Future<void> deleteJsonFile(String fileName, {String? directory}) {
  return _writeLock.run(() async {
    try {
      final dir = await resolvePersistenceDir(directory: directory);
      final file = _jsonFile(dir, fileName);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // 沿用 deleteJsonKey 静默策略
    }
  });
}

/// 单写者串行化锁。
///
/// 等价于 `package:synchronized` 的 `Lock.synchronized`，但不引入新依赖。
/// 实现细节：维护一个尾部 future `_last`，每次 [run] 把 body 接到上一个
/// 任务结束之后再执行；body 抛异常会向调用方传播，但 lock 通过 `finally`
/// 释放，保证后续排队任务不会被前一个失败拖死。
class _Mutex {
  Future<void> _last = Future<void>.value();

  Future<T> run<T>(Future<T> Function() body) async {
    final prev = _last;
    final completer = Completer<void>();
    _last = completer.future;
    try {
      await prev;
    } catch (_) {
      // 前一个任务的异常不应阻塞排队链；当前任务该走继续走。
    }
    try {
      return await body();
    } finally {
      completer.complete();
    }
  }
}
