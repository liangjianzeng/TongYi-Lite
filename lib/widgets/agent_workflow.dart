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
import 'package:flutter/scheduler.dart' show Ticker;

import '../models/chat_message.dart';
import '../providers/agent_state_provider.dart';
import '../services/device_files_service.dart';
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

/// 「执行中…」占位行（与 ChatBubble 空占位同风格；置于工具卡片之后，
/// 表示智能体正在推进任务下一步/最终答案）。
///
/// 用户定案：这里不是"思考"（真思考走 ThinkingStreamCard），只是任务
/// 执行中的状态过渡，标签必须写「执行中」，否则会误导成模型在空想。
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
            '执行中…',
            style: const TextStyle(fontSize: 13, fontStyle: FontStyle.italic),
          ),
        ],
      ),
    );
  }
}

/// _ToolGenIndicator —— 工具调用参数生成期进度（WP5）。
///
/// 模型正在流式输出工具调用块（如 write_file 的大段 HTML 报告参数）：
/// 可见流与思考流都是空的，此前 UI 只能干转圈"思考中"。这里显示
/// 「🔧 正在生成工具调用参数（已 N 字）」+ 开头预览，让用户看到在做什么。
class _ToolGenIndicator extends StatelessWidget {
  final int chars;
  final String preview;
  const _ToolGenIndicator({required this.chars, required this.preview});

