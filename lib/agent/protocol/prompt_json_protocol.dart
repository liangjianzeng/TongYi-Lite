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
import '../llm/adapter.dart' show LlmFailure, LlmFailureCode;
import '../tool_definition.dart';
import '../tool_registry.dart';
import 'tool_protocol.dart';

/// prompt-JSON/XML 文本协议。
class PromptJsonProtocol implements ToolProtocol {
  static const String kId = 'prompt-json';

  /// 精简档渲染（见 `agent_tier.dart`）：true 时工具清单压成"一行一名 +
  /// 描述首句"，并省掉 [沙箱说明] 段。只影响呈现，不影响解析侧。
  /// 默认 false = 与旧版逐字节一致。
  final bool compact;

  const PromptJsonProtocol({this.compact = false});

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
      '多个相互独立的操作可在一次回复中输出多个 <tool_call> 块（将按顺序执行）；'
      '有依赖关系的操作必须等上一步结果再调用。\n'
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
      '绝对不要输出 [get_time()] 这类函数签名文本——那样不会被当作工具调用，任务会失败。\n'
      '多个相互独立的操作可在一次回复中输出多个 {"name": …} JSON 块（将按顺序执行）；'
      '有依赖关系的操作必须等上一步结果再调用。\n'
      '收到工具结果后，根据真实结果组织最终回答。'
      '若用户要求操作（如添加待办/便签/记忆）但你未调用工具，则视为任务未完成。';

