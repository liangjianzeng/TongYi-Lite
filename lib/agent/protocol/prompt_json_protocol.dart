/// prompt-JSON/XML 文本协议 —— 当前本地引擎的兜底工具协议。
///
/// 原理：把工具清单 + 调用协议注入系统提示，要求模型输出工具调用块：
/// - JSON：`{"tool_call": {"name": "get_time", "arguments": {}}}`
/// - XML：`<tool_call>web_search<arg_key>query<arg_value>今天天气</tool_call>`
/// （真机实测 Spark/Qwen 均输出 XML 原生格式 → 提示词以 XML 呈现，遵循率更高；
///  解析器双格式兼容。）
///
/// 生成侧从文本增量流中提取完整工具调用块，解析失败时**优雅降级**
/// 为普通文本回答 —— 模型没学会调用也不阻塞对话。
library;

import 'dart:convert';

import '../capability.dart';
import '../tool_definition.dart';
import '../tool_registry.dart';
import 'tool_protocol.dart';

/// prompt-JSON/XML 文本协议。
class PromptJsonProtocol implements ToolProtocol {
  static const String kId = 'prompt-json';

  /// 协议指令（模型看到的部分）：XML 格式（贴近端侧模型训练分布）。
  static const String kProtocolInstruction =
      '当你要调用工具时，输出以下 XML 格式（不要任何多余文字、不要思考过程、'
      '不要先回答再补调用）：\n'
      '无参数：<tool_call>get_time</tool_call>\n'
      '带参数：<tool_call>web_search<arg_key>query<arg_value>今天天气</tool_call>\n'
      '收到工具结果后，根据真实结果组织最终回答。'
      '若用户要求操作（如添加待办/便签/记忆）但你未调用工具，则视为任务未完成。';

  @override
  String get id => kId;

  /// 兜底协议：任何能力都可用。
  @override
  bool supports(EngineCapabilities caps) => true;

  /// 最低优先级（原生/结构化协议存在时让位）。
  @override
  int priority(EngineCapabilities caps) => 0;

  @override
  String buildToolSection(ToolRegistry registry, {String modelId = ''}) {
    final tools = registry.visibleFor(modelId);
    if (tools.isEmpty) return '';
    final lines = <String>['[可用工具]'];
    for (final tool in tools) {
      // 文本格式（贴近端侧模型训练分布）：`- name: description`，
      // 而非完整 JSON Schema（小模型更易理解）。
      lines.add('- ${tool.name}: ${tool.description}');
    }
    lines.add('');
    lines.add('[工具调用协议]');
    lines.add(kProtocolInstruction);
    return lines.join('\n');
  }

  @override
  Future<StreamOutcome> parseStream(Stream<String> stream) async {
    final buffer = StringBuffer();
    await for (final token in stream) {
      if (token.isNotEmpty) buffer.write(token);
    }
    return _parseText(buffer.toString());
  }

  /// 从全文解析：优先 XML `<tool_call>`（llama.cpp 原生格式），
  /// 再试 JSON 对象；都失败则整段作为普通文本回答（优雅降级）。
  StreamOutcome _parseText(String text) {
    // 1) XML tool_call 格式（Spark/Hunyuan 训练分布常见）。
    final xmlCall = _extractXmlToolCall(text);
    if (xmlCall != null) {
      return StreamOutcome(
        text: xmlCall.before + xmlCall.after,
        toolCalls: [xmlCall.call],
      );
    }

    // 2) JSON 格式（提示词约定的主格式）。
    final extracted = _extractFirstJsonObject(text);
    if (extracted == null) return StreamOutcome(text: text);

    final (:json, :before, :after) = extracted;
    Object? decoded;
    try {
      decoded = jsonDecode(json);
    } catch (_) {
      // JSON 解析失败 → 整段视为普通回答。
      return StreamOutcome(text: text);
    }

    if (decoded is Map<String, dynamic>) {
      final toolCall = decoded['tool_call'];
      if (toolCall is Map<String, dynamic>) {
        final name = toolCall['name'];
        if (name is String && name.isNotEmpty) {
          final args = toolCall['arguments'];
          return StreamOutcome(
            text: before + after,
            toolCalls: [
              ToolCall(
                id: 'tool_${DateTime.now().microsecondsSinceEpoch}',
                name: name,
                arguments: args is Map<String, dynamic> ? args : null,
              ),
            ],
          );
        }
      }
    }

    // 是合法 JSON 但不是工具调用 → 整段视为普通回答。
    return StreamOutcome(text: text);
  }

