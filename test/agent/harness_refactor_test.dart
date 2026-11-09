/// Harness 重构回归测试（B1/B3/B4/A1 一次性落地的行为锁）。
///
/// 覆盖四块新语义：
/// - B3 多工具调用：文本协议一次解析全部工具调用块（XML/JSON 族）；
/// - B4 历史回放：assistant 的 tool_calls 渲染回模型自身文本形态；
/// - B1 统一压缩：tool 对不拆分、摘要必须更小、影子区跨回合重建；
/// - A1 事件落盘：SessionPersistor 排队写盘 + JSONL 加载 + 崩溃修复幂等。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:tongyi_lite/agent/protocol/prompt_json_protocol.dart';
import 'package:tongyi_lite/agent/session/session.dart';
import 'package:tongyi_lite/agent/session/store.dart';
import 'package:tongyi_lite/agent/llm/base_engine_adapter.dart';
import 'package:tongyi_lite/agent/llm/adapter.dart';
import 'package:tongyi_lite/agent/capability.dart';
import 'package:tongyi_lite/agent/protocol/tool_protocol.dart';
import 'package:tongyi_lite/agent/loop/failure.dart';
import 'package:tongyi_lite/agent/context_eng/compaction.dart';
import 'package:tongyi_lite/agent/session/event.dart'
    show
        kEventAssistantMessage,
        kEventCompactionSummary,
        kEventSystemMessage,
        kEventToolResult,
        kEventTurnEnd,
        kEventTurnStart,
        kEventUserMessage;

