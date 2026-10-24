/// 插件作者参考实现（Hello, plugin）。
///
/// 三件事它都做到了，所以平台契约可用：
/// 1. **只经 [PluginCtx] 取宿主能力** —— 本文件没有任何 `import 'package:tongyi_lite/...'`；
/// 2. **注册挂 `ctx.effect`** —— 禁用插件后账本必须干净；
/// 3. **失败一律 `Outcome`** —— 不 `throw`，每种失败都能被一句话解释并给出路。
///
/// 抄它写你的插件；`tool/plugin_scaffold.dart` 生成的骨架就是这份的精简版。
library;

import 'package:plugin_sdk/plugin_sdk.dart';

class HelloPlugin implements AppPlugin {
  @override
  PluginManifest get manifest => const PluginManifest(
        id: 'hello-plugin',
        name: '你好插件',
        description: '平台契约的参考实现：填一个输入区图标，点了打个招呼并记一笔',
        whenToUse: '演示插件平台怎么用；不是给用户用的功能',
        icon: 'waving_hand',
        source: PluginSource.builtin,
        trust: PluginTrust.trusted,
        enabledByDefault: false,
        // 只声明真依赖：能力不齐时内核根本不加载它（照抄 Cordis 的 inject 门控），
        // 于是插件代码里不需要写"如果没网就……"这种分支。
        inject: ['app.store', 'app.interact'],
        permissions: [PluginPermission.pluginStorage],
        params: [
          PluginParam(
            name: 'greetTimes',
            label: '打招呼次数',
            type: PluginParamType.number,
            defaultValue: 2,
            min: 1,
            max: 9,
            description: '每次点图标打几次招呼',
          ),
        ],
      );

  @override
  Outcome<Disposable?> apply(PluginCtx ctx) {
    // ① 自查 inject：内核也会门控，这里是双保险（面板上手动重载时内核不一定重走门控）。
    for (final id in manifest.inject) {
      if (!ctx.capabilities.isAvailable(id)) {
        return Err<Disposable?>(PluginFailure(
          code: PluginFailureKind.missingCapability,
          message: ctx.capabilities.unavailableReason(id) ?? '这台机器还缺「$id」',
          hint: '看「设置」页对应开关，或在「插件」面板查看本机能力清单',
          pluginId: manifest.id,
        ));
      }
    }

    // ② 填宿主的槽：order 决定位置，同格同 priority 会报错并指名占用者（不是静默不显示）。
    final chip = ctx.slots.register(SlotContribution<Object?>(
      slotId: 'app.input.right',
      pluginId: manifest.id,
      id: 'hello-chip',
      label: '你好',
      // 载荷是 Object?：真插件在这里塞一个 widget 工厂，测试里塞哨兵值。
      payload: 'hello-chip-icon',
      order: 20,
    ));
    if (chip.isErr) return Err<Disposable?>(chip.failureOrNull!);
    // ③ **注册必须挂 effect**，否则禁用插件后图标还在（平台最难查的一类 bug）。
    ctx.effect(chip.valueOrNull!);

    // ④ 也可以自己当 owner 声明槽，让别人往你的卡片里塞按钮（生态的关键一步）。
    final own = ctx.slots.declare(const SlotDef(
      id: 'hello.greetingAction',
      kind: SlotKind.list,
      scope: SlotScope.session,
      ownerPluginId: 'hello-plugin',
      description: '招呼卡片上的动作位；条目自己决定点击行为，能力不可用时渲染置灰。',
    ));
    if (own.isErr) return Err<Disposable?>(own.failureOrNull!);
    // declare 无需反注册：槽是 owner 的静态结构，随插件卸载由内核统一清账本。

    ctx.log.info('apply 完成，traceId=${ctx.traceId}');
    return const Ok<Disposable?>(null);
  }

  @override
  Future<Outcome<PluginRunResult>> run(PluginCtx ctx, PluginInput input) async {
    if (ctx.cancelToken.isCancelled) {
      return Err<PluginRunResult>.of(PluginFailureKind.cancelled, '已取消');
    }

    final store = ctx.capabilities.require<Store>(ServiceKeys.store);
    final interact = ctx.capabilities.require<Interact>(ServiceKeys.interact);
    if (store.isErr) return Err<PluginRunResult>(store.failureOrNull!);
    if (interact.isErr) return Err<PluginRunResult>(interact.failureOrNull!);

    final times = ctx.numberConfig('greetTimes', 2).clamp(1, 9).toInt();
    final answer = await interact.valueOrNull!
        .askNumber(question: '招呼几次？', defaultValue: times.toDouble(), min: 1, max: 9);
    final n = (answer.valueOrNull ?? times.toDouble()).toInt();

    // 每个 await 边界复查取消（本仓 _seq 血泪教训：不复查就会在"停止"之后继续干活）。
    if (ctx.cancelToken.isCancelled) {
      return Err<PluginRunResult>.of(PluginFailureKind.cancelled, '已取消');
    }

    final history = await store.valueOrNull!.read('greetings');
    final written = await store.valueOrNull!.write('greetings', '${(int.tryParse(history.valueOrNull ?? '0') ?? 0) + n}');
    return written.map((_) => PluginRunResult(
          summary: '打了 $n 次招呼（累计 ${(int.tryParse(history.valueOrNull ?? '0') ?? 0) + n}）',
          data: {'times': n},
        ));
  }
}
