/// 水平翻页 delegate 抽象层
///
/// 对应 Legado MD3 的 `HorizontalPageDelegate`。Cover / Slide / Simulation
/// 三种水平方向翻页动画共用的基类。
///
/// 当前职责（与父类 [PageDelegate] 的差别）：
/// - 承载共同的"水平翻页"语义：next 表示视觉上从右往左切下一页，prev 反之。
/// - 提供 [drawStaticCurrent] 帮助方法，用于 direction == none 时回退绘制
///   当前页（避免每个子类重复写 ContentPagePainter）。
/// - 给将来的 simulation/scroll 等留 hook：[setBitmap] 在 [HorizontalPageDelegate]
///   级别表达"下一帧前刷新预渲染快照"。
///
/// 现阶段不引入 `Scroller` 之类的额外依赖，原始 [PageDelegate.animController]
/// 已经足够 cover/slide 使用。
library;

import 'package:flutter/material.dart';

import '../content_page.dart';
import '../text_page.dart';
import 'page_delegate.dart';

abstract class HorizontalPageDelegate extends PageDelegate {
  HorizontalPageDelegate({
    required super.controller,
    required super.settings,
    required super.animController,
    super.onChapterBoundary,
    super.onCrossChapter,
  });

  /// 子类在 direction == none 且没有 picture 缓存时，可调用此方法直接绘制
  /// 当前页（不带任何变换）。
  void drawStaticCurrent(
    Canvas canvas,
    Size size,
    TextPage? currentPage,
    int totalPages,
  ) {
    drawStaticPage(canvas, size, currentPage, totalPages);
  }

  /// 绘制任意 [TextPage] 的静态快照（不带任何变换）。
  /// 用于仿真翻页等场景：当 pre-rendered picture 不可用时，至少用 TextPage
  /// 原本的内容填充动画帧，避免"动画播放但画面静止，动画结束后内容跳变"。
  void drawStaticPage(
    Canvas canvas,
    Size size,
    TextPage? page,
    int totalPages,
  ) {
    final painter = ContentPagePainter(
      page: page,
      settings: settings,
      totalPages: totalPages,
    );
    painter.paint(canvas, size);
  }

  /// 在长动画过程中刷新页面快照（仿真翻页等需要在拖拽中重建 picture）。
  /// 默认实现保持不变；子类按需覆盖。
  void setBitmap() {
    // No-op by default.
  }
}
