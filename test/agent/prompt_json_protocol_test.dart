import 'package:flutter_test/flutter_test.dart';

import 'package:tongyi_lite/agent/agent.dart';

void main() {
  final protocol = PromptJsonProtocol();

  Stream<String> tokens(String text) async* {
    for (var i = 0; i < text.length; i += 4) {
      yield text.substring(i, (i + 4).clamp(0, text.length));
    }
  }

  group('prompt-json protocol', () {
    test('解析原生工具调用 JSON', () async {
      const text = '{"tool_call": {"name": "get_time", "arguments": {}}}';
      final outcome = await protocol.parseStream(tokens(text));

      expect(outcome.hasToolCalls, isTrue);
      expect(outcome.toolCalls.single.name, 'get_time');
      expect(outcome.toolCalls.single.arguments, isEmpty);
    });

    test('解析 XML 格式工具调用（llama.cpp 原生）', () async {
      const text =
          '<tool_call>web_search<arg_key>q<arg_value>今天天气</tool_call>';
      final outcome = await protocol.parseStream(tokens(text));

      expect(outcome.hasToolCalls, isTrue);
      expect(outcome.toolCalls.single.name, 'web_search');
      expect(outcome.toolCalls.single.arguments?['q'], '今天天气');
    });

    test('XML 无参数工具调用', () async {
      const text = '<tool_call>get_time</tool_call>';
      final outcome = await protocol.parseStream(tokens(text));

      expect(outcome.hasToolCalls, isTrue);
      expect(outcome.toolCalls.single.name, 'get_time');
    });

    test('XML 未闭合 → 普通文本（不误判）', () async {
      const text = '<tool_call>get_time';
      final outcome = await protocol.parseStream(tokens(text));
      expect(outcome.hasToolCalls, isFalse);
      expect(outcome.text, '<tool_call>get_time');
    });

    test('XML 块前后文本保留', () async {
      const text =
          '让我查询一下<tool_call>web_search<arg_key>q<arg_value>天气</tool_call>请稍等';
      final outcome = await protocol.parseStream(tokens(text));

      expect(outcome.hasToolCalls, isTrue);
      expect(outcome.toolCalls.single.name, 'web_search');
      expect(outcome.text, '让我查询一下请稍等');
    });

    test('XML 数组参数（todos）解析为 List', () async {
      const text =
          '<tool_call>todo_write<arg_key>todos<arg_value>[{"content": "明天开会", "status": "todo"}]</tool_call>';
      final outcome = await protocol.parseStream(tokens(text));

      expect(outcome.hasToolCalls, isTrue);
      final call = outcome.toolCalls.single;
      expect(call.name, 'todo_write');
      expect(call.arguments?['todos'], isA<List>());
      expect(call.arguments?['todos'][0]['content'], '明天开会');
    });

    test('带参数的工具调用', () async {
      const text =
          '{"tool_call": {"name": "calculator", "arguments": {"expression": "12*7+3"}}}';
      final outcome = await protocol.parseStream(tokens(text));

      expect(outcome.toolCalls.single.name, 'calculator');
      expect(outcome.toolCalls.single.arguments?['expression'], '12*7+3');
    });

    test('流式增量拼装（分片 token）正确解析', () async {
      final text = '{"tool_call":{"name":"calculator",'
          '"arguments":{"expression":"3.5*(2-1)"}}}';
      final outcome = await protocol.parseStream(tokens(text));
      expect(outcome.hasToolCalls, isTrue);
      expect(outcome.toolCalls.single.name, 'calculator');
      expect(outcome.toolCalls.single.arguments?['expression'], '3.5*(2-1)');
    });

    test('无 JSON → 整段作为普通文本回答（优雅降级）', () async {
      const text = '现在时间不方便查询，我直接回答你。';
      final outcome = await protocol.parseStream(tokens(text));

      expect(outcome.hasToolCalls, isFalse);
      expect(outcome.text, text);
    });

    test('JSON 解析失败 → 整段降级为文本', () async {
      const text = '{"tool_call": {"name": "broken"; 不是合法 JSON';
      final outcome = await protocol.parseStream(tokens(text));

      expect(outcome.hasToolCalls, isFalse);
      expect(outcome.text, text);
    });

    test('合法 JSON 但不是工具调用 → 整段降级为文本', () async {
      const text = '{"answer": "42"}';
      final outcome = await protocol.parseStream(tokens(text));

      expect(outcome.hasToolCalls, isFalse);
      expect(outcome.text, text);
    });

    test('括号不平衡（输出被截断）→ 无工具调用', () async {
      const text = '{"tool_call": {"name": "get_time", "arguments": {';
      final outcome = await protocol.parseStream(tokens(text));

      expect(outcome.hasToolCalls, isFalse);
    });

    test('字符串内的大括号不破坏平衡扫描', () async {
      const text = '{"tool_call": {"name": "note", '
          '"arguments": {"content": "a{b}c"}}}';
      final outcome = await protocol.parseStream(tokens(text));

      expect(outcome.hasToolCalls, isTrue);
      expect(outcome.toolCalls.single.arguments?['content'], 'a{b}c');
    });

    test('工具段渲染：注入可用工具与协议指令', () {
      final registry = ToolRegistry();
      registry.register(ToolDefinition(
        name: 'get_time',
        description: '返回当前时间',
        parameters: const {'type': 'object', 'properties': {}},
        execute: (args) async => const ToolResult(content: 'ok'),
      ));
      registry.register(ToolDefinition(
        name: 'shell_exec',
        description: '执行 shell 命令',
        parameters: {
          'type': 'object',
          'properties': {
            'command': {'type': 'string', 'description': '要执行的命令'},
          },
          'required': ['command'],
        },
        execute: (args) async => const ToolResult(content: 'ok'),
      ));

      final section = protocol.buildToolSection(registry);
      expect(section, contains('[可用工具]'));
      expect(section, contains('get_time'));
      expect(section, contains('返回当前时间'));
      expect(section, contains('[工具调用协议]'));
      // 协议指令以 XML 呈现（真机实测 Spark/Qwen 均输出 XML 原生格式，
      // 遵循率更高；解析器双格式兼容 JSON+XML）。
      expect(section, contains('<tool_call>'));
      expect(section, contains('<arg_key>'));
      // 工具清单为文本格式：`- name: description`（贴近小模型训练分布）。
      expect(section, contains('- get_time: 返回当前时间'));
      // 带必填参数的工具呈现参数名提示（对照 DSH schema 呈现），
      // 让模型知道必须给出哪些参数——根治「只调工具不带参数」。
      expect(section,
          contains('- shell_exec: 执行 shell 命令（必填: command: string）'));
    });

    test('按模型渲染工具清单：受限模型不注入不可见工具', () {
      final registry = ToolRegistry();
      registry.register(ToolDefinition(
        name: 'hidden',
        description: 'x',
        parameters: const {'type': 'object'},
        execute: (args) async => const ToolResult(content: 'ok'),
      ));
      registry.restrictModel('m1', allow: {});

      // 默认视图（全局层）仍可见。
      expect(protocol.buildToolSection(registry), contains('hidden'));
      // 受限模型视图不注入该工具。
      expect(protocol.buildToolSection(registry, modelId: 'm1'), isEmpty);
    });
  });
}
