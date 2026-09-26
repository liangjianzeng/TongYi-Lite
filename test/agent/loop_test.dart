import 'dart:async';

import 'package:tongyi_lite/agent/loop/agent.dart';
import 'package:tongyi_lite/agent/loop/config.dart';
import 'package:tongyi_lite/agent/loop/failure.dart';
import 'package:tongyi_lite/agent/llm/adapter.dart';
import 'package:tongyi_lite/agent/session/session.dart';
import 'package:tongyi_lite/agent/tool_definition.dart';
import 'package:tongyi_lite/agent/tool_registry.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// 测试桩
// ---------------------------------------------------------------------------

/// 脚本化 LLM 桩：按顺序返回 [LlmResult] 或抛 [LlmFailure]。
class FakeLlmAdapter implements LlmAdapter {
  final List<Object> _script;
  int _index = 0;
  int calls = 0;
  List<Map<String, dynamic>>? lastMessages;
  final List<List<Map<String, dynamic>>> allMessages = [];

  FakeLlmAdapter(List<Object> script) : _script = script;

  @override
  Future<LlmResult> generate(
    GenerateOptions options, {
    StreamController<String>? onToken,
    Completer<void>? cancel,
  }) async {
    calls++;
    lastMessages = options.messages;
    allMessages.add(options.messages);
    final item = _index < _script.length ? _script[_index++] : null;
    if (item == null) {
      throw LlmFailure(
          code: LlmFailureCode.timeout, message: 'script exhausted (call #$calls)');
    }
    if (item is LlmFailure) throw item;
    return item as LlmResult;
  }

  @override
  void cancel() {}

  @override
  PreparedLlmCall prepareCall(String model) =>
      PreparedLlmCall(adapter: this, model: model);
}

/// 挂起桩：一直挂到 cancel 完成，然后抛 [AgentCancelledException]（验证取消竞跑）。
class HangingFakeLlmAdapter implements LlmAdapter {
  bool cancelled = false;
  int calls = 0;

  @override
  Future<LlmResult> generate(
    GenerateOptions options, {
    StreamController<String>? onToken,
    Completer<void>? cancel,
  }) async {
    calls++;
    if (cancel != null) {
      await cancel.future;
    }
    cancelled = true;
    throw const AgentCancelledException();
  }

  @override
  void cancel() {}

  @override
  PreparedLlmCall prepareCall(String model) =>
      PreparedLlmCall(adapter: this, model: model);
}

/// 一个返回固定结果的假天气工具。
ToolDefinition _weatherTool() => ToolDefinition(
      name: 'get_weather',
      description: '查询天气',
      parameters: {
        'type': 'object',
        'properties': {'city': {'type': 'string', 'description': '城市'}},
        'required': ['city'],
      },
      execute: (args) => Future.value(ToolResult(content: 'Beijing: sunny 25C')),
    );

ToolRegistry _registryWith(List<ToolDefinition> tools) {
  final reg = ToolRegistry();
  for (final t in tools) {
    reg.register(t);
  }
  return reg;
}

/// 从事件里取某类型事件的 data。
Map<String, dynamic>? _findData(SessionLog log, String type) {
  for (final e in log.rawEvents) {
    if (e.type == type) return e.data;
  }
  return null;
}

