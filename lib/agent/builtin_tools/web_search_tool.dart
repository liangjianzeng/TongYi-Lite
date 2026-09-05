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

ToolDefinition createWebSearchTool() {
  return ToolDefinition(
    name: 'web_search',
    description:
        '联网搜索，返回相关网页的标题与摘要（含来源链接）。'
        '结果有限，无结果时可尝试更换关键词。'
        '若返回 WEB_PROVIDER_ERROR，说明搜索服务未配置或不可用，'
        '请检查「设置 → 联网搜索」的 SearXNG 地址。',
    parameters: {
      'type': 'object',
      'properties': {
        'query': {'type': 'string', 'description': '搜索关键词'},
      },
      'required': ['query'],
    },
    execute: (args) async {
      final query = (args['query'] as String?)?.trim() ?? '';
      if (query.isEmpty) {
        return ToolResult.error('缺少 query 参数');
      }
      try {
        final result = await WebSearchSeam.instance.search(query);
        return _formatResult(result);
      } on WebSearchProviderError catch (e) {
        return ToolResult.error('联网搜索失败：${e.message}');
      }
    },
  );
}

/// 把标准化结果渲染为模型可读文本（标题 / 摘要 / 来源链接）。
ToolResult _formatResult(WebSearchResult result) {
  if (result.sources.isEmpty) {
    return const ToolResult(content: '未找到相关结果，可尝试更换关键词。');
  }
  final buffer = StringBuffer();
  for (final s in result.sources.take(8)) {
    final title = s.title?.trim();
    final snippet = s.snippet?.trim();
    if (title != null && title.isNotEmpty) buffer.writeln('标题：$title');
    if (snippet != null && snippet.isNotEmpty) buffer.writeln('摘要：$snippet');
    if (s.url.isNotEmpty) buffer.writeln('来源：${s.url}');
    buffer.writeln();
  }
  return ToolResult(content: buffer.toString().trim());
}
