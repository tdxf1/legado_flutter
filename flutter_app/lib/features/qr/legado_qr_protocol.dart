/// Legado 二维码 / Deep link 协议解析（批次 20 / 05-19）。
///
/// 原 Legado 在 `ui/association/OnLineImportActivity.kt` 中识别
/// `legado://import/<type>?src=<url>` 协议并按 type 分流到对应导入对话框。
/// 本批次 MVP 仅 parse + 走 `src=URL` 远端拉取模式，不支持 base64 内联。
///
/// 支持 4 种 type：
/// - `bookSource`     → 走 [`rust_api.importSourcesFromJson`]
/// - `rssSource`      → 走 [`rust_api.rssSourceImportJson`]
/// - `sourceSub`      → 走批次 19 RuleSub create + refresh
/// - `replaceRule`    → 暂占位（批次 21+ 实装）
///
/// 兜底：直接 `https?://....json` 视为 BookSource URL（适配许多人用
/// GitHub raw / pages 直接发布书源 JSON 的习惯）。
///
/// 不识别返回 null，由 UI 层显示"未识别为 Legado 协议"。
library;

import '../../core/security/webview_safety.dart';

/// 二维码识别后的 4 种类型。"无法识别"由 [parseLegadoQrPayload] 返回
/// null 表达，不再用 enum value，避免 switch 时还要处理 unknown 分支。
enum LegadoQrType {
  bookSource,
  rssSource,
  sourceSub,
  replaceRule,
}

/// 解析结果数据载体。`type` 决定 import handler 的分支，
/// `fetchUrl` 是要远端 GET 的 JSON URL（已 URL-decode）。
class ParsedLegadoQr {
  final LegadoQrType type;
  final String fetchUrl;
  const ParsedLegadoQr({required this.type, required this.fetchUrl});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ParsedLegadoQr &&
          other.type == type &&
          other.fetchUrl == fetchUrl);

  @override
  int get hashCode => Object.hash(type, fetchUrl);

  @override
  String toString() => 'ParsedLegadoQr(type: $type, fetchUrl: $fetchUrl)';
}

/// 4 种 legado:// 协议识别正则。`(.+)$` 让 src 可以含 query/fragment。
final RegExp _legadoProtocolRegExp = RegExp(
  r'^legado://import/(bookSource|rssSource|sourceSub|replaceRule)\?src=(.+)$',
);

/// 兜底：直接 https?:// 结尾 .json 视为 BookSource URL。
final RegExp _bareJsonUrlRegExp =
    RegExp(r'^https?://[^\s]+\.json(\?[^\s]*)?$', caseSensitive: false);

/// 把扫到的二维码 raw text 解析为结构化的 [ParsedLegadoQr]。
///
/// 不识别（空串 / 不是 URL / 不是 legado 协议）返回 null。
///
/// 安全：解析出的 fetchUrl 必经 [enforceWebViewScheme] 校验（http/https
/// 白名单，BATCH-05 / F-W2B-002）；越界（如 `legado://import/bookSource?src=file:///etc/passwd`）
/// 直接当"未识别"返回 null。
ParsedLegadoQr? parseLegadoQrPayload(String raw) {
  final s = raw.trim();
  if (s.isEmpty) return null;

  // 1. legado://import/<type>?src=<url>
  final m = _legadoProtocolRegExp.firstMatch(s);
  if (m != null) {
    final typeStr = m.group(1)!;
    final srcEncoded = m.group(2)!;
    String src;
    try {
      src = Uri.decodeComponent(srcEncoded);
    } catch (_) {
      // decode 失败回退到原始 src（部分二维码生成器没正确 encode）
      src = srcEncoded;
    }
    final type = _parseType(typeStr);
    if (type == null) return null;
    // BATCH-05 (F-W2B-002): scheme 白名单 —— 拦 file:// / javascript: /
    // data: 等越界协议，避免后续 dio.get 引发 SSRF / 本地资源访问。
    try {
      enforceWebViewScheme(src);
    } on WebViewSafetyException {
      return null;
    }
    return ParsedLegadoQr(type: type, fetchUrl: src);
  }

  // 2. 兜底：直接 https URL 结尾 .json
  if (_bareJsonUrlRegExp.hasMatch(s)) {
    // 已经是 https?://… 形式，scheme 安全；再校一遍是 defense-in-depth：
    // 万一未来 _bareJsonUrlRegExp 放宽到非 http(s) scheme，这里仍能拦下。
    try {
      enforceWebViewScheme(s);
    } on WebViewSafetyException {
      return null;
    }
    return ParsedLegadoQr(type: LegadoQrType.bookSource, fetchUrl: s);
  }

  return null;
}

LegadoQrType? _parseType(String s) {
  switch (s) {
    case 'bookSource':
      return LegadoQrType.bookSource;
    case 'rssSource':
      return LegadoQrType.rssSource;
    case 'sourceSub':
      return LegadoQrType.sourceSub;
    case 'replaceRule':
      return LegadoQrType.replaceRule;
    default:
      return null;
  }
}

/// 类型对应的中文标签（确认对话框展示用）。
String legadoQrTypeLabel(LegadoQrType type) {
  switch (type) {
    case LegadoQrType.bookSource:
      return '书源';
    case LegadoQrType.rssSource:
      return 'RSS 源';
    case LegadoQrType.sourceSub:
      return '订阅源';
    case LegadoQrType.replaceRule:
      return '替换规则';
  }
}
