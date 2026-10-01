/// 联网搜索核心类型（独立可复用模块，不依赖 TongYi-Lite 的任何服务）。
///
/// 本文件只定义接缝接口与标准化结果类型，供 TongYi-Lite 的 web_search 工具、
/// DSH-Phone 或其他宿主复用。具体搜索实现（SearXNG 代理 / 手机直连搜索引擎）
/// 由各宿主通过 [WebSearchProvider] 注入。
library;

/// 搜索 provider 统一接口。任何宿主可注入自定义实现（SearXNG / 直连引擎）。
abstract class WebSearchProvider {
  /// 该 provider 的稳定 id（如 "searxng" / "direct"）。
  String get id;

  /// 该 provider 的名字（用于诊断/展示）。
  String get name;

  /// 廉价可用性探测：仅本地校验（如 URL 合法性），不联网。
  /// 返回 null 表示可用；返回非空字符串表示不可用及原因。
  String? available();

  /// 执行一次搜索。失败抛 [WebSearchProviderError]。
  ///
  /// [timeout] 为 null 时使用 provider 自身配置的超时。
  Future<WebSearchResult> search(String query, {Duration? timeout});

  /// 释放资源（如 HttpClient / Dio）。
  void dispose();
}

/// 标准化搜索结果。
class WebSearchResult {
  final List<WebSearchSource> sources;

  /// 是否因超出 maxResults 丢弃过结果。
  final bool truncated;

  /// 0 结果时的引擎诊断（哪些引擎 timeout/CAPTCHA/静默 0 条），
  /// 供工具层转成可行动的报错。
  final String? diagnostics;

  const WebSearchResult({
    required this.sources,
    this.truncated = false,
    this.diagnostics,
  });
}

/// 标准化搜索结果中的一条来源。
class WebSearchSource {
  final String url;
  final String? title;
  final String? snippet;
  final String? publishedAt;

  /// 来源引擎（定位"哪个引擎给的结果"）。
  final String? engine;

  /// 相关性得分（越大越相关；缺失为 null）。
  final double? score;

  const WebSearchSource({
    required this.url,
    this.title,
    this.snippet,
    this.publishedAt,
    this.engine,
    this.score,
  });
}

/// 结构化搜索错误（对齐 DSH WEB_PROVIDER_ERROR / WEB_ABORTED）。
class WebSearchProviderError {
  /// 'WEB_PROVIDER_ERROR'（不可用/出错）| 'WEB_ABORTED'（超时/取消）。
  final String kind;
  final String message;

  const WebSearchProviderError(this.kind, this.message);
}

/// 去掉跟踪参数/fragment/尾斜杠并小写 host，用于跨引擎的同源去重。
String normalizeSourceUrl(String raw) {
  final uri = Uri.tryParse(raw.trim());
  if (uri == null || uri.host.isEmpty) return raw.trim();
  final params = uri.queryParameters.entries
      .where((e) => !e.key.toLowerCase().startsWith('utm_'))
      .where((e) => e.key.toLowerCase() != 'from')
      .toList()
    ..sort((a, b) => a.key.compareTo(b.key));
  var path = uri.path;
  if (path.length > 1 && path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  final query = params.map((e) => '${e.key}=${e.value}').join('&');
  final normalized = Uri(
    scheme: uri.scheme.toLowerCase(),
    host: uri.host.toLowerCase(),
    port: uri.hasPort ? uri.port : null,
    path: path.isEmpty ? '/' : path,
    query: query.isEmpty ? null : query,
  );
  return normalized.toString();
}
