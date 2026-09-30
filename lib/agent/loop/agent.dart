/// 智能体主循环（Phase 1）—— 对照 DSH `ReactLoopAgent`。
///
/// 结构（对照 DSH 主循环 Part 7）：
/// - 外层 `turn` 循环：一个 turn = 用户输入 → 最终回答（或失败/中断）。
///   用户消息是 turn 的唯一入口（`kick`）。
/// - 内层 `step` 循环：一个 step = 一次模型请求（llm 调用）。
///   step 内：`step/start` → 构建请求 → `llm/step` → `assistant/message`
///   → 若有工具 → 逐工具 `tool/call`+执行+`tool/result` → `step/end`。
/// - 失败瀑布（Part 9.9）：模型失败 → 落 `assistant/attempt`（log-only，
///   模型不可见）→ 跑 `CompactionPlugin`（CONTEXT_WINDOW_EXCEEDED）/
///   `LlmRetry`（瞬态）→ success 才 `{kind:retry}`（同一 step 重试）。
/// - 取消（Part 14.6）：`abortController`；`cancel()` 中止当前 step；
///   `turn/end {reason:interrupted}`；`assistant/message` 标 `interrupted:true`
///   才允许后续接话。
///
/// **G12 不变量**：请求历史只能来自 [SessionLog.deriveModelMessages]（纯投影，
/// 不手工构造）；系统提示以 `system/message` 节点入 log；工具段属 header。
library;

import 'dart:async';
import 'dart:math' as math;

import '../llm/adapter.dart';
import '../session/session.dart';
import 'config.dart';
import 'failure.dart';
import '../context_eng/spill.dart';
import '../sandbox.dart';
import '../tool_definition.dart';
import '../tool_registry.dart';
import '../tools/guard.dart';
import '../tools/pipeline.dart';
import '../tools/tool_executor.dart';
import '../tool_activity.dart' show AgentToolActivityCallback, ToolActivity;
import '../hooks/hooks.dart' show AgentHooks, PreStepContext;
import '../skills/provider.dart' show SkillProvider;

/// 智能体相位（DSH `AgentPhase`）。
enum AgentPhase {
  idle,
  running,
}

/// turn 结束原因。
enum TurnEndReasonKind {
  completed,   // 模型给出最终回答
  error,       // 瀑布终态失败
  interrupted, // 用户取消
  maxSteps,    // 达到 maxStepsPerTurn 上限（仍在调用工具）
  blocked,     // 用户输入等待（Phase 4+）
  user,        // 用户主动结束
}

/// turn 结束原因（含详情）。
final class TurnEndReason {
  final TurnEndReasonKind kind;
  final String? detail;
  const TurnEndReason(this.kind, {this.detail});
}

/// 当前相位/计数状态（UI 可查询）。
final class AgentPhaseState {
  final AgentPhase phase;
  final int turn;
  final int step;
  const AgentPhaseState(this.phase, this.turn, this.step);
}

/// 主循环（ReactLoopAgent）。
class ReactLoopAgent {
  final SessionLog _session;
  final LlmAdapter _adapter;
  final ToolRegistry _registry;
  final AgentConfig _config;
  final String _modelId;
  final ProviderKind _providerKind;
  final String _systemPrompt;
  final String? _sessionPath;

  final AgentSandboxApprover? _sandboxApprover;

  /// Phase 5 hooks（agent/pre-step、tools/result）。
  final AgentHooks? _hooks;
  /// Phase 5 skills（注入 `<available_skills>`）。
  final SkillProvider? _skills;
  /// Phase 5 AGENTS.md guidance（注入 workspace:guidance section）。
  final String? _agentsMd;

  final ToolExecutor _executor;
  final LlmRetry _retry;
  final CompactionPlugin _compaction;
  /// 六段流水线（guard/pre/post/spill 集成）；Phase 2。
  late final ToolPipeline _pipeline;

  /// 工具执行活动回调（UI 展示用）：工具开始/成功/失败均触发，
  /// 对齐旧 `runAgent` 的 [AgentToolActivityCallback]。
  final AgentToolActivityCallback? _onToolActivity;

