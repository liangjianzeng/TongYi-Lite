# 中英默写卡（`en-zh-cards`）· 零 Dart 插件 · 实例 C

**它存在的目的不是好用，是"找平台的茬"**：实例 A/B 都有相机和朗读，这个故意做成
**无相机、无朗读、纯文本进出**（用户贴一段课文 → 出中英对照卡 → 导出练习单）。
两个形态迥异的消费者才允许我们说"这套 flow 原语是通用的"（方案档 §4.10 两消费者规则）。

## 作者写了什么

只有两个文件：`plugin.json`（声明）+ `prompt.md`（语义）。一行 Dart 都没有，
实现体由内核的 flow 引擎代填（`FlowRunner`）。

用到的原语：`ask_params`（问要几张卡）→ `llm_extract`（纯文本补全）→ `review` →
`export`（练习单交给宿主分享）→ `store`（记住上次生成的卡）。

## 它替平台抓到的三个缺口（都已修）

| 缺口 | 现象 | 修法 |
|---|---|---|
| `llm_extract` 强制要 `llm:vision` | 纯文本插件被逼声明视觉权限 | 隐含权限改成看流程：有 `capture`（或 `useImages:true`）才要 `llm:vision`，否则要 `llm:chat` |
| 提示词看不到运行时问到的值 | `prompt.md` 里没法写"做 {{count}} 张" | `_renderPrompt` 三层替换：步骤参数 → `ask_params` 的值 → 用户输入 |
| 无图时走文本补全需要 `llm:chat` | 只声明 `llm:vision` 的作者被一句"未声明 llm:chat"卡住 | 失败提示直接告诉他加权限或把 capture 排前面 |

## 装到手机上

```bash
dart run tool/plugins.dart validate examples/en_zh_cards
# 整目录推到手机 文档/plugins/en-zh-cards/，在「设置 → 插件」里重新扫描并打开
```
