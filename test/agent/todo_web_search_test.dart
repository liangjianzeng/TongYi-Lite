import 'package:flutter_test/flutter_test.dart';

import 'package:tongyi_lite/agent/agent.dart';
import 'package:tongyi_lite/agent/web_search/web_search_provider.dart';
import 'package:tongyi_lite/agent/web_search/web_search_seam.dart';

/// 记录查询并返回固定结果的假 provider（并发多关键词用）。
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

    test('additional_queries：一次调用并发搜索多个关键词并合并返回', () async {
      final provider = _FakeSearchProvider({
        '国庆 武汉 活动 2026': [
          const WebSearchSource(url: 'http://a', title: '国庆活动清单', snippet: '武汉国庆活动'),
        ],
        '武汉 天气 2026': [
          const WebSearchSource(url: 'http://b', title: '武汉天气', snippet: '晴转多云'),
        ],
      });
      WebSearchSeam.instance.registerProvider(provider);
      try {
        final result = await createWebSearchTool().execute({
          'query': '国庆 武汉 活动',
          'additional_queries': ['武汉 天气'],
        });
        // 两个关键词都被搜索（年份补全后）。
        expect(provider.called, contains('国庆 武汉 活动 2026'));
        expect(provider.called, contains('武汉 天气 2026'));
        // 合并结果带关键词小节归属，两个角度都可见。
        expect(result.isError, isFalse);
        expect(result.content, contains('[搜索：国庆 武汉 活动 2026]'));
        expect(result.content, contains('[搜索：武汉 天气 2026]'));
        expect(result.content, contains('国庆活动清单'));
        expect(result.content, contains('武汉天气'));
      } finally {
        WebSearchSeam.instance.dispose();
      }
    });

    test('additional_queries 截断：最多 4 个关键词，空串忽略', () async {
      final provider = _FakeSearchProvider({});
      WebSearchSeam.instance.registerProvider(provider);
      try {
        final result = await createWebSearchTool().execute({
          'query': 'q',
          'additional_queries': ['a', 'b', 'c', 'd', 'e', '  '],
        });
        // query + 最多 3 个附加 = 4 次搜索；空串被过滤。
        expect(provider.called.length, 4);
        expect(provider.called, isNot(contains('  ')));
        expect(result.isError, isFalse);
      } finally {
        WebSearchSeam.instance.dispose();
      }
    });
  });
}