  AgentPhaseState _phase = AgentPhaseState(AgentPhase.idle, 0, 0);
  Completer<void>? _cancelCompleter;
  bool _cancelCompleted = false;

  /// 本轮最终答案：仅本轮 append 的末条 assistant/message 内容。
  /// **失败时为空串**——绝不穿透回历史里的旧 assistant（否则会把上一轮
  /// 回复冒充成本轮回复显示，看起来像"模型只会这一句"）。
  String _turnAnswer = '';
  String? _turnError;

  /// 上一步是否执行了工具调用（WP3b 分阶段预算档位依据；
  /// 每 step 开始重置，工具执行后置真）。
  bool _lastStepHadToolResults = false;

  String get lastTurnAnswer => _turnAnswer;
  String? get lastTurnError => _turnError;

  ReactLoopAgent({
    required SessionLog session,
    required LlmAdapter adapter,
    required ToolRegistry registry,
    AgentConfig? config,
    required String modelId,
    required ProviderKind providerKind,
    required String systemPrompt,
    String? sessionPath,
    AgentSandboxApprover? sandboxApprover,
    AgentToolActivityCallback? onToolActivity,
    LlmRetry? retry,
    CompactionPlugin? compaction,
    // ---- Phase 2：流水线扩展 ----
    List<ToolGuard>? guards,
    List<ToolPreExecuteListener>? preListeners,
    ToolPreExecuteApprover? preApprover,
    List<PostExecuteListener>? postListeners,
    SpillStore? spillStore,
    int? spillMaxInlineTokens,
    // ---- Phase 5：hooks ----
    AgentHooks? hooks,
    // ---- Phase 5：skills + AGENTS.md ----
    SkillProvider? skills,
    String? agentsMd,
  })  : _session = session,
        _adapter = adapter,
        _registry = registry,
        _config = config ?? AgentConfig(),
        _modelId = modelId,
        _providerKind = providerKind,
        _systemPrompt = systemPrompt,
        _sessionPath = sessionPath,
        _sandboxApprover = sandboxApprover,
        _onToolActivity = onToolActivity,
        _hooks = hooks,
        _skills = skills,
        _agentsMd = agentsMd,
        _executor = ToolExecutor(
          registry: registry,
          modelId: modelId,
          timeout: (config ?? AgentConfig()).toolTimeout,
          sandboxApprover: sandboxApprover,
        ),
        _retry = retry ??
            LlmRetry(
              maxRetries: providerKind == ProviderKind.local ? 3 : 5,
              initialDelay: const Duration(milliseconds: 500),
              maxDelay: const Duration(seconds: 10),
              // 空响应计入可重试档（两条路线都要，有界不循环）：
              // - API：思考型模型可能把 max_tokens 耗在推理上导致 content 为空
              //   （EMPTY_RESPONSE，设计文档 §5.4）；
              // - 本地：4B 模型常在思考中途直接 EOS（思考块未闭合被丢弃 → 空
              //   响应），重试一次通常能产出正式回答（2026-09-29 真机观察到，
              //   曾把 web_search 回合误判成"执行失败"）。
              retryEmptyResponse: true,
            ),
        _compaction = compaction ?? const NoCompactionPlugin() {
    // 系统提示以 system/message 节点入 log（turn 0 前一次性，幂等）。
    // Phase 5：注入 <available_skills>（skills）+ workspace:guidance（AGENTS.md）。
    String systemContent = _systemPrompt;
    if (_skills != null) {
      final skillText = _skills.availableSkillsText();
      if (skillText.trim().isNotEmpty) {
        systemContent += '\n\n$skillText';
      }
    }
    if (_agentsMd != null) {
      final am = _agentsMd.trim();
      if (am.isNotEmpty) {
        systemContent += '\n\n<workspace:guidance>\n$am\n</workspace:guidance>';
      }
    }

    _session.append(
      kEventSystemMessage,
      {'content': systemContent},
      source: const {'kind': 'system'},
    );
    // Phase 2：构建六段流水线（guard/pre/post/spill 集成）。
    _pipeline = ToolPipeline(
      executor: _executor,
      guards: guards ?? const <ToolGuard>[],
      preListeners: preListeners,
      preApprover: preApprover,
      postListeners: postListeners,
      spill: spillStore != null
          ? Spill(
              maxInlineTokens: spillMaxInlineTokens ?? 4096,
              store: spillStore,
            )
          : null,
      sessionLog: _session,
    );
  }

