# 朗读示例（`speak-example`）—— 把 `Speak` 用对的参考实现

听写、跟读、背单词这类插件都要"念一条、等几秒、再念下一条"。
这件事**只有一种正确写法**，而这个包就是那份"正确写法"的可执行版本：
`scaffold --kind dart` 生成的模板与它逐行同形，模板把 API 用错（比如自己 `sleep` 造成双倍间隔）
会被这个包的测试当场抓住。

形态：**代码级（Dart，`implements AppPlugin`）**。

## 最容易写错的四点（这个包用测试钉着）

1. **间隔写在 `Speak` 里，不许自己 `await Future.delayed`** ——
   两边都等 = 间隔翻倍，而且取消时你的 `delayed` 还在跑（用户按了停止还在念）。
2. **间隔是播放的一部分**，所以 `items` + `gapMs` 一次交给 `Speak`，不要逐条 `for` 循环。
3. **每个 await 之后复查 `ctx.cancelToken`**，取消要变成 `cancelled`，不是"静悄悄当成功"。
4. **能力先 `isAvailable` 再 `require`**，不可用时把 `unavailableReason` 原样说给用户
   （可能是没网、也可能是离线模型没放）——自己编一句"播放失败"等于把线索扔了。

## 自检

```bash
cd examples/speak_example && dart test
```

`test/speak_example_test.dart` 用的是 `plugin_sdk/testing.dart` 里的假能力，
所以**不需要真机、不需要网络**就能跑完；插件本体的契约由 `runConformance` 六组检查把关。

## 想真的在 app 里听它念

代码级插件不能从磁盘加载（见方案档 §11），两条路：

- **零 Dart 的替代**：如果只是"念一串词 + 间隔"，直接写声明式插件（见 `examples/zh_dictation/`），
  `speak_sequence` 原语已经覆盖，不用碰 Dart；
- **真要自己写代码**：把 `lib/speak_example_plugin.dart` 拷进 `lib/plugins/builtin/<你的 id>/`，
  在 `lib/plugins/plugin_host.dart` 的 `builtin.register(...)` 旁加一行，再 `bash tool/build_apk.sh`。

## 相关

- 契约与纪律：`docs/插件平台_契约冻结清单_2026-10-23.md`
- 总体设计：`docs/能力插件体系与英语听写插件_方案_2026-10-23.md`
