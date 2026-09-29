/// Phase 6 UI 状态（设计文档 §12.2）—— 订阅 SessionLog 事件流的 reducer。
///
/// 数据流（§12.4）：ReactLoopAgent 追加事件 → SessionLog.events →
/// [AgentUiStateNotifier] 归约 → UI 组件（工具卡片/压缩横幅/重试指示/徽章）。
///
/// 端侧简化：状态是**本 turn 活动视图**（tool 卡片在下一 turn attach 时清空；
/// 历史回看仍走消息列表投影）。不改变 SessionLog 唯一真相源地位。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../agent/session/event.dart';
import '../agent/session/log.dart';

/// 工具卡片状态。
enum ToolUiStatus { executing, done, failed }

/// 单个工具活动（tool/call + tool/result 归并）。
final class ToolActivityUi {
  final String callId;
  final String name;
  final Map<String, dynamic> arguments;
  ToolUiStatus status;
  String? result;
  bool isError;

  ToolActivityUi({
    required this.callId,
    required this.name,
    required this.arguments,
    this.status = ToolUiStatus.executing,
    this.result,
    this.isError = false,
  });
}

/// 时间线标记：本 turn 内某个元素何时出现（真实执行次序）。
/// 归约器按事件到达顺序追加；AgentTurnBlock 依此交错渲染思考存档与工具卡
/// （用户反馈：工具调用和思考的位置经常不按执行顺序呈现）。
sealed class UiTimelineMarker {
  const UiTimelineMarker();
}

/// 第 [index] 个思考存档（对应 [AgentUiState.thinkingHistory]）。
final class UiTimelineThinking extends UiTimelineMarker {
  final int index;
  const UiTimelineThinking(this.index);
}

/// 第 [index] 个工具卡（对应 [AgentUiState.tools]）。
final class UiTimelineTool extends UiTimelineMarker {
  final int index;
  const UiTimelineTool(this.index);
}

/// UI 状态快照（§12.2 AgentState 的端侧形态）。
final class AgentUiState {
  final bool running;
  final int turn;
  final int step;
  final List<ToolActivityUi> tools;

  /// >0：正在 llm-retry（第 N 次）。
  final int retryAttempt;

  /// 本 turn 发生过 compaction/summary（CompactionBanner）。
  final bool compacted;

  /// turn/end 的失败原因（error 时展示；completed 清空）。
  final String? lastError;

  /// 本 turn 思考流快照（adapter onThinking 推送的全量文本；
  /// 每个新 turn attach 时清空）。空串 = 本轮无思考输出。
  final String thinking;

  /// 已完成步骤的思考块存档：step 边界（kEventStepStart/turn end）把当时的
  /// thinking 快照落档并清空流式缓冲——工作流里每一步的思考都以折叠条
  /// 保留，下一步思考另起新卡流式（用户要求：过程可回看）。
  final List<String> thinkingHistory;

  /// 与 [thinkingHistory] 平行的各步思考耗时（null = 未知/历史无数据），
  /// 供存档卡显示「思考 - 持续了X秒」（用户定案：避免空洞的"思考 1/2/3"）。
  final List<Duration?> thinkingDurations;

  /// 执行顺序时间线：思考落档/工具卡加入的真实次序（live 回合渲染依据）。
  final List<UiTimelineMarker> timeline;

  const AgentUiState({
    this.running = false,
    this.turn = 0,
    this.step = 0,
    this.tools = const [],
    this.retryAttempt = 0,
    this.compacted = false,
    this.lastError,
    this.thinking = '',
    this.thinkingHistory = const [],
    this.thinkingDurations = const [],
    this.timeline = const [],
  });

  bool get hasActivity =>
      running || tools.isNotEmpty || lastError != null || compacted;

  bool get hasThinking => thinking.isNotEmpty;

  AgentUiState copyWith({
    bool? running,
    int? turn,
    int? step,
    List<ToolActivityUi>? tools,
    int? retryAttempt,
    bool? compacted,
    String? lastError,
    bool clearError = false,
    String? thinking,
    List<String>? thinkingHistory,
    List<Duration?>? thinkingDurations,
    List<UiTimelineMarker>? timeline,
  }) =>
      AgentUiState(
        running: running ?? this.running,
        turn: turn ?? this.turn,
        step: step ?? this.step,
        tools: tools ?? this.tools,
        retryAttempt: retryAttempt ?? this.retryAttempt,
        compacted: compacted ?? this.compacted,
        lastError: clearError ? null : (lastError ?? this.lastError),
        thinking: thinking ?? this.thinking,
        thinkingHistory: thinkingHistory ?? this.thinkingHistory,
        thinkingDurations: thinkingDurations ?? this.thinkingDurations,
        timeline: timeline ?? this.timeline,
      );
}