  AgentPhaseState get phaseState => _phase;

  bool get isRunning => _phase.phase == AgentPhase.running;

  /// 只读访问会话日志（诊断/测试/持久化用）。
  SessionLog get session => _session;

  /// 最终回答：log 中最后一条 model-visible assistant/message 的 content。
  /// 工具循环的每一步都追加一条 assistant/message；最终无工具调用那步的
  /// content 即最终回答。turn 无 assistant 消息（直接失败/中断）时返回空串。
  String get lastAssistantContent {
    final messages = _session.deriveModelMessages();
    for (var i = messages.length - 1; i >= 0; i--) {
      final m = messages[i];
      if (m['role'] == 'assistant') {
        final c = m['content'];
        if (c is String) return c;
      }
    }
    return '';
  }

  /// 启动一个 turn：用户输入 → 最终回答（或失败/中断）。
  Future<TurnEndReason> kick(
    String userMessage, {
    String? imagePath,
    List<String>? imagePaths,
    String? audioPath,
    StreamController<String>? onToken,
    StreamController<String>? onThinking,
    StreamController<String>? onStatus,
  }) async {
    if (_phase.phase != AgentPhase.idle) {
      throw StateError('agent is running; cancel() first');
    }
    _cancelCompleter = Completer<void>();
    _cancelCompleted = false;
    _turnAnswer = '';
    _turnError = null;
    _lastStepHadToolResults = false;
    // imagePath 入事件（store.dart importFromMessages 同款键名）：API 路线
    // 无状态，每个 step 重放历史时都要把图片重发；不入 log 则后续 step 丢图。
    final userSeq = _session.append(
      kEventUserMessage,
      {
        'content': userMessage,
        if (imagePath != null) 'imagePath': imagePath,
        // 多图（WP 多图上传）：本地引擎视觉仍只用 imagePath 首张；
        // API 路线由投影/adapter 全量发送。
        if (imagePaths != null && imagePaths.length > 1)
          'imagePaths': imagePaths,
      },
      source: const {'kind': 'user'},
    );
    final turn = _phase.turn + 1;
    _phase = AgentPhaseState(AgentPhase.running, turn, 0);
    _session.append(kEventTurnStart, {'turn': turn, 'userSeq': userSeq});

    var step = 0;
    var reason = TurnEndReasonKind.completed;
    bool turnDone = false;
    try {
      while (step < _config.maxStepsPerTurn && !turnDone) {
        // 用户取消可能在工具执行中途触发 —— 在 step 边界检查，尽快收 turn。
        if (_cancelCompleted) {
          reason = TurnEndReasonKind.interrupted;
          turnDone = true;
          break;
        }
        step++;
        // 新 step：重置本步重试预算（同一 step 内最多 maxRetries 次重试）。
        _retry.reset();
        _session.append(kEventStepStart, {'turn': turn, 'step': step});
        // WP3a：主动压缩前置——估算投影 token，超预算先裁剪，
        // 不等撞 nctx/服务端硬墙（被动压缩只救得了 CONTEXT_WINDOW_EXCEEDED）。
        if (_config.contextTokenBudget != null) {
          await _maybeCompactProactively(turn, step);
        }
        // Phase 5：agent/pre-step hook（可否决本 step；reject → turn 结束）。
        if (_hooks != null) {
          final preCtx = PreStepContext(
            turn: turn,
            step: step,
            modelId: _modelId,
            history: _session.deriveModelMessages(),
          );
          final proceed = await _hooks.shouldProceed(preCtx);
          if (!proceed) {
            reason = TurnEndReasonKind.error;
            turnDone = true;
            break;
          }
        }
        bool retryStep = true;
        while (retryStep) {
          try {
            final options =
                _buildRequest(turn, step, imagePath, audioPath,
                    onStatus: onStatus, imagePaths: imagePaths);
            final result = await _adapter.generate(
                options,
                onToken: onToken,
                onThinking: onThinking,
                cancel: _cancelCompleter,
            );
            _appendAssistant(turn, step, result);
            if (!result.hasToolCalls) {
              _turnAnswer = result.text; // 本轮最终回答（无工具那步）
              turnDone = true;
              break; // 无工具调用 → turn 完成（最终回答）
            }
            // 有工具 → 逐工具执行；成功后进入下一个 step。
            await _executeToolCalls(turn, step, result.toolCalls);
            _lastStepHadToolResults = true;
            if (_cancelCompleted) {
              reason = TurnEndReasonKind.interrupted;
              turnDone = true;
            }
            retryStep = false;
            break;
          } on LlmFailure catch (f) {
            // 失败 → 落 assistant/attempt（log-only，模型不可见）→ 跑瀑布。
            _appendAttempt(turn, step, f);
            _turnError = f.message;
            final decision = await _handleFailure(turn, step, f);
            if (decision.kind == FailureDecisionKind.retry) {
              retryStep = true; // 同一 step 重试（_retries 已累加）
            } else {
              if (decision.detail != null) {
                _turnError = '${f.message}（${decision.detail}）';
              }
              reason = TurnEndReasonKind.error;
              turnDone = true;
              break;
            }
          } on AgentCancelledException catch (_) {
            reason = TurnEndReasonKind.interrupted;
            turnDone = true;
            break;
          }
        }
        _session.append(kEventStepEnd, {'turn': turn, 'step': step});
      }
      if (!turnDone && step >= _config.maxStepsPerTurn) {
        reason = TurnEndReasonKind.maxSteps;
      }
    } finally {
      _session.append(kEventTurnEnd, {'turn': turn, 'reason': reason.name});
      _phase = AgentPhaseState(AgentPhase.idle, turn, step);
      final c = _cancelCompleter;
      if (c != null && !_cancelCompleted) {
        _cancelCompleted = true;
        c.complete();
      }
      _cancelCompleter = null;
    }
    return TurnEndReason(reason);
  }

