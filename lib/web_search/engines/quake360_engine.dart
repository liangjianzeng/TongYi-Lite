/// 360 搜索（so.com）解析器（手机 IP 多变时可用）。
library;

import 'search_engine.dart';

/// 360 结果块：`<li class="res-item">`（旧）或 `<div class="res-list">`（新）。
class Quake360Engine implements SearchEngine {
  @override
  final String id = '360search';
  @override
  final String name = '360搜索';

  @override
  Uri buildUrl(String query, {String? language}) {
    return Uri(
      scheme: 'https',
      host: 'www.so.com',
      path: '/s',
      queryParameters: <String, String>{
        'q': query,
        'src': 'rq',
      },
    );
  }

  @override
  List<EngineHit> parse(String html) {
    // 360 反爬：访问异常页面 / 验证页无结果。
    if (html.contains('访问异常') || html.contains('验证码')) {
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
    // 兼容新旧两代结构：res-item（li）与 res-list（div）。
    final itemRe = RegExp(r'<(?:li|div)[^>]*class="[^"]*(?:res-item|res-list)[^"]*"[^>]*>.*?</(?:li|div)>',
        caseSensitive: false, dotAll: true);
    for (final m in itemRe.allMatches(clean)) {
      final block = m.group(0)!;
      final a = RegExp(r'<a[^>]*href="([^"]+)"[^>]*>', caseSensitive: false)
          .firstMatch(block);
      if (a == null) continue;
      final url = _decode(a.group(1)!);
      if (url.isEmpty || url == 'javascript:void(0)') continue;
      // 标题：h3 内
      final h3 =
          RegExp(r'<h3[^>]*>(.*?)</h3>', caseSensitive: false, dotAll: true)
              .firstMatch(block);
      final title = h3 == null ? null : _text(h3.group(1)!);
      // 摘要：<p class="res-desc"> 或含 res-desc 的块
      String? snippet;
      final desc = RegExp(r'class="[^"]*res-desc[^"]*"[^>]*>(.*?)</(?:p|div)>',
              caseSensitive: false, dotAll: true)
          .firstMatch(block);
      if (desc != null) snippet = _text(desc.group(1)!);
      // 时间标记：res-desc 摘要里常带"6小时前 / 2026年X月X日"。
      final publishedAt =
          desc == null ? '' : extractDateMarker(desc.group(1)!);
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
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&nbsp;', ' ')
        .trim();
  }

  String _decode(String s) {
    // 先解 HTML 实体（URL 属性里 & 常被编码成 &amp;），再解 URL 编码。
    final decoded = s
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'");
    try {
      return Uri.decodeComponent(decoded);
    } catch (_) {
      return decoded;
    }
  }
}
