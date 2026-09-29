/// 待办清单工具（持久化，v2）。
///
/// 语义照抄 DSH 的 todo 工具：`todo_write` 全量替换任务清单；
/// `todo_list` 只读当前清单（供模型规划下一步）。清单落盘
/// `ApplicationSupport/agent_todo.json`——跨 turn、跨重启保留；
/// 配合系统提示"多步任务先 todo_write"的规划约束（WP2d）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../tool_definition.dart';

/// 进程级待办清单（惰性从磁盘加载；写入即落盘）。
List<Map<String, String>>? _todoStore;
bool _todoLoaded = false;
String? _todoFilePath;

Future<List<Map<String, String>>> _store() async {
  if (_todoLoaded) return _todoStore ??= <Map<String, String>>[];
  _todoLoaded = true;
  try {
    final dir = await getApplicationSupportDirectory();
    _todoFilePath ??= p.join(dir.path, 'agent_todo.json');
    final file = File(_todoFilePath!);
    if (file.existsSync()) {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is List) {
        _todoStore = [
          for (final e in decoded)
            if (e is Map<String, dynamic>) _cleanItem(e),
        ];
      }
    }
  } catch (_) {
    // 坏文件/测试环境无插件 → 空清单，不影响工具可用性。
  }
  return _todoStore ??= <Map<String, String>>[];
}

/// 写入即落盘（best-effort：失败不阻断，内存清单仍有效）。
void _persist() {
  final path = _todoFilePath;
  final store = _todoStore;
  if (path == null || store == null) return;
  try {
    File(path).writeAsStringSync(jsonEncode(store));
  } catch (_) {}
}

/// 测试专用：清空待办清单（回到空态；不再读盘，保证测试隔离）。
@visibleForTesting
void resetTodoStore() {
  _todoStore = null;
  _todoLoaded = true;
}

/// 生成待办清单文本。
String _render(List<Map<String, String>> items) {
  if (items.isEmpty) return '当前没有待办任务。';
  final lines = <String>[];
  for (var i = 0; i < items.length; i++) {
    final item = items[i];
    lines.add('${i + 1}. [${item['status']}] ${item['content']}');
  }
  return '当前待办清单（共 ${items.length} 项）：\n${lines.join('\n')}';
}

/// 全量替换待办清单。参数：`todos: [{content, status}]`。
/// 调用后返回当前完整清单，模型可据此继续规划。
ToolDefinition createTodoWriteTool() {
  return ToolDefinition(
    name: 'todo_write',
    description:
        '全量替换待办任务清单。todos 为任务数组，每项含 content（任务内容）'
        '与 status（状态，如 todo/done）。调用后返回当前完整清单。',
    parameters: {
      'type': 'object',
      'properties': {
        'todos': {
          'type': 'array',
          'items': {
            'type': 'object',
            'properties': {
              'content': {'type': 'string'},
              'status': {'type': 'string'},
            },
            'required': ['content'],
          },
          'description': '任务数组',
        },
      },
      'required': ['todos'],
    },
    execute: (args) async {
      final raw = args['todos'];
      // 兼容 List 与 JSON 字符串两种形态（XML 协议值可能以字符串到达）。
      List? parsed;
      if (raw is List) {
        parsed = raw;
      } else if (raw is String) {
        final trimmed = raw.trim();
        if (trimmed.isNotEmpty && trimmed.startsWith('[')) {
          try {
            final decoded = jsonDecode(trimmed);
            if (decoded is List) parsed = decoded;
          } catch (_) {}
        }
      }
      if (parsed == null) {
        return ToolResult.error('缺少 todos 参数（应为任务数组）');
      }
      final items = <Map<String, String>>[];
      try {
        for (final e in parsed) {
          if (e is Map<String, dynamic>) {
            items.add(_cleanItem(e));
          } else if (e is Map) {
            items.add(_cleanItem(Map<String, dynamic>.from(e)));
          }
        }
      } on ArgumentError catch (e) {
        return ToolResult.error('$e');
      }
      if (items.isEmpty) {
        return ToolResult.error('todos 数组为空');
      }
      final store = await _store()
        ..clear()
        ..addAll(items);
      _persist();
      return ToolResult(content: '待办清单已更新：\n${_render(store)}');
    },
  );
}

/// 读取当前待办清单（只读，不修改）。
ToolDefinition createTodoListTool() {
  return ToolDefinition(
    name: 'todo_list',
    description: '读取当前待办任务清单（只读，不修改）。',
    parameters: const {'type': 'object'},
    execute: (args) async {
      return ToolResult(content: _render(await _store()));
    },
  );
}

/// 清洗单个待办项：content 必填非空；status 缺省为 'todo'。
Map<String, String> _cleanItem(Map<String, dynamic> json) {
  final content = json['content']?.toString().trim() ?? '';
  if (content.isEmpty) {
    throw ArgumentError('任务内容不能为空');
  }
  final status = json['status']?.toString().trim() ?? 'todo';
  return {'content': content, 'status': status};
}