  String get _charsLabel => chars >= 1000
      ? '${(chars / 1000).toStringAsFixed(1)}k 字'
      : '$chars 字';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
          Expanded(
            child: Text(
              preview.isEmpty
                  ? '🔧 正在生成工具调用参数（已 $_charsLabel）…'
                  : '🔧 正在生成工具调用参数（已 $_charsLabel）：$preview',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontStyle: FontStyle.italic,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
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

/// _ThinkingBlockCard —— 已完成步骤的思考存档（折叠条）。
///
/// 与流式卡的区别：无 spinner、默认折叠、不跟随滚动；点按头部展开静态
/// 文本回看。第 N 步思考按序标注。
class _ThinkingBlockCard extends StatefulWidget {
  final String text;
  final int index;
  final Duration? duration;
  const _ThinkingBlockCard(
      {required this.text, required this.index, this.duration});

  @override
  State<_ThinkingBlockCard> createState() => _ThinkingBlockCardState();
}

class _ThinkingBlockCardState extends State<_ThinkingBlockCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tail = widget.text.length > 2000
        ? '…${widget.text.substring(widget.text.length - 2000)}'
        : widget.text;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 1),
      child: Container(
        decoration: BoxDecoration(
          color:
              theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.psychology,
                        size: 14,
                        color: theme.colorScheme.tertiary
                            .withValues(alpha: 0.7)),
                    const SizedBox(width: 6),
                    Text(
                      widget.duration == null
                          ? '思考 ${widget.index}'
                          : '思考 ${widget.index} - 持续了${_fmtDur(widget.duration)}',
                      style: TextStyle(
                          fontSize: 12,
                          color:
                              theme.colorScheme.tertiary.withValues(alpha: 0.8)),
                    ),
                    const Spacer(),
                    Icon(
                      _expanded ? Icons.expand_less : Icons.expand_more,
                      size: 15,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ),
            if (_expanded)
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 5),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 150),
                  child: SingleChildScrollView(
                    child: Text(
                      tail,
                      style: TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// ToolActivityCard —— tool/call + tool/result 结构化卡片。
///
/// 折叠态压到**最低可见文字高度**（单行 ~22px）：状态图标 + 工具名 +
/// 参数摘要；点按行内展开完整参数 JSON + 结果。
class ToolActivityCard extends StatefulWidget {
  final ToolActivityUi activity;
  const ToolActivityCard({super.key, required this.activity});

  @override
  State<ToolActivityCard> createState() => _ToolActivityCardState();
}

class _ToolActivityCardState extends State<ToolActivityCard>
    with SingleTickerProviderStateMixin {
  bool _expanded = false;

  /// 执行起点（首次以 executing 状态入树时记录）；null = 未知（历史回合）。
  DateTime? _execStart;
  Duration? _total;

  /// 秒级刷新用 Ticker（flutter test 下被 muted，无 pending-timer 问题；
  /// 真机上每帧回调，只在秒数变化时 setState）。
  Ticker? _ticker;
  int _lastSec = -1;

  String get _argsSummary {
    if (widget.activity.arguments.isEmpty) return '';
    try {
      final s = jsonEncode(widget.activity.arguments);
      return s.length > 60 ? '${s.substring(0, 60)}…' : s;
    } catch (_) {
      return '';
    }
  }

  /// WP6：export_file 产物打开目标。
  /// primary = content:// URI（exportFile 返回值）；
  /// fallback = 工作区源文件路径（部分 ROM 对 MediaStore URI 授权挑剔，
  /// Kotlin 侧凭它走 FileProvider 回退——应用自有文件授权必成）。
  /// live 取 result（工具真实输出），历史取解析后的 summary（落库 🔧 消息）。
  (String, String?)? get _exportTargetInfo {
    if (widget.activity.name != 'export_file') return null;
    final candidates = <String>[
      widget.activity.result ?? '',
      widget.activity.arguments['name']?.toString() ?? '',
    ];
    for (final s in candidates) {
      final primary =
          RegExp(r'(content://\S+|/storage/emulated/\S+)').firstMatch(s);
      if (primary == null) continue;
      final fallback =
          RegExp(r'源文件：(\S+)').firstMatch(s)?.group(1);
      return (primary.group(1)!, fallback);
    }
    return null;
  }

  Future<void> _openExport() async {
    final info = _exportTargetInfo;
    if (info == null) return;
    try {
      await DeviceFilesService.instance
          .openFile(info.$1, fallbackPath: info.$2);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('打开失败：$e')),
        );
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _syncClock();
  }

  @override
  void didUpdateWidget(covariant ToolActivityCard old) {
    super.didUpdateWidget(old);
    _syncClock();
  }

  @override
  void dispose() {
    _ticker?.dispose();
    super.dispose();
  }

  /// 计时归零/冻结：executing 且无起点 → 记录起点并开秒级 Ticker；
  /// 离开 executing → 冻结总耗时、停 Ticker。
  void _syncClock() {
    final st = widget.activity.status;
    if (st == ToolUiStatus.executing) {
      if (_execStart == null) {
        _execStart = DateTime.now();
        _lastSec = -1;
        _ticker?.dispose();
        _ticker = createTicker(_onTick)..start();
      }
    } else if (_execStart != null && _total == null) {
      _total = DateTime.now().difference(_execStart!);
      _ticker?.dispose();
      _ticker = null;
    }
  }

  void _onTick(Duration elapsed) {
    if (!mounted) return;
    final now = DateTime.now();
    if (now.second == _lastSec) return;
    _lastSec = now.second;
    setState(() {});
  }

  /// 当前/最终耗时（未知为 null）。
  Duration? get _elapsed {
    if (_total != null) return _total;
    if (_execStart == null) return null;
    return DateTime.now().difference(_execStart!);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final activity = widget.activity;
    final (IconData icon, Color color, bool busy) = switch (activity.status) {
      ToolUiStatus.executing => (
          Icons.hourglass_top,
          theme.colorScheme.tertiary,
          true
        ),
      ToolUiStatus.done => (Icons.check_circle, Colors.green.shade600, false),
      ToolUiStatus.failed =>
        (Icons.error, theme.colorScheme.error, false),
    };
    final summary = _argsSummary;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 1),
      child: Material(
        color:
            theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () => setState(() => _expanded = !_expanded),
          child: Padding(
            // 单行高度贴死文字：vertical 2 + fontSize 12 ≈ 22px。
            padding:
                const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    busy
                        ? const SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(strokeWidth: 1.5))
                        : Icon(icon, size: 13, color: color),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        '🔧 ${activity.name}',
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                    if (summary.isNotEmpty) ...[
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          summary,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 11, color: theme.colorScheme.outline),
                        ),
                      ),
                    ],
                    if (activity.status == ToolUiStatus.executing) ...[
                      const SizedBox(width: 4),
                      Text(
                        _execStart == null ? '执行中…' : '执行中 - 持续了${_fmtDur(_elapsed)}',
                        style: TextStyle(
                            fontSize: 10,
                            color: theme.colorScheme.onSurfaceVariant,
                            fontStyle: FontStyle.italic),
                      ),
                    ] else if (_total != null) ...[
                      const SizedBox(width: 4),
                      Text('持续了${_fmtDur(_total)}',
                          style: TextStyle(
                              fontSize: 10,
                              color: theme.colorScheme.outline,
                              fontStyle: FontStyle.italic)),
                    ],
                    // WP6：export_file 完成后给「打开」按钮（系统查看器
                    // 直接查阅 html/png/pdf/md 等产物）。
                    if (activity.status != ToolUiStatus.executing &&
                        _exportTargetInfo != null) ...[
                      const SizedBox(width: 6),
                      InkWell(
                        onTap: _openExport,
                        borderRadius: BorderRadius.circular(4),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 4, vertical: 2),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.open_in_new,
                                  size: 12, color: theme.colorScheme.primary),
                              const SizedBox(width: 2),
                              Text('打开',
                                  style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      color: theme.colorScheme.primary)),
                            ],
                          ),
                        ),
                      ),
                    ],
                    Icon(
                      _expanded ? Icons.expand_less : Icons.expand_more,
                      size: 14,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ],
                ),
                if (_expanded) ...[
                  if (activity.arguments.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          '参数：\n${_prettyArgs()}',
                          style: const TextStyle(
                              fontSize: 11, fontFamily: 'monospace'),
                        ),
                      ),
                    ),
                  if (activity.result != null && activity.result!.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Align(
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
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _prettyArgs() {
    try {
      return const JsonEncoder.withIndent('  ')
          .convert(widget.activity.arguments);
    } catch (_) {
      return widget.activity.arguments.toString();
    }
  }
}

/// ThinkingStreamCard —— 思考流式卡片（独立模块，不与正文混杂）。
///
/// 用户定案：思考卡主信息是**耗时**（"思考 - 持续了X秒"）。流式输出时
/// **自动展开**并跟随列表滚动（否则用户不知道智能体在干什么）；流式输出
/// 完成（答案开始/回合结束）自动闭合；点按头部可手动展开/收起。
/// 思考文本来自 adapter onThinking 全量快照。
class ThinkingStreamCard extends StatefulWidget {
  final AgentUiState ui;

  /// 正文回答是否已开始输出（保留：答案开始后不展开内容，头部仅剩耗时）。
  final bool answerVisible;
  const ThinkingStreamCard({super.key, required this.ui, this.answerVisible = false});

  @override
  State<ThinkingStreamCard> createState() => _ThinkingStreamCardState();
}

class _ThinkingStreamCardState extends State<ThinkingStreamCard>
    with SingleTickerProviderStateMixin {
  /// null = 默认收起；非 null = 用户手动覆盖。
  bool? _override;
  DateTime? _start;
  Ticker? _ticker;
  int _lastSec = -1;

  /// 流式长内容自动跟随：内容变长时滚到可见区底部，直到用户手动上滑。
  final ScrollController _scroll = ScrollController();
  bool _userScrolledUp = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _ticker?.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// 用户滚动时判定是否离开了底部：离开 = 暂停跟随；滚回底部 = 恢复。
  void _onScroll() {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    final atBottom = pos.maxScrollExtent == 0 ||
        pos.pixels >= pos.maxScrollExtent - 4;
    if (_userScrolledUp == atBottom) {
      _userScrolledUp = !atBottom;
    }
  }

  /// 流式中把最新内容滚进可见区（仅当仍在跟随状态）。
  void _followStream() {
    if (!mounted || _userScrolledUp || !_scroll.hasClients) return;
    final pos = _scroll.position;
    if (pos.maxScrollExtent > 0 && pos.pixels < pos.maxScrollExtent) {
      _scroll.jumpTo(pos.maxScrollExtent);
    }
  }

  @override
  void didUpdateWidget(ThinkingStreamCard old) {
    super.didUpdateWidget(old);
    // 内容变长（流式推进）时跟随底部；同一内容仅头部耗时刷新的重建
    // 不触发（length 相同），避免无谓跳转。
    if (widget.ui.thinking.length != old.ui.thinking.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _followStream());
    }
    // 回合结束 / 答案开始 → 自动闭合；下次再流式时恢复跟随。
    if (!widget.ui.running || widget.answerVisible) {
      _userScrolledUp = false;
    }
  }

  /// 思考开始时记录起点并开秒级 Ticker（头部耗时走秒更新）。
  void _syncClock() {
    final s = widget.ui;
    if (_start == null && s.hasThinking && s.running) {
      _start = DateTime.now();
      _lastSec = -1;
      _ticker?.dispose();
      _ticker = createTicker(_onTick)..start();
    }
  }

  void _onTick(Duration elapsed) {
    if (!mounted) return;
    final now = DateTime.now();
    if (now.second == _lastSec) return;
    _lastSec = now.second;
    setState(() {});
  }

  Duration? get _elapsed =>
      _start == null ? null : DateTime.now().difference(_start!);

  @override
  Widget build(BuildContext context) {
    final s = widget.ui;
    if (!s.hasThinking) return const SizedBox.shrink();
    _syncClock();
    final theme = Theme.of(context);
    // 流式输出中（running 且答案未开始）自动展开跟随滚动；答案开始/回合
    // 结束自动闭合。用户手动点按优先（_override 非 null 即覆盖）。
    final expanded = _override ?? (s.running && !widget.answerVisible);
    // 只显示尾部（长思考时头部早已滚出视野，截断省内存与布局开销）。
    final tail = s.thinking.length > 2000
        ? '…${s.thinking.substring(s.thinking.length - 2000)}'
        : s.thinking;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 1),
      child: Container(
        decoration: BoxDecoration(
          color:
              theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => setState(() => _override = !expanded),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.psychology,
                        size: 14, color: theme.colorScheme.tertiary),
                    const SizedBox(width: 6),
                    Text(
                      _elapsed == null
                          ? (s.running ? '思考中…' : '思考')
                          : '思考 - 持续了${_fmtDur(_elapsed)}',
                      style: TextStyle(
                          fontSize: 12, color: theme.colorScheme.tertiary),
                    ),
                    if (s.running) ...[
                      const SizedBox(width: 6),
                      const SizedBox(
                          width: 10,
                          height: 10,
                          child: CircularProgressIndicator(strokeWidth: 1.5)),
                    ],
                    const Spacer(),
                    Icon(
                      expanded ? Icons.expand_less : Icons.expand_more,
                      size: 15,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ),
            if (expanded)
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 5),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 150),
                  child: SingleChildScrollView(
                    controller: _scroll,
                    child: Text(
                      tail,
                      style: TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 智能体回合内嵌工作流块（对话内一步步向下渲染）：
///
/// [重试/压缩横幅（仅运行中回合）]
/// → [🔧 工具卡片 ×N（逐步）]
/// → [思考中…（运行中且尚无答案文本）]
/// → [最终回答 ChatBubble（保留 assistant 头像/统计/复制）]。
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

  /// 「执行中…」占位行只在「智能体确实在推进、答案未开始、且没有工具正在
  /// 执行」时显示（用户定案：这不是"思考"，是任务执行状态过渡，标签写
  /// 执行中）。工具执行中不显示——工具卡片自带「执行中 - 持续了Xs」；
  /// 重试中已有 RetryIndicator，同理。
  /// **有真思考流（思考卡）时不显示**——思考卡自带「思考 - 持续了Xs」转圈，
  /// 占位行不是真思考、纯属重复（用户定案：界面上同时最多一个 spinner）。
  bool get _thinking =>
      _answerPending &&
      !ui.hasThinking &&
      ui.toolGen == null &&
      ui.retryAttempt == 0 &&
      !steps.any((s) => s.status == ToolUiStatus.executing);

  /// live 回合按**执行顺序**交错渲染思考存档与工具卡。
  ///
  /// 时间线标记由归约器按事件到达次序生成（思考落档 / 工具卡加入时追加），
  /// 渲染时依序取对应数据——工具调用与思考不再"一律思考在前、工具在后"。
  List<Widget> _timelineWidgets() {
    final widgets = <Widget>[];
    for (final m in ui.timeline) {
      switch (m) {
        case UiTimelineThinking(:final index):
          if (index < ui.thinkingHistory.length)
            widgets.add(_ThinkingBlockCard(
              text: ui.thinkingHistory[index],
              index: index + 1,
              duration: index < ui.thinkingDurations.length
                  ? ui.thinkingDurations[index]
                  : null,
            ));
        case UiTimelineTool(:final index):
          if (index < ui.tools.length)
            widgets.add(ToolActivityCard(activity: ui.tools[index]));
      }
    }
    return widgets;
  }

  @override
  Widget build(BuildContext context) {
    // live 回合：思考存档与工具卡按**执行顺序**交错渲染（timeline 由归约器
    // 按事件到达次序生成）——不再"思考一律在前、工具一律在后"。流式思考卡
    // = 当前正在进行的思考，位于时间线末尾。
    // 历史/普通聊天回合（timeline 恒空）：按存储 🔧 消息顺序渲染工具卡。
    final stepWidgets = (isLive && ui.timeline.isNotEmpty)
        ? _timelineWidgets()
        : steps.map((s) => ToolActivityCard(activity: s)).toList();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 横幅/思考行必须属于「正在跑的这一个回合」：retry/compacted 残留
        // 状态要等下一次 attach 才清，加 ui.running 防串台到普通聊天。
        if (isLive && ui.running && ui.retryAttempt > 0)
          RetryIndicator(attempt: ui.retryAttempt),
        if (isLive && ui.running && ui.compacted) const CompactionBanner(),
        ...stepWidgets,
        if (isLive && ui.hasThinking)
          ThinkingStreamCard(
            ui: ui,
            answerVisible: answer != null && !_answerPending,
          ),
        // WP5：工具调用参数生成期反馈（大 HTML/长文本写文件时思考与可见
        // 流都为空，此前只能干转圈）——显示已生成字数 + 开头预览。
        if (isLive && ui.running && ui.toolGen != null)
          _ToolGenIndicator(
            chars: ui.toolGen!.chars,
            preview: ui.toolGen!.preview,
          ),
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
            // 智能体回答与普通聊天同款：保留 assistant 头像（用户反馈要求）。
            showAvatar: true,
          ),
      ],
    );
  }
}

/// 时长渲染："持续了X秒"（<60s）/"X分Y秒"。null → 空串（历史回合无起点）。
String _fmtDur(Duration? d) {
  if (d == null) return '';
  if (d.inSeconds < 60) return '${d.inSeconds}秒';
  return '${d.inMinutes}分${d.inSeconds % 60}秒';
}