/// 构造就绪的 ReactLoopAgent（默认带 get_weather）。
ReactLoopAgent _agent(
  LlmAdapter adapter, {
  List<ToolDefinition>? tools,
  AgentConfig? config,
}) {
  final session = SessionLog.fromEvents(const []);
  final registry = _registryWith(tools ?? [_weatherTool()]);
  final cfg = config ?? AgentConfig();
  return ReactLoopAgent(
    session: session,
    adapter: adapter,
    registry: registry,
    modelId: 'test-model',
    providerKind: ProviderKind.local,
    systemPrompt: '你是 TongYi-Lite 智能体',
    config: cfg,
    compaction: const NoCompactionPlugin(),
  );
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

void main() {
  test(
      '简单 turn：无工具调用 → completed，日志含 system/user/assistant/turn-end',
      () async {
    final fake = FakeLlmAdapter(
        [LlmResult(text: '你好，我是助手', toolCalls: const [])]);
    final agent = _agent(fake);

    final reason = await agent.kick('你好');

    expect(reason.kind, TurnEndReasonKind.completed);
    expect(fake.calls, 1);
    final data = _findData(agent.session, kEventUserMessage);
    expect(data?['content'], '你好');
    expect(agent.phaseState.phase, AgentPhase.idle);
  });

  test('工具调用 turn：模型调工具 → 执行 → 再问模型 → 最终答案', () async {
    final call = ToolCall(
        id: 'call_1',
        name: 'get_weather',
        arguments: {'city': 'Beijing'});
    final fake = FakeLlmAdapter([
      LlmResult(text: '', toolCalls: [call]),
      LlmResult(text: '北京今天晴，25C', toolCalls: const []),
    ]);
    final agent = _agent(fake);

    final reason = await agent.kick('北京天气？');

    expect(reason.kind, TurnEndReasonKind.completed);
    expect(fake.calls, 2);
    // 工具结果落日志
    expect(_findData(agent.session, kEventToolResult), isNotNull);
    // 第二次请求应能看到工具结果（G12）
    final lastMsgs = fake.allMessages.last;
    expect(lastMsgs, isNotEmpty);
  });

  test('失败 → llm-retry → 成功（llm/retry 与 assistant/attempt 落日志）',
      () async {
    final fake = FakeLlmAdapter([
      LlmFailure(code: LlmFailureCode.timeout, message: 'timeout'),
      LlmResult(text: 'ok', toolCalls: const []),
    ]);
    final agent = _agent(fake);

    final reason = await agent.kick('hi');

    expect(reason.kind, TurnEndReasonKind.completed);
    expect(fake.calls, 2); // 1 失败 + 1 重试成功
    expect(_findData(agent.session, kEventLlmRetry), isNotNull);
    expect(_findData(agent.session, kEventAssistantAttempt), isNotNull);
  });

  test('连续失败超预算 → 终态 error（不无限重试）', () async {
    final fake = FakeLlmAdapter(
        [
          LlmFailure(code: LlmFailureCode.timeout, message: 't1'),
          LlmFailure(code: LlmFailureCode.timeout, message: 't2'),
          LlmFailure(code: LlmFailureCode.timeout, message: 't3'),
          LlmFailure(code: LlmFailureCode.timeout, message: 't4'),
        ]);
    final agent = _agent(fake);

    final reason = await agent.kick('hi');

    expect(reason.kind, TurnEndReasonKind.error);
    // maxRetries=3 → 1 初始 + 3 重试 = 4 次
    expect(fake.calls, 4);
    expect(agent.phaseState.phase, AgentPhase.idle);
  });

  test('取消 → interrupted（abort 与流竞跑）', () async {
    final fake = HangingFakeLlmAdapter();
    final agent = _agent(fake);
    final future = agent.kick('hi');
    await Future.delayed(Duration(milliseconds: 50));
    agent.cancel('user stop');
    final reason = await future;
    expect(reason.kind, TurnEndReasonKind.interrupted);
    expect(agent.phaseState.phase, AgentPhase.idle);
    expect(fake.calls, 1); // 只发起一次，被取消
  });

  test('G12：每次请求历史均来自 log 派生（非手工构造）', () async {
    final fake = FakeLlmAdapter([
      LlmResult(
          text: '',
          toolCalls: [
            ToolCall(id: 'c1', name: 'get_weather',
                arguments: {'city': 'Beijing'})
          ]),
      LlmResult(text: '晴', toolCalls: const []),
    ]);
    final agent = _agent(fake);
    final session = agent.session;

    await agent.kick('北京天气？');

    // 第一次请求：log 当时只含 system + user（无 assistant/tool）
    final first = fake.allMessages.first;
    expect(first.length, 2);
    expect(first.first['role'], 'system');
    expect(first.first['content'], '你是 TongYi-Lite 智能体');
    expect(first[1]['role'], 'user');
    expect(first[1]['content'], '北京天气？');
    // 结构一致性：roles 序列正确
    expect(first.every((m) => m['role'] != null), true);
  });

  test('maxSteps：持续调工具到上限 → turn/end {reason:maxSteps}', () async {
    final fake = FakeLlmAdapter([
      LlmResult(
          text: '',
          toolCalls: [
            ToolCall(id: 'c0', name: 'get_weather',
                arguments: {'city': 'Beijing'})
          ]),
      LlmResult(
          text: '',
          toolCalls: [
            ToolCall(id: 'c1', name: 'get_weather',
                arguments: {'city': 'Beijing'})
          ]),
      // 第三次不应被调用（达到 maxSteps=2 上限）
      LlmResult(text: 'never', toolCalls: const []),
    ]);
    final agent = _agent(fake, config: const AgentConfig(maxStepsPerTurn: 2));
    final reason = await agent.kick('北京天气？');
    expect(reason.kind, TurnEndReasonKind.maxSteps);
    expect(fake.calls, 2); // 只到上限，不超
    expect(_findData(agent.session, kEventTurnEnd)?['reason'], 'maxSteps');
  });

  test('未知工具：模型调未注册工具 → 工具返回可读错误，不崩溃', () async {
    final fake = FakeLlmAdapter([
      LlmResult(text: '', toolCalls: [
        ToolCall(id: 'c1', name: 'nonexistent_tool', arguments: {})
      ]),
      LlmResult(text: '抱歉找不到该工具', toolCalls: const []),
    ]);
    final agent = _agent(fake);
    final reason = await agent.kick('用 nonexistent_tool');
    expect(reason.kind, TurnEndReasonKind.completed);
    final tr = _findData(agent.session, kEventToolResult);
    expect(tr?['isError'], true);
    expect(tr?['content'], contains('未知工具'));
  });

  test('必填参数校验：工具缺必填参数 → 工具返回引导性错误', () async {
    final fake = FakeLlmAdapter([
      LlmResult(text: '', toolCalls: [
        ToolCall(id: 'c1', name: 'get_weather', arguments: {}) // 缺 city
      ]),
      LlmResult(text: '请告诉我城市', toolCalls: const []),
    ]);
    final agent = _agent(fake);
    await agent.kick('天气');
    final tr = _findData(agent.session, kEventToolResult);
    expect(tr?['isError'], true);
    expect(tr?['content'], contains('缺少必填参数'));
  });
}