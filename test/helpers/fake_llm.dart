import 'dart:async';

import 'package:tongyi_lite/agent/llm/adapter.dart';

/// 脚本化 LLM 测试桩（全测试共享，2026-09-30 审查 P0-3：此前 4 份复制且
/// 行为漂移——本类统一；2026-11-09 二次收敛，phase5/subagents/fanout/
/// stop_generation 的本地桩并入，静默复读语义一并废除）。
///
/// 按 [script] 顺序消费：[LlmResult] 正常返回、[LlmFailure] 抛出；
/// 脚本耗尽后抛 [exhausted]（缺省 `LlmFailure(timeout)`——fail-loud，
/// 不静默复读最后一项：耗尽通常意味着测试预期的回合形状与实现漂移了）。
/// [onCall] 在第 N 次 generate 前回调（1 起；模拟"生成中途按停止"用）。
/// 无界动态应答场景用 [FakeLlmAdapter.always]（显式声明"复读"，
/// 区别于耗尽兜底）。记录字段：[calls]/[cancelCalls]/[lastMessages]/
/// [allMessages]/[allOptions]。
class FakeLlmAdapter implements LlmAdapter {
  final List<Object> _script;
  final LlmResult? _always;
  int _index = 0;

  /// 每次 generate 开始前回调（参数为第几次，1 起）。
  final void Function(int call)? onCall;

  /// 脚本耗尽时抛出的对象（null → 默认 timeout [LlmFailure]）。
  final Object? exhausted;

  int calls = 0;
  int cancelCalls = 0;
  List<Map<String, dynamic>>? lastMessages;
  final List<List<Map<String, dynamic>>> allMessages = [];
  final List<GenerateOptions> allOptions = [];

  FakeLlmAdapter(List<Object> script, {this.onCall, this.exhausted})
      : _script = script,
        _always = null;

  /// 恒返回同一结果（后台子代理这类无界应答场景；显式复读，非耗尽兜底）。
  FakeLlmAdapter.always(LlmResult result)
      : _script = const [],
        _always = result,
        onCall = null,
        exhausted = null;

  @override
  Future<LlmResult> generate(
    GenerateOptions options, {
    StreamController<String>? onToken,
    StreamController<String>? onThinking,
    Completer<void>? cancel,
  }) async {
    calls++;
    onCall?.call(calls);
    allOptions.add(options);
    lastMessages = options.messages;
    // 存快照：调用方若复用/改写消息列表，不污染已捕获的历史断言。
    allMessages.add(List.of(options.messages));
    if (_always != null) return _always;
    final item = _index < _script.length ? _script[_index++] : null;
    if (item == null) {
      if (exhausted != null) throw exhausted!;
      throw LlmFailure(
          code: LlmFailureCode.timeout,
          message: 'script exhausted (call #$calls)');
    }
    if (item is LlmFailure) throw item;
    return item as LlmResult;
  }

  @override
  void cancel() => cancelCalls++;

  @override
  PreparedLlmCall prepareCall(String model) =>
      PreparedLlmCall(adapter: this, model: model);
}
