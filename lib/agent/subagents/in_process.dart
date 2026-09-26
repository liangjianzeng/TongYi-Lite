/// 进程内子代理实现（DSH Part 11）—— spawn + fork。
///
/// - 子代理复用父的 [LlmAdapter] / [ToolRegistry] / 模型 / 系统提示（同模型、
///   同工具集，token 消耗翻倍）；独立 [SessionLog]（spawn 空白 / fork 前缀）。
/// - **审批恒 `never`**（DSH Part 7.11 不变量 10）：[neverApprover] 自动
///   **拒绝**沙箱升级 → 子代理恒 `workspace-write`，不可升 `danger-full-access`；
///   被拒工具直接失败（§9.5 端侧安全不变量 7/10）。
/// - **深度 ≤ 2**（DSH Part 11.10 不变量 6）：[SubagentDepthCounter] 嵌套计数
///   （单线程 async 内嵌套安全；子代理在父 tool 调用内同步 await）。
///
/// 端侧成本控制（§10.6）：maxStepsPerTurn=5 / maxTokensPerRound=4096。
library;

import 'dart:async';
import 'dart:math';

import '../loop/agent.dart' show ReactLoopAgent, TurnEndReasonKind;
import '../loop/config.dart' show AgentConfig;
import '../llm/adapter.dart' show LlmAdapter, ProviderKind;
import '../sandbox.dart' show AgentSandboxApprover;
import '../session/event.dart' show SessionEvent;
import '../session/session.dart' show SessionLog;
import '../tool_registry.dart' show ToolRegistry;
import 'provider.dart';

/// 嵌套委派深度计数器（单线程 async 内嵌套安全；子代理在父 tool 内 await，
/// 故 push/pop 配对不会交错）。
final class SubagentDepthCounter {
  int _depth = 0;
  int get depth => _depth;
  /// 测试用直接设置（生产代码仅通过 push/pop 修改）。
  void set depth(int value) {
    if (value < 0) throw ArgumentError('depth >= 0');
    _depth = value;
  }
  void push() => _depth++;
  void pop() {
    if (_depth > 0) _depth--;
  }
}

/// 端侧共享计数器（app 任一时刻仅一个活动 agent → 安全）。
final SubagentDepthCounter kSubagentDepth = SubagentDepthCounter();

/// 生成子代理 id 用的随机数源。
final Random _kRandom = Random();

/// 子代理审批 `never`：恒拒绝沙箱升级（子代理不可升 `danger-full-access`）。
/// 传入即 fail-closed：审批通道不"询问用户"，直接否决升级。
final AgentSandboxApprover neverApprover = (escalation, toolName) =>
    Future.value(false);

/// 进程内子代理 provider（in-process，单实现）。
final class InProcessSubagentProvider extends SubagentProvider {
  final LlmAdapter _adapter;
  final ToolRegistry _registry;
  final String _modelId;
  final ProviderKind _providerKind;
  final String _systemPrompt;
  final SessionLog _parentSession;

  // 子代理受限配置（§10.6 成本控制）。
  final AgentConfig _subConfig;

  InProcessSubagentProvider({
    required LlmAdapter adapter,
    required ToolRegistry registry,
    required String modelId,
    required ProviderKind providerKind,
    required String systemPrompt,
    required SessionLog parentSession,
  })  : _adapter = adapter,
        _registry = registry,
        _modelId = modelId,
        _providerKind = providerKind,
        _systemPrompt = systemPrompt,
        _parentSession = parentSession,
        _subConfig = const AgentConfig(
          maxStepsPerTurn: 5,
          maxTokensPerRound: 4096,
          temperature: 0.7,
          toolTimeout: Duration(seconds: 30),
          allowParallelTools: false,
          maxParallel: 4,
        ),
      super(name: 'in-process',
          capabilities: const SubagentCapabilities(),
          inheritsParentContext: false);

  @override
  Future<SubagentRun> start(SubagentStartRequest request) async {
    // 深度校验（DSH Part 11.10 不变量 6：固定 maxDepth=2）。
    if (kSubagentDepth.depth + 1 > kSubagentMaxDepth) {
      throw SubagentMaxDepthExceeded(kSubagentDepth.depth + 1);
    }
    // push 在创建前；子代理 turn 结束（result 完成）时 pop。
    kSubagentDepth.push();
    final id =
        'sub-${DateTime.now().millisecondsSinceEpoch}-${_kRandom.nextInt(10000)}';
    final session = _createSession(request);
    final completer = Completer<SubagentResult>();
    unawaited(_runTurn(session, request.task)
        .then((r) => completer.complete(r))
        .catchError((Object e, StackTrace st) =>
            completer.complete(SubagentResult.fromError(e.toString())))
        .then((_) => kSubagentDepth.pop()));
    return SubagentRun(id, session, completer.future);
  }

  SessionLog _createSession(SubagentStartRequest request) {
    if (request.mode == 'fork') {
      final prefix = completedTurnPrefix(_parentSession);
      // 上下文窗口成本控制（§10.6）：fork seed 截断到 maxTokensPerRound
      //（按字符粗略估算，中文 ~2char/token、英文 ~4char/token，取保守上限）。
      final events = _truncatePrefix(prefix, _subConfig.maxTokensPerRound);
      return SessionLog.fromEvents(events);
    }
    // spawn：空白（需 fromEvents 空列表构造）。
    return SessionLog.fromEvents(const []);
  }

  /// 将前缀事件从末尾保留，总字符数不超过 [maxChars]（粗略 token 预算）。
  /// 保留 tail（最近内容）以最大化上下文相关性。
  List<SessionEvent> _truncatePrefix(
      List<SessionEvent> prefix, int maxTokens) {
    if (prefix.isEmpty) return prefix;
    // 粗略估算：中文 ~2char/token、英文 ~4char/token，取平均 ~3。
    const double charsPerToken = 3.0;
    final maxChars = (maxTokens * charsPerToken).round();
    // 从末尾向前累加，找到最大后缀（保持 seq 有序）。
    var keptChars = 0;
    int startIndex = prefix.length;
    for (var i = prefix.length - 1; i >= 0; i--) {
      final count = _eventCharCount(prefix[i].data);
      if (keptChars + count > maxChars) break;
      keptChars += count;
      startIndex = i;
    }
    return prefix.sublist(startIndex);
  }

  int _eventCharCount(Map<String, dynamic> data) {
    String s = '';
    data.forEach((k, v) => s += '$k:$v ');
    return s.length;
  }

  Future<SubagentResult> _runTurn(SessionLog session, String task) async {
    final agent = ReactLoopAgent(
      session: session,
      adapter: _adapter,
      registry: _registry,
      config: _subConfig,
      modelId: _modelId,
      providerKind: _providerKind,
      systemPrompt: _systemPrompt,
      sandboxApprover: neverApprover,
      // 子代理不更新 UI（用户关注父输出）；工具活动归父 session。
    );
    final turnReason = await agent.kick(task);
    // 映射 turn 结束原因 → SubagentResult（§10.5）。
    bool isError;
    switch (turnReason.kind) {
      case TurnEndReasonKind.completed:
        isError = false;
        break;
      case TurnEndReasonKind.error:
      case TurnEndReasonKind.interrupted:
      case TurnEndReasonKind.maxSteps:
        isError = true;
        break;
      default:
        isError = false;
    }
    return SubagentResult(
      output: agent.lastAssistantContent,
      isError: isError,
      stopReason: turnReason.kind.name,
    );
  }
}
