/// Phase 6 UI 组件（设计文档 §12.3）：工具活动卡片 / 压缩横幅 / 重试指示 /
/// 状态徽章 + 组合面板 [AgentActivityPanel]。
///
/// 事件来源：SessionLog 事件 → AgentUiStateNotifier（§12.4 数据流）。
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/agent_state_provider.dart';

/// AgentStatusBadge —— phase（运行中/空闲）。放 AppBar。
class AgentStatusBadge extends ConsumerWidget {
  const AgentStatusBadge({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(agentUiStateProvider);
    final theme = Theme.of(context);
    if (!s.hasActivity) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Chip(
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        backgroundColor: s.running
            ? theme.colorScheme.primaryContainer
            : (s.lastError != null
                ? theme.colorScheme.errorContainer
                : theme.colorScheme.surfaceContainerHighest),
        label: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (s.running)
              const SizedBox(
                  width: 10,
                  height: 10,
                  child: CircularProgressIndicator(strokeWidth: 1.5))
            else
              Icon(
                s.lastError != null ? Icons.error_outline : Icons.check,
                size: 12,
              ),
            const SizedBox(width: 4),
            Text(
              s.running ? '运行中' : (s.lastError != null ? '出错' : '空闲'),
              style: const TextStyle(fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}

/// RetryIndicator —— "重试中…（N）"（llm/retry 事件）。
class RetryIndicator extends StatelessWidget {
  final int attempt;
  const RetryIndicator({super.key, required this.attempt});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(
                strokeWidth: 2, color: theme.colorScheme.tertiary),
          ),
          const SizedBox(width: 8),
          Text(
            '重试中…（$attempt）',
            style: TextStyle(
              fontSize: 12,
              color: theme.colorScheme.onSurfaceVariant,
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
      ),
    );
  }
}

/// CompactionBanner —— "上下文已压缩"（compaction/summary 事件）。
class CompactionBanner extends StatelessWidget {
  const CompactionBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.compress, size: 13,
              color: theme.colorScheme.onSecondaryContainer),
          const SizedBox(width: 6),
          Text(
            '上下文已压缩',
            style: TextStyle(
                fontSize: 12, color: theme.colorScheme.onSecondaryContainer),
          ),
        ],
      ),
    );
  }
}

/// ToolActivityCard —— tool/call + tool/result 结构化卡片。
///
/// 折叠态：状态图标 + 工具名 + 单行参数摘要；展开态：完整参数 JSON + 结果。
class ToolActivityCard extends StatelessWidget {
  final ToolActivityUi activity;
  const ToolActivityCard({super.key, required this.activity});

  String get _argsSummary {
    if (activity.arguments.isEmpty) return '';
    try {
      final s = jsonEncode(activity.arguments);
      return s.length > 60 ? '${s.substring(0, 60)}…' : s;
    } catch (_) {
      return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (IconData icon, Color color, bool busy) = switch (activity.status) {
      ToolUiStatus.executing => (
          Icons.hourglass_top,
          theme.colorScheme.tertiary,
          false
        ),
      ToolUiStatus.done => (Icons.check_circle, Colors.green.shade600, false),
      ToolUiStatus.failed =>
        (Icons.error, theme.colorScheme.error, false),
    };
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
      child: ExpansionTile(
        dense: true,
        shape: const Border(),
        tilePadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
        childrenPadding:
            const EdgeInsets.fromLTRB(12, 0, 12, 10),
        leading: busy
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2))
            : Icon(icon, size: 16, color: color),
        title: Row(
          children: [
            Flexible(
              child: Text(
                '🔧 ${activity.name}',
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13),
              ),
            ),
            if (activity.status == ToolUiStatus.executing) ...[
              const SizedBox(width: 6),
              Text('执行中…',
                  style: TextStyle(
                      fontSize: 11,
                      color: theme.colorScheme.onSurfaceVariant,
                      fontStyle: FontStyle.italic)),
            ],
          ],
        ),
        subtitle: _argsSummary.isEmpty
            ? null
            : Text(_argsSummary,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 11, color: theme.colorScheme.outline)),
        children: [
          if (activity.arguments.isNotEmpty)
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '参数：\n${_prettyArgs()}',
                style: const TextStyle(
                    fontSize: 11, fontFamily: 'monospace'),
              ),
            ),
          if (activity.result != null && activity.result!.isNotEmpty)
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                activity.result!.length > 800
                    ? '${activity.result!.substring(0, 800)}…'
                    : activity.result!,
                style: TextStyle(
                  fontSize: 11,
                  fontFamily: 'monospace',
                  color: activity.isError
                      ? theme.colorScheme.error
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }

  String _prettyArgs() {
    try {
      return const JsonEncoder.withIndent('  ').convert(activity.arguments);
    } catch (_) {
      return activity.arguments.toString();
    }
  }
}

/// AgentActivityPanel —— 输入框上方的活动面板（§12.4 末段）。
///
/// 是否显示（useNewAgentMode）由调用侧门控；本组件只渲染状态。
class AgentActivityPanel extends ConsumerWidget {
  const AgentActivityPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(agentUiStateProvider);
    if (!s.hasActivity) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (s.compacted) const CompactionBanner(),
        if (s.retryAttempt > 0) RetryIndicator(attempt: s.retryAttempt),
        if (s.lastError != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.error_outline,
                    size: 14, color: Theme.of(context).colorScheme.error),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    s.lastError!,
                    style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.error),
                  ),
                ),
              ],
            ),
          ),
        if (s.tools.isNotEmpty)
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 180),
            child: ListView.builder(
              shrinkWrap: true,
              reverse: false,
              padding: const EdgeInsets.symmetric(vertical: 2),
              itemCount: s.tools.length,
              itemBuilder: (_, i) =>
                  ToolActivityCard(activity: s.tools[i]),
            ),
          ),
        if (s.running && s.tools.isEmpty && s.retryAttempt == 0)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 8),
                Text(
                  '智能体运行中 · turn ${s.turn} / step ${s.step}',
                  style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        const SizedBox(height: 2),
      ],
    );
  }
}
