import 'dart:async';

import 'package:tongyi_lite/agent/capability.dart';
import 'package:tongyi_lite/agent/llm/adapter.dart';
import 'package:tongyi_lite/agent/llm/base_engine_adapter.dart';
import 'package:tongyi_lite/agent/protocol/prompt_json_protocol.dart';
import 'package:tongyi_lite/agent/protocol/protocol_selector.dart';
import 'package:tongyi_lite/agent/protocol/tool_protocol.dart';
import 'package:tongyi_lite/agent/tool_registry.dart';
import 'package:flutter_test/flutter_test.dart';

/// 覆写 prepareCall 的桩（仿 [BaseEngineAdapter]，注入能力快照）。
class _CapsAdapter extends LlmAdapter {
  final EngineCapabilities? _caps;
  _CapsAdapter(this._caps);

  @override
  Future<LlmResult> generate(
    GenerateOptions options, {
    StreamController<String>? onToken,
    StreamController<String>? onThinking,
    Completer<void>? cancel,
  }) async => const LlmResult(text: 'ok');

  @override
  PreparedLlmCall prepareCall(String model) =>
      PreparedLlmCall(adapter: this, model: model, capabilities: _caps);
}

/// 不覆写 prepareCall 的桩（走 [LlmAdapter] 默认实现：仅 adapter + model）。
class _PlainAdapter extends LlmAdapter {
  @override
  Future<LlmResult> generate(
    GenerateOptions options, {
    StreamController<String>? onToken,
    StreamController<String>? onThinking,
    Completer<void>? cancel,
  }) async => const LlmResult(text: 'ok');
}

