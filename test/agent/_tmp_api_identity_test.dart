// [TYL-LINGFIX-1027 / 临时取证用，跑完即删]
// 目的：证明「提示词分档」那次改动对 **完整档（=API 路线）逐字节零扰动**。
// 做法：把 7aabe65c^（改动前）的 buildSystemPrompt 原样搬进
//       lib/agent/_tmp_pre/agent_prompt_pre.dart 作前缀库，与当前实现同进程
//       对同一批输入产出逐字节比对。旧实现即 API 路线的既有事实。
import 'package:flutter_test/flutter_test.dart';

import 'package:tongyi_lite/agent/agent.dart';
import 'package:tongyi_lite/agent/protocol/native_tool_protocol.dart';
import 'package:tongyi_lite/agent/agent_prompt.dart';
// ignore: unused_import
import 'package:tongyi_lite/agent/_tmp_pre/agent_prompt_pre.dart' as pre;

void main() {
  ToolDefinition heavy(String name) => ToolDefinition(
        name: name,
        description: '在沙盒内执行 Python 代码：注意 stdin 是一次性喂入并关闭的批次输入，'
            '需要 input() 的脚本必须用 stdin 参数把输入一并传进来；'
            '长任务请缩小规模或改用其它工具，否则会被超时截断。',
        parameters: const {
          'type': 'object',
          'properties': {
            'code': {'type': 'string', 'description': '要执行的代码'},
            'sandbox_permissions': {'type': 'string'},
          },
          'required': ['code'],
        },
        execute: (args) async => const ToolResult(content: 'ok'),
      );

  ToolDefinition light(String name, String desc, {List<String> req = const []}) =>
      ToolDefinition(
        name: name,
        description: desc,
        parameters: {
          'type': 'object',
          'properties': {
            for (final r in req) r: {'type': 'string', 'description': '$r 参数'},
          },
          'required': req,
        },
        execute: (args) async => const ToolResult(content: 'ok'),
      );

  ToolRegistry registry() {
    final r = ToolRegistry();
    r.register(light('get_time', '获取当前时间'));
    r.register(light('web_search', '联网搜索关键字', req: ['query']));
    r.register(heavy('python_exec'));
    return r;
  }

  final cases = <String, dynamic>{
    'API 默认（无人格 / 无纪律段 / native 协议）': <String, Object?>{
      'modelName': 'gpt-4o',
      'modelId': 'gpt-4o',
      'personaName': null,
      'personaPrompt': null,
      'taskDiscipline': false,
      'protocol': const NativeToolProtocol(),
    },
    'API + 任务执行纪律段': <String, Object?>{
      'modelName': 'gpt-4o',
      'modelId': 'gpt-4o',
      'personaName': null,
      'personaPrompt': null,
      'taskDiscipline': true,
      'protocol': const NativeToolProtocol(),
    },
    'API + 标准人格（有名字有设定）': <String, Object?>{
      'modelName': 'claude',
      'modelId': 'claude-3-7',
      'personaName': '小舟',
      'personaPrompt': '说话简洁，先结论后理由。',
      'taskDiscipline': true,
      'protocol': const NativeToolProtocol(),
    },
    'API + 人格名为空串（必须走无身份段）': <String, Object?>{
      'modelName': 'claude',
      'modelId': '',
      'personaName': '   ',
      'personaPrompt': '   ',
      'taskDiscipline': true,
      'protocol': const NativeToolProtocol(),
    },
    '本地 prompt-json（完整档 = 改动前默认）': <String, Object?>{
      'modelName': 'Ling 3.0 Tiny',
      'modelId': 'ling-3.0-tiny-q4_0',
      'personaName': null,
      'personaPrompt': null,
      'taskDiscipline': true,
      'protocol': PromptJsonProtocol(),
    },
    '本地 prompt-json + compact 协议旗标（旧实现无此旗标，默认 false）': <String, Object?>{
      'modelName': 'Ling 3.0 Tiny',
      'modelId': 'ling-3.0-tiny-q4_0',
      'personaName': '小舟',
      'personaPrompt': '简洁。',
      'taskDiscipline': false,
      'protocol': PromptJsonProtocol(compact: false),
    },
  };

  cases.forEach((name, c) {
    test('完整档逐字节 == 改动前实现：$name', () {
      final args = <String, Object?>{
        'modelName': c['modelName'],
        'registry': registry(),
        'protocol': c['protocol'],
        'modelId': c['modelId'],
        'personaName': c['personaName'],
        'personaPrompt': c['personaPrompt'],
        'taskDiscipline': c['taskDiscipline'],
      };
      final oldOut = pre.buildSystemPrompt(
        modelName: args['modelName']! as String,
        registry: args['registry']! as ToolRegistry,
        protocol: args['protocol']! as ToolProtocol,
        modelId: args['modelId']! as String,
        personaName: args['personaName'] as String?,
        personaPrompt: args['personaPrompt'] as String?,
        taskDiscipline: args['taskDiscipline']! as bool,
      );
      final newFull = buildSystemPrompt(
        modelName: args['modelName']! as String,
        registry: args['registry']! as ToolRegistry,
        protocol: args['protocol']! as ToolProtocol,
        modelId: args['modelId']! as String,
        personaName: args['personaName'] as String?,
        personaPrompt: args['personaPrompt'] as String?,
        taskDiscipline: args['taskDiscipline']! as bool,
        tier: AgentPromptTier.full,
      );
      // ignore: avoid_print
      print('[IDENTITY] $name :: old=${oldOut.length} new_full=${newFull.length}');
      expect(newFull, equals(oldOut), reason: '完整档（API 路线）输出被改动了');
      // 交叉证据：精简档必须与完整档不同（否则分档形同虚设）
      final newCompact = buildSystemPrompt(
        modelName: args['modelName']! as String,
        registry: args['registry']! as ToolRegistry,
        protocol: args['protocol']! as ToolProtocol,
        modelId: args['modelId']! as String,
        personaName: args['personaName'] as String?,
        personaPrompt: args['personaPrompt'] as String?,
        taskDiscipline: args['taskDiscipline']! as bool,
        tier: AgentPromptTier.compact,
      );
      expect(newCompact.length, lessThan(newFull.length));
    });
  });
}
