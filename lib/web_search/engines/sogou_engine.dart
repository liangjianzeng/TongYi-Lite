/// 搜狗搜索引擎解析器（数据中心 IP 常被 antispider 拦截；手机 IP 多变时可用）。
library;

import 'search_engine.dart';

/// 搜狗结果块：`<div class="vrwrap">`。
class SogouEngine implements SearchEngine {
  @override
  final String id = 'sogou';
  @override
  final String name = '搜狗';

  @override
  Uri buildUrl(String query, {String? language}) {
    return Uri(
      scheme: 'https',
      host: 'www.sogou.com',
      path: '/web',
      queryParameters: <String, String>{'query': query},
    );
  }

  @override
  List<EngineHit> parse(String html) {
    // 搜狗反爬页：标题"搜狗搜索"且无结果容器。
    if (html.contains('antispider') || html.contains('请输入验证码')) {
      return const [];
    }
    final clean = html
        .replaceAll(
            RegExp(r'<script[^>]*>.*?</script>',
                caseSensitive: false, dotAll: true),
            '')
        .replaceAll(
            RegExp(r'<style[^>]*>.*?</style>',
                caseSensitive: false, dotAll: true),
            '');

    final hits = <EngineHit>[];
    final wrapRe = RegExp(r'<div[^>]*class="[^"]*vrwrap[^"]*"[^>]*>.*?</div>',
        caseSensitive: false, dotAll: true);
    for (final m in wrapRe.allMatches(clean)) {
      final block = m.group(0)!;
      final a = RegExp(r'<a[^>]*href="([^"]+)"[^>]*>', caseSensitive: false)
          .firstMatch(block);
      if (a == null) continue;
      final url = _decode(a.group(1)!);
      if (url.isEmpty || url == 'javascript:void(0)') continue;
      final h3 =
          RegExp(r'<h3[^>]*>(.*?)</h3>', caseSensitive: false, dotAll: true)
              .firstMatch(block);
      final title = h3 == null ? null : _text(h3.group(1)!);
      // 摘要：含 fz / text-layout 的 div
      String? snippet;
      final desc = RegExp(
              r'class="[^"]*(?:fz|text-layout|txt-info)[^"]*"[^>]*>(.*?)</(?:p|div)>',
              caseSensitive: false,
              dotAll: true)
          .firstMatch(block);
      if (desc != null) snippet = _text(desc.group(1)!);
      // 时间标记：vrwrap 摘要/标题里常带日期（含标题兜底）。
      final raw = (desc?.group(1) ?? '') + (h3?.group(1) ?? '');
      final publishedAt = extractDateMarker(raw);
      hits.add(EngineHit(
          url: url,
          title: title,
          snippet: snippet,
          publishedAt: publishedAt.isEmpty ? null : publishedAt));
    }
    return hits;
  }

  String _text(String html) {
    return html
        .replaceAll(RegExp(r'<!--.*?-->', caseSensitive: false, dotAll: true), '')
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&nbsp;', ' ')
        .trim();
  }

  String _decode(String s) {
    // 先解 HTML 实体，再解 URL 编码。
    final decoded = s
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'");
    // 搜狗结果 href 常为相对路径 /link?url=...，补全为绝对 URL。
    final abs = decoded.startsWith('/') ? 'https://www.sogou.com$decoded' : decoded;
    try {
      return Uri.decodeComponent(abs);
    } catch (_) {
      return abs;
    }
  }
}