  /// 取消当前 turn/step（DSH Part 14.6）。
  /// 完成取消 completer（adapter 内与流竞跑）并通知 adapter 停生成。
  Future<void> cancel([String? reason]) async {
    final c = _cancelCompleter;
    if (c != null && !_cancelCompleted) {
      _cancelCompleted = true;
      c.complete();
    }
    _adapter.cancel();
  }

  /// G12：构建请求 —— 历史只能来自 [deriveModelMessages]。
  GenerateOptions _buildRequest(
    int turn,
    int step,
    String? imagePath,
    String? audioPath, {
    StreamController<String>? onStatus,
    List<String>? imagePaths,
  }) {
    final messages = _session.deriveModelMessages();
    final tools = _registry.visibleFor(_modelId);
    // WP3b 分阶段预算：工具结果回填后的步更可能是"组织最终回答"，
    // 小模型写回答比写工具调用耗 token 多——用更大的 finalRound 预算
    // 降截断率；工具调用步维持紧预算防过度生成。API 档 finalRound=null
    // 恒用统一大预算。
    final maxTokens =
        (_lastStepHadToolResults && _config.maxTokensFinalRound != null)
            ? _config.maxTokensFinalRound!
            : _config.maxTokensPerRound;
    final options = GenerateOptions(
      provider: _providerKind,
      messages: messages,
      tools: tools,
      temperature: _config.temperature,
      maxTokens: maxTokens,
      modelId: _modelId,
      imagePath: imagePath,
      audioPath: audioPath,
      imagePaths: imagePaths,
      onStatus: onStatus,
    );
    // G12 不变量（开发期 assert）：独立重建比对，请求必须能纯投影自 log。
    assert(
      _validateRebuild(messages),
      'G12: 请求与独立重建不一致（turn=$turn, step=$step）',
    );
    return options;
  }