void main() {
  group('B3 多工具调用：_parseText 全块解析', () {
    final protocol = PromptJsonProtocol();

    test('XML：两个 tool_call 块 → 两个调用，块外文本为残差', () async {
      final outcome = await protocol.parseStream(Stream.value(
        '我先查天气和搜索。\n'
        '<tool_call>get_weather<arg_key>location<arg_value>南宁</tool_call>\n'
        '<tool_call>web_search<arg_key>query<arg_value>新闻</tool_call>',
      ));
      expect(outcome.toolCalls.length, 2);
      expect(outcome.toolCalls[0].name, 'get_weather');
      expect(outcome.toolCalls[0].arguments, {'location': '南宁'});
      expect(outcome.toolCalls[1].name, 'web_search');
      expect(outcome.toolCalls[1].arguments, {'query': '新闻'});
      // 两个 id 不相同（同一步多调用防撞）。
      expect(outcome.toolCalls[0].id, isNot(outcome.toolCalls[1].id));
      expect(outcome.text, contains('我先查天气和搜索。'));
      expect(outcome.text, isNot(contains('<tool_call>')));
    });

    test('XML：三连块（含 JSON-in-XML 变体）全解析', () async {
      final outcome = await protocol.parseStream(Stream.value(
        '<tool_call>get_time</tool_call>'
        '<tool_call>{"name": "calculator", "arguments": {"expression": "1+1"}}</tool_call>'
        '<tool_call>get_time</tool_call>',
      ));
      expect(outcome.toolCalls.length, 3);
      expect(outcome.toolCalls[1].name, 'calculator');
      expect(outcome.toolCalls[2].name, 'get_time');
    });

    test('JSON：两个顶层对象 → 两个调用，普通 JSON 文本保留', () async {
      const body = '{"name": "get_time", "arguments": {}}\n'
          '{"name": "web_search", "arguments": {"query": "天气"}}\n'
          '{"unrelated": true}';
      final outcome = await protocol.parseStream(Stream.value(body));
      expect(outcome.toolCalls.length, 2);
      expect(outcome.text, contains('{"unrelated": true}'));
    });

    test('单一调用（旧形态）行为不变：残差=块外文本', () async {
      final outcome = await protocol.parseStream(Stream.value(
        '<tool_call>get_time</tool_call>',
      ));
      expect(outcome.toolCalls.length, 1);
      expect(outcome.toolCalls.first.name, 'get_time');
      expect(outcome.text, '');
    });

    test('单块语法坏（无工具名）→ 防泄漏兜底抛错进失败瀑布', () async {
      // 名字位是 arg_key（模型没写工具名直接进参数区）→ 解不出 →
      // 文本含 tool_call 标记 → _noLeakFallback 抛 toolCallSyntax。
      expect(
        () => protocol.parseStream(
            Stream.value('<tool_call>arg_key</tool_call>')),
        throwsA(isA<LlmFailure>()),
      );
      // 对照：名字前杂散标签（<tool_call><get_time</tool_call>）是 2026-09-30
      // 定案的容错形态，能解析成功、不抛。
      final ok = await protocol.parseStream(
          Stream.value('<tool_call><get_time</tool_call>'));
      expect(ok.toolCalls.single.name, 'get_time');
    });
  });

  group('B4 历史回放', () {
    test('spark-xml 族：tool_calls 回放为半开标签形态', () {
      final p = PromptJsonProtocol();
      final replay = p.replayToolCalls('spark-2-8b', [
        {
          'id': 'c1',
          'function_name': 'web_search',
          'arguments': {'query': '新闻', 'n': 3},
        },
        {
          'id': 'c2',
          'function_name': 'get_time',
          'arguments': null,
        },
      ]);
      expect(replay, contains('<tool_call>web_search'));
      expect(replay, contains('<arg_key>query<arg_value>新闻'));
      expect(replay, contains('<arg_value>3</arg_value>'));
      expect(replay, contains('<tool_call>get_time</tool_call>'));
    });

    test('ling 族：闭合标签形态；lfm 族：JSON 形态', () {
      final p = PromptJsonProtocol();
      final calls = [
        {
          'id': 'c1',
          'function_name': 'get_time',
          'arguments': <String, dynamic>{},
        },
      ];
      final ling = p.replayToolCalls('ling-7b', calls)!;
      expect(ling, contains('<tool_call>'));
      expect(ling, contains('get_time'));
      expect(ling, contains('</tool_call>'));
      final json = p.replayToolCalls('lfm-2.5', calls);
      final decoded = jsonDecode(json!);
      expect(decoded['name'], 'get_time');
    });

    test('空调用 → null（无回放文本）', () {
      final p = PromptJsonProtocol();
      expect(p.replayToolCalls('spark', const []), isNull);
    });

    test('convertEngineMessages：assistant tool_calls 拼回 content', () {
      final adapter = _StubAdapter(
        protocol: PromptJsonProtocol(),
        capabilities: const EngineCapabilities(toolTemplate: 'spark-xml'),
      );
      final out = adapter.convertEngineMessages([
        {
          'role': 'assistant',
          'content': '',
          'tool_calls': [
            {
              'id': 'c1',
              'function_name': 'get_weather',
              'arguments': {'location': '南宁'},
            }
          ],
        },
        {'role': 'tool', 'tool_call_id': 'c1', 'content': '晴 30°C'},
        {'role': 'assistant', 'content': '南宁今天晴。'},
      ], modelId: 'spark-2-8b');
      expect(out[0]['content'], contains('<tool_call>get_weather'));
      expect(out[1]['role'], 'user'); // 非 bailing-v3 模板：tool→user
      expect(out[2]['content'], '南宁今天晴。');
    });
  });

  group('B1 统一压缩', () {
    test('tool 对不拆分：发起者 assistant 与其结果同遮蔽', () async {
      final log = SessionLog.fromEvents(const []);
      log.append(kEventUserMessage, {'content': '第一轮诉求'});
      log.append(kEventAssistantMessage, {
        'content': '',
        'toolCalls': [
          {'call_id': 'c1', 'name': 't', 'arguments': {}}
        ],
      });
      log.append(kEventToolResult,
          {'callId': 'c1', 'name': 't', 'content': '结果1：' * 40});
      log.append(kEventUserMessage, {'content': '第二轮诉求'});
      // recent 区一条 assistant(toolCalls) 不被波及。
      log.append(kEventAssistantMessage, {
        'content': '',
        'toolCalls': [
          {'call_id': 'c2', 'name': 't', 'arguments': {}}
        ],
      });
      log.append(kEventToolResult,
          {'callId': 'c2', 'name': 't', 'content': '结果2：' * 40});
      log.append(kEventUserMessage, {'content': '第三轮诉求'});
      log.append(kEventUserMessage, {'content': '第四轮诉求'});
      log.append(kEventUserMessage, {'content': '第五轮诉求'});
      log.append(kEventUserMessage, {'content': '第六轮诉求'});

      final r = await DeterministicCompaction(keepRounds: 5)
          .decide(ref: SessionRef(log), turn: 1, step: 1, reason: 'x');
      expect(r.kind, CompactionResultKind.success);
      // keepRounds=5 → 只有第一轮 user 在旧区；其 assistant(toolCalls c1)
      // 与结果必须同遮蔽（配对不变量），recent 区的 c2 对不受波及。
      // 注：digest 摘录里会出现 result1 的头 40 字（合法），判定只看
      // tool 角色的投影消息与 tool_calls 结构。
      final msgs = log.deriveModelMessages();
      expect(
        msgs.where((m) =>
            m['role'] == 'tool' &&
            (m['content'] as String).startsWith('结果1')),
        isEmpty,
        reason: '旧 tool/result 应被遮蔽',
      );
      expect(
        msgs.where((m) =>
            m['role'] == 'tool' &&
            (m['content'] as String).startsWith('结果2')),
        hasLength(1),
        reason: 'recent 区 tool/result 不受波及',
      );
      // 遮蔽区含发起者 assistant：投影里不应残留"孤立 assistant(toolCalls c1)"。
      final orphanAssistant = msgs
          .where((m) =>
              m['role'] == 'assistant' &&
              (m['tool_calls'] as List?)?.any((c) =>
                  c is Map && c['id'] == 'c1') ==
              true)
          .toList();
      expect(orphanAssistant, isEmpty);
    });

    test('摘要必须更小：旧摘要事件折叠进新摘要（不断链）', () async {
      final log = SessionLog.fromEvents(const []);
      log.append(kEventUserMessage, {'content': '旧诉求'});
      log.append(kEventToolResult,
          {'callId': 'c1', 'name': 't', 'content': '旧结果：' * 120});
      log.append(kEventUserMessage, {'content': '第一轮'});
      for (var i = 2; i <= 6; i++) {
        log.append(kEventUserMessage, {'content': '第${i}轮'});
      }
      final r1 = await DeterministicCompaction(keepRounds: 5)
          .decide(ref: SessionRef(log), turn: 1, step: 1, reason: 'x');
      expect(r1.kind, CompactionResultKind.success);
      final firstSummary = log.rawEvents
          .lastWhere((e) => e.type == kEventCompactionSummary);
      // 再来六轮带大结果的新内容 → recent 窗口前移，首轮摘要与其后的
      // 结果进入旧区 → 二次压缩必须把首轮摘要原样折叠进新摘要（不断链）。
      for (var i = 7; i <= 12; i++) {
        log.append(kEventUserMessage, {'content': '第${i}轮'});
        log.append(kEventToolResult,
            {'callId': 'c$i', 'name': 't', 'content': '轮结果$i：' * 120});
      }
      final r2 = await DeterministicCompaction(keepRounds: 5)
          .decide(ref: SessionRef(log), turn: 2, step: 1, reason: 'x');
      expect(r2.kind, CompactionResultKind.success);
      final second = log.rawEvents
          .lastWhere((e) => e.type == kEventCompactionSummary);
      // 新摘要包含旧摘要内容（链式折叠）。
      expect(
          second.data['content'],
          contains(firstSummary.data['content'] as String));
    });
  });

  group('A1 事件落盘', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('session_store_test');
    });
    tearDown(() async {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    });

    test('SessionLog 影子区重建：fromEvents 后投影保持压缩语义', () {
      final log = SessionLog.fromEvents(const []);
      log.append(kEventUserMessage, {'content': '旧消息1'});
      log.append(kEventToolResult,
          {'callId': 'c1', 'name': 't', 'content': 'x' * 200});
      log.append(kEventUserMessage, {'content': '新消息'});
      log.replace(startSeq: 1, endSeq: 2, newContent: '摘要内容');
      // 模拟 JSONL 落盘/加载：事件逐行序列化 → fromEvents 重建。
      final lines = log.rawEvents.map((e) => e.toJsonLine()).toList();
      final reloaded = SessionLog.fromEvents([
        for (final l in lines) SessionEvent.fromJsonLine(l)!,
      ]);
      final msgs = reloaded.deriveModelMessages();
      // 投影按事件序：新消息（seq3）→ 摘要（seq4 replace 事件）；
      // 旧消息/旧结果被重建的影子区遮蔽，不再出现。
      expect(msgs, hasLength(2));
      expect(msgs[0]['content'], '新消息');
      expect(msgs[1]['content'], '摘要内容');
      expect(msgs.any((m) => m['content'] == '旧消息1'), isFalse);
    });

    test('SessionPersistor：排队写盘 → flush → load 往返一致', () async {
      final store = JsonlSessionStore(baseDirOverride: tmp.path);
      final log = SessionLog.fromEvents(const []);
      final persistor = SessionPersistor(store, 'conv-1');
      log.attachSink(persistor.onEvent);
      log.append(kEventUserMessage, {'content': '你好'});
      log.append(kEventTurnStart, {'turn': 1, 'userSeq': 1});
      log.append(kEventTurnEnd, {'turn': 1, 'reason': 'completed'});
      await persistor.flush();

      final loaded = await store.load('conv-1');
      expect(loaded.eventsCount, 3);
      expect(loaded.turnEndCount, 1);
      // 崩溃修复幂等：干净日志 closeOpenTurns 不追加。
      expect(loaded.hasSyntheticClosers, isFalse);
    });

    test('closeOpenTurns：崩溃日志（turn 未闭合）修复后幂等', () async {
      final store = JsonlSessionStore(baseDirOverride: tmp.path);
      final file = File(await store.pathFor('conv-2'));
      await file.create(recursive: true);
      final lines = [
        SessionEvent(
                type: kEventTurnStart,
                seq: 1,
                timeMs: 0,
                data: {'turn': 1, 'userSeq': 0})
            .toJsonLine(),
        SessionEvent(
                type: kEventUserMessage,
                seq: 2,
                timeMs: 0,
                data: {'content': '任务'})
            .toJsonLine(),
        SessionEvent(
                type: kEventAssistantMessage,
                seq: 3,
                timeMs: 0,
                data: {
                  'content': '',
                  'toolCalls': [
                    {'call_id': 'c9', 'name': 't', 'arguments': {}}
                  ],
                })
            .toJsonLine(),
      ];
      await file.writeAsString('${lines.join('\n')}\n');
      // 崩溃现场：turn/step 开着、tool/call c9 无结果 → load 时补合成
      // tool/result（started 形态）+ turn/end。

      final loaded = await store.load('conv-2');
      expect(loaded.hasSyntheticClosers, isTrue);
      final n1 = loaded.eventsCount;
      // 再次 load（幂等）：closer 已在日志里，不重复追加。
      final reloaded = await store.load('conv-2');
      expect(reloaded.eventsCount, n1);
      expect(reloaded.hasSyntheticClosers, isTrue);
    });

    test('compactFile：物理清淤剔除影子区事件，投影不变', () async {
      final store = JsonlSessionStore(baseDirOverride: tmp.path);
      final log = SessionLog.fromEvents(const []);
      final persistor = SessionPersistor(store, 'conv-3');
      log.attachSink(persistor.onEvent);
      log.append(kEventUserMessage, {'content': '旧消息'});
      log.append(kEventToolResult,
          {'callId': 'c1', 'name': 't', 'content': 'x' * 300});
      log.append(kEventUserMessage, {'content': '新消息'});
      log.replace(startSeq: 1, endSeq: 2, newContent: '摘要');
      await persistor.flush();
      await persistor.compactFile(log);

      final loaded = await store.load('conv-3');
      final msgs = loaded.deriveModelMessages();
      expect(msgs.map((m) => m['content']), contains('摘要'));
      expect(msgs.map((m) => m['content']), contains('新消息'));
      expect(msgs.map((m) => m['content']), isNot(contains('旧消息')));
    });
  });
}

/// BaseEngineAdapter 测试桩（仅复用消息转换）。
class _StubAdapter extends BaseEngineAdapter {
  _StubAdapter({required ToolProtocol protocol, EngineCapabilities? capabilities})
      : super(protocol: protocol, capabilities: capabilities);
}
