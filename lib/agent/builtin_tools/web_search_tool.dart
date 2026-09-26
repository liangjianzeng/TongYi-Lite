/// 联网搜索工具（默认注册；设置关闭时由接入层移除）。
///
/// 对齐 DSH：工具只调 [WebSearchSeam] 接缝、不写死搜索源。具体搜索实现
///（默认 SearXNG）由接入层通过 [WebSearchSeam.registerProvider] 注入，替换
/// 搜索源无需改本工具。
///
/// 返回相关网页标题 + 摘要 + 来源链接，供模型回答时引用。
library;

import '../tool_definition.dart';
import '../web_search/web_search_seam.dart';

/// 回填给模型的文本预算（端侧上下文很贵：n_ctx 常见 8k，工具结果越大、
/// 手机 prefill 越慢）。摘要按条截断、总量按此上限截断。
const int kSnippetMaxChars = 200;
const int kResultMaxChars = 1500;

ToolDefinition createWebSearchTool() {
  return ToolDefinition(
    name: 'web_search',
    description:
        '联网搜索，返回相关网页的标题与摘要（含来源链接）。'
        '结果有限，无结果时可尝试更换关键词。'
        '若返回 WEB_PROVIDER_ERROR，说明搜索服务未配置或不可用'
        '（需用户在 设置 → API 接入 → 联网搜索 里配置 SearXNG 地址），'
        '此时不要反复重试，直接向用户说明即可。',
    parameters: {
      'type': 'object',
      'properties': {
        'query': {'type': 'string', 'description': '搜索关键词'},
      },
      'required': ['query'],
    },
    // 网络搜索比本地工具慢一个量级（实测某实例 2~21s），需要比全局默认
    // 15s 更宽的预算；[ToolDefinition.timeout] 会被 ToolExecutor 采用。
    timeout: const Duration(seconds: 30),
    execute: (args) async {
      final query = (args['query'] as String?)?.trim() ?? '';
      if (query.isEmpty) {
        return ToolResult.error('缺少 query 参数');
      }
      try {
        // 不传 timeout：用 provider（设置项）里配置的超时。传了会覆盖设置值。
        final result = await WebSearchSeam.instance.search(query);
        return _formatResult(result);
      } on WebSearchProviderError catch (e) {
        return ToolResult.error('联网搜索失败（${e.kind}）：${e.message}');
      }
    },
  );
}

/// 把标准化结果渲染为模型可读文本（标题 / 摘要 / 来源链接），并做长度预算：
/// 单条摘要截到 [kSnippetMaxChars]，整体截到 [kResultMaxChars]。
ToolResult _formatResult(WebSearchResult result) {
  if (result.sources.isEmpty) {
    return const ToolResult(content: '未找到相关结果，可尝试更换关键词。');
  }
  final buffer = StringBuffer();
  for (final s in result.sources.take(8)) {
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

String _clip(String s, int maxChars) =>
    s.length <= maxChars ? s : '${s.substring(0, maxChars)}…';
