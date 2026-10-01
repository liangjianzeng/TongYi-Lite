import 'package:flutter_test/flutter_test.dart';

import '../../lib/web_search/query_expander.dart';

void main() {
  group('detectIntent 意图分类', () {
    test('新闻意图：含"新闻/最新"等时效词', () {
      expect(detectIntent('国庆热门新闻'), SearchIntent.news);
      expect(detectIntent('最近有什么大事'), SearchIntent.news);
    });

    test('本地新闻意图：地名 + 新闻意图', () {
      expect(detectIntent('南宁最近几天新闻'), SearchIntent.localNews);
      expect(detectIntent('北京今天发生了什么'), SearchIntent.localNews);
    });

    test('概念/泛查询：无时效词', () {
      expect(detectIntent('国庆'), SearchIntent.concept);
      expect(detectIntent('量子计算原理'), SearchIntent.concept);
    });
  });

  group('expandQuery 关键词扩展', () {
    test('原词优先级最高，恒为第一个', () {
      final v = expandQuery('国庆');
      expect(v.first, '国庆');
    });

    test('概念词补新闻与年份时效变体', () {
      final v = expandQuery('国庆', now: DateTime(2026, 10, 2));
      expect(v, contains('国庆 新闻'));
      expect(v, contains('国庆 2026'));
      expect(v.length, lessThanOrEqualTo(3));
    });

    test('新闻词补"今天最新消息"时效变体', () {
      final v = expandQuery('南宁新闻', now: DateTime(2026, 10, 2));
      expect(v.first, '南宁新闻');
      expect(v, contains('南宁新闻 今天 最新消息'));
    });

    test('已含年份不再重复补年份', () {
      final v = expandQuery('2026 国庆', now: DateTime(2026, 10, 2));
      // 不含冗余的"2026 国庆 2026"。
      expect(v, isNot(contains('2026 国庆 2026')));
    });

    test('空查询返回空列表', () {
      expect(expandQuery('   '), isEmpty);
    });

    test('去重：不产生重复变体', () {
      final v = expandQuery('南宁新闻', now: DateTime(2026, 10, 2));
      expect(v.toSet().length, v.length);
    });
  });

  group('expandKeywords 候选池', () {
    test('多关键词统一扩展并整体去重、限条数', () {
      final q = expandKeywords(['国庆', '南宁新闻'],
          now: DateTime(2026, 10, 2), cap: 6);
      expect(q.length, lessThanOrEqualTo(6));
      expect(q.first, '国庆'); // 主查询原词优先级最高
      expect(q, contains('南宁新闻'));
    });
  });
}
