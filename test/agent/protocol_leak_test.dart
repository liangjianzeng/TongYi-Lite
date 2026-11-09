/// 工具调用协议残片泄漏与参数丢包的回归锁（真机 2026-11-09，Ornith 1.5 9B）。
///
/// 真机一屏三症状（智能体问「南宁天气」，工具 get_weather）：
/// 1. 工具卡三连报「缺少必填参数 city」——模型写的是
///    `<arg_key>city</arg_value>南宁`（**闭合标签用错**），旧 `_parseXmlArgs`
///    只把**开标签**当分隔符，值段前面没有开标签 → 永不配对 → 参数 `{}`
///    → 模型反复重试同一调用直到步数耗尽（三步全废）；
/// 2. 「步骤 1/2/3 输出」块内容是一串协议标签——可见流状态机是**逐字符精确
///    后缀**匹配，标签里多一个空格或被断句劈开就整块认不出来，残片留在可见
///    流里；A2/A3 把每步可见文本定格成独立行后，残片被永久固化（旧实现靠
///    单行覆写把它盖掉，用户看不见而已）；
/// 3. 答案气泡尾部只剩半截开标签（同一残片进了最终回答行）。
///
/// 标签用 `'<' + 'tool_call' + '>'` 形式拼装：本文件所在工具链对成对尖括号
/// 标记有误吞风险，逐段拼接后测试意图仍一眼可读。
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:tongyi_lite/agent/protocol/prompt_json_protocol.dart';
import 'package:tongyi_lite/agent/protocol/tool_protocol.dart'
    show StreamOutcome;
import 'package:tongyi_lite/providers/agent_stream_processor.dart';

const kOpen = '<' + 'tool_call' + '>';
const kClose = '<' + '/tool_call' + '>';
const kKeyOpen = '<' + 'arg_key' + '>';
const kKeyClose = '<' + '/arg_key' + '>';
const kValOpen = '<' + 'arg_value' + '>';
const kValClose = '<' + '/arg_value' + '>';
/// 标签内混空白（真机高发的书写噪声）。
const kKeyOpenLoose = '<' + 'arg_key' + ' >';

Future<StreamOutcome> _parse(String text) =>
    const PromptJsonProtocol().parseStream(Stream<String>.value(text));