  /// 独立重建比对：从 log 再派生一次，逐条比对结构。
  bool _validateRebuild(List<Map<String, dynamic>> messages) {
    final rebuilt = _session.deriveModelMessages();
    if (rebuilt.length != messages.length) return false;
    final allowedRoles = {'system', 'user', 'assistant', 'tool'};
    for (var i = 0; i < rebuilt.length; i++) {
      final a = rebuilt[i];
      final b = messages[i];
      if (a['role'] != b['role']) return false;
      if (!(allowedRoles.contains(a['role']))) {
        return false;
      }
      if (a['content'] != b['content']) return false;
      final ac = a['tool_calls'] as List?;
      final bc = b['tool_calls'] as List?;
      if (ac?.length != bc?.length) return false;
      if (bc is List && bc.isNotEmpty) {
        for (final tc in bc) {
          if (tc is! Map<String, dynamic>) return false;
          final tcM = tc;
          final id = (tcM['id'] ?? tcM['call_id']) as String?;
          final name = (tcM['name'] ?? tcM['function_name']) as String?;
          if (id == null || name == null) return false;
        }
      }
      if (a['role'] == 'tool' && a['tool_call_id'] == null) return false;
    }
    return true;
  }

  void _appendAssistant(int turn, int step, LlmResult result) {
    final encodedCalls = <Map<String, dynamic>>[];
    for (final call in result.toolCalls) {
      encodedCalls.add({
        'call_id': call.id,
        'name': call.name,
        'arguments': call.arguments,
      });
    }
    _session.append(kEventAssistantMessage, {
      'content': result.text,
      'toolCalls': encodedCalls,
      'turn': turn,
      'step': step,
      // API 路线 token 用量（SSE 末块 usage；本地恒 null 不落键）。
      if (result.usage != null) 'usage': result.usage,
    });
  }

  /// WP3a 主动压缩：估算当前投影 token（content 字符数/4，与
  /// Spill.estimateTokens 同口径，tool_calls 每条粗估 40 字符），
  /// 超预算 → 走与 contextWindowExceeded 相同的确定性压缩路径
  /// （decide 内部自行追加 compaction/summary + 影子遮蔽）。
  /// 无可裁（decide 非 success）不致命——真超限仍由失败瀑布兜底。
  Future<void> _maybeCompactProactively(int turn, int step) async {
    final budget = _config.contextTokenBudget!;
    final messages = _session.deriveModelMessages();
    var chars = 0;
    for (final m in messages) {
      final c = m['content'];
      if (c is String) chars += c.length;
      final tc = m['tool_calls'];
      if (tc is List) chars += tc.length * 40;
    }
    final estTokens = chars ~/ 4;
    if (estTokens <= budget) return;
    final result = await _compaction.decide(
      ref: SessionRef(_session),
      turn: turn,
      step: step,
      reason: 'proactive: 估算约 $estTokens tok 超预算 $budget（主动前置压缩）',
    );
    assert(() {
      if (result.kind == CompactionResultKind.success) {
        // ignore: avoid_print
        print('[ReactLoopAgent] proactive compaction: ~$estTokens tok > $budget');
      }
      return true;
    }());
  }

  /// 失败 → 落 assistant/attempt（log-only，模型不可见）。
  void _appendAttempt(int turn, int step, LlmFailure f) {
    _session.append(kEventAssistantAttempt, {
      'turn': turn,
      'step': step,
      'code': f.code.name,
      'content': f.message,
    });
  }

  /// 失败瀑布（DSH Part 9.9）：compaction → llm-retry → giveUp。
  Future<FailureDecision> _handleFailure(
    int turn,
    int step,
    LlmFailure f,
  ) async {
    // 1. compaction（CONTEXT_WINDOW_EXCEEDED）：仅当已推进 generation 才 retry。
    //    压缩事件（compaction/summary）由 [DeterministicCompaction.decide]
    //    内部以 [SessionLog.replace] 追加（shadow 旧区 + 摘要），此处不再重复。
    if (f.isContextWindowExceeded) {
      final result = await _compaction.decide(
        ref: SessionRef(_session),
        turn: turn,
        step: step,
        reason: f.message,
      );
      if (result.kind == CompactionResultKind.success) {
        return const FailureDecision(FailureDecisionKind.retry);
      }
    }
    // 2. llm-retry（瞬态错误，有界 + 退避）。
    if (_retry.isRetryable(f)) {
      _session.append(kEventLlmRetry, {
        'turn': turn,
        'step': step,
        'retries': _retry.retries,
        'code': f.code.name,
        'message': f.message,
      });
      // WP1b：模型可见的失败原因注记（surface）。重试不再原样重发——
      // 下次请求投影出 [上次尝试失败:...] 提示，模型先反思再修正。
      // 截断 200 字防长报错撑上下文（deriveModelMessages 每 (turn,step)
      // 只留最新一条）。
      _session.append(kEventAssistantFailureNote, {
        'turn': turn,
        'step': step,
        'code': f.code.name,
        'content': f.message.length > 200
            ? '${f.message.substring(0, 200)}…'
            : f.message,
      });
      final delay = await _retry.maybeBackoff(f);
      if (delay == null) {
        return const FailureDecision(FailureDecisionKind.giveUp,
            detail: 'llm-retry exhausted');
      }
      return const FailureDecision(FailureDecisionKind.retry);
    }
    // 3. 默认 → 终态失败。
    return const FailureDecision(FailureDecisionKind.giveUp);
  }

