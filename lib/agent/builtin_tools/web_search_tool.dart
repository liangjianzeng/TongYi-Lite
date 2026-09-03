/// 联网搜索工具（默认不注册；设置开启后由接入层按配置挂载）。
///
/// 使用 DuckDuckGo Instant Answer API（免费、无需密钥、无 CORS/限流限制），
/// 返回相关话题标题 + 摘要 + 来源链接，供模型回答时引用。
/// 免费接口结果有限：无 Instant Answer 时返回「未找到」，模型可换关键词。
library;

import 'package:dio/dio.dart';

import '../tool_definition.dart';

ToolDefinition createWebSearchTool() {
  return ToolDefinition(
    name: 'web_search',
    description:
        '联网搜索，返回相关网页的标题与摘要（含来源链接）。'
        '免费接口结果有限，无结果时可尝试更换关键词。',
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
          options: Options(receiveTimeout: const Duration(seconds: 10)),
        );
        if (resp.statusCode != 200) {
          return ToolResult.error('搜索失败：HTTP ${resp.statusCode}');
        }
        final data = resp.data ?? const <String, dynamic>{};
        return ToolResult(content: _formatResults(data, query));
      } on DioException catch (e) {
        return ToolResult.error('搜索失败：${e.message ?? e.type}');
      } catch (e) {
        return ToolResult.error('搜索失败：$e');
      }
    },
  );
}

/// 把 DuckDuckGo 响应整理为可读文本（摘要 + 相关话题）。
String _formatResults(Map<String, dynamic> data, String query) {
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
