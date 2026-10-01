/// Bing 搜索引擎解析器（cn.bing.com 302 壳，国内可直连）。
library;

import 'search_engine.dart';

/// cn.bing.com 搜索结果页：结果块是 `<li class="b_algo">`。
class BingEngine implements SearchEngine {
  @override
  final String id = 'bing';
  @override
  final String name = 'Bing';

  @override
  Uri buildUrl(String query, {String? language}) {
    final params = <String, String>{
      'q': query,
      'format': 'R1',
      'count': '10',
    };
    if (language != null && language.isNotEmpty) {
      params['setlang'] = language;
      params['cc'] = language.split('-').last;
    }
    return Uri(
      scheme: 'https',
      host: 'cn.bing.com',
      path: '/search',
      queryParameters: params,
    );
  }

  @override
  List<EngineHit> parse(String html) {
    // 先剥离脚本/样式，避免把 JS 文本误当结果。
    final clean = html
        .replaceAll(
            RegExp(r'<script[^>]*>.*?</script>',
                caseSensitive: false, dotAll: true),
            '')
        .replaceAll(
            RegExp(r'<style[^>]*>.*?</style>',
                caseSensitive: false, dotAll: true),
            '');

    // 逐个匹配 b_algo 块。
    final hits = <EngineHit>[];
    final algoRe = RegExp(r'<li[^>]*class="[^"]*b_algo[^"]*"[^>]*>.*?</li>',
        caseSensitive: false, dotAll: true);
    for (final m in algoRe.allMatches(clean)) {
      final block = m.group(0)!;
      // URL：第一个 <a href="...">
      final a = RegExp(r'<a[^>]*href="([^"]+)"[^>]*>', caseSensitive: false)
          .firstMatch(block);
      if (a == null) continue;
      final url = _unescape(a.group(1)!);
      if (url.isEmpty || url == 'javascript:void(0)') continue;
      // 标题：h2 内文本
      final h2 =
          RegExp(r'<h2[^>]*>(.*?)</h2>', caseSensitive: false, dotAll: true)
              .firstMatch(block);
      final title = h2 == null ? null : _text(h2.group(1)!);
      // 摘要：p 内文本
      final p = RegExp(r'<p[^>]*>(.*?)</p>', caseSensitive: false, dotAll: true)
          .firstMatch(block);
      final snippet = p == null ? null : _text(p.group(1)!);
      // 时间标记：p 摘要里常带"2026年9月12日 / 2月5日 / X小时前"。
      final publishedAt = p == null ? '' : extractDateMarker(p.group(1)!);
      if (url.isEmpty) continue;
      hits.add(EngineHit(
          url: url,
          title: title,
          snippet: snippet,
          publishedAt: publishedAt.isEmpty ? null : publishedAt));
    }
    return hits;
  }

  String _text(String html) {
    final t = html
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&nbsp;', ' ')
        .trim();
    return t.isEmpty ? '' : t;
  }

  String _unescape(String s) {
    // 先解 HTML 实体（URL 属性里 & 常被编码成 &amp;），再解 URL 编码。
    var out = s
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'");
    try {
      return Uri.decodeComponent(out);
    } catch (_) {
      return out;
    }
  }
}
