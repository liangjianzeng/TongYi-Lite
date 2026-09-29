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
library;

import '../tool_definition.dart';
import '../web_search/web_search_seam.dart';

/// 回填给模型的文本预算（端侧上下文很贵：n_ctx 常见 8k，工具结果越大、
/// 手机 prefill 越慢）。摘要按条截断、总量按此上限截断。
const int kSnippetMaxChars = 200;
const int kResultMaxChars = 1500;

/// 一次调用最多搜索的关键词数（query + additional_queries）。
const int kMaxQueriesPerCall = 4;

/// 查询里已含年份数字（20xx）时不再补——避免"2025 发布会 2026"这类冗余。
final RegExp _yearInQuery = RegExp(r'20\d{2}');

ToolDefinition createWebSearchTool() {
  return ToolDefinition(
    name: 'web_search',
    description:
        '联网搜索，返回相关网页的标题与摘要（含来源链接）。'
        '结果头部会标注当前时间，按它判断信息新旧；查新闻/时效性内容时'
        '关键词带上时间词（今天/昨天/最近）。'
        '一个问题的多个角度可一次提交：把想查的其他关键词放进'
        'additional_queries（最多 3 个），工具会并发搜索并合并结果一次返回，'
        '不必多次调用。'
        '无结果时可尝试更换关键词；若返回诊断说明引擎不可用，'
        '不要反复重试，直接向用户说明即可。',
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
      // 时间注入：模型经常不知道今天几号，查"最新/今天"类内容会拿到旧闻。
      // 查询缺年份时补当前年份；结果头部再带完整当前时间兜底。
      final now = DateTime.now();
      final queries = <String>[];
      if (raw.isNotEmpty) queries.add(raw);
      queries.addAll(extras);
      final prepared = queries
          .map((q) => _yearInQuery.hasMatch(q) ? q : '$q ${now.year}')
          .toList();
      try {
        // 并行搜索：总耗时 ≈ 最慢单次，而非串行求和。不传 timeout：用
        // provider（设置项）里配置的超时。传了会覆盖设置值。
        final results = await Future.wait(
          prepared.map((q) => WebSearchSeam.instance.search(q)),
        );
        return prepared.length == 1
            ? _formatResult(results.first, now)
            : _formatMultiResult(prepared, results, now);
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

/// 多关键词并发结果的合并渲染：每个关键词一个小节（标注关键词），
/// 各小节均分 [kResultMaxChars] 预算，避免前面的查询吃光全部空间。
ToolResult _formatMultiResult(
  List<String> queries,
  List<WebSearchResult> results,
  DateTime now,
) {
  final two = (int v) => v.toString().padLeft(2, '0');
  final timeTag = '当前时间：'
      '${now.year}-${two(now.month)}-${two(now.day)} '
      '${two(now.hour)}:${two(now.minute)}'
      '（周${'一二三四五六日'[now.weekday - 1]}）';
  final perQueryCap = kResultMaxChars ~/ queries.length;
  final buffer = StringBuffer();
  buffer.writeln(timeTag);
  for (var i = 0; i < queries.length; i++) {
    final result = results[i];
    final section = StringBuffer();
    section.writeln('\n[搜索：${queries[i]}]');
    if (result.sources.isEmpty) {
      final diag = result.diagnostics;
      if (diag != null) {
        section.writeln('（无结果：$diag）');
      } else {
        section.writeln('（无结果，可换关键词）');
      }
    } else {
      for (final s in result.sources.take(8)) {
        _appendSource(section, s);
        if (section.length >= perQueryCap) break;
      }
    }
    buffer.write(_clip(section.toString().trim(), perQueryCap));
    buffer.write('\n');
    if (buffer.length >= kResultMaxChars) break;
  }
  var text = buffer.toString().trim();
  if (text.length > kResultMaxChars) {
    text = '${_clip(text, kResultMaxChars)}\n（结果已截断）';
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
