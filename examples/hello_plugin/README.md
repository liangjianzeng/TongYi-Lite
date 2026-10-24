# 你好示例（`hello-note`）—— 代码级插件的参考实现

一个**什么都敢碰一遍**的最小插件：问用户一个数、存进 `app.store`、下次开机报给他，
外加两个槽位（输入区图标 + 卡片）。它不是玩具 —— 它是"平台契约可用"的证明：
**它绿了，作者照抄就是对的**。

形态：**代码级（Dart，`implements AppPlugin`）**。

## 这个目录里有什么

| 东西 | 是什么 |
|---|---|
| `lib/hello_plugin.dart` | 参考实现本体（脚手架 `scaffold --kind dart` 生成的代码与它逐行同形） |
| `test/hello_conformance_test.dart` | 跑 `runConformance` + `runCapabilityConformance` 全套体检 |
它还有一个**兄弟目录** `examples/declarative_hello/`（古诗抽查）：同一个思路的**声明式版本**，
只写 `plugin.json` + `prompt.md`，零 Dart。想知道"这件事能不能不写代码"，先看它。

平台的规矩是**一层目录 = 一个插件**（扫描只走一层），所以声明式示例绝不许塞进本包里 ——
以前它住在 `hello_plugin/declarative_example/`，`doctor --plugins-dir examples` 直接看不见它；
作者照抄就把自己的插件也套了一层，然后对着"一个都没见到"发懵。现在它自己占一层：

```bash
dart run tool/plugins.dart doctor --plugins-dir examples/declarative_hello
```

## 先自检再装机

```bash
cd examples/hello_plugin && dart test          # 契约体检，必须全绿
dart run tool/plugins.dart validate examples/declarative_hello
```

## 想真的在 app 里看到它

代码级插件**不能从磁盘加载**（今天没有这条路，见方案档 §11 `extension` 级预研），只能编进 app：

1. 把 `lib/hello_plugin.dart` 拷进 `lib/plugins/builtin/<你的 id>/`；
2. 在 `lib/plugins/plugin_host.dart` 的 `builtin.register(...)` 旁边加一行注册；
3. `bash tool/build_apk.sh`，装到手机上，设置 → 插件 里打开开关。

（app 里内置的那份是 `lib/plugins/builtin/hello/hello_plugin.dart`，与本包同源；
两边都改时要一起改，否则参考实现和真跑的那份会漂。）

## 作者纪律（7 条，违反会被 conformance 套件当场拦）

1. 永不 `throw`，一律返回 `Outcome`；
2. `apply()` 里只注册贡献物，不调能力、不做 IO；
3. 每个注册必须 `ctx.effect(...)`；
4. 每个 await 之后复查 `ctx.cancelToken`；
5. 先 `isAvailable` 再 `require`，把 `unavailableReason` 说给用户；
6. 只在自己的 `hello-note.*` 命名空间声明槽；
7. 用户可见文案 `message` ≤ 120 字、说人话，技术细节进 `cause`。
