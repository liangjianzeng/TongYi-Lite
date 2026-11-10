// 生图消息（id 前缀 `imggen_`，带 imagePaths 的 assistant 消息）两条
// 不变量的锚（能力移植自汪柴；汪柴侧对应 chat_message_image_invariant_test）：
// ① 不回灌模型——SQLite → 会话日志导入与模型消息投影全程，图片键只属于
//    user 事件；assistant 的生图图片只是 UI 展示。
// ② 不占回答槽位——回合分组把 imggen_ 行收进 TurnUnit.imageCards，
//    回答位留给真回答（todo 卡 B4 同纪律）。
import 'package:flutter_test/flutter_test.dart';

import 'package:tongyi_lite/agent/builtin_tools/builtin_tools.dart';
import 'package:tongyi_lite/agent/session/event.dart';
import 'package:tongyi_lite/agent/session/log.dart';
import 'package:tongyi_lite/agent/session/store.dart';
import 'package:tongyi_lite/models/chat_message.dart';
import 'package:tongyi_lite/services/image_gen_service.dart';
import 'package:tongyi_lite/widgets/agent_workflow.dart';

ChatMessage _imggenMessage({String id = 'imggen_conv1_1700000000000_7'}) =>
    ChatMessage(
      id: id,
      conversationId: 'conv1',
      role: MessageRole.assistant,
      content:
          '🎨 生图（qwen-image-2.1-turbo-Q5_K_M · 1024x1024 · seed 7）：赛博朋克柴犬',
      imagePath: '/data/gen/img-1_7_1.png',
      imagePaths: const [
        '/data/gen/img-1_7_1.png',
        '/data/gen/img-1_7_2.png',
      ],
    );

void main() {
  group('不变量①：生图消息不回灌模型输入', () {
    test('SQLite 导入：assistant 事件不挂 imagePath/imagePaths 键', () {
      final store = JsonlSessionStore(baseDirOverride: '/tmp/tongyilite-test');
      final log = SessionLog.fromEvents([]);
      store.importMessagesInto(log, [
        ChatMessage(
          id: 'u1',
          conversationId: 'conv1',
          role: MessageRole.user,
          content: '给我配图',
          imagePath: '/data/in/a.png',
          imagePaths: const ['/data/in/a.png', '/data/in/b.png'],
        ),
        _imggenMessage(),
      ]);

      for (final e in log.rawEvents) {
        if (e.type == kEventAssistantMessage) {
          expect(e.data.containsKey('imagePath'), isFalse,
              reason: 'assistant 事件绝不带图片键（写入侧角色闸）');
          expect(e.data.containsKey('imagePaths'), isFalse);
        }
        if (e.type == kEventUserMessage) {
          // 用户带图消息照常入事件（视觉输入不受影响）。
          expect(e.data['imagePaths'],
              ['/data/in/a.png', '/data/in/b.png']);
        }
      }
    });

    test('模型投影：deriveModelMessages 里 assistant 无图片键、user 有', () {
      final store = JsonlSessionStore(baseDirOverride: '/tmp/tongyilite-test');
      final log = SessionLog.fromEvents([]);
      store.importMessagesInto(log, [
        ChatMessage(
          id: 'u1',
          conversationId: 'conv1',
          role: MessageRole.user,
          content: '画一张',
          imagePath: '/data/in/a.png',
        ),
        _imggenMessage(),
        ChatMessage(
          id: 'a1',
          conversationId: 'conv1',
          role: MessageRole.assistant,
          content: '画好了',
        ),
      ]);

      final model = log.deriveModelMessages();
      final users = model.where((m) => m['role'] == 'user');
      final assistants = model.where((m) => m['role'] == 'assistant');
      expect(users, isNotEmpty);
      expect(users.first['imagePath'], '/data/in/a.png');
      expect(assistants, isNotEmpty);
      for (final m in assistants) {
        expect(m.containsKey('imagePath'), isFalse);
        expect(m.containsKey('imagePaths'), isFalse);
      }
    });
  });

  group('不变量②：回合分组把生图行收进 imageCards，不占回答位', () {
    test('user → 工具卡 → 生图卡 → 回答：各归其位', () {
      final units = groupMessages([
        ChatMessage(
          id: 'u1',
          conversationId: 'conv1',
          role: MessageRole.user,
          content: '画只柴犬',
        ),
        ChatMessage(
          id: 't1',
          conversationId: 'conv1',
          role: MessageRole.assistant,
          content: '🔧 generate_image ✓ 已生成',
          toolData: const ToolActivityData(
              phase: 'done', name: 'generate_image', summary: '已生成'),
        ),
        _imggenMessage(),
        ChatMessage(
          id: 'a1',
          conversationId: 'conv1',
          role: MessageRole.assistant,
          content: '柴犬画好了，还配了两张图',
        ),
      ]);
      expect(units, hasLength(2));
      expect(units.first, isA<UserUnit>());
      final turn = units.last as TurnUnit;
      expect(turn.tools, hasLength(1));
      expect(turn.imageCards, hasLength(1));
      expect(turn.imageCards.single.id, startsWith('imggen_'));
      expect(turn.imageCards.single.imagePaths, hasLength(2));
      // 回答位是真回答，不是被时间戳更晚/更早的生图行挤掉（B4 教训）。
      expect(turn.answer?.id, 'a1');
    });

    test('回合只有生图行没有回答：answer 保持空，生图行仍渲染不蒸发', () {
      final units = groupMessages([
        ChatMessage(
          id: 'u1',
          conversationId: 'conv1',
          role: MessageRole.user,
          content: '画只柴犬',
        ),
        _imggenMessage(id: 'imggen_conv1_1_1'),
        _imggenMessage(id: 'imggen_conv1_2_2'),
      ]);
      final turn = units.last as TurnUnit;
      expect(turn.answer, isNull);
      expect(turn.imageCards, hasLength(2));
    });

    test('`/图` 占位行（isStreaming、无图）也进 imageCards，不占回答位', () {
      // chat_provider._handleSlashImage 生成期落的占位卡：id 同为 imggen_
      // 前缀 → 必须走卡片通道（渲染成进度态），绝不能被当回答挤占 answer。
      final units = groupMessages([
        ChatMessage(
          id: 'u1',
          conversationId: 'conv1',
          role: MessageRole.user,
          content: '/图 画只柴犬',
        ),
        ChatMessage(
          id: 'imggen_conv1_9',
          conversationId: 'conv1',
          role: MessageRole.assistant,
          content: '🎨 生成图片中… 画只柴犬',
          isStreaming: true,
        ),
      ]);
      final turn = units.last as TurnUnit;
      expect(turn.answer, isNull);
      expect(turn.imageCards, hasLength(1));
      expect(turn.imageCards.single.isStreaming, isTrue);
      expect(turn.imageCards.single.imagePaths, isNull);
    });

    test('createGenerateImageTool 缺省不注册（门控已由 builtin 测覆盖，此处锚定导出面）', () {
      final tool = createGenerateImageTool(
          configLoader: () async =>
              const ImageGenConfig(enabled: false, baseUrl: ''));
      expect(tool.name, 'generate_image');
      expect(createBuiltinTools().map((t) => t.name),
          isNot(contains('generate_image')));
    });
  });
}
