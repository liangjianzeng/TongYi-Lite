/// 两阶段压缩（Phase 2）—— 对照 DSH Part 10.8。
///
/// 端侧默认**仅阶段 1（确定性裁剪）**：无需模型调用、免费、确定性。
/// 阶段 2（模型摘要）为可选开关，端侧默认关闭（tokens/s 低）。
///
/// 阶段 1 语义（DSH 7.4.4 裁剪）：
///   - 保留尾部 [keepRounds] 轮完整（user/assistant/tool 不动）；
///   - 遮蔽更早区域的旧 tool/result（连同其间旧消息）为一条摘要 user 消息；
///   - [replaceGeneration]++ 作前进性证明 → 允许 overflow retry。
library;

import 'package:flutter/foundation.dart' show debugPrint;

import '../session/event.dart';
import '../loop/failure.dart';

/// 两阶段压缩插件（替代 [NoCompactionPlugin] 的占位）。
///
/// 端侧：`useSummary=false`（默认）→ 只跑确定性裁剪；
/// `useSummary=true` → 裁剪后仍超预算则模型摘要（当前实现为占位：端侧默认关）。
final class DeterministicCompaction implements CompactionPlugin {
  /// 尾部保留的 user 轮数（默认 5）。
  final int keepRounds;

  /// 是否启用模型摘要（端侧默认关）。
  final bool useSummary;

  DeterministicCompaction({this.keepRounds = 5, this.useSummary = false});

  /// 判断当前会话是否超预算，并尝试压缩。
  /// [reason] 触发原因（`contextWindowExceeded` 时强制裁剪；其余情况也做主动裁剪）。
  Future<CompactionResult> decide({
    required SessionRef ref,
    required int turn,
    required int step,
    required String? reason,
  }) async {
    final log = ref.log;
    final events = log.rawEvents;

    // ---- 统计未遮蔽的 user 消息（surface）----
    final userSeqs = <int>[];
    for (final e in events) {
      if (e.type != kEventUserMessage) continue;
      if (log.isShadowed(e.seq)) continue;
      userSeqs.add(e.seq);
    }
    if (userSeqs.isEmpty) {
      return const CompactionResult(CompactionResultKind.failure);
    }

    // 保留尾部 keepRounds 轮；若 user 轮数 ≤ keepRounds，无旧内容可裁。
    if (userSeqs.length <= keepRounds) {
      return const CompactionResult(CompactionResultKind.success);
    }

    // 阈值 = 近期窗口的第一条 user 消息；其之前的 tool/result 均为"旧"。
    final threshold = userSeqs[userSeqs.length - keepRounds];

    // ---- 收集旧 tool/result（seq < threshold）----
    final oldToolResultSeqs = <int>[];
    for (final e in events) {
      if (e.type != kEventToolResult) continue;
      if (log.isShadowed(e.seq)) continue;
      if (e.seq < threshold) {
        oldToolResultSeqs.add(e.seq);
      }
    }
    if (oldToolResultSeqs.isEmpty) {
      // 旧轮无工具结果 → 无 token 大户，不压缩（避免无谓 advance）。
      return const CompactionResult(CompactionResultKind.success);
    }
    final first = oldToolResultSeqs.first;
    final last = oldToolResultSeqs.last;

    // ---- 摘要：对 [first..last] 内未遮蔽的旧 user 消息做 digest ----
    final digestParts = <String>[];
    for (final e in events) {
      if (e.seq < first || e.seq > last) continue;
      if (e.type != kEventUserMessage) continue;
      if (log.isShadowed(e.seq)) continue;
      final content = e.data['content'] as String? ?? '';
      final short = content.length > 120 ? content.substring(0, 120) : content;
      digestParts.add('用户：$short');
    }

    final summary = digestParts.isEmpty
        ? '[较早轮次的工具结果已省略，模型不可见原内容]'
        : '较早轮次摘要（旧工具结果已省略）：\n${digestParts.join('\n')}';

    // ---- 遮蔽 [first..last] 为一条摘要 ----
    final advance = log.replace(
      startSeq: first,
      endSeq: last,
      newContent: summary,
      summaryProvider: 'deterministic-prune',
      summaryModel: 'none',
    );
    if (advance > 0) {
      debugPrint(
          '[Compaction] 确定性裁剪：mask [${first}..${last}]，'
          'summary=${summary.length}chars，advance=$advance');
      return const CompactionResult(CompactionResultKind.success);
    }
    return const CompactionResult(CompactionResultKind.failure);
  }
}
