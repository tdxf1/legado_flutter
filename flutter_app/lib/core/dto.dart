/// 跨平台 DTO（FRB 桥过来的 JSON 反序列化目标）。
///
/// 历史上这里有 6 个类（FailedSource / SearchResponse / AddBookRequest /
/// AddBookResponse / ChapterContentResponse / PlatformRequest），配合
/// `core/api/` 目录下的 Dio 客户端使用。BATCH-18a 把 Dio 客户端整目录删了
/// （零消费者），同时把 5 个仅 Dio 路径用的 DTO 一并清掉，仅保留 reader_page
/// 真在用的 PlatformRequest 一个类。
class PlatformRequest {
  final String type;
  final String? url;
  final String? contentRule;
  final String? webJs;
  final String? sourceRegex;
  final Map<String, String> headers;
  final String? userAgent;

  PlatformRequest({
    required this.type,
    this.url,
    this.contentRule,
    this.webJs,
    this.sourceRegex,
    this.headers = const {},
    this.userAgent,
  });

  factory PlatformRequest.fromJson(Map<String, dynamic> json) => PlatformRequest(
        type: json['type'] as String? ?? '',
        url: json['url'] as String?,
        contentRule: json['content_rule'] as String?,
        webJs: json['web_js'] as String?,
        sourceRegex: json['source_regex'] as String?,
        headers: _stringMap(json['headers']),
        userAgent: json['user_agent'] as String?,
      );

  static PlatformRequest? fromJsonOrNull(Object? value) {
    if (value is Map<String, dynamic>) {
      return PlatformRequest.fromJson(value);
    }
    if (value is Map) {
      return PlatformRequest.fromJson(Map<String, dynamic>.from(value));
    }
    return null;
  }

  static Map<String, String> _stringMap(Object? value) {
    if (value is! Map) return const {};
    return value.map((key, val) => MapEntry(key.toString(), val.toString()));
  }
}
