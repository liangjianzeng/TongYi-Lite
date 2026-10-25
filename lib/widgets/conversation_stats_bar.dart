// ============================================================
// 会话数据统计条（2026-10-25）：DSH StatsLine 形态的 Flutter 对应物。
//
// 参考 deepseek-harness ui-conversation/chat/StatsLine.tsx：
// 单行 12px 居中读数，组间「|」分隔，无数据的组整组掉线，超长省略号。
// 组态（本 app 数据源可得的部分）：
//   {N 轮 · M 步} | {LLM {dur} · {rate} tok/s} | ≈{tok} tok | 上下文 {n}%
// DSH 的 缓存命中 / 首token平均 组依赖服务端 usage 投影，本 app 无对应
// 数据源（本地路线无逐 token 计数出口），不强造假数字。
//
// 「封装」：独立 widget，home_screen 只喂 conversationId + 消息流，
// 折算口径（轮/步/token 估算/LLM 耗时聚合）全部收在本文件内。
// ============================================================

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../agent/observability/turn_meter.dart' show estimateTokens;
import '../models/chat_message.dart';
import '../providers/context_usage_provider.dart' show contextUsageProvider;

/// 会话统计条。始终占住手势条避让高度（键盘弹出时由宿主整体收起），
/// 没有任何可显示的组时内容为空但 padding 保留——composer 不贴死屏幕底。
class ConversationStatsBar extends ConsumerWidget {
  final String conversationId;
  final List<ChatMessage> messages;

  const ConversationStatsBar({
    super.key,
    required this.conversationId,
    required this.messages,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final groupStyle = TextStyle(
      fontSize: 12,
      height: 1.4,
      color: theme.colorScheme.onSurfaceVariant,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final sepStyle = TextStyle(
        fontSize: 12, color: theme.colorScheme.outlineVariant);

    // ---- 折算 ----
    var rounds = 0;
    var steps = 0;
    var tokens = 0;
    var llmMs = 0;
    var genTok = 0;
    for (final m in messages) {
      final c = m.content;
      if (c.startsWith('🔧')) {
        steps++;
        continue;
      }
      if (c.startsWith('💭')) continue;
      if (m.role == MessageRole.user) rounds++;
      tokens += estimateTokens(c);
      final s = m.inferenceStats;
      if (s != null && s.totalMs > 0) {
        llmMs += s.totalMs;
        genTok += (s.tokPerSec * s.totalMs / 1000).round();
      }
    }

    final groups = <Widget>[];
    Widget group(String text) => Flexible(child: Text(text, style: groupStyle, maxLines: 1, overflow: TextOverflow.ellipsis));
    if (rounds > 0 || steps > 0) groups.add(group('$rounds 轮 · $steps 步'));
    if (llmMs > 0) {
      final dur = _formatDuration(llmMs);
      final rate = genTok / (llmMs / 1000);
      groups.add(group('LLM $dur · ${rate.toStringAsFixed(1)} tok/s'));
    }
    if (tokens > 0) groups.add(group('≈${_formatTokens(tokens)} tok'));
    final fraction =
        ref.watch(contextUsageProvider)[conversationId]?.fraction;
    if (fraction != null) {
      groups.add(group('上下文 ${(fraction * 100).round()}%'));
    }

    return Padding(
      // 手势条避让收口：常驻，与内容有无无关（composer 不贴死屏幕底）。
      padding: EdgeInsets.fromLTRB(
          16, 0, 16, math.max(MediaQuery.of(context).padding.bottom, 16) + 2),
      child: groups.isEmpty
          ? const SizedBox.shrink()
          : Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < groups.length; i++) ...[
                  if (i > 0)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Text('|', style: sepStyle),
                    ),
                  groups[i],
                ],
              ],
            ),
    );
  }

  /// DSH 口径：1 分钟内 45.2s，之后 2m42s。
  static String _formatDuration(int ms) {
    final s = ms / 1000;
    if (s < 60) return '${(s * 10).round() / 10}s';
    final whole = s.round();
    return '${whole ~/ 60}m${whole % 60}s';
  }

  /// DSH 口径：517 / 12.2K / 517K / 1.2M（三位以下一位小数）。
  static String _scaled(double v) {
    if (v >= 100) return v.round().toString();
    final r = (v * 10).round() / 10;
    return r == r.roundToDouble() ? r.round().toString() : r.toStringAsFixed(1);
  }

  static String _formatTokens(int n) {
    if (n < 1000) return '$n';
    if (n < 1000000) return '${_scaled(n / 1000)}K';
    return '${_scaled(n / 1000000)}M';
  }
}
