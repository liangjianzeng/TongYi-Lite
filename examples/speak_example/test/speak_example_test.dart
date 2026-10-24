import 'package:plugin_sdk/plugin_sdk.dart';
import 'package:plugin_sdk/testing.dart';
import 'package:speak_example/speak_example_plugin.dart';
import 'package:test/test.dart';

/// 朗读型插件是本平台第一个真吃能力的验收实例，这里钉的不是"能不能过体检"，
/// 而是**作者照着模板抄会不会做错**：双倍间隔、个别词失败就整场崩、
/// 用户按了停止还写"已完成"——这些坑必须在参考实现里当场死掉。
void main() {
  FakeCapabilityHarness harness({Map<int, String> failAt = const {}, Duration perItem = Duration.zero}) {
    final h = FakeCapabilityHarness();
    h.register(FakeStore());
    h.register(FakeSpeak(perItem: perItem, failAt: failAt));
    return h;
  }

  FakePluginCtx ctxOf(FakeCapabilityHarness h, {Map<String, Object?>? config}) => FakePluginCtx(
        manifest: SpeakExamplePlugin().manifest,
        harness: h,
        config: config,
      );

  PluginInput inputOf(List<String> items) =>
      PluginInput(entry: PluginEntryKind.composerAction, args: {'items': items});

  group('平台体检', () {
    test('六组检查零失败（模板烂了整套生态就烂了）', () async {
      final all = await runConformance(
        SpeakExamplePlugin.new,
        harness: harness(),
        config: const {'gapSeconds': 0},
        input: inputOf(const ['apple', 'banana']),
      );
      expect(all.where((c) => !c.passed).map((c) => '${c.group}/${c.name}：${c.detail}'), isEmpty);
      expect(all.map((c) => c.group), containsAll(<String>['契约', '生命周期', '回收', '状态与错误', '槽', '预算']));
    });
  });

  group('朗读语义', () {
    test('间隔交给能力内部控制：插件只发一次 SpeakRequest，自己不 sleep', () async {
      final h = harness();
      final r = await SpeakExamplePlugin().run(
        ctxOf(h, config: {'gapSeconds': 5}),
        inputOf(const ['apple', 'banana', 'cherry']),
      );
      expect(r.isOk, isTrue, reason: r.failureOrNull?.message);
      expect(r.valueOrNull!.summary, '读完 3 条');
      final speak = h.byId['app.speak']! as FakeSpeak;
      expect(speak.requests, hasLength(1), reason: '一轮一场，不能一条一次（否则代次/停止全乱）');
      expect(speak.lastRequest!.items, ['apple', 'banana', 'cherry']);
      expect(speak.lastRequest!.gap, const Duration(seconds: 5));
      // 双倍间隔的坑：3 条 × gap 5s 若被插件自己再 sleep 一次，这里会翻倍。
      expect(h.calls.where((c) => c.capabilityId == 'app.speak' && c.method == 'speak'), hasLength(1));
    });

    test('个别条目念不成不中断整场，最后如实报数', () async {
      final h = harness(failAt: const {1: '该音色对这段文本没有返回音频'});
      final r = await SpeakExamplePlugin().run(
        ctxOf(h, config: {'gapSeconds': 0}),
        inputOf(const ['apple', 'banana', 'cherry']),
      );
      expect(r.isOk, isTrue);
      expect(r.valueOrNull!.summary, '读完 2 条，1 条没念成');
      expect(r.valueOrNull!.data['skipped'], ['banana']);
    });

    test('用户中途停止：报"停在哪"，不写易变值、不报喜', () async {
      final h = harness(perItem: const Duration(milliseconds: 5));
      final ctx = ctxOf(h, config: {'gapSeconds': 0});
      ctx.cancelToken.cancel('用户按了停止');
      final r = await SpeakExamplePlugin().run(ctx, inputOf(const ['apple', 'banana']));
      expect(r.isOk, isTrue, reason: '取消是正常终态，不是失败');
      expect(r.valueOrNull!.userVisible, isFalse, reason: '用户自己停的，不该弹"已完成"');
      expect(r.valueOrNull!.summary, contains('已停止'));
      expect((h.byId['app.store']! as FakeStore).data, isEmpty, reason: '没念完就别记住"上次的间隔"');
    });

    test('音色原样透传（空串 = 让宿主按文本语言挑，不在插件里猜）', () async {
      final h = harness();
      await SpeakExamplePlugin().run(ctxOf(h, config: {'voice': 'en-US-AriaNeural'}), inputOf(const ['apple']));
      expect((h.byId['app.speak']! as FakeSpeak).lastRequest!.voice, 'en-US-AriaNeural');
    });
  });

  group('失败要说人话', () {
    test('没有内容 → badContent + 下一步做什么', () async {
      final r = await SpeakExamplePlugin().run(
        ctxOf(harness()),
        const PluginInput(entry: PluginEntryKind.composerAction, text: '  '),
      );
      expect(r.isErr, isTrue);
      expect(r.failureOrNull!.code, PluginFailureKind.badContent);
      expect(r.failureOrNull!.hint, contains('先选一张图或输入要念的内容'),
          reason: '空文本时不能只说不行，要给两个当场做得动的动作');
    });

    test('本机没有朗读能力 → 说清缺什么，而不是空转成功', () async {
      final h = FakeCapabilityHarness()..register(FakeStore());
      final r = await SpeakExamplePlugin().run(ctxOf(h), inputOf(const ['apple']));
      expect(r.isErr, isTrue);
      expect(r.failureOrNull!.code, PluginFailureKind.missingCapability);
      expect(r.failureOrNull!.message, contains('朗读示例需要朗读能力，本机还没有'),
          reason: '两字「朗读」太松：要说破缺的是【本机的朗读能力】，不是插件自己不想念');
    });

    test('text 入口按分隔符切条目（作者不必自己写解析）', () {
      expect(
        SpeakExamplePlugin.itemsOf(const PluginInput(entry: PluginEntryKind.slashCommand, text: 'apple、banana, cherry；date')),
        ['apple', 'banana', 'cherry', 'date'],
      );
    });
  });
}
