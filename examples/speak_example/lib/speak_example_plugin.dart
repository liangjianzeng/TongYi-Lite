/// 朗读型插件参考实现（`speak-example`）。
///
/// 存在的理由：**脚手架模板必须能编译、能跑**。
/// `tool/plugins.dart scaffold --kind dart` 生成的代码与这里逐行同形（只差 id/名字），
/// 模板把 `Speak` 的 API 用错（比如自己 sleep 造成双倍间隔）会被这个包的测试当场抓住。
library;

import 'package:plugin_sdk/plugin_sdk.dart';

final class SpeakExamplePlugin implements AppPlugin {
  static const PluginManifest manifestDef = PluginManifest(
    id: 'speak-example',
    name: '朗读示例',
    description: '把一批条目按间隔逐条念出来（参考实现）',
    whenToUse: '需要逐条朗读时用',
    inject: ['app.speak', 'app.store'],
    permissions: [PluginPermission.speechSynthesis, PluginPermission.pluginStorage],
    trust: PluginTrust.trusted,
    params: [
      PluginParam(
        name: 'gapSeconds',
        label: '间隔秒数',
        type: PluginParamType.number,
        defaultValue: 5,
        min: 1,
        max: 60,
        askAtStart: true,
      ),
      PluginParam(name: 'voice', label: '音色', type: PluginParamType.text, defaultValue: ''),
      PluginParam(
        name: 'lastGapSeconds',
        label: '上次用的间隔',
        type: PluginParamType.number,
        defaultValue: 5,
        volatile: true,
      ),
    ],
  );

  @override
  PluginManifest get manifest => manifestDef;

  @override
  Outcome<Disposable?> apply(PluginCtx ctx) {
    // apply 只注册、不做任何能力调用（conformance 的「生命周期」组数得出来）；
    // 但**要先声明能力齐不齐** —— 缺就当场失败，面板显示"缺：xxx"，别等 run 才炸。
    final ready = ensureDeclaredCapabilities(ctx);
    if (ready.isErr) return Err<Disposable?>(ready.failureOrNull!);

    final ownSlot = ctx.slots.declare(const SlotDef(
      id: 'speak-example.action',
      kind: SlotKind.list,
      scope: SlotScope.session,
      ownerPluginId: 'speak-example',
      description: '本插件自己的动作位（别人也可以来填）',
    ));
    if (ownSlot.isErr) return Err<Disposable?>(ownSlot.failureOrNull!);

    final chip = ctx.slots.register(SlotContribution<Object?>(
      slotId: 'app.input.right',
      pluginId: ctx.manifest.id,
      id: 'chip',
      label: '朗读示例',
      payload: '朗读示例',
    ));
    if (chip.isErr) return Err<Disposable?>(chip.failureOrNull!);

    // 贡献物必须挂进 effect，否则关掉插件后槽里留幽灵。
    ctx.effect(chip.valueOrNull!);
    return const Ok<Disposable?>(null);
  }

  @override
  Future<Outcome<PluginRunResult>> run(PluginCtx ctx, PluginInput input) async {
    // ① 先判可用性再取，把"本机没有"的原因原样转达（别静默失败）。
    if (!ctx.capabilities.isAvailable(ServiceKeys.speak.id)) {
      return Outcome.err<PluginRunResult>(
        code: PluginFailureKind.missingCapability,
        message: '朗读示例需要朗读能力，本机还没有',
        hint: ctx.capabilities.unavailableReason(ServiceKeys.speak.id) ?? '检查朗读相关设置',
        pluginId: ctx.manifest.id,
      );
    }
    final speak = ctx.capabilities.require<Speak>(ServiceKeys.speak);
    if (speak.isErr) return Err<PluginRunResult>(speak.failureOrNull!);

    final gap = ctx.numberConfig('gapSeconds', 5);
    final items = itemsOf(input);
    if (items.isEmpty) {
      return Outcome.err<PluginRunResult>(
        code: PluginFailureKind.badContent,
        message: '没有可朗读的内容',
        hint: '先选一张图或输入要念的内容',
        pluginId: ctx.manifest.id,
      );
    }

    // ② 朗读交给能力：间隔/合成/播放都在 Speak 内部（含"播完再等"），
    //    插件只消费进度流 —— 自己 sleep 会和能力的 gap 叠加成双倍间隔（作者常犯的错）。
    final stream = speak.valueOrNull!.speak(
      SpeakRequest(
        items: items,
        voice: ctx.stringConfig('voice', ''),
        gap: Duration(seconds: gap.round()),
      ),
      ctx.cancelToken,
    );
    var done = 0;
    final skipped = <String>[];
    await for (final progress in stream) {
      // 每个 await 边界都复查取消：用户按停止必须真停得下来。
      ctx.cancelToken.throwIfCancelled();
      switch (progress.phase) {
        case SpeakPhase.playing:
          done += 1;
        case SpeakPhase.skipped:
          // 个别条目念不成不中断整场，最后一起报给用户。
          skipped.add(progress.text);
        case SpeakPhase.synthesizing:
        case SpeakPhase.gap:
          break;
      }
    }

    // ③ 被用户中途停掉：如实报"停在哪"，但不写易变值、不报喜（userVisible=false 由调用方决定显不显示）。
    if (ctx.cancelToken.isCancelled) {
      return Ok<PluginRunResult>(PluginRunResult(
        summary: '已停止（读到第 \$done 条）',
        data: {'count': done, 'skipped': skipped},
        userVisible: false,
      ));
    }

    // ④ 记下易变值（volatile 参数不算配置变更，不会诱发重载）。
    final store = ctx.capabilities.isAvailable(ServiceKeys.store.id)
        ? ctx.capabilities.require<Store>(ServiceKeys.store)
        : null;
    if (store != null && store.isOk) {
      await store.valueOrNull!.write('lastGapSeconds', '$gap');
    }

    ctx.log.info('读完 $done/${items.length} 条（间隔 ${gap}s，入口 ${input.entry.name}）');
    final tail = skipped.isEmpty ? '' : '，${skipped.length} 条没念成';
    return Ok<PluginRunResult>(
      PluginRunResult(summary: '读完 $done 条$tail', data: {'count': done, 'skipped': skipped}),
    );
  }

  /// 入口内容：优先 args 里的显式列表，其次把 text 按分隔拆开。
  static List<String> itemsOf(PluginInput input) {
    final fromArgs = input.args['items'];
    if (fromArgs is List) {
      return [for (final e in fromArgs) '$e'.trim()].where((e) => e.isNotEmpty).toList();
    }
    return input.text
        .split(RegExp(r'[、,，;；\n]'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
  }
}
