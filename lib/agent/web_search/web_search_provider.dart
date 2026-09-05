/// 联网搜索 provider 与标准化结果（对齐 DSH `ctx.web` 的可插拔搜索能力）。
///
/// 本文件只定义接缝与默认实现（SearXNG）：web_search 工具通过 [WebSearchSeam]
/// 调用、不感知具体搜索源——替换搜索实现只需 [WebSearchSeam.registerProvider]。
///
/// 搜索实现（SearXNG）调用自建 SearXNG 实例的 JSON API，把返回的 `results[]`
/// 映射为标准化 [WebSearchSource]；无需 API key（私有实例才需要，作为 Bearer
/// token 发送）。
library;

import 'package:dio/dio.dart';

import '../../services/settings_service.dart';
import 'web_search_seam.dart';

/// 搜索 provider 统一接口（对齐 DSH ctx.web 的可插拔搜索能力）。
abstract class WebSearchProvider {
  /// 该 provider 的稳定 id（如 "searxng"）。
  String get id;

  /// 该 provider 的名字（用于诊断/展示）。
  String get name;

  /// 廉价可用性探测：仅本地校验（如 URL 合法性），不联网。
  /// 返回 null 表示可用；返回非空字符串表示不可用及原因。
  String? available();

  /// 执行一次搜索。失败抛 [WebSearchProviderError]。
  Future<WebSearchResult> search(String query, {Duration timeout});

  /// 释放资源（如 HttpClient / Dio）。
  void dispose();
}

/// 标准化搜索结果（对齐 DSH WebSearchResult）。
class WebSearchResult {
  final List<WebSearchSource> sources;
  final bool truncated;
  const WebSearchResult({required this.sources, this.truncated = false});
}

/// 标准化搜索结果中的一条来源（对齐 DSH WebSearchSource）。
class WebSearchSource {
  final String url;
  final String? title;
  final String? snippet;
  final String? publishedAt;
  const WebSearchSource({
    required this.url,
    this.title,
    this.snippet,
    this.publishedAt,
  });
}

/// 结构化搜索错误（对齐 DSH WEB_PROVIDER_ERROR / WEB_ABORTED）。
class WebSearchProviderError {
  /// 'WEB_PROVIDER_ERROR'（provider 不可用）| 'WEB_ABORTED'（请求被取消/超时）。
  final String kind;
  final String message;
  const WebSearchProviderError(this.kind, this.message);
}

/// SearXNG 搜索 provider（对齐 DSH `@deepseek-ai/dsh-web-search-searxng`）。
///
/// 调用自建 SearXNG 实例的 JSON API：`GET {baseURL}/search?q=...&format=json`，
/// 把返回的 `results[]` 映射为标准化 [WebSearchSource]（url / title /
/// content←snippet / publishedDate）。无需 API key（私有实例才需要，作为
/// Bearer token 发送）。最大返回条数、超时、语言、分类均可配置。
class SearXNGSearchProvider implements WebSearchProvider {
  static const String kDefaultBaseUrl = 'http://127.0.0.1:8080';
  static const int kDefaultMaxResults = 8;
  // 与端侧 agent 循环默认工具超时（15s）对齐：provider 自身超时不超过约束，
  // 避免与循环的通用超时竞争；仍作为独立于循环的安全兜底。
  static const Duration kDefaultTimeout = Duration(seconds: 15);

  @override
  final String id = 'searxng';
  @override
  final String name = 'SearXNG';

  final String baseURL;
  final String? apiKey;
  final int maxResults;
  final Duration timeout;
  final String? language;
  final String? categories;

  final Dio _dio = Dio();

  SearXNGSearchProvider({
    this.baseURL = kDefaultBaseUrl,
    this.apiKey,
    this.maxResults = kDefaultMaxResults,
    this.timeout = kDefaultTimeout,
    this.language,
    this.categories,
  });

