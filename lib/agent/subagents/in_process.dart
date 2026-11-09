/// 进程内子代理实现（DSH Part 11）—— spawn + fork。
///
/// - 子代理复用父的 [LlmAdapter] / [ToolRegistry] / 模型 / 系统提示（同模型、
///   同工具集，token 消耗翻倍）；独立 [SessionLog]（spawn 空白 / fork 前缀）。
/// - **审批恒 `never`**（DSH Part 7.11 不变量 10）：[neverApprover] 自动
///   **拒绝**沙箱升级 → 子代理恒 `workspace-write`，不可升 `danger-full-access`；
///   被拒工具直接失败（§9.5 端侧安全不变量 7/10）。
/// - **深度 ≤ 2**（DSH Part 11.10 不变量 6）：[SubagentDepthCounter] 深度是
///   **Zone 作用域的委派链属性**（子代理回合整体跑在抬高后的 Zone 里）。
///   旧实现是全局 push/pop 计数：fan-out 的**兄弟**后台子代理并发运行期间
///   互相抬高同一计数器，第 3 个后台任务被误判为深度 3 而拒绝启动
///   （时序依赖的潜在缺陷，A 期 UI 重构改变 kick 收尾时序后稳定复现）。
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

/// 嵌套委派深度计数器（DSH Part 11.10：**每条委派链**的深度，非并发计数）。
///
/// 深度存在 [Zone] 里：子代理的整个回合执行期被 [runChild] 包进
/// `depth = 父深度 + 1` 的 Zone，它内部再委派时读到的就是自己的深度；
/// **并发/后台的兄弟子代理各在各自 Zone，互不抬高**。工具执行发生在
/// 回合的调用栈上，天然继承该 Zone——无需全局 push/pop。
final class SubagentDepthCounter {
  static const Symbol _zoneKey = #subagentDepth;

  /// Zone 外的回落深度（测试预置 / 顶层进程）。
  int _base = 0;

  /// 当前有效深度：Zone 内 = 本委派链深度；Zone 外 = [_base]。
  int get depth => Zone.current[_zoneKey] as int? ?? _base;

  /// 测试用直接设置（生产代码只通过 [runChild] 抬升）。
  void set depth(int value) {
    if (value < 0) throw ArgumentError('depth >= 0');
    _base = value;
  }

  /// 在「子代理自身回合」的执行期把深度抬升为 [childDepth]。
  R runChild<R>(int childDepth, R Function() body) =>
      runZoned(body, zoneValues: {_zoneKey: childDepth});
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

  /// 本代理所属委派链深度（spawn 时 = 父深度 + 1）：send_message 续轮仍在
  /// 该深度 Zone 里跑（续轮是**它自己**的回合，不是调用方的子辈）。
  final int childDepth;
  bool running = false;
  _Continuable(this.agent, this.session, {this.childDepth = 1});
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
    // 深度取**调用方 Zone**（父回合栈）；子代理回合随后整体跑在
    // `callerDepth + 1` 的 Zone 里——并发兄弟互不抬高（见计数器文档）。
    final callerDepth = kSubagentDepth.depth;
    if (callerDepth + 1 > kSubagentMaxDepth) {
      throw SubagentMaxDepthExceeded(callerDepth + 1);
    }
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
    _rememberContinuable(id, agent, session, childDepth: callerDepth + 1);
    final entry = _continuable[id]!;
    entry.running = true;
    final completer = Completer<SubagentResult>();
    unawaited(kSubagentDepth.runChild(callerDepth + 1, () {
      return _runTurnWith(agent, request.task,
              onProgress: request.onProgress)
          .then((r) => completer.complete(r))
          .catchError((Object e, StackTrace st) =>
              completer.complete(SubagentResult.fromError(e.toString())))
          .then((_) {
        entry.running = false;
      });
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
    entry.running = true;
    try {
      // 续轮 = 子代理自己的回合 → 跑在**它所属委派链**的深度 Zone 里。
      return await kSubagentDepth.runChild(
          entry.childDepth, () => _runTurnWith(entry.agent, msg));
    } finally {
      entry.running = false;
    }
  }

  void _rememberContinuable(String id, ReactLoopAgent agent, SessionLog s,
      {int childDepth = 1}) {
    while (_continuable.length >= kContinuableCapacity) {
      _continuable.remove(_continuable.keys.first);
    }
    _continuable[id] = _Continuable(agent, s, childDepth: childDepth);
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