void main() {
  group('XML 参数配对：闭合标签用错也不丢值（真机主因）', () {
    test('正常格式 key/value 配对', () async {
      final r = await _parse(
          '南宁今天晴。$kOpen' 'get_weather$kKeyOpen' 'city$kValOpen' '南宁$kClose');
      expect(r.toolCalls, hasLength(1));
      expect(r.toolCalls.single.name, 'get_weather');
      expect(r.toolCalls.single.arguments, {'city': '南宁'});
      expect(r.text, '南宁今天晴。');
    });

    test('闭合标签用错（真机原样：key 后用 arg_value 收尾）', () async {
      // 模型实际输出：`<arg_key>city</arg_value>南宁</arg_value>`
      final r = await _parse(
          '$kOpen' 'get_weather$kKeyOpen' 'city$kValClose' '南宁$kValClose$kClose');
      expect(r.toolCalls, hasLength(1), reason: '真机这里解析不出调用 → 工具三连失败');
      expect(r.toolCalls.single.arguments, {'city': '南宁'},
          reason: '值段前面没有"开标签"也必须配上——旧实现只认开标签，'
              '参数丢成 {} → 工具报缺少必填参数 → 模型反复重试');
      expect(r.text.contains('arg_key'), isFalse, reason: '标签不得残留在可见文本');
    });

    test('key/value 各带闭合标签', () async {
      final r = await _parse(
          '$kOpen' 'get_weather$kKeyOpen' 'city$kKeyClose$kValOpen' '南宁$kValClose$kClose');
      expect(r.toolCalls.single.arguments, {'city': '南宁'});
    });

    test('值误塞进 key 标签（旧坏格式容错不回归）', () async {
      final r = await _parse('$kOpen' 'web_search$kKeyOpen' 'query$kKeyOpen'
          'AI news today$kValClose$kClose');
      expect(r.toolCalls.single.arguments, {'query': 'AI news today'});
    });

    test('标签内混空白也能配对', () async {
      final r = await _parse(
          '$kOpen' 'get_weather$kKeyOpenLoose' 'city$kValOpen' '南宁$kClose');
      expect(r.toolCalls.single.arguments, {'city': '南宁'});
    });

    test('多参数顺序不错', () async {
      final r = await _parse('$kOpen' 'shell$kKeyOpen' 'command$kValOpen'
          'ls -la$kKeyOpen' 'cwd$kValOpen' '/sdcard$kClose');
      expect(r.toolCalls.single.arguments, {'command': 'ls -la', 'cwd': '/sdcard'});
    });

    test('孤立 value（没有 key）忽略；有 key 无 value 丢弃', () async {
      final r = await _parse('$kOpen' 'noop$kValOpen' 'orphan$kClose');
      expect(r.toolCalls.single.arguments, isEmpty);
    });

    test('普通尖括号正文不被误当协议', () async {
      final r = await _parse('比较 a < b 时，写成 if (a < b) 即可。');
      expect(r.toolCalls, isEmpty);
      expect(r.text, contains('a < b'));
    });
  });

  group('可见流状态机：协议块整体隐藏，不留残片', () {
    AgentStreamProcessor feed(String token, {bool finish = true}) {
      final p = AgentStreamProcessor();
      p.add(token);
      if (finish) p.finish();
      return p;
    }

    test('正常块：可见只剩前言', () {
      final p = feed('南宁今天晴。$kOpen' 'get_weather$kKeyOpen' 'city$kValOpen'
          '南宁$kClose');
      expect(p.visibleText, '南宁今天晴。');
      expect(p.hasToolCalls, isTrue);
    });

    test('标签内混空白：整块仍被隐藏（旧实现在此漏网）', () {
      final looseClose = '<' + '/tool_call' + ' >';
      final p = feed('答案在前。$kOpen' 'get_weather$kKeyOpen' 'city$kValOpen'
          '南宁$looseClose');
      expect(p.visibleText, '答案在前。',
          reason: '精确后缀匹配认不出带空白的闭合标签 → 残片渗进可见流');
    });

    test('逐字符喂入（标签跨 token 断开）也不留残片', () {
      final p = AgentStreamProcessor();
      final full =
          '前言。$kOpen' 'get_weather$kKeyOpen' 'city$kValOpen' '南宁$kClose';
      for (final ch in full.split('')) {
        p.add(ch);
      }
      p.finish();
      expect(p.visibleText, '前言。');
      expect(p.visibleText.contains('arg'), isFalse);
    });

    test('闭合标签写坏（模型把收尾写成 arg_value）→ finish 不Dump标签', () {
      // 真机形态：块尾写成 `</arg_value>`，状态机等不到闭合标签 → 旧 finish()
      // 把整串原始标签写回可见流（答案气泡/步答块因此满是尖括号）。
      final p = feed('南宁晴。$kOpen' 'get_weather$kKeyOpen' 'city$kValClose'
          '南宁$kValClose');
      expect(p.visibleText.contains('arg'), isFalse);
      expect(p.visibleText.contains('tool_call'), isFalse,
          reason: '未闭合块恢复时协议标签必须剥掉，只留真正文');
    });

    test('尾部停在半截开标签 → finish 扫掉', () {
      const half = '<' + 'tool_ca';
      final p = feed('回答正文。$half');
      expect(p.visibleText, '回答正文。');
    });

    test('普通文本里的尖括号不被吞（不误伤正文）', () {
      final p = feed('代码 if (a < b) { f(); } 这样写');
      expect(p.visibleText, '代码 if (a < b) { f(); } 这样写');
    });
  });

  group('落库前末道净化：残片绝不成「步骤 N 输出」', () {
    test('整段是残片 → 空串（步答块宁可不产）', () {
      final dirty = '$kKeyOpen' + 'city$kValClose' + '南宁$kClose';
      expect(AgentStreamProcessor.stripProtocolResidue(dirty), isEmpty);
    });

    test('半截开标签（尾部未闭合）也剥掉', () {
      const half = '<' + 'tool_ca'; // 断在标签中间
      expect(AgentStreamProcessor.stripProtocolResidue('步骤输出 $half'), '步骤输出');
    });

    test('正文夹残片 → 只留正文', () {
      final mixed = '南宁今日晴，25℃。$kOpen' 'get_weather$kKeyOpen' 'city$kValClose'
          '南宁$kValClose$kClose';
      final cleaned = AgentStreamProcessor.stripProtocolResidue(mixed);
      expect(cleaned, '南宁今日晴，25℃。');
    });

    test('普通尖括号与代码示例保留（不误吞正文）', () {
      const keep = '比较 a < b 时写 if (a < b)；HTML 例：<div> 与 </div>';
      expect(AgentStreamProcessor.stripProtocolResidue(keep), keep);
    });
  });
}
