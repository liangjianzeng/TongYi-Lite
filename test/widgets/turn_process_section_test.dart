/// 折叠条摘要与展开区**同源**的行为锁（2026-11-09 复盘）。
///
/// 症状：智能体回合完成后「执行过程」折叠条上写的统计与点开看到的块对不上
/// ——头部另取 DB 🔧/💭 行族长度，展开区取 turnTrace 事件投影，于是
/// 步答块/失败尝试/通知行不进数字、解析失败的 🔧 行被静默丢掉（卡片照出）、
/// live 刚收尾时思考卡与步答块还被渲染两遍而头部只算一份。
///
/// 现口径：children 与计数在**同一趟遍历**产出（`_ProcessContent`），头部只
/// 能吃这份摘要。故本测试刻意让"行族口径"与"信封口径"互相矛盾，断言头部
/// 跟着**实际渲染的块**走；并逐个类型数展开后的块数，与头部数字一一对齐。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tongyi_lite/models/chat_message.dart';
import 'package:tongyi_lite/models/turn_trace.dart';
import 'package:tongyi_lite/providers/agent_state_provider.dart';
import 'package:tongyi_lite/widgets/agent_workflow.dart';

const _conv = 'c1';

ChatMessage _msg(String id, String content, {MessageKind kind = MessageKind.text}) =>
    ChatMessage(
      id: id,
      conversationId: _conv,
      role: MessageRole.assistant,
      content: content,
      timestamp: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      kind: kind,
    );

ToolActivityUi _tool(String name) => ToolActivityUi(
      callId: name,
      name: name,
      arguments: const {},
      status: ToolUiStatus.done,
      result: '$name 完成',
    );

Future<void> _pumpTurn(
  WidgetTester tester, {
  required AgentUiState ui,
  required bool isLive,
  List<ToolActivityUi> steps = const [],
  ChatMessage? answer,
  List<String> thinking = const [],
  List<TurnUiItem>? trace,
  Map<String, ToolActivityUi> traceTools = const {},
  List<ChatMessage> stepTexts = const [],
  List<ChatMessage> notices = const [],
  ChatMessage? todoCard,
  ChatMessage? planCard,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: ListView(
        children: [
          AgentTurnBlock(
            isLive: isLive,
            ui: ui,
            steps: steps,
            answer: answer,
            thinking: thinking,
            trace: trace,
            traceTools: traceTools,
            stepTexts: stepTexts,
            notices: notices,
            todoCard: todoCard,
            planCard: planCard,
          ),
        ],
      ),
    ),
  ));
}

/// 展开折叠区（默认收起，展开后才渲染内容块）。
Future<void> _expand(WidgetTester tester) async {
  await tester.tap(find.text('展开'));
  await tester.pump();
}

String _header(WidgetTester tester) =>
    find.textContaining('执行过程').evaluate().first.widget is Text
        ? (find.textContaining('执行过程').evaluate().first.widget as Text).data!
        : '';

