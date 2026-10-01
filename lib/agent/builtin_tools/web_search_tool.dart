/// 联网搜索工具（默认注册；设置关闭时由接入层移除）。
///
/// 对齐 DSH：工具只调 [WebSearchSeam] 接缝、不写死搜索源。具体搜索实现
///（默认 SearXNG）由接入层通过 [WebSearchSeam.registerProvider] 注入，替换
/// 搜索源无需改本工具。
///
/// 返回相关网页标题 + 摘要 + 来源链接，供模型回答时引用。
///
/// **并发多关键词**（2026-09-29 用户要求）：一次调用可提交最多 4 个关键词
///（query + additional_queries），工具并行搜索、合并结果一次返回——把
/// "一个问题搜几次"压缩成"一次搜多个角度"，减少智能体回合的交互次数。
///
/// **回合级搜索预算**（2026-09-29，对齐 DSH 服务端工具 `web_search_20250305`
/// 的 `max_uses` 语义）：每回合最多调用 [maxSearchesPerTurn] 次。达到上限后
/// 工具**拒绝联网**并返回收敛指令，让模型基于既有结果直接回答——杜绝
/// "反复搜索同一内容 / 用完循环次数没输出"的搜索死循环。同一回合内主查询
/// 归一化后与已搜过的关键词相同 → 直接回缓存结果（不重复联网）。
library;

import '../tool_definition.dart';
import '../web_search/web_search_seam.dart';
import '../../web_search/query_expander.dart';

/// 回填给模型的文本预算（端侧上下文很贵：n_ctx 常见 8k，工具结果越大、
/// 手机 prefill 越慢）。摘要按条截断、总量按此上限截断。
const int kSnippetMaxChars = 200;
const int kResultMaxChars = 1500;

/// 一次调用最多提交的关键词数（query + additional_queries）。
const int kMaxQueriesPerCall = 4;

/// 每回合 web_search 最多调用次数（对齐 DSH `max_uses` 默认 5；可经设置调整）。
/// 每次调用消耗 1 次预算（含重复关键词），达到上限即拒绝联网、强制收敛。
const int kMaxSearchesPerTurn = 5;

/// 意图扩展后，单次调用内部最多搜索的关键词组数（主查询 + 附加查询的
/// 时效变体）。内部扩展搜索不消耗 max_uses（模型调用仍只消耗 1 次）。
const int kInternalMaxQueries = 6;

/// 内部搜索分批并发数：控制单次调用耗时（每批并行，串行分批）。
const int kInternalBatch = 3;

/// 合并结果达到此条数即提前停止继续搜索（够了就不用搜剩余变体）。
const int kCollectTarget = 12;

/// 时效评分：3=今天/昨日/X小时前/X天前，2=当前年，1=无时间标记，
/// 0=明确往年（如 2025/2024）旧闻。用于过滤旧闻 + 近期优先排序。
int _recencyScore(WebSearchSource s, int currentYear) {
  final t = s.publishedAt ?? '';
  if (t.contains('今天') || t.contains('昨日') || t.contains('昨天') ||
      RegExp(r'\d+小时前|\d+天前').hasMatch(t)) {
    return 3;
  }
  final m = RegExp(r'(20\d{2})').firstMatch(t);
  if (m != null) {
    return int.parse(m.group(1)!) == currentYear ? 2 : 0;
  }
  return 1;
}

/// 归一化查询：小写 + 只留中英文/数字，用于同回合重复搜索判定
///（"华为大会 " / "华为 大会" / "华为大会。" 视为同一关键词）。
String _normalizeQuery(String q) {
  final lower = q.toLowerCase();
  final buf = StringBuffer();
  for (var i = 0; i < lower.length; i++) {
    final c = lower.codeUnitAt(i);
    // 0-9 / a-z / CJK 及更高（含全角标点一并保留，中文句读不影响判定）。
    if ((c >= 0x30 && c <= 0x39) ||
        (c >= 0x61 && c <= 0x7a) ||
        c >= 0x80) {
      buf.writeCharCode(c);
    }
  }
  return buf.toString();
}

/// 每回合搜索会话（DSH `max_uses` 语义）。
class _WebSearchTurnSession {
  final int maxSearches;

  /// 本轮已调用次数（每次调用消耗 1，含重复；对齐服务端 max_uses 计数）。
  int used = 0;

  /// 归一化主查询 → 首次搜索结果（重复调用直接回缓存，不重复联网）。
  final Map<String, ToolResult> cache = {};

