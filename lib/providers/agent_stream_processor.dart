import 'dart:convert';

/// 思考块类型（区分 HTML / Qwen 风格，闭合判定不同）。
enum _ThinkKind { html, qwen }

/// 智能体流式处理器：串联「思考块过滤」与「工具调用 JSON 块增量检测」。
///
/// 思考块支持两种端侧模型常见格式（按字符状态机处理，跨 token 边界）：
/// - HTML 风格：`<thinking>...</thinking>`
/// - Qwen 风格：` thinking ... response`（原生层 chatml 的 no-think 触发链）
///
/// 工具 JSON：含 `tool_call` 的完整 JSON 对象隐藏并记录；其余文本进入可见输出。
class AgentStreamProcessor {
  /// JSON 试探缓冲上限：超过则视为普通文本，放弃试探。
  static const int probeMaxLen = 2048;

  /// 已确认的可见输出（用户最终看到的文本）。
  final StringBuffer visible = StringBuffer();

  /// 思考块缓冲（丢弃用）。
  final StringBuffer thinking = StringBuffer();

  /// JSON 试探缓冲（可能形成工具调用 JSON）。
  final StringBuffer probe = StringBuffer();

  /// 本轮解析出的工具调用 JSON 块（含 `tool_call`）。
  final List<Map<String, dynamic>> toolJsonBlocks = [];

  /// 本轮解析出的 XML 工具调用块（llama.cpp 原生 `<tool_call>...</tool_call>`）。
  final List<String> toolXmlBlocks = [];

  _ThinkKind? _thinkKind;
  bool _inProbe = false;
  int _probeDepth = 0;
  StringBuffer? _xmlTool;

  /// 当前可见文本（思考过滤 + JSON 隐藏后）。
  String get visibleText => visible.toString();

  /// 是否正在思考块内（UI 可显示「思考中…」）。
  bool get thinkingActive => _thinkKind != null;

  /// 是否解析出了工具调用块（JSON 或 XML）。
  bool get hasToolCalls =>
      toolJsonBlocks.isNotEmpty || toolXmlBlocks.isNotEmpty;

  /// 处理一个 token（可含多字符；跨 token 状态自动衔接）。
  void add(String token) {
    for (var i = 0; i < token.length; i++) {
      _addChar(token[i]);
    }
  }

  /// 流结束收尾：把未闭合的 XML 工具块 / JSON 试探恢复为普通文本
  /// （思考块未闭合则丢弃——思考不该出现在最终回答）。
  void finish() {
    if (_xmlTool != null) {
      visible.write(_xmlTool!.toString());
      _xmlTool = null;
    }
    if (_inProbe) {
      visible.write(probe.toString());
      probe.clear();
      _inProbe = false;
    }
    thinking.clear();
    _thinkKind = null;
  }

  void _addChar(String ch) {
    // ---- 思考块内：只收集，检测闭合 ----
    if (_thinkKind != null) {
      thinking.write(ch);
      final t = thinking.toString();
      if (_thinkKind == _ThinkKind.html &&
          (t.endsWith('</thinking>') || t.endsWith(' response'))) {
        // ` response` 兼容 Qwen3.5 的 HTML 变体（无 `</thinking>` 闭合）。
        _thinkKind = null;
        thinking.clear();
      } else if (_thinkKind == _ThinkKind.qwen && t.endsWith(' response')) {
        _thinkKind = null;
        thinking.clear();
      }
      return;
    }

    // ---- XML 工具块内：缓冲直到闭合 ----
    if (_xmlTool != null) {
      _xmlTool!.write(ch);
      if (_xmlTool!.toString().endsWith('</tool_call>')) {
        toolXmlBlocks.add(_xmlTool!.toString());
        _xmlTool = null;
      }
      return;
    }

    // ---- JSON 试探中 ----
    if (_inProbe) {
      probe.write(ch);
      if (ch == '{') {
        _probeDepth++;
      } else if (ch == '}') {
        _probeDepth--;
        if (_probeDepth == 0) {
          _tryFinishProbe();
        }
      }
      if (_inProbe && probe.length > probeMaxLen) {
        // 试探过长：放弃，按普通文本显示。
        visible.write(probe.toString());
        probe.clear();
        _inProbe = false;
      }
      return;
    }

    // ---- 普通文本：先写入可见，检测到特殊开始再回退 ----
    visible.write(ch);
    final v = visible.toString();

    // XML 工具块开始：`<tool_call>`（Spark 训练分布）。
    const xmlTag = '<tool_call>';
    if (v.endsWith(xmlTag)) {
      visible
        ..clear()
        ..write(v.substring(0, v.length - xmlTag.length));
      _xmlTool = StringBuffer()..write(xmlTag);
      return;
    }

    // JSON 工具块开始：`{`。
    if (ch == '{') {
      visible
        ..clear()
        ..write(v.substring(0, v.length - 1));
      _inProbe = true;
      _probeDepth = 1;
      probe.write(ch);
      return;
    }

    // HTML 风格思考：`<thinking>` / ` think`（Qwen3.5 实际输出不带 ing）。
    // ` think` 是 ` thinking` 的前缀，一并覆盖带 ing 的完整变体。
    const htmlTags = ['<thinking>', ' think'];
    for (final tag in htmlTags) {
      if (v.endsWith(tag)) {
        _enterThink(_ThinkKind.html, v, tag);
        return;
      }
    }

    // Qwen 风格思考：` think`（空格 + think）触发思考链（原生层注入的
    // no-think 触发词；端侧模型实际输出不带 ing，宽松检测可接受）。
    const qwenTag = ' think';
    if (v.length >= qwenTag.length && v.endsWith(qwenTag)) {
      _enterThink(_ThinkKind.qwen, v, qwenTag);
    }
  }

  /// 进入思考态：把已写入 visible 的触发标签回退到 thinking 缓冲（后续字符全丢弃）。
  void _enterThink(_ThinkKind kind, String v, String tag) {
    final before = v.substring(0, v.length - tag.length);
    visible
      ..clear()
      ..write(before);
    thinking.write(tag);
    _thinkKind = kind;
  }

  /// 试探深度归零：尝试把 probe 解析为完整 JSON。
  /// - 含 `tool_call` → 工具调用块（隐藏）；
  /// - 否则 → 按普通文本并入可见输出。
  void _tryFinishProbe() {
    final raw = probe.toString();
    Map<String, dynamic>? decoded;
    try {
      final d = jsonDecode(raw);
      if (d is Map<String, dynamic>) decoded = d;
    } catch (_) {
      decoded = null;
    }

    if (decoded != null && decoded['tool_call'] != null) {
      toolJsonBlocks.add(decoded);
    } else {
      visible.write(raw);
    }
    probe.clear();
    _inProbe = false;
  }
}
