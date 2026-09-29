/// 智能体内嵌工作流 UI（主流智能体形态，§12.3 改造）。
///
/// 状态提示不再分散在 AppBar 徽章 / 输入区面板，而是对话内按回合
/// 一步步向下渲染：[思考中…] → [🔧 工具卡片 ×N（逐步）] → [最终回答]。
///
/// - 运行中回合：步骤取 [AgentUiState] 事件流实时数据（参数/结果/状态
///   实时更新）；
/// - 历史回合：步骤解析自存储的 🔧 活动消息（[parseToolActivity]），
///   历史对话可回看每次工具调用。
library;

import 'dart:convert';

import 'package:flutter/material.dart';

import '../models/chat_message.dart';
import '../providers/agent_state_provider.dart';
import 'chat_bubble.dart';

// ---------------------------------------------------------------------------
// 消息分组
// ---------------------------------------------------------------------------

/// 对话展示单元：普通消息保持原样；智能体回合重排为
/// [工具步骤… → 最终回答] 的 [AgentTurnBlock]（内嵌工作流）。
sealed class RenderUnit {
  const RenderUnit();
}

/// 单条用户/普通消息。
class UserUnit extends RenderUnit {
  final ChatMessage message;
  const UserUnit(this.message);
}

/// 一个智能体回合：[tools, answer] 的重排展示单元。
class TurnUnit extends RenderUnit {
  /// 存储顺序中的 🔧 活动消息（新模式 [user, ans, t1..tk]；
  /// 旧模式 [user, t1..tk, ans]）——展示时全部排到回答之前。
  final List<ChatMessage> tools;

  /// 本回合的 assistant 回答（可能为空：中断且未产出答案）。
  final ChatMessage? answer;

  const TurnUnit(this.tools, this.answer);
}

/// 把原始消息流按回合重排为展示单元。
///
/// 规则：user 消息是分界；user 之后的非 🔧 assistant 消息 = 回答；
/// 🔧 前缀的 assistant 消息 = 工具步骤。无论存储顺序如何，都重排为
/// [工具… → 回答]，与 [AgentTurnBlock] 的渲染顺序一致。
List<RenderUnit> groupMessages(List<ChatMessage> messages) {
  final units = <RenderUnit>[];
  final pendingTools = <ChatMessage>[];
  ChatMessage? pendingAnswer;

  void flush() {
    if (pendingTools.isEmpty && pendingAnswer == null) return;
    // 必须拷贝：TurnUnit 保存的列表引用若直接复用 pendingTools，
    // 随后的 pendingTools.clear() 会把已入队的 tools 一并清空。
    units.add(TurnUnit([...pendingTools], pendingAnswer));
    pendingTools.clear();
    pendingAnswer = null;
  }

  for (final m in messages) {
    if (m.role == MessageRole.user) {
      flush();
      units.add(UserUnit(m));
    } else if (_isToolActivityMessage(m)) {
      pendingTools.add(m);
    } else {
      pendingAnswer = m;
    }
  }
  flush();
  return units;
}

/// 🔧 前缀的 assistant 消息 = 工具活动消息（仅 UI 展示，不入模型上下文）。
bool _isToolActivityMessage(ChatMessage msg) =>
    msg.role == MessageRole.assistant && msg.content.startsWith('🔧');

/// 把 🔧 活动消息内容解析为卡片数据（历史回合步骤回看）。
///
/// 存储约定（新主循环会话层与旧 runAgent 会话共用模板）：
/// - executing：`🔧 正在调用 {name}…`（旧模式多工具为 `🔧 正在调用：A、B…`）；
/// - done/failed：`🔧 {name} ✓/⚠️{summary}`。
ToolActivityUi? parseToolActivity(ChatMessage msg) {
  final c = msg.content.trim();
  if (!c.startsWith('🔧')) return null;
  // 🔧 后通常跟一个空格（"🔧 正在调用 …"）；trim 掉，避免
  // body.startsWith('正在调用') / indexOf 被前置空格干扰。
  final body = c.substring('🔧'.length).trim();

  if (body.startsWith('正在调用')) {
    final name = body
        .substring('正在调用'.length)
        .trim()
        .replaceAll(RegExp(r'^[:：]+'), '')
        .replaceAll(RegExp(r'\…+$'), '')
        .trim();
    return ToolActivityUi(
      callId: '',
      name: name,
      arguments: const {},
      status: ToolUiStatus.executing,
    );
  }

  final done = body.indexOf('✓');
  final fail = body.indexOf('⚠️');
  int idx;
  bool failed;
  if (done != -1 && (fail == -1 || done < fail)) {
    idx = done;
    failed = false;
  } else if (fail != -1) {
    idx = fail;
    failed = true;
  } else {
    return null;
  }
  final name = body.substring(0, idx).trim();
  final summary = body
      .substring(idx + (failed ? '⚠️'.length : '✓'.length))
      .trim();
  return ToolActivityUi(
    callId: '',
    name: name,
    arguments: const {},
    status: failed ? ToolUiStatus.failed : ToolUiStatus.done,
    result: summary.isEmpty ? null : summary,
    isError: failed,
  );
}

