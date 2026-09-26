/// Phase 6 tests：SessionLog 事件流 + AgentUiState reducer + 活动面板渲染。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tongyi_lite/agent/session/event.dart';
import 'package:tongyi_lite/agent/session/log.dart';
import 'package:tongyi_lite/providers/agent_state_provider.dart';
import 'package:tongyi_lite/widgets/agent_activity_panel.dart';

void main() {
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

  group('AgentActivityPanel 渲染', () {
    Future<void> pump(WidgetTester tester, AgentUiStateNotifier n) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            agentUiStateProvider.overrideWith((ref) => n),
          ],
          child: const MaterialApp(
            home: Scaffold(body: AgentActivityPanel()),
          ),
        ),
      );
    }

    testWidgets('空状态不渲染', (tester) async {
      await pump(tester, AgentUiStateNotifier());
      expect(find.byType(ToolActivityCard), findsNothing);
    });

    testWidgets('工具卡片 + 压缩横幅 + 重试指示渲染', (tester) async {
      final n = AgentUiStateNotifier();
      final log = SessionLog.fromEvents([]);
      n.attach(log);
      log.append(kEventTurnStart, {'turn': 1});
      log.append(kEventCompactionSummary, {'content': '摘要'});
      log.append(kEventLlmRetry, {'turn': 1, 'step': 1, 'retries': 2});
      log.append(kEventToolCall,
          {'callId': 'c1', 'name': 'get_time', 'arguments': {'tz': 'UTC'}});
      log.append(kEventToolResult,
          {'callId': 'c1', 'name': 'get_time', 'content': 'ok', 'isError': false});

      await pump(tester, n);
      expect(find.text('🔧 get_time'), findsOneWidget);
      expect(find.text('上下文已压缩'), findsOneWidget);
      expect(find.text('重试中…（2）'), findsOneWidget);
      n.detach();
      log.dispose();
    });

    testWidgets('运行中且无工具 → 状态行含 turn/step', (tester) async {
      final n = AgentUiStateNotifier();
      final log = SessionLog.fromEvents([]);
      n.attach(log);
      log.append(kEventTurnStart, {'turn': 2});
      log.append(kEventStepStart, {'turn': 2, 'step': 3});
      await pump(tester, n);
      expect(find.textContaining('turn 2 / step 3'), findsOneWidget);
      n.detach();
      log.dispose();
    });
  });
}
