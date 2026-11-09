/// 压缩插件（Phase 2 → B1 重写）—— 对照 DSH compaction-basic。
///
/// 端侧：阶段 1（确定性结构化 digest）恒可用、免费、即时；
/// 阶段 2（模型摘要）按 [CompactionPlugin.decide] 的 `allowModelSummary`
/// 与是否注入 [llmSummarizer] 决定——失败/超时/空回复一律回退确定性
/// digest，压缩永不因摘要模型而失败。
///
/// B1 三约束（DSH compaction 不变量）：
/// 1. **不拆 tool-call/result 对**：遮蔽区间自动扩到包含被遮结果的
///    assistant 发起者（模型可见历史里 assistant(toolCalls) 与 tool/result
///    永远成对出现，OpenAI 400 / 本地模板渲染断链都被根治）；
/// 2. **摘要必须比原文小**：遮蔽区 token 估算 ≤ 摘要 token 估算时拒绝
///    提交（返回 failure，不做假前进）；
/// 3. **前进性**：只有真正 replace（遮蔽 + 摘要）才返回 success，
///    overflow retry 以 replaceGeneration 前进为前提。
///
/// B2 结构化摘要（对照 DSH summarizer 八段骨架的端侧裁剪版）：
/// 摘要固定骨架（诉求/关键结果/错误/路径产物/工具清单/此前摘要合并），
/// 旧摘要内容折叠进新摘要（不丢链）。LLM 摘要时输入 = 对话真前缀 +
/// 末尾指令 user 消息——本地引擎 LCP 增量 prefill 直接命中前缀缓存。
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;

import '../observability/quiet_fail.dart';
import '../session/session.dart';
import '../loop/failure.dart';
import 'token_estimate.dart';

/// LLM 摘要器 seam（B2）：
/// - [instruction]：压缩指令（要求生成结构化摘要的提示词正文）；
/// - [prefixMessages]：对话真前缀（decide 时点的模型可见投影）——
///   端侧真前缀摘要调用要求 messages = prefixMessages + [user: instruction]，
///   本地引擎 LCP 命中前缀缓存，增量 prefill 只有指令尾部；
///   API 路线可忽略 prefix（沿用自身的便宜 system + user(instruction)）。
/// 返回摘要正文；失败返回 null。
typedef LlmSummarizer = Future<String?> Function(
  String instruction,
  List<Map<String, dynamic>> prefixMessages,
);

/// 压缩插件（替代 [NoCompactionPlugin] 的占位）。
final class DeterministicCompaction implements CompactionPlugin {
  /// 尾部保留的 user 轮数（默认 5）。
  final int keepRounds;

  /// LLM 摘要器（B2 seam）；null = 纯确定性 digest。
  final LlmSummarizer? llmSummarizer;

  /// 摘要提示词里的单条工具结果摘录上限（字符）——自适应预算的上限档。
  static const int _excerptLen = 400;

  /// 确定性 digest 各清单条数上限（防极端长会话摘要自身爆炸）。
  static const int _maxExcerpts = 24;

  DeterministicCompaction({
    this.keepRounds = 5,
    this.llmSummarizer,
  });

