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

  const AgentUiState({
    this.running = false,
    this.turn = 0,
    this.step = 0,
    this.tools = const [],
    this.retryAttempt = 0,
    this.compacted = false,
    this.lastError,
  });

  bool get hasActivity =>
      running || tools.isNotEmpty || lastError != null || compacted;

  AgentUiState copyWith({
    bool? running,
    int? turn,
    int? step,
    List<ToolActivityUi>? tools,
    int? retryAttempt,
    bool? compacted,
    String? lastError,
    bool clearError = false,
  }) =>
      AgentUiState(
        running: running ?? this.running,
        turn: turn ?? this.turn,
        step: step ?? this.step,
        tools: tools ?? this.tools,
        retryAttempt: retryAttempt ?? this.retryAttempt,
        compacted: compacted ?? this.compacted,
        lastError: clearError ? null : (lastError ?? this.lastError),
      );
}

/// 事件 → 状态归约器。attach 一次订阅一个 [SessionLog]；
/// detach 只停订阅、保留末态（面板在 turn 结束后仍显示本轮活动）。
class AgentUiStateNotifier extends StateNotifier<AgentUiState> {
  AgentUiStateNotifier() : super(const AgentUiState());

  StreamSubscription<SessionEvent>? _sub;

  void attach(SessionLog log) {
    detach();
    state = const AgentUiState();
    _sub = log.events.listen(onEvent);
  }

  void detach() {
    _sub?.cancel();
    _sub = null;
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
        state = state.copyWith(
          step: (e.data['step'] as num?)?.toInt() ?? state.step);
        break;
      case kEventToolCall:
        final tools = [...state.tools, ToolActivityUi(
          callId: e.data['callId'] as String? ?? '',
          name: e.data['name'] as String? ?? '',
          arguments: (e.data['arguments'] as Map<String, dynamic>?) ??
              const {},
        )];
        state = state.copyWith(tools: tools);
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
        state = state.copyWith(
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