  /// 提取 XML 格式的工具调用（llama.cpp 原生 / Spark 训练分布）：
  /// `<tool_call>name<arg_key>k1<arg_value>v1</arg_value></arg_key>...</tool_call>`
  /// 兼容半开标签（无 `</arg_key>`/`</arg_value>` 闭合）。
  ({String before, String after, ToolCall call})? _extractXmlToolCall(
      String text) {
    const openTag = '<tool_call>';
    const closeTag = '</tool_call>';
    final open = text.indexOf(openTag);
    if (open < 0) return null;
    final close = text.indexOf(closeTag, open + openTag.length);
    if (close < 0) return null; // 未闭合 → 不解析（避免误判为普通文本）

    final body = text.substring(open + openTag.length, close);

    // 工具名：到第一个 <arg_key> 或 <arg_value> 之前。
    final nameMatch = RegExp(r'^\s*([^<\s]+)').firstMatch(body);
    if (nameMatch == null) return null;
    final name = nameMatch.group(1)!.trim();
    if (name.isEmpty) return null;

    // 参数对：独立提取 <arg_key>KEY 与 <arg_value>VALUE 再按序配对
    // （兼容闭合标签与半开标签两种变体）。
    final keyRe = RegExp(r'<arg_key>\s*([^<]+)');
    final valueRe = RegExp(r'<arg_value>\s*([^<]+)');
    final keys = keyRe
        .allMatches(body)
        .map((m) => m.group(1)!.trim())
        .where((k) => k.isNotEmpty)
        .toList();
    final values = valueRe
        .allMatches(body)
        .map((m) => m.group(1)!.trim())
        .where((v) => v.isNotEmpty)
        .toList();
    final arguments = <String, dynamic>{};
    for (var i = 0; i < keys.length && i < values.length; i++) {
      arguments[keys[i]] = values[i];
    }

    return (
      before: text.substring(0, open),
      after: text.substring(close + closeTag.length),
      call: ToolCall(
        id: 'tool_${DateTime.now().microsecondsSinceEpoch}',
        name: name,
        arguments: arguments,
      ),
    );
  }

  /// 提取文本中第一个完整的 JSON 对象。
  ///
  /// 返回 `(jsonText, 前导文本, 尾随文本)`；找不到完整对象时返回 null。
  /// 平衡括号扫描会跳过字符串字面量内的 `{`/`}`（含转义）。
  ({String json, String before, String after})? _extractFirstJsonObject(
      String text) {
    final open = text.indexOf('{');
    if (open < 0) return null;

    var depth = 0;
    var inString = false;
    var escaped = false;
    for (var i = open; i < text.length; i++) {
      final ch = text[i];
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (ch == r'\') {
          escaped = true;
        } else if (ch == '"') {
          inString = false;
        }
        continue;
      }
      switch (ch) {
        case '"':
          inString = true;
          break;
        case '{':
          depth++;
          break;
        case '}':
          depth--;
          if (depth == 0) {
            return (
              json: text.substring(open, i + 1),
              before: text.substring(0, open),
              after: text.substring(i + 1),
            );
          }
          break;
      }
    }
    // 括号不平衡（模型输出被截断）→ 视为无完整 JSON。
    return null;
  }
}