void main() {
  group('执行过程折叠条摘要 = 展开区实际块数（同源）', () {
    testWidgets('信封口径优先：行族数字（DB 🔧/💭 行数）不得干扰摘要', (tester) async {
      // 刻意制造两套口径矛盾：DB 行族说有 5 个工具、0 个思考；
      // 信封（渲染真相源）实际是 3 工具 / 2 思考 / 2 步答 / 1 失败 / 1 通知。
      await _pumpTurn(
        tester,
        ui: const AgentUiState(),
        isLive: false,
        steps: List.generate(5, (i) => _tool('t$i')),
        thinking: const [],
        trace: [
          TurnUiItem.tool('a1'),
          TurnUiItem.think('先看目录结构'),
          TurnUiItem.tool('a2'),
          TurnUiItem.step('ans-s1'),
          TurnUiItem.think('再改配置'),
          TurnUiItem.tool('a3'),
          TurnUiItem.step('ans-s2'),
          TurnUiItem.error('失败尝试（timeout）：第 2 次重试超时'),
          TurnUiItem.notice('🔔 子代理已完成'),
        ],
        traceTools: {
          'a1': _tool('read_file'),
          'a2': _tool('write_file'),
          'a3': _tool('shell'),
        },
        stepTexts: [
          _msg('ans-s1', '第一步产出：定位到配置文件', kind: MessageKind.stepText),
          _msg('ans-s2', '第二步产出：已写入新配置', kind: MessageKind.stepText),
        ],
      );

      expect(_header(tester),
          '执行过程 · 2 步 · 3 工具 · 2 思考 · 1 失败 · 1 通知');

      await _expand(tester);
      // 头部每个数字都要能在展开区里数出来。
      expect(find.byType(ToolActivityCard), findsNWidgets(3));
      expect(find.text('思考'), findsNWidgets(2));
      expect(find.textContaining(' 输出'), findsNWidgets(2));
      expect(find.text('失败尝试（timeout）：第 2 次重试超时'), findsOneWidget);
      expect(find.text('🔔 子代理已完成'), findsOneWidget);
    });

    testWidgets('live 刚收尾（无信封）：思考卡与步答块不得渲染两遍', (tester) async {
      // timeline 已含一次思考 + 一个步答块；DB 侧 💭/stepText 行也在场。
      // 旧实现在这条回退路径上两套都渲染 → 各显示两遍，头部却只算一份。
      await _pumpTurn(
        tester,
        isLive: true,
        ui: AgentUiState(
          running: false,
          tools: [_tool('read_file')],
          thinkingHistory: const ['先想清楚再动手'],
          stepTexts: const ['中间步的可见文本'],
          timeline: const [
            UiTimelineThinking(0),
            UiTimelineTool(0),
            UiTimelineStepText(0),
          ],
          lastError: '本轮执行失败（net）：连接被重置',
        ),
        thinking: const ['先想清楚再动手'],
        stepTexts: [
          _msg('ans-s1', '中间步的可见文本', kind: MessageKind.stepText),
        ],
      );

      expect(_header(tester), '执行过程 · 1 步 · 1 工具 · 1 思考 · 1 失败');

      await _expand(tester);
      expect(find.byType(ToolActivityCard), findsOneWidget);
      expect(find.text('思考'), findsOneWidget,
          reason: '思考卡只能有一份：timeline 与 💭 行是同一批思考的两种载体');
      expect(find.textContaining(' 输出'), findsOneWidget,
          reason: '步答块同理：timeline 与 stepText 行不得双份');
      expect(find.text('本轮执行失败（net）：连接被重置'), findsOneWidget,
          reason: '回合级失败在折叠区要有落点（B3）');
    });

    testWidgets('无信封旧数据：空内容行不渲染也不计入摘要', (tester) async {
      await _pumpTurn(
        tester,
        ui: const AgentUiState(),
        isLive: false,
        steps: [_tool('web_search'), _tool('shell')],
        thinking: const ['想法甲', '想法乙'],
        stepTexts: [
          _msg('ans-s1', '第一步文本', kind: MessageKind.stepText),
          _msg('ans-s2', '   ', kind: MessageKind.stepText), // 空白 → 不渲染不计
        ],
        notices: [_msg('n1', '🔔 后台子代理完成', kind: MessageKind.notice)],
        todoCard: _msg('todo_$_conv', '☑ 任务清单\n- [x] 收尾'),
      );

      expect(_header(tester), '执行过程 · 1 步 · 2 工具 · 2 思考 · 1 通知');
      await _expand(tester);
      expect(find.byType(ToolActivityCard), findsNWidgets(2));
      expect(find.text('思考'), findsNWidgets(2));
      expect(find.textContaining(' 输出'), findsOneWidget);
      expect(find.text('🔔 后台子代理完成'), findsOneWidget);
    });

    testWidgets('过程全空：整个折叠区不渲染（不留空摘要头）', (tester) async {
      await _pumpTurn(
        tester,
        ui: const AgentUiState(),
        isLive: false,
        answer: _msg('ans', '最终回答'),
        stepTexts: [_msg('ans-s1', '   ', kind: MessageKind.stepText)],
      );
      expect(find.textContaining('执行过程'), findsNothing);
      expect(find.text('最终回答'), findsOneWidget);
    });
  });
}
