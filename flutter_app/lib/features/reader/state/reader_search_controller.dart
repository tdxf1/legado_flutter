/// 阅读器内文本搜索控制器
///
/// 把章节内段落级关键字搜索从 widget state 中分离出来。
///
/// 提供：
/// - [start] / [close]：进入 / 退出搜索面板
/// - [perform]：根据关键字在 [chapters] 各段落中匹配，并通过 [onScroll] 回调让外层滚动
/// - [next] / [prev]：在匹配项之间跳转
///
/// 调用约定：
/// - widget 在 setState 时读 [isActive] / [matches] / [currentIndex] / [textController]
/// - 滚动定位由调用方提供 [onScroll]，本控制器不直接操作 ScrollController
library;

import 'package:flutter/widgets.dart';

class ReaderSearchMatch {
  final int chapterIdx;
  final int paragraphIdx;
  const ReaderSearchMatch(this.chapterIdx, this.paragraphIdx);
}

class ReaderSearchController {
  ReaderSearchController({required VoidCallback onChanged})
      : _onChanged = onChanged;

  final VoidCallback _onChanged;
  final TextEditingController textController = TextEditingController();

  bool _isActive = false;
  final List<ReaderSearchMatch> _matches = <ReaderSearchMatch>[];
  int _currentIndex = -1;

  bool get isActive => _isActive;
  List<ReaderSearchMatch> get matches => List.unmodifiable(_matches);
  int get currentIndex => _currentIndex;

  /// 由调用方在 [next] / [prev] / [perform] 命中后触发，参数是当前 match。
  ///
  /// 因为 reader 的滚动定位策略（连续滚动 / 分页 / 仿真）各不相同，
  /// 控制器不直接持 ScrollController，由 widget 在回调内自己处理。
  ValueChanged<ReaderSearchMatch>? onScroll;

  void start() {
    _isActive = true;
    _onChanged();
  }

  void close() {
    _isActive = false;
    _matches.clear();
    _currentIndex = -1;
    textController.clear();
    _onChanged();
  }

  /// 在传入的 [chapters] 中按段落搜索 [keyword]，大小写不敏感。
  ///
  /// [chapters] 形如 `[ {paragraphs: [...]} ]`，每章给出已切段后的段落数组；
  /// 这里用回调式访问以避免引入 `_LoadedChapter` 这类内部类型。
  void perform(
    String keyword,
    int chapterCount,
    List<String> Function(int chapterIndex) paragraphsAt,
  ) {
    _matches.clear();
    _currentIndex = -1;
    if (keyword.isEmpty) {
      _onChanged();
      return;
    }
    final k = keyword.toLowerCase();
    for (var ci = 0; ci < chapterCount; ci++) {
      final ps = paragraphsAt(ci);
      for (var pi = 0; pi < ps.length; pi++) {
        if (ps[pi].toLowerCase().contains(k)) {
          _matches.add(ReaderSearchMatch(ci, pi));
        }
      }
    }
    if (_matches.isNotEmpty) {
      _currentIndex = 0;
      onScroll?.call(_matches[_currentIndex]);
    }
    _onChanged();
  }

  void next() {
    if (_matches.isEmpty) return;
    _currentIndex = (_currentIndex + 1) % _matches.length;
    onScroll?.call(_matches[_currentIndex]);
    _onChanged();
  }

  void prev() {
    if (_matches.isEmpty) return;
    _currentIndex = (_currentIndex - 1 + _matches.length) % _matches.length;
    onScroll?.call(_matches[_currentIndex]);
    _onChanged();
  }

  void dispose() {
    textController.dispose();
  }
}