  /// 执行一轮工具调用（tool/call → 执行 → tool/result）。
  ///
  /// Phase 2：走六段流水线 [ToolPipeline]；`allowParallelTools` 时按
  /// [config.maxParallel] 分批并发执行，否则串行。日志/ UI 始终按模型
  /// 调用顺序落 tool/call、tool/result（保持模型视角一致）。
  /// 单次工具调用安全包装（流水线异常不逃逸，转 ToolResult）。
  Future<ToolResult> _safeExecute(ToolCall call) async {
    try {
      return await _pipeline.execute(call, _modelId);
    } catch (e) {
      return ToolResult.error('工具 "${call.name}" 流水线异常: $e');
    }
  }

  Future<void> _executeToolCalls(
    int turn,
    int step,
    List<ToolCall> calls,
  ) async {
    if (calls.isEmpty) return;

    // ---- 1. 先记 tool/call + 触发 executing（全部先记，保模型顺序）----
    for (final call in calls) {
      _session.append(kEventToolCall, {
        'callId': call.id,
        'name': call.name,
        'turn': turn,
        'step': step,
        // Phase 6：UI 工具卡片展示参数（可选属性，向后兼容）。
        'arguments': call.arguments ?? const <String, dynamic>{},
      });
      if (_onToolActivity != null) {
        await _onToolActivity(ToolActivity(name: call.name, status: 'executing'));
      }
    }

    // ---- 2. 执行（并行 / 串行）----
    final results = await _runCalls(turn, step, calls);

    // ---- 3. 按模型顺序记 tool/result + 触发 done/failed ----
    for (var i = 0; i < calls.length; i++) {
      final call = calls[i];
      final result = results[i];
      _session.append(kEventToolResult, {
        'callId': call.id,
        'name': call.name,
        'turn': turn,
        'step': step,
        'content': result.content,
        'isError': result.isError,
      });
      // Phase 5：tools/result hook（read-only 同步通知）。
      _hooks?.notifyResult(call, result);
      if (_onToolActivity != null) {
        await _onToolActivity(
            ToolActivity(
                name: call.name,
                status: result.isError ? 'failed' : 'done',
                result: result.content));
      }
    }
  }

  /// 执行一批工具调用：`allowParallelTools` 则按 [AgentConfig.maxParallel]
  /// 分批并发（batch 内并发、batch 间串行，并发上限 = maxParallel），
  /// 否则串行。返回按 [calls] 顺序排列的 [ToolResult] 列表。
  Future<List<ToolResult>> _runCalls(
    int turn,
    int step,
    List<ToolCall> calls,
  ) async {
    final maxParallel = _config.allowParallelTools ? _config.maxParallel : 1;
    final results = <ToolResult>[];
    if (maxParallel <= 1 || calls.length <= 1) {
      // 串行。
      for (final call in calls) {
        results.add(await _safeExecute(call));
      }
      return results;
    }
    // 并行：每批 maxParallel 个并发，批间串行（并发上限 = maxParallel）。
    for (var i = 0; i < calls.length; i += maxParallel) {
      final end = math.min(i + maxParallel, calls.length);
      final batch = calls.sublist(i, end);
      final batchResults =
          await Future.wait(batch.map((call) => _safeExecute(call)));
      results.addAll(batchResults);
    }
    return results;
  }
}