  /// Ling（Bailing V3）系模型指令：**原生 XML 带闭合标签格式**（官方
  /// chat_template.jinja 训练分布：`<tool_call>` 后换行写工具名，每个参数
  /// `<arg_key>k</arg_key>` + `<arg_value>v</arg_value>` 成对闭合，一个参数
  /// 一行。1.3B 激活的 tiny 对自带格式遵循度最高，改用半开标签格式反而
  /// 掉进非训练分布导致不调用/格式坏）。
  static const String kProtocolInstructionLing =
      '当你要调用工具时，输出以下格式（工具调用块前后可以有简短说明文字）：\n'
      '无参数：<tool_call>\nget_time\n</tool_call>\n'
      '带参数：<tool_call>\nweb_search\n<arg_key>query</arg_key>\n'
      '<arg_value>今天天气</arg_value>\n</tool_call>\n'
      '数组参数：<tool_call>\ntodo_write\n<arg_key>todos</arg_key>\n'
      '<arg_value>[{"content": "明天开会", "status": "todo"}]</arg_value>\n</tool_call>\n'
      '键值规则：每个参数写一行，<arg_key>参数名</arg_key> 与 '
      '<arg_value>参数值</arg_value> 必须成对闭合，先键后值。\n'
      '必填参数必须完整给出（如 web_search 的 query），遗漏会导致工具失败。\n'
      '多个相互独立的操作可在一次回复中输出多个 <tool_call> 块（将按顺序执行）；'
      '有依赖关系的操作必须等上一步结果再调用。\n'
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
      // 精简档只留描述首句（python_exec 295 字/shell_exec 273 字这类长描述
      // 是 tiny 档 prefill 的大头，且 tiny 模型并不会因为描述更细就填对参数）。
      final desc =
          compact ? _briefDescription(tool.description) : tool.description;
      lines.add('- ${tool.name}: $desc${_requiredParamsHint(tool)}');
    }

    // 沙箱升级说明（对照 DSH bashDescription）：带升级能力的工具默认在
    // workspace 沙盒内运行；确需完整文件系统访问时请求用户批准。
    // 精简档不注入：能触发升级的只有 python/shell/文件类工具，它们已被
    // 精简档工具白名单挡在门外，留着纯属白烧 token。
    if (!compact && tools.any(_hasEscalation)) {
      lines.add('');
      lines.add('[沙箱说明]');
      lines.add('文件/命令类工具默认在 app workspace 沙盒内运行，'
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

  /// 从全文解析（B3 多调用）：按格式族依次提取**全部**工具调用块——
  /// XML `<tool_call>`（Spark/Hunyuan）→ 属性式 `<function>`（MiniCPM5）
  /// → 签名式 `[tool(arg)]`（退化输出）→ JSON 对象（LFM/Qwen）。
  /// 块外文本合并为可见文本；全部失败则整段作为普通文本回答（优雅降级）。
  StreamOutcome _parseText(String text) {
    // 0) 截断兜底（先于一切降级）：文本以未闭合的工具调用块开头
    //    （生成 token 预算不足，JSON/`</tool_call>` 被拦腰截断）。旧行为是
    //    整段当普通回答 → turn 静默"完成"，任务半途而废且无提示——
    //    正是"迭代一两下就停、输出没完成任务"的静默卡死路径。现在按
    //    完整性分类：结构完整（仅缺收尾括号）→ 补全执行；断在参数内容里
    //    → 抛 toolCallTruncated 失败，交失败瀑布重试并在 UI 明确报错；
    //    补完括号仍非法的语法错误 → 继续走下面的容错解析（不误报截断）。
    final truncation = _truncatedToolCall(text);
    if (truncation != null) {
      final repaired = truncation.repairedJson;
      if (repaired == null) {
        // 断在字符串/参数内容内部：内容真丢了，不可修复。
        throw toolCallTruncatedFailure();
      }
      final call = _decodeToolCallAnyForm(repaired);
      if (call != null) {
        final head = text.substring(0, truncation.start);
        return StreamOutcome(text: head, toolCalls: [call]);
      }
      // 补齐收尾括号后仍解不出 JSON ⇒ 这不是预算截断，而是模型自己的
      // 语法错误（如用 `;` 代替 `,`）。预算截断只有两种形态：断在字符串
      // 内部（上面已抛）、纯缺收尾括号（补全后即可解码），都不会落到这里。
      // 语法错误落回下方容错解析 —— 保持"解析失败优雅降级为文本"的
      // 协议契约，不误报"token 预算不足"误导用户去调设置。
    }

    // 1) XML tool_call 格式（Spark/Hunyuan 训练分布常见）——全部块。
    final xmlAll = _extractAllXmlToolCalls(text);
    if (xmlAll != null) {
      return StreamOutcome(text: xmlAll.residual, toolCalls: xmlAll.calls);
    }

    // 1b) 属性式 <function name=…><parameter name=…> 格式（MiniCPM5/Hunyuan
    //     系原生工具标记，特殊 token 渲染后可见）。有无 <tool_call> 包裹均可。
    final funcAll = _extractAllFunctionToolCalls(text);
    if (funcAll != null) {
      return StreamOutcome(text: funcAll.residual, toolCalls: funcAll.calls);
    }

    // 2) [tool_name(arg)] 函数签名式调用（LFM 等模型退化输出，
    //    如 [get_time()]、[web_search("今天天气")]）。签名式无法可靠映射
    //    多参数，维持首块语义。
    final bracketCall = _matchBracketCall(text);
    if (bracketCall != null) {
      return StreamOutcome(
        text: bracketCall.before + bracketCall.after,
        toolCalls: [bracketCall.call],
      );
    }

    // 3) JSON 格式（提示词约定的主格式）——全部可解码对象。
    final jsonAll = _extractAllJsonToolCalls(text);
    if (jsonAll != null) {
      return StreamOutcome(text: jsonAll.residual, toolCalls: jsonAll.calls);
    }

    _noLeakFallback(text);
    return StreamOutcome(text: text);
  }

  /// 工具调用 id 生成（B3：同一步多调用不撞 id）。
  static String _callId(int index) =>
      'tool_${DateTime.now().microsecondsSinceEpoch}_$index';

  /// 提取**全部** XML `<tool_call>` 块（含 MiniCPM 特殊标记变体）。
  ///
  /// 返回 (残差文本, 按序调用列表)；首块存在但解析失败 → 返回 null
  /// （整体回落其它格式族，保持既有失败语义）；后续块解析失败时其文本
  /// 保留在残差里继续收集（优雅降级，不吞掉已解析的调用）。
  ({String residual, List<ToolCall> calls})? _extractAllXmlToolCalls(
      String text) {
    const openTag = '<tool_call>';
    const miniOpenTag = '<|tool_call_start|>';
    final calls = <ToolCall>[];
    final residualParts = <String>[];
    var cursor = 0;
    var seenAnyOpen = false;
    while (true) {
      final openPlain = text.indexOf('<tool_call>', cursor);
      final openMini = text.indexOf('<|tool_call_start|>', cursor);
      final int open;
      final bool useMini;
      if (openPlain < 0 && openMini < 0) {
        open = -1;
        useMini = false;
      } else if (openMini < 0 || (openPlain >= 0 && openPlain < openMini)) {
        open = openPlain;
        useMini = false;
      } else {
        open = openMini;
        useMini = true;
      }
      if (open < 0) break;
      seenAnyOpen = true;
      residualParts.add(text.substring(cursor, open));
      final effOpenTag = useMini ? miniOpenTag : openTag;
      final effCloseTag =
          useMini ? '<|tool_call_end|>' : '</tool_call>';
      final parsed = _parseXmlToolCallAt(text, open, effOpenTag, effCloseTag,
          index: calls.length);
      if (parsed == null) {
        if (calls.isEmpty) return null; // 首块坏 → 回落其它格式
        // 后续块坏：文本保留（防泄漏兜底在 _parseText 尾部统一裁决），
        // 跳过开标签防死循环。
        cursor = open + effOpenTag.length;
        continue;
      }
      calls.add(parsed.call);
      cursor = parsed.end;
    }
    if (!seenAnyOpen) return null;
    residualParts.add(text.substring(cursor));
    return (residual: residualParts.join(), calls: calls);
  }

  /// 解析 `open` 处的一个 XML 工具调用块，返回 (call, 块结束索引)。
  /// [effOpenTag]/[effCloseTag] 由调用方选定（普通/MiniCPM 变体）；
  /// [index] 为本步第几个调用（id 防撞）。
  /// 坏格式（漏闭合）兼容：以最后一个 `</arg_value>`/`</arg_key>` 收尾，
  /// 或漏 `>` 的 `</tool_call` 松闭合。
  ({ToolCall call, int end})? _parseXmlToolCallAt(
      String text, int open, String effOpenTag, String effCloseTag,
      {int index = 0}) {
    final close = text.indexOf(effCloseTag, open + effOpenTag.length);
    var bodyEnd = close;
    var altClosed = false;
    if (close < 0) {
      // 坏格式兼容：模型常漏 `</tool_call>`，以最后一个 `</arg_value>` /
      // `</arg_key>` 收尾。无任何闭合标签则不解析。
      final lastValue = text.lastIndexOf('</arg_value>');
      final lastKey = text.lastIndexOf('</arg_key>');
      final altEnd = lastValue > lastKey ? lastValue : lastKey;
      if (altEnd >= open + effOpenTag.length) {
        bodyEnd = altEnd;
        altClosed = true;
      } else {
        // 再退一步：闭合标签漏了 `>`（`</tool_call`）也能定位块尾；
        // MiniCPM5 系漏 `<|tool_call_end|>` 尾段同理。
        final loose = effCloseTag == '</tool_call>'
            ? text.indexOf('</tool_call', open + effOpenTag.length)
            : text.indexOf('<|tool_call_end', open + effOpenTag.length);
        if (loose < 0) return null;
        bodyEnd = loose;
        altClosed = true;
      }
    }

    final body = text.substring(open + effOpenTag.length, bodyEnd);
    final trimmed = body.trim();

    // JSON-in-XML：`<tool_call>{"name": ..., "arguments": {...}}</tool_call>`
    // （Qwen/LFM 系 chat template 训练分布）。LFM2.5 / MiniCPM5 原生输出。
    if (trimmed.startsWith('{')) {
      final jsonCall = _decodeJsonToolCall(trimmed, index: index);
      if (jsonCall != null) {
        return (
          call: jsonCall,
          end: altClosed
              ? bodyEnd
              : close + effCloseTag.length,
        );
      }
      // JSON 解析失败 → 落到下方 XML 解析（容错）。
    }

    // 工具名：到第一个 <arg_key> 或 <arg_value> 之前。
    // 容错（2026-09-30 真机定案）：2B 级模型常在名字前后混入杂散标签字符
    // （实测 `<tool_call><get_time</tool_call>`），先剥掉名字前的
    // `<`/`>`/`/`/空白再提取；剥完若是 arg_key/arg_value 说明模型没写
    // 工具名、直接进了参数区 → 无法解析。
    final cleanedBody =
        body.trim().replaceAll(RegExp(r'^[<>/\s]+'), '').trim();
    final nameMatch =
        RegExp(r'^([A-Za-z_][A-Za-z0-9_.\-]*)').firstMatch(cleanedBody);
    if (nameMatch == null) return null;
    final name = nameMatch.group(1)!.trim();
    if (name.isEmpty ||
        name == 'arg_key' ||
        name == 'arg_value' ||
        name == 'tool_call' ||
        // `<function name=…>` 属性式格式 → 交给 _extractAllFunctionToolCalls。
        name == 'function' ||
        name == 'parameter') {
      return null;
    }

    // 参数对：顺序扫描 <arg_key>/<arg_value>，兼容闭合/半开标签，并**容错
    // 坏格式**——模型常见错误是把值文本直接塞进 <arg_key>。
    final arguments = _parseXmlArgs(body);

    return (
      call: ToolCall(
        id: _callId(index),
        name: name,
        arguments: arguments,
      ),
      end: altClosed
          ? bodyEnd // 坏格式：闭合标签之前的残留文本归入下一轮残差
          : close + effCloseTag.length,
    );
  }

  /// 提取**全部**属性式 `<function name=…>` 块（MiniCPM5/Hunyuan 原生格式）。
  /// 无可解析块返回 null（整体回落其它格式族）。
  ({String residual, List<ToolCall> calls})? _extractAllFunctionToolCalls(
      String text) {
    final fnRe = RegExp(r'<function\s+name\s*=\s*"([^"]+)"\s*>');
    final paramRe = RegExp(
      r'<parameter\s+name\s*=\s*"([^"]+)"\s*>(.*?)(?:</parameter>|(?=<parameter)|$)',
      dotAll: true,
    );
    final calls = <ToolCall>[];
    final residualParts = <String>[];
    var cursor = 0;
    var index = 0;
    for (final fn in fnRe.allMatches(text)) {
      if (fn.start < cursor) continue; // 已被上一块消费
      final name = fn.group(1)!.trim();
      if (name.isEmpty) {
        cursor = fn.end;
        continue;
      }
      residualParts.add(text.substring(cursor, fn.start));
      // 块结束先定位（`</function>` 优先，缺省时 `</tool_call>`），
      // 参数扫描限定在本块内——防止下一块的 <parameter> 被吸进当前块。
      final after = text.substring(fn.end);
      var end = text.length;
      final fnClose = after.indexOf('</function>');
      if (fnClose >= 0) {
        end = fn.end + fnClose + '</function>'.length;
      } else {
        final tcClose = after.indexOf('</tool_call>');
        if (tcClose >= 0) end = fn.end + tcClose + '</tool_call>'.length;
      }
      final arguments = <String, dynamic>{};
      for (final p in paramRe.allMatches(text.substring(fn.end, end))) {
        final k = p.group(1)!.trim();
        var v = p.group(2)?.trim() ?? '';
        if (k.isEmpty) continue;
        // 值尽量还原类型：数组/对象走 JSON，数字/布尔按字面量，其余字符串。
        final decoded = _tryDecodeScalar(v);
        arguments[k] = decoded ?? v;
      }
      calls.add(ToolCall(id: _callId(index++), name: name, arguments: arguments));
      cursor = end;
    }
    if (calls.isEmpty) return null;
    residualParts.add(text.substring(cursor));
    return (residual: residualParts.join(), calls: calls);
  }

  /// 防泄漏兜底（2026-09-30 真机定案）：所有容错解析都解不开，但文本里
  /// 明确有工具调用标记——模型**想调用工具但格式坏了**。此时绝不把原始
  /// 工具标签当普通回答漏给用户（用户看到的就是一串 tool 标签），改抛
  /// [LlmFailureCode.toolCallSyntax] 进入可重试失败瀑布：重新采样 +
  /// 「上次尝试失败」反思注记，模型按正确格式重写。
  /// 纯文本回答（无工具标记）不受影响。
  void _noLeakFallback(String text) {
    if (RegExp(r'<\s*/?\s*(tool_call|function|parameter)\b').hasMatch(text)) {
      throw const LlmFailure(
        code: LlmFailureCode.toolCallSyntax,
        message: '工具调用块语法错误（<tool_call>/<function> 格式坏），无法解析执行。'
            '请严格按约定格式重写：无参数 <tool_call>get_time</tool_call>；'
            '带参数 <tool_call>web_search<arg_key>query<arg_value>…</tool_call>'
            '（或 JSON {"name":…,"arguments":…}），不要混入多余字符。',
      );
    }
  }

  /// 标量值还原：JSON 可解（数组/对象/带引号字符串）→ 解码；纯数字/布尔 →
  /// 对应类型；否则保持字符串。
  Object? _tryDecodeScalar(String v) {
    if (v.isEmpty) return v;
    if (v.startsWith('[') || v.startsWith('{')) {
      try {
        return jsonDecode(v);
      } catch (_) {
        return v;
      }
    }
    if (v == 'true') return true;
    if (v == 'false') return false;
    final n = num.tryParse(v);
    if (n != null && RegExp(r'^-?\d+(\.\d+)?$').hasMatch(v)) return n;
    return v;
  }

  /// 提取**全部**可解码为工具调用的 JSON 对象（顶层 `{"name":...}` 与
  /// 包裹式 `{"tool_call": {...}}`）。无可解码对象返回 null（保持既有
  /// 优雅降级语义）；对象解码失败时其文本保留在残差里继续扫描。
  ({String residual, List<ToolCall> calls})? _extractAllJsonToolCalls(
      String text) {
    final calls = <ToolCall>[];
    final residualParts = <String>[];
    var cursor = 0;
    var index = 0;
    while (true) {
      final open = text.indexOf('{', cursor);
      if (open < 0) break;
      final extracted = _extractFirstJsonObject(text.substring(open));
      if (extracted == null) break; // 括号不平衡（截断），无更多完整对象
      final end = open + extracted.json.length;
      // 包裹式 {"tool_call": {...}} → 解码内层；顶层 → _decodeJsonToolCall。
      ToolCall? call;
      Object? decoded;
      try {
        decoded = jsonDecode(extracted.json);
      } catch (_) {
        decoded = null;
      }
      if (decoded is Map<String, dynamic>) {
        final wrapped = decoded['tool_call'];
        if (wrapped is Map<String, dynamic>) {
          if (wrapped['name'] is String) {
            call = _decodeJsonToolCall(jsonEncode(wrapped), index: index);
          }
        }
        if (call == null) {
          call = _decodeJsonToolCall(extracted.json, index: index);
        }
      }
      if (call != null) {
        residualParts.add(text.substring(cursor, open));
        calls.add(call);
        index++;
        cursor = end;
      } else {
        // 不是工具调用的合法 JSON（如普通 JSON 回答）→ 文本保留。
        residualParts.add(text.substring(cursor, end));
        cursor = end;
      }
    }
    if (calls.isEmpty) return null;
    residualParts.add(text.substring(cursor));
    return (residual: residualParts.join(), calls: calls);
  }

  /// 按模型选择指令：LFM 系（id 以 lfm 开头）用 JSON 风格；Ling/Bailing 系
  /// （id 以 ling 开头）用原生闭合标签 XML 风格（Bailing V3 训练分布）；
  /// 其余用半开标签 XML 风格。
  String _instructionFor(String modelId) {
    final lower = modelId.toLowerCase();
    if (lower.startsWith('lfm')) {
      return kProtocolInstructionJson;
    }
    if (lower.startsWith('ling')) {
      return kProtocolInstructionLing;
    }
    return kProtocolInstruction;
  }

  /// 工具是否声明了沙箱升级能力（含 `sandbox_permissions` 字段）。
  bool _hasEscalation(ToolDefinition tool) {
    final props = tool.parameters['properties'];
    return props is Map && props['sandbox_permissions'] != null;
  }

  /// 精简档描述压缩：只留描述首句（按换行/。/；/括号断句，保底 12 字不被切没，
  /// 上限 48 字）。必填参数标注由 [_requiredParamsHint] 单独追加，不受瘦身影响
  /// ——「参数填不全」是端侧头号失败模式，宁可砍描述也不砍必填提示。
  static const int _kBriefDescriptionMaxChars = 48;

  String _briefDescription(String description) {
    var s = description.trim();
    final nl = s.indexOf('\n');
    if (nl > 0) s = s.substring(0, nl);
    for (final sep in const ['。', '；', ';', '（必填', '（注意', '(必填']) {
      final i = s.indexOf(sep);
      if (i >= 12) s = s.substring(0, i);
    }
    s = s.trim();
    if (s.length > _kBriefDescriptionMaxChars) {
      s = s.substring(0, _kBriefDescriptionMaxChars).trim();
    }
    return s.isEmpty ? description.trim() : s;
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

  /// 签名式单参工具的命名参数映射：`[web_search("x")]` → {query: "x"}。
  static const Map<String, String> _bracketArgKeys = {
    'web_search': 'query',
    'get_weather': 'location',
    'calculator': 'expression',
  };

  /// 匹配 [tool_name(arg)] 函数签名式调用（LFM 等模型退化输出，如
  /// `[get_time()]`、`[web_search("今天天气")]`）。无参数 → 空参数调用；
  /// 单参数 → 按映射表对应命名参数；多参数/未知工具不解析（避免错误执行）。
  ({String before, String after, ToolCall call})? _matchBracketCall(String text) {
    final re = RegExp(r'\[\s*([A-Za-z_][A-Za-z0-9_]*)\s*\(([^)]*)\)\s*\]');
    final m = re.firstMatch(text);
    if (m == null) return null;
    final name = m.group(1)!.trim();
    if (name.isEmpty) return null;
    final argsStr = m.group(2)!.trim();
    Map<String, dynamic>? arguments;
    if (argsStr.isNotEmpty) {
      // 逗号分隔多个参数 → 无法可靠映射命名参数，不解析（避免错误执行）。
      if (argsStr.contains(',')) return null;
      final key = _bracketArgKeys[name];
      if (key == null) return null; // 未知工具参数名映射 → 不解析
      final value = argsStr.trim();
      // 去掉首尾引号（单/双引号）。
      final unquoted = value.length >= 2 &&
              ((value.startsWith('"') && value.endsWith('"')) ||
                  (value.startsWith("'") && value.endsWith("'")))
          ? value.substring(1, value.length - 1)
          : value;
      arguments = {key: unquoted};
    }
    return (
      before: text.substring(0, m.start),
      after: text.substring(m.end),
      call: ToolCall(
        id: 'tool_${DateTime.now().microsecondsSinceEpoch}',
        name: name,
        arguments: arguments,
      ),
    );
  }

  /// 解码 JSON 对象形式的工具调用：`{"name": ..., "arguments": {...}}`。
  /// 用于 `<tool_call>{...}</tool_call>`（Qwen/LFM 系）与顶层 JSON 对象。
  /// 结构不符（缺 name / name 非字符串）返回 null。
  ToolCall? _decodeJsonToolCall(String jsonText, {int index = 0}) {
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
      id: _callId(index),
      name: name,
      arguments: args is Map<String, dynamic> ? args : null,
    );
  }

  /// 宽容解码：先试 `{"tool_call": {...}}` 包裹式，再试顶层
  /// `{"name": ...}` 式（提示词约定的两种格式）。用于截断修复路径。
  ToolCall? _decodeToolCallAnyForm(String jsonText) {
    try {
      final decoded = jsonDecode(jsonText);
      if (decoded is Map<String, dynamic>) {
        final wrapped = decoded['tool_call'];
        if (wrapped is Map<String, dynamic>) {
          return _decodeJsonToolCall(jsonEncode(wrapped));
        }
      }
    } catch (_) {
      // 落到顶层解码（其内部自带 try-catch）。
    }
    return _decodeJsonToolCall(jsonText);
  }

  // ---------------------------------------------------------------------------
  // B4：assistant 历史回放（模型在上下文里看见自己发过的调用）
  // ---------------------------------------------------------------------------

  @override
  String? replayToolCalls(
      String modelId, List<Map<String, dynamic>> toolCalls) {
    if (toolCalls.isEmpty) return null;
    final lower = modelId.toLowerCase();
    final buf = StringBuffer();
    var index = 0;
    for (final tc in toolCalls) {
      final name = ((tc['function_name'] ?? tc['name']) as String?) ?? '';
      if (name.isEmpty) continue;
      final args = tc['arguments'];
      if (lower.startsWith('lfm')) {
        // LFM/Qwen：JSON 对象（与 kProtocolInstructionJson 一致）。
        buf.writeln(jsonEncode(<String, dynamic>{
          'name': name,
          'arguments': args is Map<String, dynamic> ? args : <String, dynamic>{},
        }));
      } else if (lower.startsWith('ling')) {
        // Ling/Bailing V3：闭合标签 XML（与 kProtocolInstructionLing 一致）。
        buf.writeln('<tool_call>');
        buf.writeln(name);
        if (args is Map) {
          args.forEach((k, v) {
            buf.writeln('<arg_key>$k</arg_key>');
            buf.writeln('<arg_value>${_argText(v)}</arg_value>');
          });
        }
        buf.writeln('</tool_call>');
      } else {
        // Spark/Qwen 系：半开标签 XML（与 kProtocolInstruction 一致）。
        buf.write('<tool_call>$name');
        if (args is Map) {
          args.forEach((k, v) {
            buf.write('<arg_key>$k<arg_value>${_argText(v)}</arg_value>');
          });
        }
        buf.writeln('</tool_call>');
      }
      index++;
    }
    if (index == 0) return null;
    return buf.toString().trimRight();
  }

  /// 参数值文本化：字符串原样（模型当初就是裸文本输出），其余 JSON 编码。
  static String _argText(Object? v) {
    if (v == null) return '';
    if (v is String) return v;
    try {
      return jsonEncode(v);
    } catch (_) {
      return '$v';
    }
  }

  /// 顺序解析 XML 参数对（容错坏格式）。
  ///
  /// 状态机只有两个位置：**等 key** / **等 value**。每遇到一个参数标签
  /// （开闭都算），其后到下一个 `<` 之前的文本按当前位置归属：
  /// - 等 key 时遇到 arg_key 类标签 → 文本是键名；
  /// - 等 value 时遇到任何参数标签 → 文本是值，配对完成。
  ///
  /// 覆盖的坏格式（真机 Ornith 1.5 9B 实锤，2026-11-09）：
  /// - 正常 `<arg_key>query<arg_value>今天天气`；带闭合 `<arg_key>city</arg_key><arg_value>南宁</arg_value>`；
  /// - **闭合标签用错** `<arg_key>city</arg_value>南宁`——旧实现只匹配**开标签**
  ///   `<(arg_key|arg_value)>`，这种写法只产出一个 key 段，值段前面没有开标签
  ///   → 永不配对 → 参数 `{}` → 工具报「缺少必填参数 city」→ 模型反复重试
  ///   同一调用直到步数耗尽（真机三步全废）。**开/闭一律当分隔符**即修复此案。
  /// - 值误塞进 key 标签 `<arg_key>query<arg_key>AI news today</arg_value>`
  ///   （第二个标签时已在"等 value"位 → 文本自然配成值，与旧行为等价）。
  /// - 标签内混空白 `<arg_key >k<arg_value>v`（旧正则要求 `>` 紧跟，真机残片
  ///   常见形态之一）。
  /// 孤立 value（还没拿到 key）忽略；残留 pendingKey（有 key 无 value）丢弃。
  Map<String, dynamic> _parseXmlArgs(String body) {
    final args = <String, dynamic>{};
    final tagRe = RegExp(r'<\s*(/?)(arg_key|arg_value)\s*>');
    final tags = tagRe.allMatches(body).toList();
    if (tags.isEmpty) return args;

    String? pendingKey;
    for (final t in tags) {
      final kind = t.group(2)!;
      // 标签后的文本：到下一个 '<'（含任何闭合标签）为止。
      final nextLt = body.indexOf('<', t.end);
      final end = nextLt < 0 ? body.length : nextLt;
      final text = body.substring(t.end, end).trim();
      if (text.isEmpty) continue; // 空段不改变状态（闭合标签常紧跟开标签）

      if (pendingKey == null) {
        // 等 key：只有 arg_key 类标签的文本算键名；孤立 arg_value 忽略。
        if (kind == 'arg_key') pendingKey = text;
      } else {
        // 等 value：任何参数标签（开或闭）后的文本都配对成值。
        args[pendingKey] = _decodeXmlArgValue(text);
        pendingKey = null;
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

  // ---------------------------------------------------------------------------
  // 截断工具调用检测与修复（token 预算不足的静默卡死根治）
  // ---------------------------------------------------------------------------

  /// 检测文本中的**截断工具调用**：XML 有 `<tool_call>` 但整个文本没有
  /// 收尾（`</tool_call>` / `</arg_key>` / `</arg_value>`），或 JSON 从
  /// `{"name"` 起手但括号/字符串未闭合。
  ///
  /// 返回 null = 不存在截断的调用（正常文本 / 完整调用，走原解析）。
  /// 返回非 null：`repairedJson` 非空 = 结构完整可补全（仅缺收尾括号，
  /// 未断在字符串内部，参数无损）；为空 = 参数内容真丢了，不可修复。
  ({int start, String? repairedJson})? _truncatedToolCall(String text) {
    // XML：有开标签且全文无任何收尾标记（有收尾时即便格式坏也走原容错解析；
    // `</tool_call` 漏 `>` 与 `<|tool_call_end|>` 系都算有收尾，交回 XML 容错）。
    final xmlOpen = text.indexOf('<tool_call>');
    final miniOpen = text.indexOf('<|tool_call_start|>');
    if ((xmlOpen >= 0 || miniOpen >= 0) &&
        !text.contains('</tool_call') &&
        !text.contains('<|tool_call_end') &&
        !text.contains('</arg_key>') &&
        !text.contains('</arg_value>')) {
      final head = xmlOpen >= 0 ? xmlOpen : miniOpen;
      final tagLen = xmlOpen >= 0 ? '<tool_call>'.length : '<|tool_call_start|>'.length;
      final body = text.substring(head + tagLen).trimLeft();
      // JSON-in-XML 且结构只差收尾 → 可补全。
      if (body.startsWith('{')) {
        final rep = _repairTruncatedJsonObject(body);
        return (start: head, repairedJson: rep);
      }
      return (start: head, repairedJson: null);
    }

    // JSON：首个平衡对象缺失时，若文本以 `{"name"` 或 `{"tool_call"`
    // 起手则判为截断调用（两种提示词约定格式都覆盖）。
    final open = text.indexOf('{');
    if (open < 0) return null;
    if (_extractFirstJsonObject(text) != null) return null; // 有完整对象
    final afterBrace = text.substring(open + 1);
    if (!RegExp(r'^\s*"(?:name|tool_call)"\s*:').hasMatch(afterBrace)) {
      return null;
    }
    final rep = _repairTruncatedJsonObject(text.substring(open));
    return (start: open, repairedJson: rep);
  }

  /// 修复只差收尾括号/逗号的 JSON 对象文本：字符串字面量未闭合（参数断在
  /// 内容中间）→ 返回 null（不可修复，绝不伪造半截参数去执行）；
  /// 否则按括号栈补 `"]}` 等收尾返回修复文本（纯语法补全，是否真能解出
  /// 工具调用由调用方解码判定）。
  String? _repairTruncatedJsonObject(String src) {
    var depth = 0;
    var inString = false;
    var escaped = false;
    for (var i = 0; i < src.length; i++) {
      final ch = src[i];
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
        case '[':
          depth++;
          break;
        case '}':
        case ']':
          depth--;
          break;
      }
    }
    if (depth <= 0) return null; // 并非"只差收尾"（或本就平衡），交回原逻辑
    if (inString) return null; // 断在字符串内部：参数内容丢失，不可修复
    var trimmed = src.trimRight();
    while (trimmed.endsWith(',')) {
      trimmed = trimmed.substring(0, trimmed.length - 1);
    }
    // 按"先闭合未闭合容器"朴素补全（对象/数组统一用栈计数补全括号种类，
    // 但小模型工具调用几乎恒为纯对象嵌套，直接按剩余层数补 '}' 即可）。
    // 只补括号、不做解码：能否真正解出工具调用由调用方判定（区分
    // "预算截断"与"模型语法错误"）。
    return '$trimmed${'}' * depth}';
  }
}

/// 工具调用截断失败（协议 → 主循环失败瀑布的约定信号）。
LlmFailure toolCallTruncatedFailure() => const LlmFailure(
      code: LlmFailureCode.toolCallTruncated,
      message: '工具调用生成不完整（输出 token 预算不足被截断）：'
          '请在设置中调大「智能体每轮生成 token」后重试',
    );
