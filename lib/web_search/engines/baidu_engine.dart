/// 百度搜索引擎解析器（手机 IP 多变时可用，数据中心 IP 会被安全验证）。
library;

import 'search_engine.dart';

/// 百度结果块：`<div class="result ...">`。
class BaiduEngine implements SearchEngine {
  @override
  final String id = 'baidu';
  @override
  final String name = '百度';

  @override
  Uri buildUrl(String query, {String? language}) {
    return Uri(
      scheme: 'https',
      host: 'www.baidu.com',
      path: '/s',
      queryParameters: <String, String>{
        'wd': query,
        'ie': 'utf-8',
        'rn': '10',
      },
    );
  }

  @override
  List<EngineHit> parse(String html) {
    // 百度安全验证页（wappass）无结果块。
    if (html.contains('wappass.baidu.com') || html.contains('安全验证')) {
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
    final resultRe = RegExp(r'<div[^>]*class="[^"]*result[^"]*"[^>]*>.*?</div>',
        caseSensitive: false, dotAll: true);
    for (final m in resultRe.allMatches(clean)) {
      final block = m.group(0)!;
      final a = RegExp(r'<a[^>]*href="([^"]+)"[^>]*>', caseSensitive: false)
          .firstMatch(block);
      if (a == null) continue;
      final url = _decode(a.group(1)!);
      // 百度跳转链接：/link?url=... 或 http://www.baidu.com/link?url=
      if (url.isEmpty || url == 'javascript:void(0)') continue;
      final h3 =
          RegExp(r'<h3[^>]*>(.*?)</h3>', caseSensitive: false, dotAll: true)
              .firstMatch(block);
      final title = h3 == null ? null : _text(h3.group(1)!);
      // 摘要：含 c-abstract / c-span-layout 的 div
      final abstractRe = RegExp(
          r'class="[^"]*(?:c-abstract|c-span-layout|cr-content)[^"]*"[^>]*>(.*?)(?:</div>|<span)',
          caseSensitive: false,
          dotAll: true);
      String? snippet;
      final abs = abstractRe.firstMatch(block);
      if (abs != null) {
        snippet = _text(abs.group(1)!);
      }
      hits.add(EngineHit(url: url, title: title, snippet: snippet));
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
    // 先解 HTML 实体（URL 属性里 & 常被编码成 &amp;）。
    final decoded = s
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'");
    // 百度 /link?url=... 需还原真实地址：从 url= 参数取。
    if (decoded.contains('/link?url=')) {
      final uri = Uri.tryParse(decoded);
      if (uri != null && uri.queryParameters.containsKey('url')) {
        return Uri.decodeComponent(uri.queryParameters['url']!);
      }
    }
    try {
      return Uri.decodeComponent(decoded);
    } catch (_) {
      return decoded;
    }
  }
}
