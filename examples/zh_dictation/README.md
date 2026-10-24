# 中文生字听写（`zh-dictation`）

拍语文课本生字表，按间隔朗读生字和拼音

形态：**声明式（只写 plugin.json + prompt.md，零 Dart）**

## 怎么让它跑起来

- 声明式：把整个目录推到手机的 `文档/plugins/zh-dictation/`，
  设置 → 插件 里「重新扫描」即可 —— 它写了 `enabledByDefault: true`，第一次扫到就自动是开的，
  不用再进面板点一下（自动打开只发生在**第一次见到**这个插件：你在面板把它关掉之后，
  重扫、重启都不会被翻回来 —— 你的决定优先于作者的默认值）。
  ```bash
  adb push ./examples/zh_dictation /storage/emulated/0/Android/data/<包名>/documents/plugins/zh-dictation
  ```
- 命令式：把生成的 `.dart` 放进 `lib/plugins/builtin/zh-dictation/`，
  并在 `lib/plugins/plugin_host.dart` 的 `builtin.register(...)` 旁边加一行注册。

## 先自检再装机

```bash
dart run tool/plugins.dart validate examples/zh_dictation
dart run tool/plugins.dart doctor --plugins-dir examples   # 看它（和别的示例）到底什么状态
```

## 作者纪律（7 条，违反会被 conformance 套件当场拦）

1. 永不 `throw`，一律返回 `Outcome`；
2. `apply()` 里只注册贡献物，不调能力、不做 IO；
3. 每个注册必须 `ctx.effect(...)`；
4. 每个 await 之后复查 `ctx.cancelToken`；
5. 先 `isAvailable` 再 `require`，把 `unavailableReason` 说给用户；
6. 只在自己的 `zh-dictation.*` 命名空间声明槽；
7. 用户可见文案 `message` ≤ 120 字、说人话，技术细节进 `cause`。


