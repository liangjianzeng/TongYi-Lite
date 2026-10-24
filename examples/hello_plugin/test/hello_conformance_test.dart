import 'dart:convert';
import 'dart:io';

import 'package:hello_plugin/hello_plugin.dart';
import 'package:plugin_sdk/plugin_sdk.dart';
import 'package:plugin_sdk/testing.dart';
import 'package:test/test.dart';

/// 参考实现必须**永远通过一致性套件**：它是作者的模板，模板烂了整套生态就烂了。
void main() {
  FakeCapabilityHarness harness() {
    final h = FakeCapabilityHarness();
    h.register(FakeStore());
    h.register(FakeInteract(numbers: [3]));
    h.register(FakeLlmComplete());
    h.register(FakeLlmVision());
    h.register(FakeSpeak());
    h.register(FakeCapture());
    return h;
  }

  group('参考实现通过平台体检', () {
    test('六组检查零失败', () async {
      final all = await runConformance(
        () => HelloPlugin(),
        harness: harness(),
        config: const {'greetTimes': 3},
      );
      expect(all.where((c) => !c.passed).map((c) => c.toString()), isEmpty);
    });

    test('run 真的写了分域存储（不是空转通过）', () async {
      final h = harness();
      final all = await runConformance(() => HelloPlugin(), harness: h, config: const {'greetTimes': 2});
      expect(all.every((c) => c.passed), isTrue);
      expect(h.calls.map((c) => '${c.capabilityId}.${c.method}'), containsAll(<String>['app.store.read', 'app.store.write']));
      expect((h.byId['app.store']! as FakeStore).data['greetings'], '3'); // 预设答 3 次
    });

    test('禁用插件后输入区图标消失（回收组的现实版）', () async {
      final h = harness();
      final ctx = FakePluginCtx(manifest: HelloPlugin().manifest, harness: h, permissions: const {'storage:plugin'});
      final apply = HelloPlugin().apply(ctx);
      expect(apply.isOk, isTrue);
      expect(ctx.slotsLedger.entries('app.input.right').map((e) => e.id), ['hello-chip']);
      expect(ctx.slotsLedger.isDeclared('hello.greetingAction'), isTrue);
      await ctx.disposeAllEffects();
      expect(ctx.slotsLedger.entries('app.input.right'), isEmpty);
    });

    test('能力不齐（没装 ASR 之类的场景）时 apply 明确失败并说清缺什么', () async {
      final h = harness();
      (h.byId['app.interact']! as FakeCapability).available = false;
      final ctx = FakePluginCtx(manifest: HelloPlugin().manifest, harness: h, permissions: const {'storage:plugin'});
      final r = HelloPlugin().apply(ctx);
      expect(r.failureOrNull?.code, PluginFailureKind.missingCapability);
      expect(r.failureOrNull?.message, contains('app.interact'),
          reason: 'isNotEmpty 什么都过；真正的契约是**必须点名缺哪个能力**（message 可能来自能力自报的理由，也可能是兜底句，钉死整句反而变成断测试桩的话）');
      expect(r.failureOrNull?.hint, contains('看「设置」页对应开关'),
          reason: '两字「设置」可以是任何设置页；真话还给了第二条路（在「插件」面板看能力清单）');
      expect(ctx.slotsLedger.entries('app.input.right'), isEmpty, reason: '失败就不该留下半个图标');
    });
  });

  group('声明式示例（用户手写的那一档）', () {
    test('plugin.json 合契约（含隐含权限齐全）', () {
      final raw = _readExample('plugin.json');
      final r = validateManifestText(
        raw,
        knownCapabilityIds: {'app.capture', 'llm.vision', 'app.interact', 'app.speak', 'app.store'},
      );
      expect(r.issues.map((e) => e.toString()), isEmpty, reason: r.format());
      expect(r.ok, isTrue);
    });

    test('prompt.md 在预算内且不为空', () {
      final text = _readExample('prompt.md');
      expect(validatePrompt(text, pluginId: 'poem-recite').ok, isTrue);
      expect(text, contains('不许补全'));
    });

    test('manifest 往返后仍然合契约（面板保存→重读不回退）', () {
      final m = PluginManifest.fromJson(jsonDecode(_readExample('plugin.json')) as Map<String, dynamic>);
      expect(m.trust, PluginTrust.declarative);
      expect(m.flow!.steps.map((s) => s.op).toList(), [
        FlowStepOp.capture,
        FlowStepOp.llmExtract,
        FlowStepOp.review,
        FlowStepOp.askParams,
        FlowStepOp.speakSequence,
      ]);
      final again = validateManifest(m.toJson(), knownCapabilityIds: {'app.capture', 'llm.vision', 'app.interact', 'app.speak'});
      expect(again.issues.map((e) => e.toString()), isEmpty);
    });
  });
}

String _readExample(String name) {
  // 声明式示例是**兄弟目录**（`examples/declarative_hello`）：平台的规矩是"一层目录 = 一个插件"，
  // 把它塞进本包里就会让 `doctor --plugins-dir examples` 看不见它 —— 示例必须自己守住自己定的规矩。
  // 两个 base 分别是"在本包目录下跑 dart test"与"在仓库根跑"，都能命中。
  for (final base in ['../declarative_hello', 'examples/declarative_hello', 'declarative_hello']) {
    final f = File('$base/$name');
    if (f.existsSync()) return f.readAsStringSync();
  }
  throw StateError('找不到示例文件 $name（应在 examples/hello_plugin 下运行 dart test，声明在兄弟目录 examples/declarative_hello）');
}