void main() {
  convertEngineMessagesTests();

  // 取消令牌回归（T3 并发缺陷，2026-11）：adapter 实例会被共享（chat_provider
  // 默认让子代理复用父回合的 adapter），旧 cancel() 无条件杀 currentSub 单槽
  // ——后发起的 generate 覆盖槽位后，父回合 cancel() 会误杀子代理的流。
  // 契约：归属判定=该次 generate 的取消信号已触发（或未传信号），未表态的
  // 令牌是别人的生成，一律不碰。
  group('取消令牌：共享 adapter 下 cancel() 只杀归属自己的生成', () {
    /// 造一个"在途生成"：真·流订阅，onCancel 经共享 map 观测中止与否。
    final cancelledFlags = <StreamController<void>, bool>{};
    (CancelToken, StreamController<void>) spawn(
      BaseEngineAdapter adapter,
      Completer<void>? signal,
    ) {
      late final StreamController<void> ctrl;
      ctrl = StreamController<void>(onCancel: () async {
        cancelledFlags[ctrl] = true;
      });
      final token = adapter.beginGeneration(cancel: signal);
      adapter.bindGenerationStream(token, ctrl.stream.listen((_) {}));
      return (token, ctrl);
    }

    bool wasKilled(StreamController<void> ctrl) => cancelledFlags[ctrl] ?? false;

    test('父回合信号已触发 → 只中止父令牌；子代理令牌（未表态）存活', () async {
      final adapter = _EngineAdapter(protocol: PromptJsonProtocol());
      final parentSignal = Completer<void>();
      final (parent, parentCtrl) = spawn(adapter, parentSignal);
      final (sub, subCtrl) = spawn(adapter, Completer<void>());

      parentSignal.complete(); // ReactLoopAgent.cancel 固定顺序：先表态再 cancel
      expect(adapter.cancelOwnedGenerations(), isTrue);
      await Future<void>.delayed(Duration.zero); // 让 onCancel 微任务跑完

      expect(wasKilled(parentCtrl), isTrue, reason: '归属本次取消 → 中止');
      expect(wasKilled(subCtrl), isFalse,
          reason: '子代理信号未触发 → 不得误杀（T3 缺陷本体）');
      expect(adapter.currentSub, isNotNull,
          reason: 'currentSub 槽属于子令牌（后注册者），不得被清');
      await parentCtrl.close();
      await subCtrl.close();
    });

    test('未传取消信号的令牌（旧式直调）保留可被任意 cancel 中止的旧行为', () async {
      final adapter = _EngineAdapter(protocol: PromptJsonProtocol());
      final (_, ctrl) = spawn(adapter, null);
      expect(adapter.cancelOwnedGenerations(), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(wasKilled(ctrl), isTrue);
      await ctrl.close();
    });

    test('无归属目标时 cancel 不杀任何流（native 停发不触发）', () async {
      final adapter = _EngineAdapter(protocol: PromptJsonProtocol());
      final (_, ctrl) = spawn(adapter, Completer<void>());
      adapter.cancel(); // 公开 API：签名不变；无归属目标时不动任何流
      expect(adapter.cancelOwnedGenerations(), isFalse,
          reason: '信号未触发 → 无归属目标');
      await Future<void>.delayed(Duration.zero);
      expect(wasKilled(ctrl), isFalse);
      await ctrl.close();
    });

    test('endGeneration：先结束者不清后来者的 currentSub 槽（防误清空）', () async {
      final adapter = _EngineAdapter(protocol: PromptJsonProtocol());
      final (parent, parentCtrl) = spawn(adapter, Completer<void>());
      final (sub, subCtrl) = spawn(adapter, Completer<void>());
      final subStream = adapter.currentSub; // 子令牌注册后槽位 = 子流

      parent.sub?.cancel(); // 模拟父回合先结束（finally 的 sub?.cancel()）
      adapter.endGeneration(parent);
      expect(adapter.currentSub, same(subStream),
          reason: '槽位已被子令牌覆盖，父令牌注销不得清掉');
      adapter.endGeneration(sub); // 子令牌注销才清槽
      expect(adapter.currentSub, isNull);
      await parentCtrl.close();
      await subCtrl.close();
    });
  });

  test('prepareCall：覆写版固化能力快照（adapter + model + capabilities）', () {
    final caps = EngineCapabilities(
      nativeToolCall: false,
      toolTemplate: 'spark-xml',
      maxParallelToolCalls: 4,
    );
    final adapter = _CapsAdapter(caps);
    final call = adapter.prepareCall('qwen3.5-4b');
    expect(call.adapter, adapter);
    expect(call.model, 'qwen3.5-4b');
    expect(call.capabilities, caps);
  });

  test('prepareCall（默认）：不覆写时仅 adapter + model，capabilities=null', () {
    final adapter = _PlainAdapter();
    final call = adapter.prepareCall('m1');
    expect(call.adapter, adapter);
    expect(call.model, 'm1');
    expect(call.capabilities, null);
  });

  test('EngineCapabilities.resolve：probed 事实优先，缺失字段回退 declared', () {
    final declared = EngineCapabilities(
      nativeToolCall: true, // 预期（静态声明）
      structuredOutput: true, // 预期
      toolTemplate: 'spark-xml',
    );
    final probed = EngineCapabilities(
      nativeToolCall: false, // 事实（引擎上报：实际不支持）
      structuredOutput: false, // 事实
      // toolTemplate 缺失 → 回退 declared
    );
    final resolved = EngineCapabilities.resolve(declared: declared, probed: probed);
    expect(resolved.nativeToolCall, false);
    expect(resolved.structuredOutput, false);
    expect(resolved.toolTemplate, 'spark-xml');
  });

  test('EngineCapabilities.resolve：无 probed → 纯 declared', () {
    final declared = const EngineCapabilities(
      nativeToolCall: true,
      toolTemplate: 'openai',
    );
    final resolved = EngineCapabilities.resolve(declared: declared, probed: null);
    expect(resolved.nativeToolCall, true);
    expect(resolved.toolTemplate, 'openai');
  });

  test('selectProtocol：至少一个候选时返回最优先级（此处唯一 prompt-json）', () {
    final protocol = selectProtocol(
      [PromptJsonProtocol()],
      const EngineCapabilities(),
    );
    expect(protocol.id, isNot(null));
    final byNative = selectProtocol(
      [PromptJsonProtocol()],
      const EngineCapabilities(nativeToolCall: true),
    );
    expect(byNative.id, protocol.id);
    expect(byNative.supports(const EngineCapabilities(nativeToolCall: true)), true);
  });

  test('selectProtocol：空候选抛 ArgumentError', () {
    expect(
      () => selectProtocol(<PromptJsonProtocol>[], const EngineCapabilities()),
      throwsArgumentError,
    );
  });

  test('selectProtocol：无协议 supports 时抛 StateError', () {
    final noSupport = _NoSupportProtocol();
    expect(
      () => selectProtocol([noSupport], const EngineCapabilities(nativeToolCall: true)),
      throwsStateError,
    );
  });
}

/// 对任何能力都不支持的协议（验证 StateError 路径）。
class _NoSupportProtocol implements ToolProtocol {
  @override
  String get id => 'no-support';

  @override
  bool supports(EngineCapabilities caps) => false;

  @override
  int priority(EngineCapabilities caps) => 0;

  @override
  String buildToolSection(ToolRegistry registry, {String modelId = ''}) => '';

  @override
  Future<StreamOutcome> parseStream(Stream<String> stream) async =>
      const StreamOutcome(text: '');

  @override
  String? replayToolCalls(
          String modelId, List<Map<String, dynamic>> toolCalls) =>
      null;
}

/// BaseEngineAdapter 具体桩：仅复用 [BaseEngineAdapter.convertEngineMessages]
/// （generate 沿用基类抛 UnimplementedError，本组测试不触发生成）。
class _EngineAdapter extends BaseEngineAdapter {
  _EngineAdapter({required super.protocol, super.capabilities});
}

void convertEngineMessagesTests() {
  final protocol = PromptJsonProtocol();

  List<Map<String, dynamic>> input() => [
        {'role': 'user', 'content': '帮我看下时间'},
        {'role': 'assistant', 'content': '我来查一下'},
        {'role': 'tool', 'content': '2026-10-14 12:00:00'},
      ];

  test('convertEngineMessages：默认（无能力快照）tool→user', () {
    final adapter = _EngineAdapter(protocol: protocol);
    final out = adapter.convertEngineMessages(input());
    expect(out[2]['role'], 'user');
  });

  test('convertEngineMessages：spark-xml 模板 tool→user（模板不识别 tool 角色）',
      () {
    final adapter = _EngineAdapter(
      protocol: protocol,
      capabilities: const EngineCapabilities(toolTemplate: 'spark-xml'),
    );
    final out = adapter.convertEngineMessages(input());
    expect(out[2]['role'], 'user');
  });

  test('convertEngineMessages：bailing-v3（Ling）模板保留 role:tool'
      '（渲染为 OBSERVATION）', () {
    final adapter = _EngineAdapter(
      protocol: protocol,
      capabilities: const EngineCapabilities(toolTemplate: 'bailing-v3'),
    );
    final out = adapter.convertEngineMessages(input());
    expect(out[2]['role'], 'tool');
    expect(out[2]['content'], '2026-10-14 12:00:00');
  });
}
