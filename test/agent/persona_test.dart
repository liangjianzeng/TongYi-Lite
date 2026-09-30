import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:tongyi_lite/agent/agent.dart';
import 'package:tongyi_lite/models/agent_persona.dart';
import 'package:tongyi_lite/services/settings_service.dart';

void main() {
  ToolRegistry registry() {
    final r = ToolRegistry();
    r.register(ToolDefinition(
      name: 'web_search',
      description: 'search',
      parameters: const {'type': 'object'},
      execute: (args) async => ToolResult(content: 'ok'),
    ));
    return r;
  }

  group('buildSystemPrompt 人格注入', () {
    test('标准人格（不传参）行为不变：默认身份段、无人设段', () {
      final prompt = buildSystemPrompt(
        modelName: 'qwen-test',
        registry: registry(),
        protocol: PromptJsonProtocol(),
        modelId: 'qwen-test',
      );
      expect(prompt, contains('你是 TongYi-Lite 智能体，由 qwen-test 模型驱动。'));
      expect(prompt, isNot(contains('——TongYi-Lite 智能体')));
      expect(prompt, isNot(contains('【人格设定】')));
      // 工具纪律仍完整。
      expect(prompt, contains('【工具调用规则】'));
    });

    test('自定义人格：身份段以人格自称开头 + 人设段注入', () {
      final prompt = buildSystemPrompt(
        modelName: 'qwen-test',
        registry: registry(),
        protocol: PromptJsonProtocol(),
        modelId: 'qwen-test',
        personaName: '写作助手',
        personaPrompt: '你是一名资深中文编辑，回答精炼、语气克制。',
      );
      expect(prompt, contains('「写作助手」'));
      expect(prompt, contains('由 qwen-test 模型驱动'));
      expect(prompt, contains('【人格设定】'));
      expect(prompt, contains('资深中文编辑'));
      // 人设段在工具规则之前（人设不覆盖工具纪律）。
      expect(prompt.indexOf('【人格设定】'), lessThan(prompt.indexOf('【工具调用规则】')));
    });

    test('人设提示词为空 → 不插人设段，仅身份段换自称', () {
      final prompt = buildSystemPrompt(
        modelName: 'qwen-test',
        registry: registry(),
        protocol: PromptJsonProtocol(),
        modelId: 'qwen-test',
        personaName: '  写作助手  ',
        personaPrompt: '   ',
      );
      expect(prompt, contains('「写作助手」'));
      expect(prompt, isNot(contains('【人格设定】')));
    });
  });

  group('AgentPersona 序列化', () {
    test('toJson/fromJson 往返', () {
      final persona = const AgentPersona(
        id: 'p1',
        name: '翻译官',
        prompt: '只输出译文。',
      );
      final restored =
          AgentPersona.fromJson(jsonDecode(jsonEncode(persona.toJson())) as Map<String, dynamic>);
      expect(restored.id, 'p1');
      expect(restored.name, '翻译官');
      expect(restored.prompt, '只输出译文。');
    });
  });

  group('InferenceSettings 人格持久化', () {
    test('默认值：标准人格、无人格列表', () {
      final settings = const InferenceSettings();
      expect(settings.activePersonaId, kStandardPersonaId);
      expect(settings.agentPersonas, isEmpty);
      expect(settings.activePersona(), isNull);
    });

    test('toJson/fromJson 往返保留人格列表与激活 id', () {
      const settings = InferenceSettings(
        agentPersonas: [
          AgentPersona(id: 'p1', name: '写作助手', prompt: '精炼、克制'),
          AgentPersona(id: 'p2', name: '翻译官'),
        ],
        activePersonaId: 'p2',
      );
      final restored = InferenceSettings.fromJson(
          jsonDecode(jsonEncode(settings.toJson())) as Map<String, dynamic>);
      expect(restored.agentPersonas.length, 2);
      expect(restored.agentPersonas[0].name, '写作助手');
      expect(restored.agentPersonas[1].prompt, isEmpty);
      expect(restored.activePersonaId, 'p2');
      expect(restored.activePersona()?.name, '翻译官');
    });

    test('激活 id 指向不存在的人格 → activePersona 回落标准（null）', () {
      const settings = InferenceSettings(
        agentPersonas: [AgentPersona(id: 'p1', name: '写作助手')],
        activePersonaId: 'gone',
      );
      expect(settings.activePersona(), isNull);
    });

    test('旧配置缺人格字段 → 默认标准人格（向后兼容）', () {
      final restored = InferenceSettings.fromJson({'agentEnabled': true});
      expect(restored.activePersonaId, kStandardPersonaId);
      expect(restored.agentPersonas, isEmpty);
    });

    test('fromJson 丢弃缺 id/name 的非法人格条目', () {
      final restored = InferenceSettings.fromJson({
        'agentPersonas': [
          {'name': 'no-id'},
          {'id': 'p1', 'name': '有效', 'prompt': 'ok'},
        ],
      });
      expect(restored.agentPersonas.length, 1);
      expect(restored.agentPersonas[0].id, 'p1');
    });

    test('copyWith 更新人格与激活 id', () {
      const base = InferenceSettings();
      final updated = base.copyWith(
        agentPersonas: [const AgentPersona(id: 'p1', name: 'A')],
        activePersonaId: 'p1',
      );
      expect(updated.activePersona()?.name, 'A');
      // 未传激活 id 时保留旧值。
      expect(
        updated.copyWith(agentPersonas: []).activePersonaId,
        'p1',
      );
    });
  });
}
