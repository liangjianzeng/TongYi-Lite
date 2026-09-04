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
      '数组参数：<tool_call>todo_write<arg_key>todos<arg_value>[{"content": "明天开会", "status": "todo"}]</tool_call>\n'
      '键值规则：一个 <arg_key>键名</arg_key> 后面必须紧跟 <arg_value>值</arg_value>，'
      '先键后值、一个键配一个值，值不要放进 arg_key。\n'
      '必填参数必须完整给出（如 web_search 的 query），遗漏会导致工具失败。\n'
      '收到工具结果后，根据真实结果组织最终回答。'
      '若用户要求操作（如添加待办/便签/记忆）但你未调用工具，则视为任务未完成。';

  /// LFM 系模型指令：JSON 对象格式（<tool_call> 内嵌 JSON 是 Qwen/LFM 系
  /// chat template 训练分布，小模型对 XML <arg_key> 标签遵循度差，常直接
  /// 输出普通文本导致工具不执行）。
  static const String kProtocolInstructionJson =
      '当你要调用工具时，输出以下 JSON 格式（不要任何多余文字、不要思考过程、'
      '不要先回答再补调用）：\n'
      '无参数：{"name": "get_time", "arguments": {}}\n'
      '带参数：{"name": "web_search", "arguments": {"query": "今天天气"}}\n'
      '数组参数：{"name": "todo_write", "arguments": {"todos": [{"content": "明天开会", "status": "todo"}]}}\n'
      '必填参数必须完整给出（如 web_search 的 query），遗漏会导致工具失败。\n'
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
      // 关键：列出必填参数名（对照 DSH 的 schema 呈现），
      // 让模型知道带参数工具必须给出哪些参数——根治「只调工具不带参数」。
      lines.add('- ${tool.name}: ${tool.description}${_requiredParamsHint(tool)}');
    }

    // 沙箱升级说明（对照 DSH bashDescription）：带升级能力的工具默认在
    // workspace 沙盒内运行；确需完整文件系统访问时请求用户批准。
    if (tools.any(_hasEscalation)) {
      lines.add('');
      lines.add('[沙箱说明]');
      lines.add('文件/命令类工具默认在 app workspace 沙盒内运行。'
          '确需访问公共目录/完整文件系统时，在调用中带 '
          '<arg_key>sandbox_permissions<arg_value>danger-full-access</arg_value> '
          '和 <arg_key>justification<arg_value>一句话理由</arg_value> '
          '请求用户批准；批准后仅本次调用生效。被拒时不要偷偷绕过，先解释或放弃。');
    }

    lines.add('');
    lines.add('[工具调用协议]');
    // LFM 系（Qwen/LiquidAI 训练分布）主推 JSON 格式；spark/qwen 等主推
    // XML <arg_key> 格式（各自贴近训练分布，模型遵循度更高）。
    lines.add(_instructionFor(modelId));
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
      // 格式 1：{"tool_call": {"name": ..., "arguments": {...}}}（提示词约定）。
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

      // 格式 2：顶层 {"name": ..., "arguments": {...}}（OpenAI/LFM 风格）。
      final topLevel = _decodeJsonToolCall(json);
      if (topLevel != null) {
        return StreamOutcome(
          text: before + after,
          toolCalls: [topLevel],
        );
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
    var bodyEnd = close;
    var altClosed = false;
    if (close < 0) {
      // 坏格式兼容：模型常漏 `</tool_call>`，以最后一个 `</arg_value>` /
      // `</arg_key>` 收尾（如 `<tool_call>web_search<arg_key>query<arg_key>
      // AI news today</arg_value></arg_key>`）。无任何闭合标签则不解析。
      final lastValue = text.lastIndexOf('</arg_value>');
      final lastKey = text.lastIndexOf('</arg_key>');
      final altEnd = lastValue > lastKey ? lastValue : lastKey;
      if (altEnd < open + openTag.length) return null;
      bodyEnd = altEnd;
      altClosed = true;
    }

    final body = text.substring(open + openTag.length, bodyEnd);
    final trimmed = body.trim();

    // JSON-in-XML：`<tool_call>{"name": ..., "arguments": {...}}</tool_call>`
    // （Qwen/LFM 系 chat template 训练分布：函数调用为 XML 标签内嵌 JSON
    // 对象，而非 <arg_key> 标签）。LFM2.5 等模型原生输出这种格式。
    if (trimmed.startsWith('{')) {
      final jsonCall = _decodeJsonToolCall(trimmed);
      if (jsonCall != null) {
        return (
          before: text.substring(0, open),
          after: altClosed
              ? text.substring(bodyEnd)
              : text.substring(close + closeTag.length),
          call: jsonCall,
        );
      }
      // JSON 解析失败 → 落到下方 XML 解析（容错）。
    }

    // 工具名：到第一个 <arg_key> 或 <arg_value> 之前。
    final nameMatch = RegExp(r'^\s*([^<\s]+)').firstMatch(body);
    if (nameMatch == null) return null;
    final name = nameMatch.group(1)!.trim();
    if (name.isEmpty) return null;

    // 参数对：顺序扫描 <arg_key>/<arg_value>，兼容闭合/半开标签，并**容错
    // 坏格式**——模型常见错误是把值文本直接塞进 <arg_key>（如
    // `<arg_key>query<arg_key>AI news today</arg_value>`），此时把第二个
    // <arg_key> 的文本当作 value 配对给前面的 key，一次调用即可成功。
    final arguments = _parseXmlArgs(body);

    return (
      before: text.substring(0, open),
      after: altClosed
          ? text.substring(bodyEnd) // 坏格式：闭合标签之后的残留文本
          : text.substring(close + closeTag.length),
      call: ToolCall(
        id: 'tool_${DateTime.now().microsecondsSinceEpoch}',
        name: name,
        arguments: arguments,
      ),
    );
  }

  /// 按模型选择指令：LFM 系（id 以 lfm 开头）用 JSON 风格，其余用 XML 风格。
  String _instructionFor(String modelId) {
    if (modelId.toLowerCase().startsWith('lfm')) {
      return kProtocolInstructionJson;
    }
    return kProtocolInstruction;
  }

  /// 工具是否声明了沙箱升级能力（含 `sandbox_permissions` 字段）。
  bool _hasEscalation(ToolDefinition tool) {
    final props = tool.parameters['properties'];
    return props is Map && props['sandbox_permissions'] != null;
  }

  /// 生成必填参数提示（对照 DSH schema 呈现）：`（必填: command: string）`。
  /// 带类型让模型首次调用就能填对（根治「只调工具不带参数」）。
  String _requiredParamsHint(ToolDefinition tool) {
    final required = tool.parameters['required'];
    if (required is! List || required.isEmpty) return '';
    final props = tool.parameters['properties'];
    final parts = required.map((r) {
      final name = r.toString();
      if (props is Map && props[name] is Map) {
        final type = (props[name] as Map)['type']?.toString();
        if (type != null) return '$name: $type';
      }
      return name;
    }).toList();
    return '（必填: ${parts.join(', ')}）';
  }

  /// 解码 JSON 对象形式的工具调用：`{"name": ..., "arguments": {...}}`。
  /// 用于 `<tool_call>{...}</tool_call>`（Qwen/LFM 系）与顶层 JSON 对象。
  /// 结构不符（缺 name / name 非字符串）返回 null。
  ToolCall? _decodeJsonToolCall(String jsonText) {
    Object? decoded;
    try {
      decoded = jsonDecode(jsonText);
    } catch (_) {
      return null;
    }
    if (decoded is! Map<String, dynamic>) return null;
    final name = decoded['name'];
    if (name is! String || name.isEmpty) return null;
    final args = decoded['arguments'];
    return ToolCall(
      id: 'tool_${DateTime.now().microsecondsSinceEpoch}',
      name: name,
      arguments: args is Map<String, dynamic> ? args : null,
    );
  }

  /// 顺序解析 XML 参数对（容错坏格式）。
  ///
  /// 正常：`<arg_key>key<arg_value>value` 或带闭合标签；
  /// 坏格式：`<arg_key>key<arg_key>value文本</arg_value>`（值误塞进 key 标签）
  /// → 第二个 <arg_key> 的文本被配对给 pendingKey。
  /// 孤立 value（key 缺失）忽略；残留 pendingKey（有 key 无 value）丢弃。
  Map<String, dynamic> _parseXmlArgs(String body) {
    final args = <String, dynamic>{};
    final tagRe = RegExp(r'<(arg_key|arg_value)>');
    final tags = tagRe.allMatches(body).toList();
    if (tags.isEmpty) return args;

    String? pendingKey;
    for (var i = 0; i < tags.length; i++) {
      final tag = tags[i].group(1)!;
      final valueStart = tags[i].end;
      // 标签后的文本：到下一个 '<'（含闭合标签）为止。
      final nextLt = body.indexOf('<', valueStart);
      final end = nextLt < 0 ? body.length : nextLt;
      final text = body.substring(valueStart, end).trim();
      if (text.isEmpty) continue;

      if (tag == 'arg_key') {
        if (pendingKey != null) {
          // 连续 arg_key（无中间 arg_value）= 坏格式：当前文本是值，
          // 配对给 pendingKey（如 `<arg_key>query<arg_key>AI news today</arg_value>`）。
          args[pendingKey] = _decodeXmlArgValue(text);
          pendingKey = null;
        } else {
          // 正常：文本是 key。
          pendingKey = text;
        }
      } else {
        // arg_value：文本是值，配对给 pendingKey；孤立 value 忽略。
        if (pendingKey != null) {
          args[pendingKey] = _decodeXmlArgValue(text);
          pendingKey = null;
        }
      }
    }
    return args;
  }

  /// 解码 XML 工具参数值：以 `[`/`{` 开头且以 `]`/`}` 结尾的字符串按 JSON 解析
  /// （数组/对象参数，如 todo_write 的 todos），解析失败保留原字符串。
  dynamic _decodeXmlArgValue(String raw) {
    final trimmed = raw.trim();
    if ((trimmed.startsWith('[') || trimmed.startsWith('{')) &&
        (trimmed.endsWith(']') || trimmed.endsWith('}'))) {
      try {
        return jsonDecode(trimmed);
      } catch (_) {
        return raw;
      }
    }
    return raw;
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