  _WebSearchTurnSession(this.maxSearches);
}

ToolDefinition createWebSearchTool({int maxSearchesPerTurn = kMaxSearchesPerTurn}) {
  // 每次 createWebSearchTool 都新建回合会话：接入层每回合重建注册表
  // （createBuiltinTools 全量新建），状态天然随回合重置。
  final session = _WebSearchTurnSession(maxSearchesPerTurn);
  return ToolDefinition(
    name: 'web_search',
    description:
        '联网搜索，返回相关网页的标题与摘要（含来源链接）。'
        '结果头部会标注当前时间，按它判断信息新旧；查新闻/时效性内容时'
        '关键词带上时间词（今天/昨天/最近）。'
        '注意：搜索引擎对本地（某地）近几天的实时新闻覆盖有限，结果多为'
        '百科/攻略/政策页。若无近期新闻条目，请如实说明，并结合能确认的'
        '时效信息（天气/活动/政策，标注日期）回答，不要拿百科/旧攻略'
        '冒充最新新闻。'
        '一个问题的多个角度可一次提交：把想查的其他关键词放进'
        'additional_queries（最多 3 个），工具会并发搜索并合并结果一次返回，'
        '不必多次调用。'
        '每回合最多搜索 $maxSearchesPerTurn 次（含重复），已有足够结果时'
        '直接回答，不要重复搜索同一关键词；无结果时可尝试更换关键词；'
        '若返回诊断说明引擎不可用，不要反复重试，直接向用户说明即可。',
    parameters: {
      'type': 'object',
      'properties': {
        'query': {'type': 'string', 'description': '主要搜索关键词'},
        'additional_queries': {
          'type': 'array',
          'items': {'type': 'string'},
          'description': '可选：同一问题想覆盖的其他角度/关键词，最多 3 个；'
              '并发搜索后合并返回',
        },
      },
      'required': ['query'],
    },
    // 网络搜索比本地工具慢一个量级（实测某实例 2~21s），需要比全局默认
    // 15s 更宽的预算；[ToolDefinition.timeout] 会被 ToolExecutor 采用。
    // 并发搜索时总耗时 ≈ 最慢单次（并行），30s 预算依旧够。
    timeout: const Duration(seconds: 30),
    execute: (args) async {
      final raw = (args['query'] as String?)?.trim() ?? '';
      final extras = (args['additional_queries'] as List?)
          ?.whereType<String>()
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .take(kMaxQueriesPerCall - 1)
          .toList() ??
          const <String>[];
      if (raw.isEmpty && extras.isEmpty) {
        return ToolResult.error('缺少 query 参数');
      }

      // ---- 预算闸（DSH max_uses）：每次调用消耗 1，含重复。达到上限拒绝
      // 联网，返回收敛指令让模型基于既有结果直接回答，杜绝搜索死循环。----
      if (session.used >= session.maxSearches) {
        return ToolResult.error(
            '本轮搜索次数已达上限（$maxSearchesPerTurn 次）。'
            '请直接基于以上已有的搜索结果回答，不要再调用 web_search。');
      }

      // ---- 去重：主查询归一化后与已搜过的相同 → 回缓存结果（不联网），
      // 但仍消耗预算——重复搜索本身就是浪费，尽快逼模型收敛。----
      final norm = raw.isNotEmpty ? _normalizeQuery(raw) : '';
      final cached = session.cache[norm];
      if (cached != null) {
        session.used++;
        return ToolResult(
            content: '（此关键词本轮已搜索过，结果同上，未重复联网。'
            '请直接基于已有结果回答，不要重复搜索。）\n${cached.content}');
      }

      session.used++;
      final now = DateTime.now();
      // ---- 意图理解 + 关键词扩展：把主查询和附加查询扩展成候选关键词池
      // （补"新闻 / 最新 / 年份"等时效变体），按优先级从高到低。工具内部
      // 循环搜索多组关键词、跨关键词合并去重——单次调用即覆盖多个角度与
      // 时效变体，充分利用每回合搜索预算。内部扩展搜索不消耗 max_uses
      // （模型调用仍只消耗 1 次）。----
      final queries = <String>[];
      if (raw.isNotEmpty) queries.add(raw);
      queries.addAll(extras);
      final candidates =
          expandKeywords(queries, now: now, cap: kInternalMaxQueries);

      try {
        // ---- 内部循环搜索：分批并发，跨关键词合并去重，够条数提前停。
        // 每个关键词走 provider（内部再并发多引擎），单次调用内即可覆盖
        // 多个关键词变体，信息量远大于只搜一次。----
        final seen = <String>{};
        final merged = <WebSearchSource>[];
        final failedDiags = <String>{};
        for (var i = 0;
            i < candidates.length && merged.length < kCollectTarget;
            i += kInternalBatch) {
          final end = (i + kInternalBatch).clamp(0, candidates.length);
          final slice = candidates.sublist(i, end);
          final results = await Future.wait(slice.map((q) async {
            try {
              return await WebSearchSeam.instance.search(q);
            } on WebSearchProviderError catch (e) {
              failedDiags.add('${e.kind}:${e.message}');
              return null;
            }
          }));
          for (final r in results) {
            if (r == null) continue;
            if (r.diagnostics != null) failedDiags.add(r.diagnostics!);
            for (final s in r.sources) {
              final key = normalizeSourceUrl(s.url);
              if (!seen.add(key)) continue;
              merged.add(s);
            }
          }
        }

        // 时效过滤：剔除明确往年的旧闻，近期条目优先——避免模型拿 2025/2024
        // 旧闻当"最新"回答。无时间标记的条目保留（排后）。
        merged.removeWhere((s) => _recencyScore(s, now.year) == 0);
        merged.sort((a, b) =>
            _recencyScore(b, now.year).compareTo(_recencyScore(a, now.year)));

        final truncated = merged.length > kCollectTarget;
        final result = _formatResult(
          WebSearchResult(
            sources: merged.take(kCollectTarget).toList(),
            truncated: truncated,
            diagnostics: failedDiags.isEmpty
                ? null
                : failedDiags.join('；'),
          ),
          now,
        );
        // 主查询结果入缓存（含时间标签；同回合重复调用直接回读）。
        if (norm.isNotEmpty && !result.isError) {
          session.cache[norm] = result;
        }
        return result;
      } on WebSearchProviderError catch (e) {
        return ToolResult.error('联网搜索失败（${e.kind}）：${e.message}');
      }
    },
  );
}

