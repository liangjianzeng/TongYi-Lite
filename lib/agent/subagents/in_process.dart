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
import '../session/event.dart'
    show SessionEvent, kEventStepStart, kEventToolCall, kEventTurnEnd;
import '../session/session.dart' show SessionLog;
import '../context_eng/token_estimate.dart' show estimateTextTokens;
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

/// 可续轮子代理保留容量（FIFO）。
const int kContinuableCapacity = 8;

/// 一个可续轮子代理（会话 + agent + 运行标记）。
final class _Continuable {
  final ReactLoopAgent agent;
  final SessionLog session;
  bool running = false;
  _Continuable(this.agent, this.session);
}

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

  /// 可续轮子代理表（DSH continuable subagent）：id → 会话+agent。
  /// 容量 [kContinuableCapacity] FIFO（超出回收最旧——父代理拿到的 id
  /// 太旧时 sendMessage 报"已回收"，重新委派即可）。
  final Map<String, _Continuable> _continuable = {};

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
        // 子代理受限配置（§10.6 成本控制），按驱动路线分档：
        // API 档放宽步数与预算（云端模型便宜快），local 档维持端侧紧预算。
        _subConfig = providerKind == ProviderKind.api
            ? const AgentConfig(
                maxStepsPerTurn: 8,
                maxTokensPerRound: 8192,
                temperature: 0.7,
                toolTimeout: Duration(seconds: 30),
                allowParallelTools: false,
                maxParallel: 4,
              )
            : const AgentConfig(
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
    // C2 toolFilter：allowedTools 非空 → 过滤注册表（最小权限委派）。
    // 白名单里的名字在父注册表不存在时静默忽略（模型可见清单即真相）。
    ToolRegistry? filtered;
    final allowed = request.allowedTools;
    if (allowed != null && allowed.isNotEmpty) {
      filtered = ToolRegistry();
      final wanted = allowed.toSet();
      for (final t in _registry.all) {
        if (wanted.contains(t.name)) filtered.register(t);
      }
    }
    final agent = _buildAgent(session, registry: filtered);
    _rememberContinuable(id, agent, session);
    final entry = _continuable[id]!;
    entry.running = true;
    final completer = Completer<SubagentResult>();
    unawaited(_runTurnWith(agent, request.task, onProgress: request.onProgress)
        .then((r) => completer.complete(r))
        .catchError((Object e, StackTrace st) =>
            completer.complete(SubagentResult.fromError(e.toString())))
        .then((_) {
      kSubagentDepth.pop();
      entry.running = false;
    }));
    return SubagentRun(id, session, completer.future);
  }

  @override
  Future<SubagentResult> sendMessage(String id, String message) async {
    final entry = _continuable[id];
    if (entry == null) {
      return SubagentResult(
        output: '子代理 $id 不存在或已被回收（可续轮子代理最多保留 '
            '$kContinuableCapacity 个）。请重新用 subagent 委派。',
        isError: true,
        stopReason: 'error',
      );
    }
    final msg = message.trim();
    if (msg.isEmpty) {
      return SubagentResult.fromError('send_message 的 message 不能为空');
    }
    if (entry.running) {
      return SubagentResult(
        output: '子代理 $id 仍在执行中，本次消息未送达。'
            '请等它完成后再 send_message。',
        isError: true,
        stopReason: 'error',
      );
    }
    kSubagentDepth.push();
    try {
      entry.running = true;
      return await _runTurnWith(entry.agent, msg);
    } finally {
      entry.running = false;
      kSubagentDepth.pop();
    }
  }

  void _rememberContinuable(String id, ReactLoopAgent agent, SessionLog s) {
    while (_continuable.length >= kContinuableCapacity) {
      _continuable.remove(_continuable.keys.first);
    }
    _continuable[id] = _Continuable(agent, s);
  }

  ReactLoopAgent _buildAgent(SessionLog session, {ToolRegistry? registry}) {
    return ReactLoopAgent(
      session: session,
      adapter: _adapter,
      registry: registry ?? _registry,
      config: _subConfig,
      modelId: _modelId,
      providerKind: _providerKind,
      systemPrompt: _systemPrompt,
      sandboxApprover: neverApprover,
      // 子代理不更新 UI（用户关注父输出）；工具活动归父 session。
    );
  }

  SessionLog _createSession(SubagentStartRequest request) {
    if (request.mode == 'fork') {
      final prefix = completedTurnPrefix(_parentSession);
      // 上下文窗口成本控制（§10.6）：fork seed 截断到 maxTokensPerRound
      //（A4 统一口径：estimateTextTokens，与主循环预算/压缩同一把尺）。
      final events = _truncatePrefix(prefix, _subConfig.maxTokensPerRound);
      return SessionLog.fromEvents(events);
    }
    // spawn：空白（需 fromEvents 空列表构造）。
    return SessionLog.fromEvents(const []);
  }

  /// 将前缀事件从末尾保留，总估算 token 不超过 [maxTokens]。
  /// 保留 tail（最近内容）以最大化上下文相关性。
  List<SessionEvent> _truncatePrefix(
      List<SessionEvent> prefix, int maxTokens) {
    if (prefix.isEmpty) return prefix;
    var keptTokens = 0;
    int startIndex = prefix.length;
    for (var i = prefix.length - 1; i >= 0; i--) {
      final count = _eventTokens(prefix[i].data);
      if (keptTokens + count > maxTokens) break;
      keptTokens += count;
      startIndex = i;
    }
    return prefix.sublist(startIndex);
  }

  /// 单个事件载荷的估算 token（A4 统一口径）。
  int _eventTokens(Map<String, dynamic> data) {
    String s = '';
    data.forEach((k, v) => s += '$k:$v ');
    return estimateTextTokens(s);
  }

  Future<SubagentResult> _runTurnWith(ReactLoopAgent agent, String task,
      {void Function(String line)? onProgress}) async {
    // C2 进度流：订阅子代理事件流的里程碑（步开始/工具调用/收尾），
    // 经 [onProgress] 转发（UI 展示用，不进父模型上下文）。subscription
    // 在 kick 完成后取消——进度只覆盖本次运行。
    StreamSubscription<SessionEvent>? progressSub;
    if (onProgress != null) {
      var stepNo = 0;
      progressSub = agent.session.events.listen((e) {
        switch (e.type) {
          case kEventStepStart:
            stepNo = (e.data['step'] as num?)?.toInt() ?? stepNo + 1;
            onProgress('步 $stepNo 开始');
            break;
          case kEventToolCall:
            onProgress(
                '步 $stepNo 调用 ${e.data['name'] ?? '?'}');
            break;
          case kEventTurnEnd:
            onProgress('结束（${e.data['reason'] ?? '?'}）');
            break;
          default:
            break;
        }
      });
    }
    try {
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
    } finally {
      await progressSub?.cancel();
    }
  }
}
