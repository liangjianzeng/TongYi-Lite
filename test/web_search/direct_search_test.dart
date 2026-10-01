// 手机直连搜索引擎模块（独立可复用）测试：引擎解析器 + 直连 provider 合并去重。
import 'package:flutter_test/flutter_test.dart';

import '../../lib/web_search/direct_search_config.dart';
import '../../lib/web_search/direct_search_provider.dart';
import '../../lib/web_search/engines/bing_engine.dart';
import '../../lib/web_search/engines/baidu_engine.dart';
import '../../lib/web_search/engines/quake360_engine.dart';
import '../../lib/web_search/engines/sogou_engine.dart';
import '../../lib/web_search/engines/search_engine.dart';
import '../../lib/web_search/web_search_core.dart';

void main() {
  group('BingEngine 解析', () {
    test('从 b_algo 块提取标题/URL/摘要', () {
      final html = '''
<html><body>
<li class="b_algo"><h2><a href="https://example.com/foo">标题 <b>加粗</b></a></h2>
<p>摘要内容 &amp; 更多</p></li>
<li class="b_algo"><h2><a href="https://example2.com/bar">第二条</a></h2><p>摘要2</p></li>
</body></html>
''';
      final hits = BingEngine().parse(html);
      expect(hits.length, 2);
      expect(hits[0].url, 'https://example.com/foo');
      expect(hits[0].title, '标题 加粗');
      expect(hits[0].snippet, '摘要内容 & 更多');
      expect(hits[1].url, 'https://example2.com/bar');
    });

    test('无结果块时返回空', () {
      expect(BingEngine().parse('<html><body>no results</body></html>'), isEmpty);
    });

    test('URL 被 HTML 实体转义时还原', () {
      final html = '''
<li class="b_algo"><h2><a href="https://example.com/a&amp;b">t</a></h2><p>s</p></li>
''';
      final hits = BingEngine().parse(html);
      expect(hits.single.url, 'https://example.com/a&b');
    });
  });

  group('BaiduEngine 解析', () {
    test('从 result 块提取标题/摘要', () {
      final html = '''
<div class="result"><h3><a href="https://baike.baidu.com/item/foo">百度百科词条</a></h3>
<div class="c-abstract">这是摘要</div></div>
''';
      final hits = BaiduEngine().parse(html);
      expect(hits.length, 1);
      expect(hits[0].title, '百度百科词条');
      expect(hits[0].snippet, contains('这是摘要'));
    });

    test('安全验证页返回空', () {
      expect(BaiduEngine().parse('<html>wappass.baidu.com 安全验证</html>'), isEmpty);
    });
  });

  group('Quake360Engine 解析', () {
    test('从 res-item 块提取结果', () {
      final html = '''
<li class="res-item"><h3><a href="https://so.com/1">标题一</a></h3>
<p class="res-desc">摘要一</p></li>
''';
      final hits = Quake360Engine().parse(html);
      expect(hits.length, 1);
      expect(hits[0].title, '标题一');
      expect(hits[0].snippet, '摘要一');
    });

    test('反爬页返回空', () {
      expect(Quake360Engine().parse('<html>访问异常</html>'), isEmpty);
    });

    test('新版 res-list 结构可解析', () {
      final html = '''
<div class="res-list"><h3><a href="https://so.com/new1">新标题</a></h3>
<p class="res-desc">新摘要</p></div>
''';
      final hits = Quake360Engine().parse(html);
      expect(hits.length, 1);
      expect(hits[0].title, '新标题');
      expect(hits[0].snippet, '新摘要');
    });
  });

  group('SogouEngine 解析', () {
    test('相对路径 /link?url= 补全为绝对 URL', () {
      final html = '''
<div class="vrwrap"><h3 class="vr-title"><a href="/link?url=abc123">秦汉足道</a></h3>
<div class="fz-mid">摘要内容</div></div>
''';
      final hits = SogouEngine().parse(html);
      expect(hits.length, 1);
      expect(hits[0].url, 'https://www.sogou.com/link?url=abc123');
      expect(hits[0].title, '秦汉足道');
    });

    test('标题含 HTML 注释时被清理', () {
      final html = '''
<div class="vrwrap"><h3 class="vr-title"><a href="/link?url=xyz"><!--awbg5-->标题 <em>加粗</em></a></h3>
<div class="fz-mid">摘要</div></div>
''';
      final hits = SogouEngine().parse(html);
      expect(hits.length, 1);
      expect(hits[0].title, '标题 加粗');
    });

    test('antispider 反爬页返回空', () {
      expect(SogouEngine().parse('<html>antispider</html>'), isEmpty);
    });
  });

  group('DirectSearchProvider', () {
    test('跨引擎同源 URL 去重', () {
      // 手动构造 provider（注入内存引擎，不联网）。
      final provider = DirectSearchProvider(
        config: const DirectSearchConfig(
          engines: [DirectEngine.bing, DirectEngine.baidu],
        ),
        engines: {
          DirectEngine.bing: _FakeEngine('bing', [
            EngineHit(url: 'https://a.com/x?utm_source=1'),
            EngineHit(url: 'https://a.com/x'),
          ]),
          DirectEngine.baidu: _FakeEngine('baidu', [
            EngineHit(url: 'https://A.com/x'),
          ]),
        },
      );
      // 直接测 normalizeSourceUrl 的去重行为（不联网）。
      expect(normalizeSourceUrl('https://a.com/x?utm_source=1'),
          normalizeSourceUrl('https://a.com/x'));
      expect(normalizeSourceUrl('https://a.com/x'),
          normalizeSourceUrl('https://A.com/x'));
    });

    test('available 恒可用（无外部实例依赖）', () {
      expect(DirectSearchProvider().available(), isNull);
    });

    test('id/name 稳定', () {
      expect(DirectSearchProvider().id, 'direct');
      expect(DirectSearchProvider().name, '手机直连搜索');
    });
  });
}

/// 测试用假引擎：直接返回固定结果。
class _FakeEngine implements SearchEngine {
  final String engineId;
  final List<EngineHit> hits;
  _FakeEngine(this.engineId, this.hits);

  @override
  String get id => engineId;
  @override
  String get name => '引擎$engineId';

  @override
  Uri buildUrl(String query, {String? language}) =>
      Uri.parse('https://fake/$engineId?q=$query');

  @override
  List<EngineHit> parse(String html) => hits;
}