/// 把标准化结果渲染为模型可读文本（标题 / 摘要 / 来源链接），并做长度预算：
/// 单条摘要截到 [kSnippetMaxChars]，整体截到 [kResultMaxChars]。
ToolResult _formatResult(WebSearchResult result, DateTime now) {
  final two = (int v) => v.toString().padLeft(2, '0');
  final timeTag = '当前时间：'
      '${now.year}-${two(now.month)}-${two(now.day)} '
      '${two(now.hour)}:${two(now.minute)}'
      '（周${'一二三四五六日'[now.weekday - 1]}）';
  if (result.sources.isEmpty) {
    // 0 结果 ≠ "没这信息"：先分清是实例挂了还是真无结果，别让模型拿
    // "查询不到"当答案糊弄用户。
    final diag = result.diagnostics;
    if (diag != null) {
      return ToolResult.error('$timeTag\n搜索服务异常：$diag');
    }
    return ToolResult.error('$timeTag\n未找到相关结果，可尝试更换关键词。');
  }
  final buffer = StringBuffer();
  buffer.writeln(timeTag);
  buffer.writeln();
  for (final s in result.sources.take(8)) {
    _appendSource(buffer, s);
    // 够了就停：手机端上下文和 prefill 都很贵，别把 8 条长摘要全塞进去。
    if (buffer.length >= kResultMaxChars) break;
  }
  var text = buffer.toString().trim();
  if (text.length > kResultMaxChars) {
    text = '${_clip(text, kResultMaxChars)}\n（结果已截断）';
  }
  if (result.truncated) {
    text = '$text\n[另有更多结果未展示，可换更具体的关键词]';
  }
  return ToolResult(content: text);
}

/// 追加一条结果的标题 / 摘要 / 时间 / 来源（共享格式）。
void _appendSource(StringBuffer buffer, WebSearchSource s) {
  final title = s.title?.trim();
  final snippet = s.snippet?.trim();
  if (title != null && title.isNotEmpty) buffer.writeln('标题：$title');
  if (snippet != null && snippet.isNotEmpty) {
    buffer.writeln('摘要：${_clip(snippet, kSnippetMaxChars)}');
  }
  if (s.publishedAt != null && s.publishedAt!.isNotEmpty) {
    buffer.writeln('时间：${s.publishedAt}');
  }
  if (s.url.isNotEmpty) buffer.writeln('来源：${s.url}');
  buffer.writeln();
}

String _clip(String s, int maxChars) =>
    s.length <= maxChars ? s : '${s.substring(0, maxChars)}…';
