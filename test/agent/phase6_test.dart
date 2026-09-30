/// Phase 6 tests：SessionLog 事件流 + AgentUiState reducer + 内嵌工作流
/// UI 渲染（回合块 / 消息分组 / 工具活动解析）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tongyi_lite/agent/session/event.dart';
import 'package:tongyi_lite/agent/session/log.dart';
import 'package:tongyi_lite/models/chat_message.dart';
import 'package:tongyi_lite/providers/agent_state_provider.dart';
import 'package:tongyi_lite/widgets/agent_workflow.dart';

void main() {
  /// 测试消息工厂（分组/解析组共用）。
  ChatMessage userMsg(String c) => ChatMessage(
        id: 'u',
        conversationId: 'c',
        role: MessageRole.user,
        content: c,
        timestamp: DateTime.now(),
      );

  ChatMessage asst(String c, {bool streaming = false}) => ChatMessage(
        id: 'a',
        conversationId: 'c',
        role: MessageRole.assistant,
        content: c,
        isStreaming: streaming,
        timestamp: DateTime.now(),
      );

  group('SessionLog.events 广播流', () {
    test('append 实时推送事件', () async {
      final log = SessionLog.fromEvents([]);
      final received = <SessionEvent>[];
      log.events.listen(received.add);
      log.append(kEventTurnStart, {'turn': 1});
      log.append(kEventToolCall, {'callId': 'c1', 'name': 'x'});
      expect(received.length, 2);
      expect(received.first.type, kEventTurnStart);
      expect(received.last.data['callId'], 'c1');
      log.dispose();
    });

    test('多订阅者都能收到（broadcast）', () async {
      final log = SessionLog.fromEvents([]);
      final a = <SessionEvent>[];
      final b = <SessionEvent>[];
      log.events.listen(a.add);
      log.events.listen(b.add);
      log.append(kEventStepStart, {'turn': 1, 'step': 1});
      expect(a.length, 1);
      expect(b.length, 1);
      log.dispose();
    });

    test('dispose 后 append 正常但不再推送', () async {
      final log = SessionLog.fromEvents([]);
      final received = <SessionEvent>[];
      log.events.listen(received.add);
      log.dispose();
      log.append(kEventTurnStart, {'turn': 1}); // 不抛
      expect(received, isEmpty);
    });
  });

  group('AgentUiStateNotifier reducer', () {
    late SessionLog log;
    late AgentUiStateNotifier n;

    setUp(() {
      log = SessionLog.fromEvents([]);
      n = AgentUiStateNotifier();
      n.attach(log);
    });

    tearDown(() {
      n.detach();
      log.dispose();
    });

    test('step 边界把流式思考落档为历史块（工作流可回看）', () {
      n.setThinking('第一步思考内容');
      log.append(kEventStepStart, {'turn': 1, 'step': 2});
      expect(n.state.thinkingHistory, ['第一步思考内容']);
      expect(n.state.thinking, isEmpty);

      n.setThinking('第二步思考');
      log.append(kEventTurnEnd, {'reason': 'completed'});
      expect(n.state.thinkingHistory, ['第一步思考内容', '第二步思考']);
      expect(n.state.thinking, isEmpty);
      expect(n.state.running, isFalse);
    });

    test('turn/start → running + turn；step/start → step', () {
      log.append(kEventTurnStart, {'turn': 3});
      expect(n.state.running, isTrue);
      expect(n.state.turn, 3);
      log.append(kEventStepStart, {'turn': 3, 'step': 2});
      expect(n.state.step, 2);
    });

    test('tool/call → 卡片（含参数）；tool/result → done', () {
      log.append(kEventToolCall, {
        'callId': 'c1',
        'name': 'get_time',
        'arguments': {'tz': 'Asia/Shanghai'},
      });
      expect(n.state.tools.length, 1);
      expect(n.state.tools.first.status, ToolUiStatus.executing);
      expect(n.state.tools.first.arguments['tz'], 'Asia/Shanghai');

      log.append(kEventToolResult,
          {'callId': 'c1', 'name': 'get_time', 'content': '12:00', 'isError': false});
      expect(n.state.tools.first.status, ToolUiStatus.done);
      expect(n.state.tools.first.result, '12:00');
    });

    test('tool/result isError → failed', () {
      log.append(kEventToolCall, {'callId': 'c2', 'name': 'shell'});
      log.append(kEventToolResult,
          {'callId': 'c2', 'name': 'shell', 'content': 'boom', 'isError': true});
      expect(n.state.tools.first.status, ToolUiStatus.failed);
      expect(n.state.tools.first.isError, isTrue);
    });

    test('llm/retry → retryAttempt；turn/end 清零', () {
      log.append(kEventLlmRetry, {'turn': 1, 'step': 1, 'retries': 2});
      expect(n.state.retryAttempt, 2);
      log.append(kEventTurnEnd, {'turn': 1, 'reason': 'completed'});
      expect(n.state.running, isFalse);
      expect(n.state.retryAttempt, 0);
      expect(n.state.lastError, isNull);
    });

    test('compaction/summary → compacted', () {
      log.append(kEventCompactionSummary, {'content': '摘要'});
      expect(n.state.compacted, isTrue);
    });

    test('turn/end reason=error（String 形态）→ lastError', () {
      log.append(kEventTurnEnd, {'turn': 1, 'reason': 'error'});
      expect(n.state.lastError, isNotNull);
    });

    test('turn/end reason=Map 形态（崩溃修复）兼容', () {
      log.append(kEventTurnEnd, {
        'turn': 1,
        'reason': {'kind': 'interrupted'},
      });
      expect(n.state.running, isFalse);
      expect(n.state.lastError, isNull);
    });

    test('detach 后事件不再进 state（状态保留）', () {
      log.append(kEventTurnStart, {'turn': 1});
      n.detach();
      log.append(kEventToolCall, {'callId': 'cX', 'name': 'x'});
      expect(n.state.tools, isEmpty);
      expect(n.state.running, isTrue); // 末态保留
    });

    test('attach 新 log 重置状态', () {
      log.append(kEventTurnStart, {'turn': 9});
      final log2 = SessionLog.fromEvents([]);
      n.attach(log2);
      expect(n.state.turn, 0);
      expect(n.state.running, isFalse);
      log2.dispose();
    });
  });

  group('groupMessages 消息重排（内嵌工作流）', () {
    test('新存储序 [user, ans, t1, t2] → 块 [t1, t2, ans]', () {
      final units = groupMessages([
        userMsg('Q1'),
        asst('最终答案'),
        asst('🔧 A ✓ok'),
        asst('🔧 B ✓ok2'),
      ]);
      expect(units.length, 2);
      expect(units.first, isA<UserUnit>());
      final turn = units.last as TurnUnit;
      expect(turn.tools.length, 2);
      expect(turn.tools.map((m) => m.content), ['🔧 A ✓ok', '🔧 B ✓ok2']);
      expect(turn.answer?.content, '最终答案');
      expect(turn.answer?.role, MessageRole.assistant);
    });

    test('旧存储序 [user, t1, t2, ans] → 块 [t1, t2, ans]（重排到回答之前）', () {
      final units = groupMessages([
        userMsg('Q1'),
        asst('🔧 A ✓ok'),
        asst('🔧 B ✓ok2'),
        asst('最终答案'),
      ]);
      expect(units.length, 2);
      final turn = units.last as TurnUnit;
      expect(turn.tools.length, 2);
      expect(turn.tools.map((m) => m.content), ['🔧 A ✓ok', '🔧 B ✓ok2']);
      expect(turn.answer?.content, '最终答案');
    });

    test('多回合：user 是分界；末回合也 flush；非 🔧 回答成普通回合块', () {
      final units = groupMessages([
        userMsg('Q1'),
        asst('🔧 X ✓'),
        asst('A1'),
        userMsg('Q2'),
        asst('A2'),
      ]);
      expect(units.length, 4);
      expect(units[0], isA<UserUnit>());
      final t1 = units[1] as TurnUnit;
      expect(t1.tools.length, 1);
      expect(t1.tools.first.content, '🔧 X ✓');
      expect(t1.answer?.content, 'A1');
      expect(units[2], isA<UserUnit>());
      final t2 = units[3] as TurnUnit;
      expect(t2.tools, isEmpty);
      expect(t2.answer?.content, 'A2');
    });

    test('空输入 → 空', () {
      expect(groupMessages([]), isEmpty);
    });

    test('💭 思考存档归入回合 thinking（不入 tools 也不当回答）', () {
      final units = groupMessages([
        userMsg('Q1'),
        asst('💭 第一段思考'),
        asst('🔧 A ✓ok'),
        asst('💭 第二段思考'),
        asst('最终答案'),
      ]);
      expect(units.length, 2);
      final turn = units.last as TurnUnit;
      expect(turn.thinking, ['第一段思考', '第二段思考']);
      expect(turn.tools.length, 1);
      expect(turn.answer?.content, '最终答案');
    });
  });

  group('parseToolActivity 工具活动解析（历史回合步骤回看）', () {
    test('✓ 成功摘要', () {
      final ui = parseToolActivity(asst('🔧 file_write ✓写入 3 行'));
      expect(ui?.name, 'file_write');
      expect(ui?.status, ToolUiStatus.done);
      expect(ui?.result, '写入 3 行');
      expect(ui?.isError, isFalse);
    });

    test('⚠️ 失败（isError + 摘要）', () {
      final ui = parseToolActivity(asst('🔧 shell ⚠️exit code=1'));
      expect(ui?.name, 'shell');
      expect(ui?.status, ToolUiStatus.failed);
      expect(ui?.result, 'exit code=1');
      expect(ui?.isError, isTrue);
    });

    test('执行中（新单工具格式）', () {
      final ui = parseToolActivity(asst('🔧 正在调用 web_search…'));
      expect(ui?.name, 'web_search');
      expect(ui?.status, ToolUiStatus.executing);
      expect(ui?.result, isNull);
    });

    test('执行中（旧多工具冒号格式）也能解析', () {
      final ui = parseToolActivity(asst('🔧 正在调用：web_search、shell…'));
      expect(ui?.name, 'web_search、shell');
      expect(ui?.status, ToolUiStatus.executing);
    });

    test('非 🔧 消息 → null', () {
      expect(parseToolActivity(asst('普通回复')), isNull);
      expect(parseToolActivity(asst('🔧 无状态标记')), isNull);
    });
  });

  group('AgentTurnBlock 内嵌工作流渲染', () {
    ToolActivityUi act({
      required ToolUiStatus status,
      required String name,
      String? result,
      Map<String, dynamic>? args,
    }) => ToolActivityUi(
          callId: 'c1',
          name: name,
          arguments: args ?? const {},
          status: status,
          result: result,
        );

    Future<void> pump(WidgetTester tester, AgentUiState ui,
        {List<ToolActivityUi> steps = const [],
         ChatMessage? answer,
         bool isLive = false,
         List<String> thinking = const []}) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: AgentTurnBlock(
                isLive: isLive,
                steps: steps,
                answer: answer,
                ui: ui,
                thinking: thinking,
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('空步骤无回答：不渲染内容', (tester) async {
      await pump(tester, const AgentUiState(), isLive: false);
      expect(find.byType(ToolActivityCard), findsNothing);
      expect(find.textContaining('思考中'), findsNothing);
    });

    testWidgets('执行中步骤：卡片 + 执行中标签', (tester) async {
      await pump(
        tester,
        const AgentUiState(running: true),
        steps: [act(status: ToolUiStatus.executing, name: 'get_time', args: {'tz': 'UTC'})],
        isLive: true,
      );
      expect(find.textContaining('🔧 get_time'), findsOneWidget);
      expect(find.textContaining('执行中'), findsOneWidget);
    });

    testWidgets('完成步骤：总折叠区展开后显示结果', (tester) async {
      await pump(
        tester,
        const AgentUiState(running: false),
        steps: [act(status: ToolUiStatus.done, name: 'get_time', result: '12:00', args: {'tz': 'UTC'})],
        isLive: false,
      );
      // 已完成回合：工具卡收进「执行过程」总折叠区，默认收起不可见。
      expect(find.textContaining('执行过程'), findsOneWidget);
      expect(find.textContaining('🔧 get_time'), findsNothing);
      await tester.tap(find.textContaining('执行过程'));
      await tester.pump();
      expect(find.textContaining('🔧 get_time'), findsOneWidget);
      expect(find.textContaining('12:00'), findsNothing); // 工具卡未展开
      await tester.tap(find.byType(ToolActivityCard));
      await tester.pump();
      expect(find.textContaining('12:00'), findsOneWidget);
      expect(find.textContaining('参数'), findsOneWidget);
    });

    testWidgets('失败步骤：⚠️ 标记 + 结果（总折叠区展开可见）', (tester) async {
      await pump(
        tester,
        const AgentUiState(running: false),
        steps: [act(status: ToolUiStatus.failed, name: 'shell', result: 'exit code=1')],
        isLive: false,
      );
      expect(find.textContaining('执行过程'), findsOneWidget);
      await tester.tap(find.textContaining('执行过程'));
      await tester.pump();
      expect(find.textContaining('🔧 shell'), findsOneWidget);
      await tester.tap(find.byType(ToolActivityCard));
      await tester.pump();
      expect(find.textContaining('exit code=1'), findsOneWidget);
    });

    testWidgets('已完成回合：思考存档入总折叠区（展开后可回看）', (tester) async {
      await pump(
        tester,
        const AgentUiState(running: false),
        steps: [act(status: ToolUiStatus.done, name: 'get_time')],
        answer: asst('答案'),
        thinking: const ['思考一', '思考二'],
        isLive: false,
      );
      expect(find.textContaining('1 工具 · 2 思考'), findsOneWidget);
      expect(find.textContaining('思考 1'), findsNothing);
      await tester.tap(find.textContaining('执行过程'));
      await tester.pump();
      // 展开后呈现思考存档块（块本身仍是折叠条，点开再看正文）。
      expect(find.textContaining('思考 1'), findsOneWidget);
      expect(find.textContaining('思考 2'), findsOneWidget);
      expect(find.textContaining('思考一'), findsNothing);
      await tester.tap(find.textContaining('思考 1'));
      await tester.pump();
      expect(find.textContaining('思考一'), findsOneWidget);
      expect(find.textContaining('答案'), findsOneWidget);
    });

    testWidgets('运行中且无答案 → 执行中…', (tester) async {
      await pump(tester, const AgentUiState(running: true), isLive: true);
      expect(find.text('执行中…'), findsOneWidget);
      // 非 live：历史回合不显示执行中行
      await pump(tester, const AgentUiState(running: true), isLive: false);
      expect(find.text('执行中…'), findsNothing);
    });

    testWidgets('live 回合：思考与工具按执行顺序交错渲染', (tester) async {
      // 时间线 [思考0, 工具0, 思考1, 工具1] → 渲染顺序必须与执行次序一致，
      // 而非"思考一律在前、工具一律在后"（用户反馈）。
      final ui = AgentUiState(
        running: true,
        thinkingHistory: ['第一步思考', '第二步思考'],
        thinkingDurations: const [Duration(seconds: 3), Duration(seconds: 2)],
        tools: [
          act(status: ToolUiStatus.done, name: 'web_search', result: '2 条结果'),
          act(status: ToolUiStatus.done, name: 'get_weather', result: '晴'),
        ],
        timeline: const [
          UiTimelineThinking(0),
          UiTimelineTool(0),
          UiTimelineThinking(1),
          UiTimelineTool(1),
        ],
      );
      await pump(tester, ui, isLive: true);
      expect(find.textContaining('思考 1 - 持续了3秒'), findsOneWidget);
      expect(find.textContaining('🔧 web_search'), findsOneWidget);
      expect(find.textContaining('思考 2 - 持续了2秒'), findsOneWidget);
      expect(find.textContaining('🔧 get_weather'), findsOneWidget);
      // 垂直顺序 = 执行顺序（思考0 → 工具0 → 思考1 → 工具1）。
      final dyThink1 = tester.getTopLeft(find.textContaining('思考 1 - 持续了3秒')).dy;
      final dyTool1 = tester.getTopLeft(find.textContaining('🔧 web_search')).dy;
      final dyThink2 = tester.getTopLeft(find.textContaining('思考 2 - 持续了2秒')).dy;
      final dyTool2 = tester.getTopLeft(find.textContaining('🔧 get_weather')).dy;
      expect(dyThink1, lessThan(dyTool1));
      expect(dyTool1, lessThan(dyThink2));
      expect(dyThink2, lessThan(dyTool2));
    });

    testWidgets('思考流式自动展开：流式中内容可见，答案开始/回合结束自动闭合',
        (tester) async {
      // 流式输出中 → 自动展开（否则用户不知道智能体在干什么）。
      final streaming = AgentUiState(running: true, thinking: '正在推理的内容');
      await pump(tester, streaming, isLive: true);
      expect(find.text('正在推理的内容'), findsOneWidget);

      // 答案开始 → 自动闭合（内容隐藏，仅剩头部耗时）。
      await pump(tester, streaming,
          isLive: true, answer: asst('答案'));
      expect(find.text('正在推理的内容'), findsNothing);

      // 回合结束（running=false）→ 闭合。
      await pump(tester, AgentUiState(thinking: '正在推理的内容'), isLive: true);
      expect(find.text('正在推理的内容'), findsNothing);
    });

    testWidgets('思考流式长内容：自动滚动到底部，用户上滑后暂停跟随', (tester) async {
      // 流式内容超过卡片 150px 可见区时，最新输出必须滚进可见区
      //（用户反馈：内容长了之后最新输出跑到可见区外）。
      String lines(int n) =>
          List.generate(n, (i) => '流式思考第$i行内容').join('\n');
      await pump(tester, AgentUiState(running: true, thinking: lines(3)),
          isLive: true);
      await tester.pump(); // 等首帧：didUpdateWidget 的 post-frame 跟随执行
      // 内容变长 → 自动滚到底部。
      await pump(tester,
          AgentUiState(running: true, thinking: lines(60)), isLive: true);
      await tester.pump();

      final scrollable = tester.widget<Scrollable>(find.byType(Scrollable).first);
      final pos = scrollable.controller!.position;
      expect(pos.maxScrollExtent, greaterThan(0)); // 内容确实超出可见区
      expect(pos.pixels, pos.maxScrollExtent); // 已跟随到底部

      // 用户手动上滑（查看早前内容）→ 暂停跟随。
      await tester.drag(find.byType(Scrollable).first, const Offset(0, 120));
      await tester.pump();
      final before = scrollable.controller!.position.pixels;
      expect(before, lessThan(scrollable.controller!.position.maxScrollExtent));

      // 流式继续变长 → 位置保持不动（不抢用户的阅读位置）。
      await pump(tester,
          AgentUiState(running: true, thinking: lines(80)), isLive: true);
      await tester.pump();
      expect(scrollable.controller!.position.pixels, before);
    });

    testWidgets('live 显示重试/压缩横幅，非 live 不显示', (tester) async {
      final liveUi = const AgentUiState(running: true, retryAttempt: 2, compacted: true);
      await pump(tester, liveUi, isLive: true);
      expect(find.textContaining('重试中'), findsOneWidget);
      expect(find.textContaining('上下文已压缩'), findsOneWidget);
      await pump(tester, liveUi, isLive: false);
      expect(find.textContaining('重试中'), findsNothing);
      expect(find.textContaining('上下文已压缩'), findsNothing);
    });

    testWidgets('答案：渲染回答内容（无头像）', (tester) async {
      final answer = asst('答案内容');
      await pump(tester, const AgentUiState(), answer: answer, isLive: false);
      expect(find.text('答案内容'), findsOneWidget);
    });
  });
}
