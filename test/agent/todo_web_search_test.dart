import 'package:flutter_test/flutter_test.dart';

import 'package:tongyi_lite/agent/agent.dart';

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
  });
}
