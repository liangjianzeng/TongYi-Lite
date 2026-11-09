import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:tongyi_lite/agent/loop/agent.dart';
import 'package:tongyi_lite/agent/loop/config.dart';
import 'package:tongyi_lite/agent/loop/failure.dart';
import 'package:tongyi_lite/agent/llm/adapter.dart';
import 'package:tongyi_lite/agent/session/session.dart';
import 'package:tongyi_lite/agent/tool_definition.dart';
import 'package:tongyi_lite/agent/tool_registry.dart';
import '../helpers/fake_llm.dart';

// 停止按钮这条链的回归（用户 2026-10-24：「那个停止一点卵用都没有」）。
//
// 修掉的三个洞，每个都对应这里一条用例：
// ① 取消后以 LlmFailure 形态到达的中止（API request cancelled / 本地 stopGeneration
//    打断流）旧版会进重试瀑布 → 按下停止后循环自己又发一次生成；
// ② 步与步之间（工具执行中）取消时 _cancelCompleter 为 null，旧 cancel() 那时
//    什么都不做 → _cancelCompleted 仍 false → 下一步检查放行，继续烧 token；
// ③ 取消后仍去走压缩（改写会话 + 再发一次请求）。

// 中止到达时的失败形态：transport 在重试器里**是可重试的**，
// 正好复现"停止后自己重试"的旧行为（用共享桩 exhausted 注入）。
const _cancelled =
    LlmFailure(code: LlmFailureCode.transport, message: 'request cancelled');

ToolRegistry _registry(void Function() onExecute) {
  final reg = ToolRegistry();
  reg.register(ToolDefinition(
    name: 'get_weather',
    description: '查询天气',
    parameters: {
      'type': 'object',
      'properties': {'city': {'type': 'string'}},
      'required': ['city'],
    },
    execute: (args) {
      onExecute();
      return Future.value(const ToolResult(content: 'Beijing: sunny 25C'));
    },
  ));
  return reg;
}

ReactLoopAgent _agent(
  FakeLlmAdapter fake, {
  void Function()? onToolExecute,
}) =>
    ReactLoopAgent(
      session: SessionLog.fromEvents(const []),
      adapter: fake,
      registry: _registry(onToolExecute ?? () {}),
      modelId: 'test-model',
      providerKind: ProviderKind.local,
      systemPrompt: '你是 TongYi-Lite 智能体',
      config: const AgentConfig(maxStepsPerTurn: 8, maxTokensPerRound: 512),
      compaction: const NoCompactionPlugin(),
      retry: LlmRetry(
          maxRetries: 3, initialDelay: Duration.zero, maxDelay: Duration.zero),
    );

const _toolStep = LlmResult(
  text: '',
  toolCalls: [ToolCall(id: 'c1', name: 'get_weather', arguments: {'city': 'Beijing'})],
);

void main() {
  group('停止按钮 · 中止必须真中止', () {
    test('取消后到达的可重试失败不得进重试瀑布（无幽灵生成）', () async {
      late ReactLoopAgent agent;
      final fake = FakeLlmAdapter([],
          onCall: (n) {
            if (n == 1) unawaited(agent.cancel());
          },
          exhausted: _cancelled);
      agent = _agent(fake);

      final reason = await agent.kick('北京天气？');

      expect(reason.kind, TurnEndReasonKind.interrupted);
      expect(fake.calls, 1, reason: '旧行为：这里会变成 2（停止后自己又发一次）');
      expect(fake.cancelCalls, greaterThan(0), reason: '必须通知 adapter 停后端');
      expect(agent.lastTurnAnswer, '', reason: '中止不得冒充答案');
    });

    test('工具执行期间按下停止：不得再发起下一步', () async {
      late ReactLoopAgent agent;
      // 第 1 次返回工具调用；工具执行中按下停止。
      final fake = FakeLlmAdapter([_toolStep], exhausted: _cancelled);
      agent = _agent(fake, onToolExecute: () => unawaited(agent.cancel()));

      final reason = await agent.kick('查天气再总结');

      expect(reason.kind, TurnEndReasonKind.interrupted);
      expect(fake.calls, 1, reason: '旧行为：步间隙取消不置位 → 还会跑第 2 步');
    });

    test('取消不跨回合：未 running 时 cancel 幂等，且不得让新回合开局就死',
        () async {
      final fake = FakeLlmAdapter([const LlmResult(text: '好的')],
          exhausted: _cancelled);
      final agent = _agent(fake);
      await agent.cancel(); // 幂等：没有回合在跑时调用不得抛

      final reason = await agent.kick('随便说点什么');

      // 取消是**回合级**动作：kick 开新回合必须清掉旧取消位，否则下一次发消息
      // 直接"什么都不发"，那是另一种更难查的坏法。
      expect(reason.kind, TurnEndReasonKind.completed);
      expect(fake.calls, 1);
      expect(agent.lastTurnAnswer, '好的');
    });

    test('取消态下上下文溢出也不去压缩（压缩=再发一次请求）', () async {
      final fake = FakeLlmAdapter([],
          onCall: (n) {
            if (n == 1) unawaited(agentRef.value!.cancel());
          },
          exhausted: const LlmFailure(
              code: LlmFailureCode.contextWindowExceeded,
              message: 'request cancelled'));
      final agent = _agent(fake);
      agentRef.value = agent;

      final reason = await agent.kick('长文总结');

      expect(reason.kind, TurnEndReasonKind.interrupted);
      expect(fake.calls, 1, reason: '压缩路径也不许在停止后再发请求');
      agentRef.value = null;
    });
  });
}

/// 最后一个用例需要在桩里拿到 agent 句柄（onCall 早于 agent 构造完成）。
final agentRef = _Box();

class _Box {
  ReactLoopAgent? value;
}
