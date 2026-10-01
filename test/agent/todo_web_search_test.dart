import 'package:flutter_test/flutter_test.dart';

import 'package:tongyi_lite/agent/agent.dart';
import 'package:tongyi_lite/agent/web_search/web_search_provider.dart';
import 'package:tongyi_lite/agent/web_search/web_search_seam.dart';

/// 记录查询并返回固定结果的假 provider。
class _FakeSearchProvider implements WebSearchProvider {
  final List<String> called = [];
  final Map<String, List<WebSearchSource>> byQuery;

  _FakeSearchProvider(this.byQuery);

  @override
  String get id => 'fake';
  @override
  String get name => 'fake';
  @override
  String? available() => null;
  @override
  void dispose() {}
  @override
  Future<WebSearchResult> search(String query, {Duration? timeout}) async {
    called.add(query);
    return WebSearchResult(sources: byQuery[query] ?? const []);
  }
}

void main() {
  setUp(() {
    resetTodoStore();
  });

  group('todo_write 工具', () {
    test('写入清单并返回完整清单', () async {
      final tool = createTodoWriteTool();
      final result = await tool.execute({
        'todos': [
          {'content': '下载模型', 'status': 'done'},
          {'content': '验证推理'},
        ],
      });
      expect(result.isError, isFalse);
      expect(result.content, contains('待办清单已更新'));
      expect(result.content, contains('1. [done] 下载模型'));
      expect(result.content, contains('2. [todo] 验证推理'));
    });

    test('todo_list 可读取当前清单', () async {
      await createTodoWriteTool().execute({
        'todos': [
          {'content': '写代码'},
        ],
      });
      final result = await createTodoListTool().execute(const {});
      expect(result.isError, isFalse);
      expect(result.content, contains('1. [todo] 写代码'));
    });

    test('空清单 todo_list 提示无任务', () async {
      final result = await createTodoListTool().execute(const {});
      expect(result.isError, isFalse);
      expect(result.content, contains('没有待办'));
    });

    test('缺少 todos 参数 → 错误', () async {
      final result = await createTodoWriteTool().execute(const {});
      expect(result.isError, isTrue);
      expect(result.content, contains('todos'));
    });

    test('空数组 → 错误', () async {
      final result = await createTodoWriteTool().execute({'todos': []});
      expect(result.isError, isTrue);
      expect(result.content, contains('为空'));
    });

    test('空任务内容 → 错误', () async {
      final result = await createTodoWriteTool().execute({
        'todos': [
          {'content': '  '},
        ],
      });
      expect(result.isError, isTrue);
      expect(result.content, contains('不能为空'));
    });

    test('todos 为 JSON 字符串（XML 协议形态）→ 同样可写入', () async {
      final result = await createTodoWriteTool().execute({
        'todos': '[{"content": "明天开会", "status": "todo"}]',
      });
      expect(result.isError, isFalse);
      expect(result.content, contains('1. [todo] 明天开会'));
    });

    test('todos 为非法 JSON 字符串 → 错误', () async {
      final result = await createTodoWriteTool().execute({
        'todos': '不是合法数组',
      });
      expect(result.isError, isTrue);
      expect(result.content, contains('todos'));
    });
  });

  group('web_search 工具', () {
    test('缺少 query → 错误', () async {
      final result = await createWebSearchTool().execute(const {});
      expect(result.isError, isTrue);
      expect(result.content, contains('query'));
    });

    test('空 query → 错误', () async {
      final result = await createWebSearchTool().execute({'query': '   '});
      expect(result.isError, isTrue);
      expect(result.content, contains('query'));
    });

    test('意图扩展：单个泛关键词内部循环搜索多个时效变体并合并返回', () async {
      final year = DateTime.now().year.toString();
      final provider = _FakeSearchProvider({
        '国庆': [
          const WebSearchSource(url: 'http://a', title: '百科词条', snippet: '国庆简介'),
        ],
        '国庆 新闻': [
          const WebSearchSource(url: 'http://b', title: '国庆新闻', snippet: '最新动态'),
        ],
        '国庆 $year': [
          const WebSearchSource(url: 'http://c', title: '国庆 2026', snippet: '时效信息'),
        ],
      });
      WebSearchSeam.instance.registerProvider(provider);
      try {
        final result = await createWebSearchTool().execute({'query': '国庆'});
        // 意图理解后内部循环多搜：原词 + 新闻 + 年份三个时效变体都被搜索。
        expect(provider.called.length, greaterThanOrEqualTo(3));
        expect(provider.called, contains('国庆'));
        expect(provider.called, contains('国庆 新闻'));
        expect(provider.called, contains('国庆 $year'));
        // 跨变体合并去重后一并返回，信息量远大于只搜一次。
        expect(result.isError, isFalse);
        expect(result.content, contains('百科词条'));
        expect(result.content, contains('国庆新闻'));
        expect(result.content, contains('国庆 2026'));
      } finally {
        WebSearchSeam.instance.dispose();
      }
    });

    test('合并去重：跨变体同源 URL 只保留一次', () async {
      final provider = _FakeSearchProvider({
        '国庆': [
          const WebSearchSource(url: 'http://same', title: '标题A', snippet: '摘要A'),
        ],
        '国庆 新闻': [
          const WebSearchSource(url: 'http://same', title: '标题A', snippet: '摘要A'),
        ],
      });
      WebSearchSeam.instance.registerProvider(provider);
      try {
        final result = await createWebSearchTool().execute({'query': '国庆'});
        // 两个变体返回同一来源 → 合并后只出现一次。
        expect(result.content.split('标题A').length - 1, 1);
        expect(result.isError, isFalse);
      } finally {
        WebSearchSeam.instance.dispose();
      }
    });

    test('结果够数提前停：首批收集足够后不再搜剩余变体', () async {
      final year = DateTime.now().year.toString();
      final provider = _FakeSearchProvider({
        '国庆': List.generate(12, (i) => WebSearchSource(
            url: 'http://s$i', title: '标题$i', snippet: '摘要$i')),
        '国庆 新闻': [
          const WebSearchSource(url: 'http://x', title: '不应出现', snippet: '摘要'),
        ],
        // 附加关键词的变体不应被搜索（首批已够 12 条）。
      });
      WebSearchSeam.instance.registerProvider(provider);
      try {
        final result = await createWebSearchTool().execute({
          'query': '国庆',
          'additional_queries': ['南宁新闻'],
        });
        // 首批（国庆 原词/新闻/$year）收集够条数 → 提前停，南宁新闻 变体不搜。
        expect(provider.called, isNot(contains('南宁新闻')));
        expect(provider.called, contains('国庆 $year'));
        expect(result.isError, isFalse);
      } finally {
        WebSearchSeam.instance.dispose();
      }
    });

    test('additional_queries：主查询与附加查询各自扩展、合并返回', () async {
      final year = DateTime.now().year.toString();
      final provider = _FakeSearchProvider({
        '国庆 武汉 活动': [
          const WebSearchSource(url: 'http://a', title: '国庆活动清单', snippet: '武汉国庆活动'),
        ],
        '国庆 武汉 活动 新闻': [
          const WebSearchSource(url: 'http://a', title: '国庆活动清单', snippet: '武汉国庆活动'),
        ],
        '国庆 武汉 活动 $year': [
          const WebSearchSource(url: 'http://a', title: '国庆活动清单', snippet: '武汉国庆活动'),
        ],
        '武汉 天气': [
          const WebSearchSource(url: 'http://b', title: '武汉天气', snippet: '晴转多云'),
        ],
        '武汉 天气 新闻': [
          const WebSearchSource(url: 'http://b', title: '武汉天气', snippet: '晴转多云'),
        ],
        '武汉 天气 $year': [
          const WebSearchSource(url: 'http://b', title: '武汉天气', snippet: '晴转多云'),
        ],
      });
      WebSearchSeam.instance.registerProvider(provider);
      try {
        final result = await createWebSearchTool().execute({
          'query': '国庆 武汉 活动',
          'additional_queries': ['武汉 天气'],
        });
        // 两个关键词的时效变体都被内部搜索。
        expect(provider.called, contains('国庆 武汉 活动'));
        expect(provider.called, contains('武汉 天气'));
        // 合并结果两个角度都可见（同源去重后各保留一条）。
        expect(result.isError, isFalse);
        expect(result.content, contains('国庆活动清单'));
        expect(result.content, contains('武汉天气'));
      } finally {
        WebSearchSeam.instance.dispose();
      }
    });

    test('候选池截断：扩展关键词过多时截断到内部上限', () async {
      final provider = _FakeSearchProvider({});
      WebSearchSeam.instance.registerProvider(provider);
      try {
        final result = await createWebSearchTool().execute({
          'query': 'q',
          'additional_queries': ['a', 'b', 'c', 'd', 'e', '  '],
        });
        // 候选池最多 kInternalMaxQueries=6 组；空串被过滤。
        expect(provider.called.length, lessThanOrEqualTo(6));
        expect(provider.called, isNotEmpty);
        expect(provider.called, isNot(contains('  ')));
        // 全部变体无结果 → 返回"无结果"错误（而非联网失败）。
        expect(result.isError, isTrue);
        expect(result.content, contains('未找到相关结果'));
      } finally {
        WebSearchSeam.instance.dispose();
      }
    });

    test('重复关键词：同回合再次搜索相同内容 → 直接回缓存结果，不重复联网', () async {
      final provider = _FakeSearchProvider({
        '华为开发者大会': [
          const WebSearchSource(url: 'http://a', title: '华为大会', snippet: '开发者大会'),
        ],
      });
      WebSearchSeam.instance.registerProvider(provider);
      try {
        final tool = createWebSearchTool();
        final first = await tool.execute({'query': '华为开发者大会'});
        expect(first.isError, isFalse);
        expect(first.content, contains('华为大会'));
        // 同回合再次以相同关键词调用：命中缓存，不再触发 provider.search
        //（内部扩展变体数量不再增加）。
        final countAfterFirst = provider.called.length;
        final second = await tool.execute({'query': '华为开发者大会'});
        expect(provider.called.length, countAfterFirst);
        expect(second.isError, isFalse);
        expect(second.content, contains('已搜索过'));
        expect(second.content, contains('华为大会'));
      } finally {
        WebSearchSeam.instance.dispose();
      }
    });

    test('预算上限：超过每回合搜索次数 → 拒绝联网并返回收敛指令', () async {
      final provider = _FakeSearchProvider({});
      WebSearchSeam.instance.registerProvider(provider);
      try {
        final tool = createWebSearchTool(maxSearchesPerTurn: 2);
        await tool.execute({'query': 'q1'});
        await tool.execute({'query': 'q2'});
        // 第 3 次：预算耗尽 → 不联网，返回收敛指令（isError=true）。
        final countAfterTwo = provider.called.length;
        final third = await tool.execute({'query': 'q3'});
        expect(provider.called.length, countAfterTwo);
        expect(third.isError, isTrue);
        expect(third.content, contains('已达上限'));
        expect(third.content, contains('不要再调用 web_search'));
      } finally {
        WebSearchSeam.instance.dispose();
      }
    });

    test('预算含重复调用：重复也消耗预算，尽快逼模型收敛', () async {
      final provider = _FakeSearchProvider({
        'q': [
          const WebSearchSource(url: 'http://a', title: '标题A', snippet: '摘要A'),
        ],
      });
      WebSearchSeam.instance.registerProvider(provider);
      try {
        final tool = createWebSearchTool(maxSearchesPerTurn: 2);
        await tool.execute({'query': 'q'});
        final countAfterFirst = provider.called.length;
        await tool.execute({'query': 'q'}); // 去重命中，不联网
        // 预算已满（2/2）→ 新的关键词直接返回收敛指令，不联网。
        final third = await tool.execute({'query': '新关键词'});
        expect(provider.called.length, countAfterFirst);
        expect(third.isError, isTrue);
        expect(third.content, contains('已达上限'));
      } finally {
        WebSearchSeam.instance.dispose();
      }
    });
  });
}