  /// 从持久化设置构建（对齐 DSH web-search-searxng settings section）。
  factory SearXNGSearchProvider.fromSettings(InferenceSettings settings) {
    return SearXNGSearchProvider(
      baseURL: settings.webSearchSearXngBaseUrl,
      apiKey: settings.webSearchSearXngApiKey,
      maxResults: settings.webSearchSearXngMaxResults,
      timeout: Duration(milliseconds: settings.webSearchSearXngTimeoutMs),
      language: settings.webSearchSearXngLanguage,
      categories: settings.webSearchSearXngCategories,
    );
  }

  /// 廉价可用性探测：仅校验 baseURL 可解析且有 host，不联网。
  /// 对齐 DSH available() 只做廉价 URL 校验、不发起请求。
  @override
  String? available() {
    try {
      final uri = Uri.parse(baseURL);
      if (uri.scheme.isEmpty || uri.host.isEmpty) {
        return 'baseURL 未配置或格式错误：$baseURL';
      }
      return null;
    } catch (_) {
      return 'baseURL 格式错误：$baseURL';
    }
  }

  @override
  Future<WebSearchResult> search(String query, {Duration? timeout}) async {
    final t = timeout ?? this.timeout;
    final base = Uri.parse(baseURL);
    final queryParts = <String>[
      'q=${Uri.encodeQueryComponent(query)}',
      'format=json',
    ];
    if (language != null && language!.isNotEmpty) {
      queryParts.add('language=${Uri.encodeQueryComponent(language!)}');
    }
    if (categories != null && categories!.isNotEmpty) {
      queryParts.add('categories=${Uri.encodeQueryComponent(categories!)}');
    }
    final uri = base.replace(query: queryParts.join('&'), fragment: '');
    try {
      final resp = await _dio.get<Map<String, dynamic>>(
        uri.toString(),
        options: Options(
          receiveTimeout: t,
          headers: _headers(),
        ),
      );
      if (resp.statusCode != null && resp.statusCode! >= 400) {
        throw WebSearchProviderError('WEB_PROVIDER_ERROR',
            'SearXNG 返回 HTTP ${resp.statusCode}');
      }
      final data = resp.data ?? const <String, dynamic>{};
      return WebSearchResult(sources: _mapResults(data));
    } on WebSearchProviderError {
      rethrow;
    } on DioException catch (e) {
      if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.receiveTimeout ||
          e.type == DioExceptionType.sendTimeout) {
        throw const WebSearchProviderError('WEB_ABORTED', 'SearXNG 搜索超时');
      }
      throw WebSearchProviderError('WEB_PROVIDER_ERROR',
          'SearXNG 不可达：${e.message ?? e.type}');
    }
  }

  Map<String, String> _headers() {
    final headers = <String, String>{'User-Agent': 'deepseek-harness/0.0.1'};
    if (apiKey != null && apiKey!.isNotEmpty) {
      headers['Authorization'] = 'Bearer $apiKey';
    }
    return headers;
  }

  List<WebSearchSource> _mapResults(Map<String, dynamic> data) {
    final seen = <String>{};
    final sources = <WebSearchSource>[];
    final results = data['results'] as List? ?? const [];
    for (final item in results) {
      if (item is! Map) continue;
      final url = item['url'];
      if (url is! String || url.isEmpty) continue;
      if (seen.contains(url)) continue;
      seen.add(url);
      sources.add(WebSearchSource(
        url: url,
        title: item['title'] as String?,
        snippet: item['content'] as String?,
        publishedAt: item['publishedDate'] as String?,
      ));
    }
    return sources.take(maxResults).toList();
  }

  @override
  void dispose() {
    _dio.close();
  }
}

/// 用持久化设置（重新）构建并注册当前 SearXNG provider 到 [WebSearchSeam]。
///
/// 在设置变更时调用即可热切换搜索源，无需重启应用。
void applySearXNGProviderFromSettings(InferenceSettings settings) {
  WebSearchSeam.instance.registerProvider(
    SearXNGSearchProvider.fromSettings(settings),
  );
}
