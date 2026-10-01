/// 直连搜索引擎的解析器抽象（独立可复用模块）。
///
/// 每个引擎：构造搜索 URL → 用真实 UA 请求 HTML → 解析出结果条目。
/// 解析失败/被反爬时返回空列表，由直连 provider 合并去重。
library;

/// 单条原始结果（解析出的标题/URL/摘要）。
class EngineHit {
  final String url;
  final String? title;
  final String? snippet;
  final String? publishedAt;
  const EngineHit({
    required this.url,
    this.title,
    this.snippet,
    this.publishedAt,
  });
}

/// 引擎解析器统一接口。
abstract class SearchEngine {
  /// 引擎 id（对齐 [DirectEngine]）。
  String get id;

  /// 引擎展示名。
  String get name;

  /// 构造搜索请求 URL。
  Uri buildUrl(String query, {String? language});

  /// 把 HTML 响应解析成结果条目列表；解析不出时返回空。
  List<EngineHit> parse(String html);
}
