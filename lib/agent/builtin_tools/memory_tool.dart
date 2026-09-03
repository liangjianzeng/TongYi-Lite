/// 长期记忆工具（持久化到 workspace/memory.json，跨会话保留）。
///
/// `memory_set` 写入键值，`memory_get` 读取全部记忆。模型可用它记住
/// 用户偏好/事实，跨会话延续（对齐 DSH 的记忆/持久化能力）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../tool_definition.dart';

/// 记忆文件路径（workspace/memory.json）。
Future<File> _memoryFile() async {
  final docs = await getApplicationDocumentsDirectory();
  final dir = Directory(p.join(docs.path, 'workspace'));
  if (!await dir.exists()) await dir.create(recursive: true);
  return File(p.join(dir.path, 'memory.json'));
}

/// 读取现有记忆。
Future<Map<String, String>> _readAll() async {
  final file = await _memoryFile();
  if (!await file.exists()) return <String, String>{};
  try {
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is Map<String, dynamic>) {
      return decoded.map((k, v) => MapEntry(k, v.toString()));
    }
  } catch (_) {}
  return <String, String>{};
}

/// 写入记忆（原子写 tmp + rename）。
Future<void> _writeAll(Map<String, String> memory) async {
  final file = await _memoryFile();
  final tmp = File('${file.path}.tmp');
  await tmp.writeAsString(jsonEncode(memory), flush: true);
  await tmp.rename(file.path);
}

/// 写入一条记忆。参数：`key`、`value`。
ToolDefinition createMemorySetTool() {
  return ToolDefinition(
    name: 'memory_set',
    description:
        '写入一条长期记忆（跨会话保留，如用户偏好/重要事实）。'
        'key 为记忆名称，value 为内容。同 key 覆盖。',
    parameters: {
      'type': 'object',
      'properties': {
        'key': {'type': 'string', 'description': '记忆键'},
        'value': {'type': 'string', 'description': '记忆内容'},
      },
      'required': ['key', 'value'],
    },
    execute: (args) async {
      final key = (args['key'] as String?)?.trim() ?? '';
      final value = (args['value'] as String?)?.trim() ?? '';
      if (key.isEmpty) return ToolResult.error('缺少 key 参数');
      if (value.isEmpty) return ToolResult.error('value 为空');
      final memory = await _readAll();
      memory[key] = value;
      await _writeAll(memory);
      return ToolResult(content: '已记住：$key = $value');
    },
  );
}

/// 读取全部记忆。
ToolDefinition createMemoryGetTool() {
  return ToolDefinition(
    name: 'memory_get',
    description: '读取当前全部长期记忆（只读，不修改）。',
    parameters: const {'type': 'object'},
    execute: (args) async {
      final memory = await _readAll();
      if (memory.isEmpty) return ToolResult(content: '当前没有长期记忆。');
      final entries = memory.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
      return ToolResult(content: entries.map((e) => '${e.key}: ${e.value}').join('\n'));
    },
  );
}
