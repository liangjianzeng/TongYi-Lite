import 'package:flutter_test/flutter_test.dart';

import 'package:tongyi_lite/agent/agent.dart';

/// 可注入的 fake 模型流：按轮次返回预设结果，并捕获每次收到的消息历史。
class FakeAgentStream {
  final List<StreamOutcome> outcomes;
  final List<List<Map<String, String>>> captured = [];
  int calls = 0;

  FakeAgentStream(this.outcomes);

  Future<StreamOutcome> call(
    List<Map<String, String>> messages,
    ToolProtocol protocol,
    AgentConfig config,
  ) async {
    captured.add(List.of(messages));
    final outcome = outcomes[calls < outcomes.length ? calls : outcomes.length - 1];
    calls++;
    return outcome;
  }
}

void main() {
  ToolRegistry buildRegistry() {
    final registry = ToolRegistry();
    for (final tool in createBuiltinTools()) {
      registry.register(tool);
    }
    return registry;
  }

  ToolCall callOf(String name, {Map<String, dynamic>? args}) => ToolCall(
        id: 'c-$name',
        name: name,
        arguments: args,
      );

  group('agent loop', () {
    test('模型直接回答（无工具调用）→ 返回文本，无工具执行', () async {
      final registry = buildRegistry();
      final fake = FakeAgentStream([
        const StreamOutcome(text: '现在是晚上八点。'),
      ]);
      final result = await runAgent(
        history: [
          {'role': 'user', 'content': '你好'},
          {'role': 'assistant', 'content': '你好！'},
        ],
        userPrompt: '现在几点？',
        registry: registry,
        protocol: PromptJsonProtocol(),
        streamFn: fake.call,
        modelId: 'test-model',
      );

      expect(result.answer, '现在是晚上八点。');
      expect(result.toolCallCount, 0);
      expect(result.activities, isEmpty);
      // 历史 + 本轮用户消息，共 3 条。
      expect(fake.captured.first.length, 3);
    });

    test('systemPrompt 注入为首条 system 消息', () async {
      final registry = buildRegistry();
      final fake = FakeAgentStream([
        const StreamOutcome(text: '好的。'),
      ]);
      final result = await runAgent(
        history: [
          {'role': 'user', 'content': '你好'},
          {'role': 'assistant', 'content': '你好！'},
        ],
        userPrompt: '现在几点？',
        registry: registry,
        protocol: PromptJsonProtocol(),
        streamFn: fake.call,
        modelId: 'test-model',
        systemPrompt: '你是智能体，可调用工具。',
      );

      expect(result.answer, '好的。');
      expect(result.toolCallCount, 0);
      // system + 历史 2 + 用户 1，共 4 条。
      final messages = fake.captured.first;
      expect(messages.length, 4);
      expect(messages.first['role'], 'system');
      expect(messages.first['content'], '你是智能体，可调用工具。');
      expect(messages.last['role'], 'user');
    });

    test('onToolActivity 回调：执行中 → 完成（含结果）', () async {
      final registry = buildRegistry();
      final fake = FakeAgentStream([
        StreamOutcome(text: '', toolCalls: [callOf('get_time')]),
        const StreamOutcome(text: '当前时间是 2026-09-02 09:00:00（星期三）。'),
      ]);
      final activities = <String>[];
      final results = <String>[];

      await runAgent(
        history: [],
        userPrompt: '现在几点？',
        registry: registry,
        protocol: PromptJsonProtocol(),
        streamFn: fake.call,
        modelId: 'test-model',
        onToolActivity: (activity) async {
          activities.add('${activity.name}:${activity.status}');
          if (activity.status == 'done' || activity.status == 'failed') {
            results.add(activity.result ?? '');
          }
        },
      );

      // 每个工具：executing → done。
      expect(activities, ['get_time:executing', 'get_time:done']);
      // done 回调携带执行结果。
      expect(results, hasLength(1));
      expect(results.single, isNotEmpty);
    });

    test('先调用工具再回答 → 执行工具、结果回填、最终回答引用结果', () async {
      final registry = buildRegistry();
      final fake = FakeAgentStream([
        StreamOutcome(text: '', toolCalls: [callOf('get_time')]),
        const StreamOutcome(text: '当前时间是 2026-09-02 09:00:00（星期三）。'),
      ]);

      final result = await runAgent(
        history: [],
        userPrompt: '现在几点？',
        registry: registry,
        protocol: PromptJsonProtocol(),
        streamFn: fake.call,
        modelId: 'test-model',
      );

      expect(result.toolCallCount, 1);
      expect(result.activities, ['get_time → 成功']);
      expect(fake.calls, 2);
      // 第二轮消息 = 用户消息 + 工具结果回填。
      final second = fake.captured[1];
      expect(second.length, 2);
      expect(second[1]['role'], 'user');
      expect(second[1]['content'], contains('工具调用结果(get_time)'));
      expect(second[1]['content'], contains('当前时间'));
      expect(second[1]['toolCallId'], 'c-get_time');
      expect(result.answer, contains('当前时间是'));
    });

    test('连续两次工具调用（get_time → calculator）后回答', () async {
      final registry = buildRegistry();
      final fake = FakeAgentStream([
        StreamOutcome(text: '', toolCalls: [callOf('get_time')]),
        StreamOutcome(text: '', toolCalls: [
          callOf('calculator', args: {'expression': '12*7+3'}),
        ]),
        const StreamOutcome(text: '时间已获取，12×7+3=87。'),
      ]);

      final result = await runAgent(
        history: [],
        userPrompt: '现在几点？顺便算 12×7+3',
        registry: registry,
        protocol: PromptJsonProtocol(),
        streamFn: fake.call,
        modelId: 'test-model',
      );

      expect(fake.calls, 3);
      expect(result.toolCallCount, 2);
      expect(result.activities, ['get_time → 成功', 'calculator → 成功']);
      expect(fake.captured[2][2]['content'], contains('12*7+3 = 87'));
      expect(result.answer, contains('87'));
    });

    test('未知工具 → 回填错误并继续，不崩溃', () async {
      final registry = buildRegistry();
      final fake = FakeAgentStream([
        StreamOutcome(text: '', toolCalls: [callOf('unknown_tool')]),
        const StreamOutcome(text: '抱歉，我无法完成。'),
      ]);

      final result = await runAgent(
        history: [],
        userPrompt: '调用一个不存在的工具',
        registry: registry,
        protocol: PromptJsonProtocol(),
        streamFn: fake.call,
        modelId: 'test-model',
      );

      expect(result.toolCallCount, 1);
      expect(result.activities, ['unknown_tool → 失败']);
      expect(fake.captured[1][1]['content'], contains('未知工具 "unknown_tool"'));
      expect(result.answer, '抱歉，我无法完成。');
    });

    test('工具执行抛异常 → 回填错误并继续', () async {
      final registry = buildRegistry();
      registry.register(ToolDefinition(
        name: 'boom_tool',
        description: '总是失败',
        parameters: const {'type': 'object'},
        execute: (args) async {
          throw StateError('内部错误');
        },
      ));
      final fake = FakeAgentStream([
        StreamOutcome(text: '', toolCalls: [callOf('boom_tool')]),
        const StreamOutcome(text: '遇到了问题。'),
      ]);

      final result = await runAgent(
        history: [],
        userPrompt: '调用会失败的工具',
        registry: registry,
        protocol: PromptJsonProtocol(),
        streamFn: fake.call,
        modelId: 'test-model',
      );

      expect(result.activities, ['boom_tool → 失败']);
      expect(fake.captured[1][1]['content'], contains('执行失败'));
    });

    test('工具执行超时 → 回填超时错误并继续', () async {
      final registry = buildRegistry();
      registry.register(ToolDefinition(
        name: 'slow_tool',
        description: '很慢',
        parameters: const {'type': 'object'},
        execute: (args) async {
          await Future<void>.delayed(const Duration(seconds: 2));
          return const ToolResult(content: 'done');
        },
      ));
      final fake = FakeAgentStream([
        StreamOutcome(text: '', toolCalls: [callOf('slow_tool')]),
        const StreamOutcome(text: '等太久了。'),
      ]);

      final result = await runAgent(
        history: [],
        userPrompt: '调用慢工具',
        registry: registry,
        protocol: PromptJsonProtocol(),
        streamFn: fake.call,
        modelId: 'test-model',
        config: const AgentConfig(toolTimeout: Duration(milliseconds: 50)),
      );

      expect(result.activities, ['slow_tool → 失败']);
      expect(fake.captured[1][1]['content'], contains('超时'));
    });

    test('达到轮次上限 → 给出提示而非死循环', () async {
      final registry = buildRegistry();
      // 每轮都返回工具调用，永不回答。
      final fake = FakeAgentStream([
        StreamOutcome(text: '', toolCalls: [callOf('get_time')]),
      ]);

      final result = await runAgent(
        history: [],
        userPrompt: '无限调用',
        registry: registry,
        protocol: PromptJsonProtocol(),
        streamFn: fake.call,
        modelId: 'test-model',
        config: const AgentConfig(maxRounds: 3),
      );

      expect(fake.calls, 3); // 恰好 3 轮，不无限循环
      expect(result.toolCallCount, 3);
      expect(result.answer, contains('轮次上限 3'));
    });

    test('模型不可见工具 → 视为未知工具（分层校验）', () async {
      final registry = buildRegistry();
      registry.restrictModel('locked-model', allow: {'get_time'});
      final fake = FakeAgentStream([
        StreamOutcome(text: '', toolCalls: [callOf('calculator')]),
        const StreamOutcome(text: '完成。'),
      ]);

      final result = await runAgent(
        history: [],
        userPrompt: '算一下',
        registry: registry,
        protocol: PromptJsonProtocol(),
        streamFn: fake.call,
        modelId: 'locked-model',
      );

      expect(result.activities, ['calculator → 失败']);
      expect(fake.captured[1][1]['content'], contains('当前模型不可用'));
    });
  });
}