  @override
  Future<CompactionResult> decide({
    required SessionRef ref,
    required int turn,
    required int step,
    required String? reason,
    bool allowModelSummary = true,
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
    // 返回 failure（而非 success）：DSH 不变量 11 —— 重试必须以
    // replaceGeneration 前进为前提。此处没有遮蔽任何事件，若返回 success
    // 会让失败瀑布无条件 retry 同一超限请求 → 无限循环（turn 永不结束）。
    if (userSeqs.length <= keepRounds) {
      return const CompactionResult(CompactionResultKind.failure);
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
      // 旧轮无工具结果 → 无 token 大户可裁，无前进 → failure（同上，防死循环）。
      return const CompactionResult(CompactionResultKind.failure);
    }
    var first = oldToolResultSeqs.first;
    final last = oldToolResultSeqs.last;

    // ---- 约束 1：不拆 tool-call/result 对 ----
    // 遮蔽区向前扩展：凡是发起过「结果被遮蔽的调用」的 assistant 消息
    // 一并遮蔽。迭代到不动点（扩大区间可能吞进更早的 tool/result，
    // 其发起者又需要扩展）。
    var expanded = true;
    while (expanded) {
      expanded = false;
      final maskedCallIds = <String>{};
      for (final e in events) {
        if (e.seq < first || e.seq > last) continue;
        if (e.type != kEventToolResult) continue;
        final cid = e.data['callId'] as String? ?? '';
        if (cid.isNotEmpty) maskedCallIds.add(cid);
      }
      for (final e in events) {
        if (e.seq >= first) break; // 事件按 seq 递增
        if (e.type != kEventAssistantMessage) continue;
        final calls = e.data['toolCalls'] as List<dynamic>?;
        if (calls == null || calls.isEmpty) continue;
        for (final c in calls) {
          if (c is! Map<String, dynamic>) continue;
          final cid = (c['call_id'] as String?) ??
              (c['id'] as String?) ??
              '';
          if (cid.isNotEmpty && maskedCallIds.contains(cid)) {
            first = e.seq;
            expanded = true;
            break;
          }
        }
      }
    }

    // ---- 约束 2 预算：遮蔽区 token（原文侧）先行测量 ----
    // 摘录长度按遮蔽区大小自适应（约束 2：摘要必须更小——小遮蔽区用短
    // 摘录，大遮蔽区才放宽到 400 字），骨架开销占比随之受控。
    final maskedTokens = _estimateRangeTokens(log, events, first, last);

    // ---- 区域起点对齐 DSH 选区语义 ----
    // 从最老的未遮蔽表面事件起整段收编（终点仍是最后一个旧工具结果）：
    // 此前的压缩摘要事件因此落入区间 → 旧摘要链式折叠进新摘要（不断链）；
    // 孤立在结果之前的旧 user 诉求文本也一并收编（digest 有 240 字/条
    // 摘录承载）。配对不变量只许区间扩大，方向一致。
    for (final e in events) {
      if (e.seq >= first) break;
      if (categoryOf(e.type) != EventTypeCategory.surface) continue;
      if (log.isShadowed(e.seq)) continue;
      first = e.seq;
      break;
    }

    // ---- 摘要素材收集：[first..last] 内未遮蔽事件 ----
    // 旧 user 诉求（240 字/条——120 字经常截掉后半句，模型据此"失忆式续跑"）
    final userAsks = <String>[];
    // 工具结果原文（成功 → 关键结果；isError → 错误与失败）——摘录长度
    // 在收集完后按预算统一切
    final resultContents = <(String, String, bool)>[];
    // 涉及路径/产物（工具结果里的路径样文本）
    final pathLike = <String>{};
    final toolNames = <String>{};
    // 旧摘要合并（B2：链式折叠，多轮压缩不丢前情）
    final priorSummaries = <String>[];

    for (final e in events) {
      if (e.seq < first || e.seq > last) continue;
      if (log.isShadowed(e.seq)) continue;
      switch (e.type) {
        case kEventUserMessage:
          final content = e.data['content'] as String? ?? '';
          if (content.isEmpty) break;
          // 回合引导/环境快照/插话等系统形消息不进"用户诉求"。
          if (content.startsWith('[系统]') ||
              content.startsWith('[系统通知]') ||
              content.startsWith('[用户插话]') ||
              content.startsWith('【环境】')) {
            break;
          }
          userAsks.add(content.length > 240
              ? content.substring(0, 240)
              : content);
          break;
        case kEventAssistantMessage:
          break; // 助手文本随区间遮蔽，重要结论由工具结果/摘要承载
        case kEventToolResult:
          final name = e.data['name'] as String? ?? 'tool';
          if (name.isNotEmpty) toolNames.add(name);
          final content = e.data['content'] as String? ?? '';
          if (content.isEmpty) break;
          final isError = e.data['isError'] == true;
          if (resultContents.length < _maxExcerpts * 2) {
            resultContents.add((name, content, isError));
          }
          _collectPathLike(content, pathLike);
          break;
        case kEventCompactionSummary:
          // 被折叠的旧摘要（含前几轮压缩产物）——原样并入新摘要，不断链。
          final prior = e.data['content'] as String? ?? '';
          if (prior.isNotEmpty && priorSummaries.length < 3) {
            priorSummaries.add(prior);
          }
          break;
        default:
          break;
      }
    }

    // user 诉求条数上限（区域对齐 DSH 选区后可能覆盖很多轮文本，
    // 摘要自身不能爆炸——保留最近 8 条，最新的诉求最关键）。
    if (userAsks.length > 8) {
      userAsks.removeRange(0, userAsks.length - 8);
    }

    // ---- 自适应摘录预算（约束 2 的事前保障）----
    // 骨架+诉求+旧摘要的固定开销之外，摘录总预算 ≈ 遮蔽区的 50%；
    // 摘录数多则每条变短，最少保底 40 字（保留可辨识度）。
    final keyResults = <String>[];
    final errorNotes = <String>[];
    if (resultContents.isNotEmpty) {
      final fixedTokens =
          _skeletonOverhead(priorSummaries: priorSummaries, asks: userAsks);
      final budgetTokens =
          (maskedTokens * 0.5).floor() - fixedTokens;
      final perExcerptTokens =
          (budgetTokens ~/ resultContents.length).clamp(30, 300);
      // CJK 3/4 tok/字 → 字 ≈ tok×4/3。
      final excerptLen =
          (perExcerptTokens * 4 ~/ 3).clamp(40, _excerptLen);
      for (final (name, content, isError) in resultContents) {
        final excerpt = content.length > excerptLen
            ? '${content.substring(0, excerptLen)}…'
            : content;
        if (isError) {
          errorNotes.add('[$name] $excerpt');
        } else {
          keyResults.add('[$name] $excerpt');
        }
      }
    }

    // ---- 确定性结构化 digest（B2 骨架）----
    final deterministic = _buildDeterministicDigest(
      userAsks: userAsks,
      keyResults: keyResults,
      errorNotes: errorNotes,
      pathLike: pathLike,
      toolNames: toolNames,
      priorSummaries: priorSummaries,
    );

    // 遮蔽前投影懒计算复用：摘要前缀（B2）与 beforeTokens 基线是同一次
    // replace 之前的模型可见投影（deriveModelMessages 为 O(events)，长会话
    // 下两次全量重算白付一倍）；中间无任何 log 写入，快照一致。
    List<Map<String, dynamic>>? preMaskProjection;
    List<Map<String, dynamic>> preMask() =>
        preMaskProjection ??= log.deriveModelMessages();

    // ---- 阶段 2：LLM 摘要（失败/超时/禁用一律回退确定性 digest）----
    var finalSummary = deterministic;
    var summaryProvider = 'deterministic-prune';
    var summaryModel = 'none';
    final summarizer = llmSummarizer;
    if (summarizer != null && allowModelSummary && userAsks.isNotEmpty) {
      try {
        final instruction = _buildSummaryInstruction(
          toolNames: toolNames,
          priorSummaries: priorSummaries,
        );
        // 真前缀（B2）：decide 时点（replace 之前）的模型可见投影 =
        // 最近一次请求的消息列表，本地引擎 LCP 直接命中。
        final prefixMessages = preMask();
        final modelSummary = await summarizer(instruction, prefixMessages)
            .timeout(const Duration(seconds: 90));
        final t = modelSummary?.trim() ?? '';
        if (t.isNotEmpty) {
          finalSummary = _wrapSummaryTag(t, priorSummaries: priorSummaries);
          summaryProvider = 'llm';
          summaryModel = 'compression';
        }
      } on TimeoutException catch (e) {
        // 超时 → 确定性 digest 兜底（压缩本身不能失败）；留痕防静默降级成常态。
        quietFail('compaction.summary.timeout', e);
      } on Exception catch (e) {
        // 摘要模型失败 → 同上（TimeoutException 是 Exception 子类，
        // 必须先接超时档，否则永远落到泛 Exception）。
        quietFail('compaction.summary.model', e);
      }
    }

    // ---- 约束 2：摘要必须比原文小（最终闸门）----
    final summaryTokens = estimateTextTokens(finalSummary) + 16;
    if (summaryTokens >= maskedTokens) {
      debugPrint('[Compaction] 拒绝提交：摘要 ${summaryTokens}tok ≥ '
          '遮蔽区 ${maskedTokens}tok（约束 2：摘要必须更小）');
      return const CompactionResult(CompactionResultKind.failure);
    }

    // ---- 遮蔽 [first..last] 为一条摘要 ----
    // 压缩前基线：估算当前投影 token（与预算/呈现同一口径）。
    final beforeTokens = estimateContextTokens(preMask());
    final advance = log.replace(
      startSeq: first,
      endSeq: last,
      newContent: finalSummary,
      summaryProvider: summaryProvider,
      summaryModel: summaryModel,
    );
    if (advance > 0) {
      final afterTokens = estimateContextTokens(log.deriveModelMessages());
      final stats = CompactionStats(
        maskedEvents: last - first + 1,
        beforeTokens: beforeTokens,
        afterTokens: afterTokens,
        provider: summaryProvider,
        summaryChars: finalSummary.length,
      );
      debugPrint('[Compaction] 裁剪（$summaryProvider）：mask [$first..$last]，'
          '${stats.beforeTokens}→${stats.afterTokens} tok'
          '（省 ${stats.savedTokens}），summary=${finalSummary.length}chars');
      return CompactionResult(CompactionResultKind.success, stats);
    }
    return const CompactionResult(CompactionResultKind.failure);
  }

  /// 遮蔽区 [first..last] 的投影 token 估算（约束 2 的"原文"侧）。
  int _estimateRangeTokens(
      SessionLog log, List<SessionEvent> events, int first, int last) {
    var tokens = 0;
    for (final e in events) {
      if (e.seq < first || e.seq > last) continue;
      if (log.isShadowed(e.seq)) continue;
      if (categoryOf(e.type) != EventTypeCategory.surface) continue;
      final content = e.data['content'] as String?;
      if (content != null) tokens += estimateTextTokens(content);
      final calls = e.data['toolCalls'] as List?;
      if (calls is List) tokens += calls.length * 40;
      tokens += 4; // 每条消息 role 开销（DSH token-meter 同款）
    }
    return tokens;
  }

  /// 摘录预算的固定开销测算：骨架 + 诉求 + 旧摘要（不含摘录本身）。
  int _skeletonOverhead({
    required List<String> priorSummaries,
    required List<String> asks,
  }) {
    final probe = _buildDeterministicDigest(
      userAsks: asks,
      keyResults: const [],
      errorNotes: const [],
      pathLike: const {},
      toolNames: const {},
      priorSummaries: priorSummaries,
    );
    return estimateTextTokens(probe);
  }

  /// 从工具结果文本里收集路径样 token（`/`、`\`、`.` 后缀形态）。
  static final RegExp _pathRe =
      RegExp(r'[A-Za-z0-9_./\\-]{4,}(/[A-Za-z0-9_./\\-]+)+');

  void _collectPathLike(String content, Set<String> out) {
    if (out.length >= 12) return;
    for (final m in _pathRe.allMatches(content)) {
      out.add(m.group(0)!);
      if (out.length >= 12) return;
    }
  }

  /// 确定性结构化 digest（B2 骨架，无模型调用）。
  String _buildDeterministicDigest({
    required List<String> userAsks,
    required List<String> keyResults,
    required List<String> errorNotes,
    required Set<String> pathLike,
    required Set<String> toolNames,
    required List<String> priorSummaries,
  }) {
    final buf = StringBuffer('<compacted-summary>');
    buf.write('\n## 用户诉求（较早轮次，按序）\n');
    if (userAsks.isEmpty) {
      buf.writeln('- （无可提炼的用户消息）');
    } else {
      for (final a in userAsks) {
        buf.writeln('- $a');
      }
    }
    buf.writeln('\n## 关键结果与数据（工具结果摘录）');
    if (keyResults.isEmpty) {
      buf.writeln('- （无）');
    } else {
      for (final k in keyResults) {
        buf.writeln('- $k');
      }
      if (keyResults.length >= _maxExcerpts) buf.writeln('- （其余结果已省略）');
    }
    if (errorNotes.isNotEmpty) {
      buf.writeln('\n## 错误与失败');
      for (final e in errorNotes) {
        buf.writeln('- $e');
      }
    }
    if (pathLike.isNotEmpty) {
      buf.writeln('\n## 涉及路径与产物');
      buf.writeln('- ${pathLike.join('、')}');
    }
    buf.writeln('\n## 已调用工具');
    buf.writeln('- ${toolNames.isEmpty ? '无' : toolNames.join('、')}');
    for (final p in priorSummaries) {
      buf.writeln('\n## 此前压缩摘要（原样保留）\n$p');
    }
    buf.write('</compacted-summary>');
    return buf.toString();
  }

  /// LLM 摘要指令（B2：骨架对齐 DSH summarizer）。
  String _buildSummaryInstruction({
    required Set<String> toolNames,
    required List<String> priorSummaries,
  }) {
    final buf = StringBuffer();
    buf.writeln('请把以上对话（截至最后一条用户消息之前的完整历史）压缩成一份'
        '结构化摘要，供后续对话作为已确立背景使用。要求：');
    buf.writeln('1. 严格按以下 Markdown 骨架输出，无内容的小节写"（无）"；');
    buf.writeln('2. 总长不超过 400 字，不逐条罗列工具结果原文，只保留结论'
        '与关键数据（数字/路径/文件名必须保真）；');
    buf.writeln('3. 只输出摘要本身，不要评论、不要致谢。');
    buf.writeln();
    buf.writeln('骨架：');
    buf.writeln('# 对话摘要');
    buf.writeln('## 用户核心诉求');
    buf.writeln('## 关键结论与数据');
    buf.writeln('## 涉及文件与路径');
    buf.writeln('## 错误与修正');
    buf.writeln('## 未完成事项');
    buf.writeln('## 当前工作状态');
    if (toolNames.isNotEmpty) {
      buf.writeln('（此前已调用过的工具：${toolNames.join('、')}，'
          '不要重复这些调用的过程描述）');
    }
    if (priorSummaries.isNotEmpty) {
      buf.writeln('已有先前压缩摘要（骨架中的相应小节必须合并其内容，'
          '不得丢弃既有事实）：');
      for (final p in priorSummaries) {
        buf.writeln(p);
      }
    }
    return buf.toString();
  }

  /// LLM 摘要落盘包装：`<compacted-summary>` 标签 + 前情合并（不断链）。
  String _wrapSummaryTag(String body, {required List<String> priorSummaries}) {
    final buf = StringBuffer('<compacted-summary>\n$body\n');
    for (final p in priorSummaries) {
      buf.writeln('\n## 此前压缩摘要（原样保留）\n$p');
    }
    buf.write('</compacted-summary>');
    return buf.toString();
  }
}
