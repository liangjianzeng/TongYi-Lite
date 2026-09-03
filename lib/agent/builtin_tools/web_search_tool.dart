/// 联网搜索工具（默认不注册；设置开启后由接入层按配置挂载）。
///
/// 主源：Bing RSS（cn.bing.com，国内可达、无需密钥、结构化 XML）。
/// 备源：DuckDuckGo Instant Answer API（国内不可达时自动跳过，仅作兜底）。
/// 返回相关话题标题 + 摘要 + 来源链接，供模型回答时引用。
library;

import 'package:dio/dio.dart';

import '../tool_definition.dart';

ToolDefinition createWebSearchTool() {
  return ToolDefinition(
    name: 'web_search',
    description:
        '联网搜索，返回相关网页的标题与摘要（含来源链接）。'
        '结果有限，无结果时可尝试更换关键词。',
    parameters: {
      'type': 'object',
      'properties': {
        'query': {'type': 'string', 'description': '搜索关键词'},
      },
      'required': ['query'],
    },
    timeout: const Duration(seconds: 15),
    execute: (args) async {
      final query = (args['query'] as String?)?.trim() ?? '';
      if (query.isEmpty) {
        return ToolResult.error('缺少 query 参数');
      }

      // 主源：Bing RSS（国内可达）。
      final bing = await _searchBing(query);
      if (bing != null) return bing;

      // 备源：DuckDuckGo（部分网络可达）。
      final ddg = await _searchDuckDuckGo(query);
      if (ddg != null) return ddg;

      return ToolResult.error('联网搜索失败：主源与备源均不可达，请稍后重试');
    },
  );
}

/// Bing RSS 搜索：返回格式化文本，失败返回 null（交备源）。
Future<ToolResult?> _searchBing(String query) async {
  try {
    final dio = Dio();
    final resp = await dio.get<String>(
      'https://cn.bing.com/search',
      queryParameters: {'q': query, 'format': 'rss'},
      options: Options(receiveTimeout: const Duration(seconds: 10)),
    );
    if (resp.statusCode != 200) return null;
    final xml = resp.data ?? '';
    final items = _parseRssItems(xml);
    if (items.isEmpty) {
      return ToolResult(content: '未找到「$query」的相关结果，可尝试更换关键词。');
    }
    return ToolResult(content: items.take(6).join('\n'));
  } catch (_) {
    return null;
  }
}

/// DuckDuckGo Instant Answer（兜底）：失败返回 null。
Future<ToolResult?> _searchDuckDuckGo(String query) async {
  try {
    final dio = Dio();
    final resp = await dio.get<Map<String, dynamic>>(
      'https://api.duckduckgo.com/',
      queryParameters: {
        'q': query,
        'format': 'json',
        'no_html': '1',
        'pretty': '0',
      },
      options: Options(receiveTimeout: const Duration(seconds: 8)),
    );
    if (resp.statusCode != 200) return null;
    final data = resp.data ?? const <String, dynamic>{};
    return ToolResult(content: _formatDdgResults(data, query));
  } catch (_) {
    return null;
  }
}

/// 从 Bing RSS XML 提取 item 块（title / link / description）。
/// 无第三方 xml 依赖，用轻量正则解析（Bing RSS 结构稳定）。
List<String> _parseRssItems(String xml) {
  final items = <String>[];
  final itemRe = RegExp(r'<item>(.*?)</item>', dotAll: true);
  for (final m in itemRe.allMatches(xml)) {
    final block = m.group(1) ?? '';
    String? title = RegExp(r'<title>(.*?)</title>', dotAll: true)
        .firstMatch(block)
        ?.group(1);
    String? link = RegExp(r'<link>(.*?)</link>', dotAll: true)
        .firstMatch(block)
        ?.group(1);
    String? desc = RegExp(r'<description>(.*?)</description>', dotAll: true)
        .firstMatch(block)
        ?.group(1);
    // 去除 XML 实体与 CDATA。
    String clean(String? s) => (s ?? '')
        .replaceAll('<![CDATA[', '')
        .replaceAll(']]>', '')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .trim();
    title = clean(title);
    link = clean(link);
    desc = clean(desc);
    // description 常含 HTML 标签，剥掉标签只留文本。
    desc = desc.replaceAll(RegExp(r'<[^>]+>'), '').trim();
    if (title.isNotEmpty || desc.isNotEmpty) {
      final lines = <String>[];
      if (title.isNotEmpty) lines.add(title);
      if (desc.isNotEmpty) lines.add(desc);
      if (link != null && link.isNotEmpty) lines.add('来源：$link');
      items.add(lines.join('\n'));
    }
  }
  return items;
}

/// 把 DuckDuckGo 响应整理为可读文本（摘要 + 相关话题）。
String _formatDdgResults(Map<String, dynamic> data, String query) {
  final parts = <String>[];

  final abstractText = data['AbstractText']?.toString().trim();
  final abstractUrl = data['AbstractURL']?.toString().trim();
  if (abstractText != null && abstractText.isNotEmpty) {
    parts.add('$abstractText${abstractUrl != null ? '\n来源：$abstractUrl' : ''}');
  }

  final answer = data['Answer']?.toString().trim();
  if (answer != null && answer.isNotEmpty && answer != ' ') {
    parts.add('答案：$answer');
  }

  final topics = data['RelatedTopics'] as List? ?? const [];
  var topicCount = 0;
  for (final t in topics.take(6)) {
    if (t is! Map) continue;
    final text = t['Text']?.toString().trim();
    final url = t['FirstURL']?.toString().trim();
    if (text != null && text.isNotEmpty) {
      parts.add('$text${url != null ? '\n来源：$url' : ''}');
      topicCount++;
    }
    if (topicCount >= 4) break;
  }

  if (parts.isEmpty) {
    return '未找到「$query」的相关结果，可尝试更换关键词。';
  }
  return parts.take(5).join('\n');
}