/// 事件 → 状态归约器。attach 一次订阅一个 [SessionLog]；
/// detach 只停订阅、保留末态（面板在 turn 结束后仍显示本轮活动）。
class AgentUiStateNotifier extends StateNotifier<AgentUiState> {
  AgentUiStateNotifier() : super(const AgentUiState());

  StreamSubscription<SessionEvent>? _sub;

  /// 当前思考块的起点（首个非空 thinking 推送时记录；落档后复位）。
  DateTime? _thinkingStart;

  /// 思考流推送（adapter 全量快照）。节流由调用方（chat_provider）负责，
  /// 这里直接落 state——事件频率低（流 delta 聚合后）。
  void setThinking(String text) {
    if (state.thinking == text) return;
    _thinkingStart ??= (text.isNotEmpty) ? DateTime.now() : null;
    state = state.copyWith(thinking: text);
  }

  void attach(SessionLog log) {
    detach();
    state = const AgentUiState();
    _thinkingStart = null;
    _sub = log.events.listen(onEvent);
  }

  void detach() {
    _sub?.cancel();
    _sub = null;
  }

  /// 把当前流式思考快照落档（step 边界/turn 结束时调用），清空流式缓冲。
  /// 落档时顺带记录耗时（起点未知 → null），供存档卡显示"持续了X秒"；
  /// 并追加时间线标记（思考存档在**此刻**进入渲染序列，而不是一律排最前）。
  AgentUiState _finalizeThinking(AgentUiState s) {
    if (s.thinking.isEmpty) return s;
    Duration? dur;
    if (_thinkingStart != null) {
      dur = DateTime.now().difference(_thinkingStart!);
      _thinkingStart = null;
    }
    return s.copyWith(
      thinkingHistory: [...s.thinkingHistory, s.thinking],
      thinkingDurations: [...s.thinkingDurations, dur],
      timeline: [...s.timeline, UiTimelineThinking(s.thinkingHistory.length)],
      thinking: '',
    );
  }

  /// 事件归约（纯函数式：只产新 state，不改 log）。测试可直接调用。
  void onEvent(SessionEvent e) {
    switch (e.type) {
      case kEventTurnStart:
        state = AgentUiState(
          running: true,
          turn: (e.data['turn'] as num?)?.toInt() ?? state.turn,
        );
        break;
      case kEventStepStart:
        // step 边界：上一步的思考已结束 → 落档折叠，新 step 另起思考卡。
        state = _finalizeThinking(state).copyWith(
          step: (e.data['step'] as num?)?.toInt() ?? state.step);
        break;
      case kEventToolCall:
        final tools = [...state.tools, ToolActivityUi(
          callId: e.data['callId'] as String? ?? '',
          name: e.data['name'] as String? ?? '',
          arguments: (e.data['arguments'] as Map<String, dynamic>?) ??
              const {},
        )];
        state = state.copyWith(
          tools: tools,
          timeline: [...state.timeline, UiTimelineTool(tools.length - 1)],
        );
        break;
      case kEventToolResult:
        final callId = e.data['callId'] as String? ?? '';
        final isError = e.data['isError'] as bool? ?? false;
        final content = e.data['content'] as String? ?? '';
        final tools = [...state.tools];
        for (var i = tools.length - 1; i >= 0; i--) {
          // 从后向前找同 callId 的 executing 卡片（并行调用同名的场合）。
          if (tools[i].callId == callId) {
            tools[i]
              ..status = isError ? ToolUiStatus.failed : ToolUiStatus.done
              ..result = content
              ..isError = isError;
            break;
          }
        }
        state = state.copyWith(tools: tools);
        break;
      case kEventLlmRetry:
      case kEventLlmRetryStarted:
        state = state.copyWith(
            retryAttempt: (e.data['retries'] as num?)?.toInt() ??
                state.retryAttempt + 1);
        break;
      case kEventCompactionSummary:
        state = state.copyWith(compacted: true);
        break;
      case kEventTurnEnd:
        final kind = _reasonKind(e.data['reason']);
        state = _finalizeThinking(state).copyWith(
          running: false,
          retryAttempt: 0,
          lastError: kind == 'error' ? '本轮执行失败（见推理日志）' : null,
          clearError: kind != 'error',
        );
        break;
      default:
        break;
    }
  }

  /// reason 双形态兼容：主循环写 String（completed/...），崩溃修复写
  /// Map（{kind: ...}）。
  static String _reasonKind(Object? reason) {
    if (reason is String) return reason;
    if (reason is Map) return reason['kind'] as String? ?? '';
    return '';
  }
}

final agentUiStateProvider =
    StateNotifierProvider<AgentUiStateNotifier, AgentUiState>(
        (ref) => AgentUiStateNotifier());
