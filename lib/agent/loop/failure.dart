/// llm-retry 插件 + 失败瀑布决策（Phase 1）。
///
/// 对照 DSH Part 9.9：有界重试 + 指数退避。
/// 主循环失败瀑布：
///   模型失败 → 落 assistant/attempt → 跑瀑布：
///     1. compaction（CONTEXT_WINDOW_EXCEEDED）→ success 则 {kind:retry}
///     2. llm-retry（retryPolicy 允许该 code）→ 退避后 {kind:retry}
///     3. 默认 → 终态失败（turn/end {reason:error}）
library;

import 'dart:async';
import 'dart:math' as math;

import '../llm/adapter.dart';
import '../session/session.dart' show SessionLog;

/// 失败处理决策。
enum FailureDecisionKind {
  retry,     // 同一 step 重试（compaction 成功 / llm-retry 允许）
  giveUp,    // 终态失败（turn/end {reason:error}）
}

final class FailureDecision {
  final FailureDecisionKind kind;
  final String? detail;

  const FailureDecision(this.kind, {this.detail});
}

/// 失败处理插件（compaction seam，Phase 2 实现确定性裁剪/摘要）。
///
/// [decide] 返回 success 表示已推进 generation（可安全 retry）；
/// failure 表示无法推进（避免死循环）。
enum CompactionResultKind {
  success,
  failure,
}

final class CompactionResult {
  final CompactionResultKind kind;
  const CompactionResult(this.kind);
}

abstract class CompactionPlugin {
  /// 给定上下文溢出，尝试压缩。success 才允许 retry（前进性证明）。
  Future<CompactionResult> decide({
    required SessionRef ref,
    required int turn,
    required int step,
    required String? reason,
  });
}

/// Phase 1 占位：不压缩，返回 failure（Phase 2 用确定性裁剪/摘要替代）。
final class NoCompactionPlugin implements CompactionPlugin {
  const NoCompactionPlugin();

  @override
  Future<CompactionResult> decide({
    required SessionRef ref,
    required int turn,
    required int step,
    required String? reason,
  }) async {
    return const CompactionResult(CompactionResultKind.failure);
  }
}

/// 轻量会话引用（loop 内部用；避免循环依赖，直接持有 SessionLog）。
final class SessionRef {
  final SessionLog _log;
  const SessionRef(this._log);
  SessionLog get log => _log;
}

/// llm-retry 插件：有界 + 指数退避。
final class LlmRetry {
  final int maxRetries;
  final Duration initialDelay;
  final Duration maxDelay;
  final double backoffFactor;
  int _retries;

  LlmRetry({
    this.maxRetries = 3,
    this.initialDelay = const Duration(milliseconds: 500),
    this.maxDelay = const Duration(seconds: 10),
    this.backoffFactor = 2.0,
  }) :
    _retries = 0;

  void reset() => _retries = 0;
  int get retries => _retries;

  /// 该失败是否允许 llm-retry（compaction 不在此判定，由瀑布分开处理）。
  bool isRetryable(LlmFailure f) {
    // 无适配器 / 上下文溢出 → 不靠 retry 解决。
    if (f.code == LlmFailureCode.noAdapter) return false;
    if (f.code == LlmFailureCode.contextWindowExceeded) return false;
    if (f.code == LlmFailureCode.emptyResponse) return false;
    return _retries < maxRetries;
  }

  /// 记录一次重试并返回退避时长；首次无退避。
  /// 返回 null 表示不应重试（超出 maxRetries）。
  Future<Duration?> maybeBackoff(LlmFailure f) async {
    if (!isRetryable(f)) return null;
    _retries++;
    if (_retries == 1) return const Duration(milliseconds: 0);
    final rawMs = (initialDelay.inMilliseconds *
        math.pow(backoffFactor, _retries - 1)).round();
    final ms = math.min(rawMs, maxDelay.inMilliseconds);
    if (ms > 0) {
      await Future.delayed(Duration(milliseconds: ms));
    }
    return const Duration(milliseconds: 0);
  }
}