/// 🔧 活动消息列表 → 卡片数据（跳过无法解析的异常消息）。
List<ToolActivityUi> parsedToolActivities(List<ChatMessage> tools) =>
    tools.map(parseToolActivity).whereType<ToolActivityUi>().toList();

// ---------------------------------------------------------------------------
// 组件
// ---------------------------------------------------------------------------

/// 「思考中…」占位行（与 ChatBubble 空占位同风格；置于工具卡片之后，
/// 表示模型在处理下一个步骤/最终答案）。
class ThinkingIndicator extends StatelessWidget {
  const ThinkingIndicator({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
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
            '思考中…',
            style: const TextStyle(fontSize: 13, fontStyle: FontStyle.italic),
          ),
        ],
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

/// 智能体回合内嵌工作流块（对话内一步步向下渲染）：
///
/// [重试/压缩横幅（仅运行中回合）]
/// → [🔧 工具卡片 ×N（逐步）]
/// → [思考中…（运行中且尚无答案文本）]
/// → [最终回答 ChatBubble（showAvatar:false，保留统计/复制）]。
class AgentTurnBlock extends StatelessWidget {
  final List<ToolActivityUi> steps;
  final ChatMessage? answer;
  final AgentUiState ui;
  /// 是否当前运行中回合（决定横幅/思考行/流式点是否显示）。
  final bool isLive;

  const AgentTurnBlock({
    super.key,
    required this.steps,
    required this.answer,
    required this.ui,
    required this.isLive,
  });

  /// 答案占位中：live 智能体回合、答案还没有任何文本。
  bool get _answerPending =>
      isLive && ui.running && (answer == null || answer!.content.trim().isEmpty);

  /// 思考行只在「模型确实在转、答案未开始、且没有工具正在执行」时显示。
  /// 工具执行中不显示——工具卡片自带「执行中…」状态，再叠一个就是
  /// 双转圈（蠢）；重试中已有 RetryIndicator 转圈，同理不再叠加。
  /// 全程保证界面上同时最多一个 spinner。
  bool get _thinking =>
      _answerPending &&
      ui.retryAttempt == 0 &&
      !steps.any((s) => s.status == ToolUiStatus.executing);

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 横幅/思考行必须属于「正在跑的这一个回合」：retry/compacted 残留
        // 状态要等下一次 attach 才清，加 ui.running 防串台到普通聊天。
        if (isLive && ui.running && ui.retryAttempt > 0)
          RetryIndicator(attempt: ui.retryAttempt),
        if (isLive && ui.running && ui.compacted) const CompactionBanner(),
        ...steps.map((s) => ToolActivityCard(activity: s)),
        if (_thinking) const ThinkingIndicator(),
        // 智能体回合里答案还是空占位 → 不渲染回答气泡：ChatBubble 自带的
        // 「思考中…」占位会和上面的思考行/工具卡转圈叠成第二个 spinner。
        if (answer != null && !_answerPending)
          ChatBubble(
            role: 'assistant',
            content: answer!.content,
            timestamp: answer!.timestamp,
            isStreaming: isLive && answer!.isStreaming,
            imagePath: answer!.imagePath,
            audioPath: answer!.audioPath,
            inferenceStats: answer!.inferenceStats,
            showAvatar: false,
          ),
      ],
    );
  }
}
