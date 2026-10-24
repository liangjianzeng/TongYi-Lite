# 古诗抽查（`poem-recite`）—— 零 Dart 的声明式最小样例

拍一页课本 → 抽出诗句 → 家长点掉认错的 → 按间隔逐句朗读。

形态：**声明式（只写 `plugin.json` + `prompt.md`，零 Dart）**。
它是"这件事到底要不要写代码"的那把尺子 —— 听写、抽查、跟读这类流程，
四个原语（`capture` / `llm_extract` / `review` / `speak_sequence`）就够了，不用碰 Dart。

## 为什么值得先看它一眼

| 这里演示的 | 为什么重要 |
|---|---|
| `review` 夹在抽取与朗读之间 | 模型认错的句子**必须先被人点掉**再念给孩子听，不然错的一遍遍进耳朵 |
| `prompt.md` 的"不许补全"硬规则 | 照片里没有的句子**绝不许凭记忆补上** —— 孩子背错正是要抓出来的东西；看不清就整句不要，**宁少不错** |
| `ask_params` 放在朗读阶段 | 间隔几秒、念几遍、要不要连标题一起念，是**当时才决定**的事，不该逼用户提前在设置里配 |
| 顺序保真 | 按照片里的行文顺序，不许重排、不许按字数强拆 —— 听写场景里顺序就是答案 |

## 目录形状（作者最容易踩的一条）

```
examples/declarative_hello/
├── plugin.json     ← 声明（一层目录 = 一个插件，扫描只走一层）
└── prompt.md       ← 抽取指令（llm_extract 的 promptFile 指向它）
```

**别把声明再套一层**（比如塞进某个 Dart 包里）：`doctor --plugins-dir` 只看一层，
套进去的声明**不会被看见**，你会对着"一个都没见到"发懵。

## 装机

```bash
dart run tool/plugins.dart doctor --plugins-dir examples/declarative_hello   # 先体检
# 整目录推到手机 文档/plugins/poem-recite/，在「设置 → 插件」里重新扫描并打开
```

`doctor` 里它显示"📱 只在 app 里跑"是**正常的**：flow 引擎跑在 app 里，CLI 进程没有。

## 参数（`plugin.json` 的 `params`）

| 参数 | 意思 | 什么时候定 |
|---|---|---|
| `gapSeconds` | 每句之间隔几秒 | 跑之前 `ask_params` **当场问**；在面板「设置」里先填好，问的时候就是初值 |
| `repeatTimes` | 每句念几遍 | 同上 |
（以前这里还写着 `includeTitle`「连标题作者一起念」—— 流程里没有任何一步读它，
是个"面板上摆了个改了没反应的开关"的装饰品，`validate` 现在会提醒 `unusedParam`，于是删掉了。
**要加参数，就必须同时让流程真的用它**：`{{config.你的名字}}` 或 `ask_params` 的 `names`。）

注意 `ask_params` 那一步读的是 **`params.names`**：

```json
{ "id": "ask", "op": "ask_params", "phase": "recite", "params": { "names": ["gapSeconds", "repeatTimes"] } }
```

写成 `"params": { "params": [...] }` 是最容易踩的一个键名错 —— 运行时**一个问题都不会问**，
`{{config.gapSeconds}}` 退回默认值 0，古诗就变成不停顿的连珠炮，而流程显示"跑成功了"。
`validate`/`doctor` 现在会当场拦住这种写法（`askParamsWrongKey`）。

## 作者纪律（声明式版，5 条）

1. `id` 全局唯一，且只用自己 `poem-recite.*` 的命名空间；
2. `permissions` 与实际用到的能力对得上（用了 `capture` 才要 `camera`/`photo_library`；
   `llm_extract` 有图才要 `llm:vision`，纯文本要 `llm:chat`）；
3. `prompt.md` 是给模型看的，不是给用户看的 —— 硬规则写在里面，别指望它复述；
4. 抽取类任务一律配 `review`，除非错了不影响后果；
5. 文案里不许出现"失败/异常/错误码"这类词，说人话并给出下一步（`doctor` 会告诉你缺什么）。
