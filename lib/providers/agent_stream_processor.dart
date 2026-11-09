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

  /// **跨块累计**的思考字数。
  ///
  /// [thinking] 每遇一个闭合记号就 clear（单块口径），小模型爱
  /// `think…response…think…response` 反复横跳 → 单块口径下总量无上限，
  /// 思考失控守卫（agentThinkingMaxChars）形同虚设。失控判定必须用本字段。
  int _totalThinkingChars = 0;
  int get totalThinkingChars => _totalThinkingChars;

  /// 「算已产出」的最小可见字数。
  ///
  /// 门槛存在的理由：模型常在思考前先吐一句引导语（「好的」「我来看看」），
  /// 若把任何非空可见文本都当产出，思考失控守卫就永远不触发（实测：
  /// 开头两句寒暄即可让 4 万字独白畅通无阻）。低于此字数视为寒暄，不算产出。
  static const int kMinUsefulChars = 80;

  /// 本步是否已产出任何有用内容（够长的可见文本，或工具调用）。
  /// 思考预算只在「还没产出」时用来止损，避免误杀长思考后正常作答。
  bool get producedAnything =>
      hasToolCalls || visible.toString().trim().length >= kMinUsefulChars;

  /// 思考失控判定（**守卫的唯一口径**，adapter 侧必须用它，不许自己量块长）。
  ///
  /// 两个条件同时成立才算失控：
  /// 1. 累计思考超过预算 —— 同时看「当前块长」与「跨块累计」：
  ///    只量当前块会被 think…response 反复横跳绕过（每块归零，总量无上限）；
  /// 2. 本步还没有任何产出 —— 已经吐出答案或工具调用的，不算失控，
  ///    避免把「思考长但已能交付」的正常回合误杀。
  bool thinkingRunaway(int maxChars) =>
      (thinking.length > maxChars || _totalThinkingChars > maxChars) &&
      !producedAnything;

  /// 已累计思考字数（失控判定的分子，暴露给诊断/测试）。
  int get thinkingCharsSoFar => _totalThinkingChars;

  /// 原始流去掉思考块（保留工具调用 XML/JSON），供最终协议解析。
  /// 保证思考内容不渗入最终文本（LlmResult.text），
  /// 从而历史 assistant 内容不会携带原始思考块。
  final StringBuffer clean = StringBuffer();

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

  /// 当前思考块是否由孤立闭合记号（隐式 opener）开启。
  /// 这类块装的是"被提前闭合的思考续写"泄漏：finish 时**整体丢弃**，
  /// 不走短块恢复——恢复会把泄漏续写渗回可见回答（孤立 response 契约）。
  /// 真 opener 开的块不受影响（Clover 误触发的短正文仍恢复可见）。
  bool _thinkFromOrphanCloser = false;

  /// 当前可见文本（思考过滤 + JSON 隐藏后）。
  String get visibleText => visible.toString();

  /// [marker]（形如 `
  /// `）的**容错**命中：允许尖括号内侧混入空白——真机高发的书写噪声是
  /// 「标签里多一个空格」与「标签被断句劈开」，两种都会让精确匹配失效。
  ///
  /// 为什么不能只用 `endsWith`：状态机原来是**逐字符精确后缀**匹配，标签里
  /// 多一个空格或断句就整块认不出来，于是协议标签原样留在可见流里——过去
  /// 答案行是单行覆写，下一行把它盖掉，用户看不见；A2/A3 把每步可见文本
  /// **定格成独立行**之后，这些残片被永久固化成「步骤 N 输出」块（真机截图
  /// 即此：步骤卡内容是一串协议标签）。慢路仅在尾部出现 `<` 时走（正常
  /// 中文答案零命中），热路径不受影响。
  static bool _endsWithTag(String s, String marker) =>
      _tailTagLength(s, marker) != null;

  /// 可见文本尾部实际匹配到的标签长度（精确或容错）；未命中返回 null。
  /// 返回**实际**长度而非 marker.length：容错命中时尾部比 marker 长（多出的
  /// 是空白），调用方按此长度回退，否则会把空白留在可见流里。
  static int? _tailTagLength(String s, String marker) {
    if (s.endsWith(marker)) return marker.length; // 快路（绝大多数命中）
    if (!s.contains('<')) return null; // 无尖括号 → 不可能命中
    // 逐个尖括号起点试（最左 `<` 不匹配时后面还可能有）：正文里先出现普通
    // 尖括号、协议标签在其后才到达尾部，只查最左一个就会漏判。
    final loose = _looseTagPattern(marker);
    for (var i = s.length - 2; i >= 0; i--) {
      if (s[i] != '<') continue;
      final m = loose.matchAsPrefix(s, i);
      if (m != null && m.end == s.length) return m.end - i;
    }
    return null;
  }

  /// [marker] 的「任意字符间可混空白」宽松式（`</tool_call >`、`< /tool_call>`
  /// 这类真机书写噪声）。
  ///
  /// 分隔必须带上**尖括号本身**：`join` 只在元素之间插分隔，若 `<`/`>` 不参与
  /// 拼接，`< /tool_call>`（空格紧跟 `<`）与 `</tool_call >`（空格紧贴 `>`）
  /// 这两种真机最常见的写法都会漏判。
  static RegExp _looseTagPattern(String marker) {
    return RegExp(
      marker
          .split('')
          .map(RegExp.escape)
          .join(r'\s*'),
    );
  }

  /// [marker] 的**部分前缀**是否正压在可见文本尾部（跨 token 断开的协议标签）。
  ///
  /// 命中时该字符**先留在可见流**：下一字符继续喂进来后要么补全成完整标签
  /// （那时 [_endsWithTag] 命中，整块连同这段前缀一起回退隐藏），要么不成
  /// 标签（自然转正为正文，与旧行为一致）。旧实现没有这一态，标签的前半截
  /// 单独到达时不进缓冲，其后的参数区就再也不会被识别为工具块。
  static bool _tagPrefixAtTail(String s, String marker) {
    for (var i = s.length - 1; i >= 0; i--) {
      // 每个 `<` 都当候选起点：前面的正文里另有普通尖括号不影响后面的判断。
      if (s[i] != '<') continue;
      // 至少吃掉 `<` 才算"标签可疑"（起点即 `<`，天然满足）。
      if (_isLoosePrefixOf(s.substring(i), marker)) return true;
    }
    return false;
  }

  /// [tail] 是否形如 [marker] 的**前缀**——允许已到达部分内混入空白
  /// （`< /tool_call`、`<tool_ca` 都算），但不许超出 [marker] 本身。
  static bool _isLoosePrefixOf(String tail, String marker) {
    if (tail.length > marker.length) return false;
    var j = 0; // marker 游标
    for (var i = 0; i < tail.length; i++) {
      final c = tail[i];
      if (c == ' ' || c == '\t' || c == '\n') continue; // 噪声字符跳过
      while (j < marker.length &&
          (marker[j] == ' ' || marker[j] == '\t' || marker[j] == '\n')) {
        j++;
      }
      if (j >= marker.length || marker[j] != c) return false;
      j++;
    }
    return true;
  }

  /// 协议标签字符串（拼接书写：本文件所在工具链对成对尖括号标记有误吞风险）。
  static const List<String> _protocolTags = [
    '<' 'tool_call' '>',
    '<' '/tool_call' '>',
    '<' 'arg_key' '>',
    '<' '/arg_key' '>',
    '<' 'arg_value' '>',
    '<' '/arg_value' '>',
    '<|tool_call_start|>',
    '<|tool_call_end|>',
    '<' 'thinking' '>',
    '<' '/thinking' '>',
    '<' 'think' '>',
    '<' '/think' '>',
  ];

  /// 协议标签关键词（拼接书写，理由同上）。
  static const List<String> _protocolTagWords = [
    'tool' + '_call',
    'thin' + 'k',
    'think' + 'ing',
    'arg' + '_key',
    'arg' + '_value',
    'function',
    'parameter',
  ];

  /// 尖括号片段是否是**协议**标记（含 MiniCPM 特殊 token 与属性式 function）。
  static bool _isProtocolFragment(String frag) {
    final lower = frag.toLowerCase();
    for (final w in _protocolTagWords) {
      if (lower.contains(w)) return true;
    }
    return false;
  }

  /// 只**删协议尖括号片段**，保留其间正文（用于 finish 扫尾：可见流末尾压着
  /// 半截协议标签前缀——[_tagPrefixAtTail] 的"等补全"态——流已终结不会补全，
  /// 标签必须扫掉，而它周围真写的正文要留）。
  static String stripProtocolTags(String text) {
    if (!text.contains('<')) return text;
    final sb = StringBuffer();
    var i = 0;
    while (i < text.length) {
      final lt = text.indexOf('<', i);
      if (lt < 0) {
        sb.write(text.substring(i));
        break;
      }
      sb.write(text.substring(i, lt));
      final gt = text.indexOf('>', lt + 1);
      if (gt < 0) {
        final tail = text.substring(lt);
        if (!_isProtocolFragment(tail) && !_looksLikeProtocolTagPrefix(tail)) {
          sb.write(tail);
        }
        break;
      }
      final frag = text.substring(lt, gt + 1);
      if (!_isProtocolFragment(frag)) sb.write(frag);
      i = gt + 1;
    }
    return sb.toString().replaceAll(RegExp(r'[ \t]+\n'), '\n').trim();
  }

  /// 从**第一个协议标记**起整段截断（落库前的末道防线，供步答块定格与答案
  /// 行写入调用）。
  ///
  /// 与 [stripProtocolTags] 的分工：模型一旦吐出工具调用开标签，其后的内容
  /// 是**参数区**而不是正文——只删尖括号会把 `city南宁` 这类参数文本当正文
  /// 留下（真机「步骤 N 输出」的成因）。故这里遇到协议标记就整段截尾。
  ///
  /// 判据保守：普通尖括号（「a < b」、示例代码里的 `<div>`）不触发截断，
  /// 只有含 [_protocolTagWords] 关键词、或明显是协议标签前缀（尾部断开的
  /// `<tool_ca`）的片段才算协议。
  static String stripProtocolResidue(String text) {
    if (!text.contains('<')) return text.trim();
    var i = 0;
    while (i < text.length) {
      final lt = text.indexOf('<', i);
      if (lt < 0) break;
      final gt = text.indexOf('>', lt + 1);
      final frag = gt < 0 ? text.substring(lt) : text.substring(lt, gt + 1);
      if (_isProtocolFragment(frag) ||
          (gt < 0 && _looksLikeProtocolTagPrefix(frag))) {
        // 协议标记起 = 参数区开始，整段截尾。
        return text.substring(0, lt).trim();
      }
      if (gt < 0) break; // 尾部非协议残段：保留并结束扫描
      i = gt + 1;
    }
    return text.trim();
  }

  /// 尾部文本是否是某个协议标签的**前缀**（跨 token 断开的标签，如半截开标签）。
  static bool _looksLikeProtocolTagPrefix(String tail) {
    if (!tail.startsWith('<')) return false;
    final lower = tail.toLowerCase();
    for (final tag in _protocolTags) {
      if (tag.length > lower.length &&
          tag.toLowerCase().startsWith(lower.replaceFirst('<', '<'))) {
        return true;
      }
    }
    // `<|...` 形态的特殊 token 前缀。
    return lower.startsWith('<|');
  }

  /// 各风格的思考闭合记号（' response' 兼容 Qwen3.5 无闭合标签变体）。
  static const List<String> _thinkClosers = [
    '</thinking>',
    '</think>',
    ' response',
  ];

  /// 思考缓冲的**展示用**文本：剥掉尾部瞬态的闭合记号（流式推送时闭合标签
  /// 是逐字符进入缓冲、命中后整体 clear 的，直接推会把 `</thi` 这类残尾
  /// 闪现在思考卡片上）。
  String get thinkingText {
    var t = thinking.toString();
    for (final c in _thinkClosers) {
      if (t.endsWith(c)) return t.substring(0, t.length - c.length);
    }
    // 尾部是某个闭合记号的前缀（还没写完）→ 同样剥掉。
    final maxLen = _thinkClosers.map((c) => c.length).reduce((a, b) => a > b ? a : b);
    for (var len = maxLen; len >= 1; len--) {
      if (t.length < len) continue;
      final tail = t.substring(t.length - len);
      if (_thinkClosers.any((c) => c.startsWith(tail))) {
        return t.substring(0, t.length - len);
      }
    }
    return t;
  }

  /// 去除思考块后的原始文本（工具调用块保留，供协议解析）。
  String get cleanText => clean.toString();

  /// 是否正在思考块内（UI 可显示「思考中…」）。
  bool get thinkingActive => _thinkKind != null;

  /// 是否解析出了工具调用块（JSON 或 XML）。
  bool get hasToolCalls =>
      toolJsonBlocks.isNotEmpty || toolXmlBlocks.isNotEmpty;

  /// 是否正在生成工具调用块（XML/JSON 缓冲中；WP5 进度反馈用——
  /// 此时可见流与思考流都是空的，UI 只能干转圈，需要这个状态）。
  bool get toolGenActive => _xmlTool != null || _inProbe;

  /// 当前工具调用缓冲的字符数（配合 [toolGenActive] 显示"已生成 N 字"）。
  int get toolGenChars => (_xmlTool?.length ?? 0) + (_inProbe ? probe.length : 0);

  /// 工具调用缓冲的开头预览（最多 60 字符，换行压成空格；UI 单行提示用）。
  String get toolGenPreview {
    final b = _xmlTool ?? (_inProbe ? probe : null);
    if (b == null) return '';
    var s = b.toString().replaceAll('\n', ' ').trim();
    if (s.length > 60) s = '${s.substring(0, 60)}…';
    return s;
  }

  /// 处理一个 token（可含多字符；跨 token 状态自动衔接）。
  void add(String token) {
    for (var i = 0; i < token.length; i++) {
      _addChar(token[i]);
    }
  }

  /// 流结束收尾：JSON 试探恢复为普通文本；未闭合 XML 工具块**整块丢弃**
  /// （参数区文本不是答案，2026-11-09 真机契约，理由见函数体注释）。
  /// 思考块未闭合：**短块恢复为可见文本**（dllm-CLOVER-APP-FIX，2026-10-30）。
  /// 旧策略一律丢弃是为 Qwen 系"think  runaway 兜底"设计的，但 Clover 一类
  /// 混合中英文输出会在正文中途吐出 ` think`/` response` 碎片触发思考态，
  /// 答案尾部整段被吞进 thinking 再在 finish 丢弃 → 用户看到"输出截断/乱码"
  /// （真机 830 实锤：'你是谁'→'我是m 一pu/kleysiies'，CLI 同模型输出干净）。
  /// 短未闭合块几乎必然是误触发的正文字符，恢复可见；长块仍丢弃保住
  /// 思考失控止损（thinkingRunaway 预算远大于此阈值）。
  void finish() {
    if (_xmlTool != null) {
      // 流结束时工具块仍未闭合 = 调用本身作废（参数区没写完/闭合标签写坏），
      // 其后内容全是参数区文本——恢复回可见流会把 `city南宁` 这类东西喂给
      // 答案气泡与步答块（真机截图即此）。旧策略"剥标签后恢复"仍漏参数文本
      // （剥的是尖括号，留的是尖括号之间的内容），故整块丢弃：
      // 宁可少一段本来就不完整的"答案"，不可把协议残骸当答案。
      _xmlTool = null;
    }
    if (_inProbe) {
      visible.write(probe.toString());
      probe.clear();
      _inProbe = false;
    }
    if (_thinkKind != null &&
        !_thinkFromOrphanCloser &&
        thinking.length <= _recoverUnclosedThinkingMaxChars) {
      visible.write(thinking.toString());
    }
    thinking.clear();
    _thinkKind = null;
    _thinkFromOrphanCloser = false;
    // 尾部还压着半截协议标签（[_tagPrefixAtTail] 的"先留着等补全"态）而流已
    // 结束 → 永远不会补全了，扫掉，否则答案尾部就是一串尖括号。
    final tail = stripProtocolTags(visible.toString());
    if (tail != visible.toString()) {
      visible
        ..clear()
        ..write(tail);
    }
  }

  /// 未闭合思考块恢复为可见文本的长度上限（ runaway 兜底阈值以下才恢复）。
  static const int _recoverUnclosedThinkingMaxChars = 4096;

  void _addChar(String ch) {
    // ---- 思考块内：只收集，检测闭合 ----
    if (_thinkKind != null) {
      thinking.write(ch);
      _totalThinkingChars++;
      final t = thinking.toString();
      if (_thinkKind == _ThinkKind.html &&
          (t.endsWith('</thinking>') ||
              t.endsWith('</think>') ||
              t.endsWith(' response'))) {
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
      clean.write(ch);
      final buf = _xmlTool!.toString();
      // MiniCPM5 特殊标记闭合 → 归一化写入 </tool_call> 再收块。
      const miniEnd = '<|tool_call_end|>';
      if (buf.endsWith(miniEnd)) {
        _xmlTool!
          ..clear()
          ..write(buf.substring(0, buf.length - miniEnd.length) + '</tool_call>');
        final c = clean.toString();
        clean
          ..clear()
          ..write(c.substring(0, c.length - miniEnd.length) + '</tool_call>');
        toolXmlBlocks.add(_xmlTool!.toString());
        _xmlTool = null;
        return;
      }
      if (_endsWithTag(buf, '</tool_call>')) {
        toolXmlBlocks.add(_xmlTool!.toString());
        _xmlTool = null;
      }
      return;
    }

    // ---- JSON 试探中 ----
    if (_inProbe) {
      probe.write(ch);
      clean.write(ch);
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
    clean.write(ch);
    final v = visible.toString();

    // XML 工具块开始：`<tool_call>`（Spark 训练分布）。
    const xmlTag = '<tool_call>';
    if (_endsWithTag(v, xmlTag)) {
      _enterXmlTool(v, xmlTag, xmlTag);
      return;
    }

    // MiniCPM5 系特殊 token 形式（原生层 special=true 渲染后到达此处）：
    // `<|tool_call_start|>` → 归一化为 `<tool_call>`，`<|tool_call_end|>` 同理，
    // 下游解析与隐藏逻辑统一走 XML 工具块路径（2026-09-30 真机定案）。
    const miniTag = '<|tool_call_start|>';
    if (_endsWithTag(v, miniTag)) {
      _enterXmlTool(v, miniTag, xmlTag);
      return;
    }

    // 标签前缀压在尾部（`<`、`<tool`、`<|tool_cal` 这类跨 token 断口）：
    // 本字符留在可见流，等下一字符补全再判——补全成标签时整块（含这段前缀）
    // 一起回退隐藏；不成标签则自然转正为正文。缺这一态时，标签前半截单独
    // 到达就不进缓冲，其后参数区永远不会被识别成工具块。
    if (_tagPrefixAtTail(v, xmlTag) || _tagPrefixAtTail(v, miniTag)) return;

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

    // 孤立闭合记号（无前置 think 触发）：Qwen 风格模型偶发在回答中途再输出
    // ` response`——通常是一段被提前闭合的思考续写。把它当作隐式 opener
    // 重新进入思考态、续写一并丢弃，否则闭合记号与后续内容会直接渗进
    // 可见回答（2026-09-29 真机观察到）。紧跟英文/数字（如 "API response"
    // 这类词）不算孤立闭合记号，保持原样不吞——宽松检测代价与既有
    // `' think'` 触发一致：中文回答罕见，可接受。
    for (final c in _thinkClosers) {
      if (c == '</thinking>') continue;
      if (v.endsWith(c)) {
        if (v.length > c.length) {
          final prev = v[v.length - c.length - 1];
          if (_isAsciiWord(prev)) return;
        }
        // 仅 ` response` 按隐式 opener 豁免位置门（契约见 _enterThink）；
        // `</think>` 无契约，保持旧行为（仅回答开头触发）不放大误吞面。
        _enterThink(_ThinkKind.qwen, v, c, orphanCloser: c == ' response');
        return;
      }
    }

    // HTML 风格思考：`<thinking>` / `<think>`（Qwen3/DeepSeek 短标签）/
    // ` think`（Qwen3.5 实际输出不带 ing，宽松检测可接受）。
    const htmlTags = ['<thinking>', '<think>', ' think'];
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

  /// 进入 XML 工具块缓冲：从 visible/clean 回退掉触发标记 [marker]，
  /// 并以规范化形式 [canonical]（如 `<tool_call>`）开启缓冲。
  void _enterXmlTool(String v, String marker, String canonical) {
    // 回退长度取**实际命中长度**：容错命中（标签内混空白）时尾部比 marker 长。
    final n = _tailTagLength(v, marker) ?? marker.length;
    visible
      ..clear()
      ..write(v.substring(0, v.length - n));
    // clean 同步回退标记，再写入规范化开标签（工具块保留在 clean 里供协议解析）。
    final c = clean.toString();
    final cn = _tailTagLength(c, marker);
    if (cn != null) {
      clean
        ..clear()
        ..write(c.substring(0, c.length - cn));
    }
    clean.write(canonical);
    _xmlTool = StringBuffer()..write(canonical);
  }

  /// 进入思考态：把已写入 visible 的触发标签回退掉（后续字符全丢弃进思考缓冲）。
  /// 触发标签**不写入** thinking 缓冲——思考内容展示时不许露出 `<think>` 这类
  /// 标签（用户要求：只标注"思考"，标签是协议记号不是内容）。
  ///
  /// [orphanCloser]：触发记号是孤立闭合记号（` response`，无前置 opener）——
  /// 按隐式 opener 处理（被提前闭合的思考续写，2026-09-29 真机）。
  void _enterThink(_ThinkKind kind, String v, String tag,
      {bool orphanCloser = false}) {
    final before = v.substring(0, v.length - tag.length);
    // 位置门（dllm-CLOVER-APP-FIX，2026-10-30）：思考只在回答**开头**出现一次，
    // 这是全部端侧思考模型的真实分布。正文中途冒出的 ` think`/` response`
    // 碎片（Clover 混合输出高发，真机 830 实锤切碎答案：每命中一次就吞掉
    // 一段正文直到下一个闭合记号）一律按**字面文本**保留，不再进思考态。
    // 判据：触发点前的可见文本 ≤ 16 字符（容忍开头空白）且本轮还没闭合过
    // 任何思考块。二者任一不满足 → 视为正文，原样可见。
    //
    // 两条例外（思考失控守卫契约，2026-11-08 定案）：
    // ① 显式 HTML 标签（<think>/<thinking>）是协议记号不是正文碎片，任何
    //    位置都进思考态——否则多段 <think>…</think> 块从第 2 段起被当字面
    //    文本，跨块累计口径（totalThinkingChars）失效，"多段短思考"每块
    //    归零即可绕过失控守卫（红测试 1/2 契约）。
    // ② 孤立闭合记号 ` response`（无前置 opener）＝被提前闭合的思考续写：
    //    当作隐式 opener 重新进思考态，续写一并丢弃（红测试 3 契约）。仅当
    //    本轮已有思考才豁免——纯正文里首个 response 仍按位置门防误吞；
    //    英文词 "API response" 已由调用侧 ASCII 守卫拦截。
    final explicitHtmlTag = tag.startsWith('<');
    if (!explicitHtmlTag &&
        !(orphanCloser && _totalThinkingChars > 0) &&
        (_totalThinkingChars > 0 || before.trim().length > 16)) {
      return; // 正文中途的伪触发：保持字面文本，不回退、不吞后续。
    }
    visible
      ..clear()
      ..write(before);
    // clean 在工具块缓冲期间与 visible 脱节，但此刻两者尾部都恰为触发 tag；
    // 只去掉 clean 尾部这串 tag，保留其前部已积累的工具块。
    final raw = clean.toString();
    if (raw.length >= tag.length) {
      clean
        ..clear()
        ..write(raw.substring(0, raw.length - tag.length));
    }
    _thinkKind = kind;
    _thinkFromOrphanCloser = orphanCloser;
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

/// 单个字符是否为 ASCII 字母/数字（用于区分英文词 "response" 与孤立闭合记号）。
bool _isAsciiWord(String ch) {
  if (ch.isEmpty) return false;
  final c = ch.codeUnitAt(0);
  return (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122);
}
