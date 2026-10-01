/// 手机直连搜索引擎的搜索 provider（独立可复用模块）。
///
/// 核心思路：手机 IP 随网络经常变化，反爬标记远少于固定数据中心 IP，因此
/// 用真实浏览器 User-Agent 直接请求搜索引擎 HTML 页，规避国内引擎（百度/
/// 360/搜狗）对固定 IP 的 CAPTCHA 拦截——无需自建 SearXNG 实例。
///
/// 多个引擎并发搜索，合并去重后按序返回，单引擎反爬/超时不影响整体。
library;

import 'dart:async';
import 'dart:io' show HttpHeaders;

import 'package:dio/dio.dart';

import 'direct_search_config.dart';
import 'engines/bing_engine.dart';
import 'engines/baidu_engine.dart';
import 'engines/quake360_engine.dart';
import 'engines/sogou_engine.dart';
import 'engines/search_engine.dart';
import 'web_search_core.dart';

/// 直连搜索 provider，实现 [WebSearchProvider]。
class DirectSearchProvider implements WebSearchProvider {
  @override
  final String id = 'direct';
  @override
  final String name = '手机直连搜索';

  /// 配置（可复用、独立于 settings_service）。
  final DirectSearchConfig config;

  /// 引擎 id → 解析器。
  final Map<String, SearchEngine> _engines;

  final Dio _dio;

  /// 连接超时（不设时 Dio 不限连接阶段，主机不可达会挂到 OS TCP 超时）。
  static const Duration kConnectTimeout = Duration(seconds: 6);

  DirectSearchProvider({
    DirectSearchConfig? config,
    Map<String, SearchEngine>? engines,
    Dio? dio,
  })  : config = config ?? const DirectSearchConfig(),
        _engines = engines ?? _defaultEngines(),
        _dio = dio ??
            Dio(BaseOptions(
              // 按字符串收 HTML，自行解析。
              responseType: ResponseType.plain,
              connectTimeout: kConnectTimeout,
              sendTimeout: const Duration(seconds: 10),
              receiveTimeout: config?.timeout,
              followRedirects: true,
              maxRedirects: 5,
            ));

  static Map<String, SearchEngine> _defaultEngines() => <String, SearchEngine>{
        DirectEngine.bing: BingEngine(),
        DirectEngine.baidu: BaiduEngine(),
        DirectEngine.quake: Quake360Engine(),
        DirectEngine.sogou: SogouEngine(),
      };

  /// 配置签名（供宿主判断是否需要重建 provider）。
  String get configSignature => config.configSignature;

  /// 廉价可用性探测：直连模式总是可用（无外部实例依赖）。
  @override
  String? available() => null;

  /// 并发搜索全部启用引擎，合并去重。
  @override
  Future<WebSearchResult> search(String query, {Duration? timeout}) async {
    final t = timeout ?? config.timeout;
    final active = config.engines
        .map((id) => _engines[id])
        .whereType<SearchEngine>()
        .toList();

    // 每个引擎独立请求：单个失败/反爬不影响其他引擎。
    final futures = active.map((engine) => _fetchEngine(engine, query, t));
    final results = await Future.wait(futures);

    final seen = <String>{};
    final sources = <WebSearchSource>[];
    final failed = <String>[];
    for (var i = 0; i < results.length; i++) {
      final engine = active[i];
      final hits = results[i];
      if (hits == null) {
        failed.add(engine.name);
        continue;
      }
      if (hits.isEmpty) {
        // 空结果（反爬/无匹配）不直接判失败，避免误报。
        continue;
      }
      for (final hit in hits) {
        final key = normalizeSourceUrl(hit.url);
        if (!seen.add(key)) continue;
        sources.add(WebSearchSource(
          url: hit.url,
          title: hit.title,
          snippet: hit.snippet,
          publishedAt: hit.publishedAt,
          engine: engine.name,
        ));
      }
    }

    // 截断到 maxResults。
    final truncated = sources.length > config.maxResults;
    final top = sources.take(config.maxResults).toList();

    // 诊断：全失败时说明原因；部分失败列出失败引擎。
    String? diagnostics;
    if (top.isEmpty) {
      if (failed.isNotEmpty) {
        diagnostics = '直连引擎（${failed.join('、')}）被反爬或超时';
      } else {
        diagnostics = '所有启用引擎都未返回结果，可更换关键词';
      }
    }

    return WebSearchResult(
      sources: top,
      truncated: truncated,
      diagnostics: diagnostics,
    );
  }

  /// 请求单个引擎并解析；返回 null = 请求失败/超时，空列表 = 反爬/无匹配。
  Future<List<EngineHit>?> _fetchEngine(
    SearchEngine engine,
    String query,
    Duration t,
  ) async {
    final uri = engine.buildUrl(query, language: config.language);
    var result = await _request(engine, uri, t);
    // 空/反爬/连接失败：重试一次。手机 IP 多变，换一次连接可能绕过
    // antispider；瞬时连接失败重试大概率能成。重试只补一次，控制延迟。
    if (result == null || result.isEmpty) {
      result = await _request(engine, uri, t);
    }
    return result;
  }

  Future<List<EngineHit>?> _request(
      SearchEngine engine, Uri uri, Duration t) async {
    try {
      final resp = await _dio.get<String>(
        uri.toString(),
        options: Options(
          receiveTimeout: t,
          responseType: ResponseType.plain,
          validateStatus: (_) => true,
          headers: {
            HttpHeaders.userAgentHeader: config.userAgent,
            HttpHeaders.acceptHeader:
                'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
            HttpHeaders.acceptLanguageHeader: 'zh-CN,zh;q=0.9,en;q=0.8',
          },
        ),
      );
      final status = resp.statusCode ?? 0;
      if (status >= 400) {
        return null;
      }
      final body = resp.data ?? '';
      return engine.parse(body);
    } on DioException {
      // 反爬/超时/连接失败 → 该引擎放弃。
      return null;
    }
  }

  @override
  void dispose() {
    _dio.close(force: true);
  }
}
