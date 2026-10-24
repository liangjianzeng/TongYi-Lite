# TongYi-Lite 智能体「思考失控」治理记录

目标（用户原话）：**tongyilite 智能体模式，思考时非常容易输出超长失控，超过 32k，看看怎么解决。**
本文是这条线的唯一真源：根因 → 机检口径 → 改动 → 验收数据。

---

## 1. 根因（读码 + 机检复现，不是猜）

| # | 缺陷 | 位置 | 后果 |
|---|---|---|---|
| 1 | **守卫只量「当前思考块」**，块闭合即 `thinking.clear()` | `providers/agent_stream_processor.dart` 状态机 + 三个 adapter 的 `processor.thinking.length > max` | 模型 `think…response…think…response` 反复横跳时每块归零 → **累计思考无上限**。机检 S2：20 段交替思考共 **40250 字**畅通无阻，现行守卫一次都不触发 |
| 2 | **任何寒暄即可豁免守卫**（若按「非空即已产出」判定） | 同上（新口径设计时踩到） | 开头一句「好的，我来看看」+ 4 万字独白 → 永远不触发（机检已固化为用例） |
| 3 | **thinkingOverflow 是确定性失败，整轮判死** | `agent/loop/failure.dart` `if (f.code == thinkingOverflow) return false;` | 止损后不抢救、不重试 → 用户看到「本轮执行失败」，几分钟白等 |
| 4 | **工具决策步也开着思考** | `agent/loop/agent.dart _buildRequest` 从不干预思考开关 | 端侧小模型最需要"少说话"的那一步（只需产出一个工具调用）反而最容易开始长篇独白；原生已有的「不思考注入」防线（JNI `!enable_thinking` → 追加 no-think 块）在智能体路径从未被启用 |
| 5 | 无 opener 的独白属**正文**而非思考块 | 状态机本质 | 守卫看不见（已知盲区，见 §4） |

## 2. 机检（可重跑，不靠肉眼）

`tool/measure_thinking_guard.dart` —— 7+1 场景，同一口径跑「现行守卫」与「目标守卫」，
输出 漏网 / 误杀 / 白烧字数 三列：

```
cd TongYi-Lite && ~/flutter/bin/dart run tool/measure_thinking_guard.dart
```

改动后的终表（阈值 6000 字 = 设置项 `agentThinkingMaxChars` 默认）：

```
场景                                      真相    现行    目标    白烧字(现行/目标)       判定
S1 单块未闭合 think 标签 40k              失控    触发    触发    0 / 0                   两者都堵
S2 think/response 交替 20 块 共 40k       失控    漏网    触发    40250 / 0               ★ 现行漏网 → 目标已堵
S3 无 opener 独白 40k（守卫盲区）         失控    漏网    漏网    0 / 0                   两者都漏（盲区）
S4 Qwen 风格 think 未闭合 40k             失控    触发    触发    0 / 0                   两者都堵
S5 正常 思考800+答案300                   正常    漏网    漏网    0 / 0                   放行正常
S6 正常 思考800+工具调用                  正常    漏网    漏网    0 / 0                   放行正常
S7 正常 40k 工具调用参数                  正常    漏网    漏网    0 / 0                   放行正常
S8 长思考 7000 + 答案 300（取舍）         正常    触发    触发    0 / 0                   ✗ 目标误杀

失控漏网：  现行 2 / 目标 1   |   正常误杀：  现行 1 / 目标 1   |   白烧思考：  现行 40250 字 / 目标 0 字
```

**读数解释**

- **头号战果 = S2**：跨块累计把 40250 字白烧压到 **0**。这正是用户"思考动辄超 32k"的形态
  ——4 万字符 ≈ 2~3 万 token 级思考，把每轮预算与 nctx 一口吃光。
- **S8 的"误杀"不是新引入**：现行守卫同样在 6000 字处掐断 7000 字长思考（两列都是「触发」）。
  本次改动没让它变差，并且把它从「整轮判死」变成「止损 + 关思考重试一次」（见 §3 第 3 条），
  真要长推理就在设置里调大「思考失控守卫阈值」（1000~65536）。
- **S3 是已知盲区**，见 §4。

## 3. 改动（Dart 层，全部有回归用例）

1. **守卫口径唯一真源**：`AgentStreamProcessor.thinkingRunaway(maxChars)`
   = `(当前块长 > max || 累计 > max) && !producedAnything`。
   - 新增 `_totalThinkingChars`（跨块累计）与 `thinkingCharsSoFar`；
   - `producedAnything` = 有工具调用 **或** 可见文本 ≥ `kMinUsefulChars`(80 字)——
     门槛是机检逼出来的（S1 用例）：允许两句寒暄当"产出"，守卫就等于没有。
   - 三个 adapter（local / openai 文本协议 / openai 原生）**一律改调这个方法**，
     不许再各自量块长（原生路线改用 `thinkingSoFar + 无正文 + 无工具分片` 等价判据）。
2. **止损后先抢救再判死**：`thinkingOverflow` 时若已产出工具调用/够长答案 → 照常交付结果，
   不再丢弃整步产出（旧行为：白等几分钟然后「本轮执行失败」）。
3. **失败可恢复**：`LlmRetry` 允许 thinkingOverflow **重试一次**，且该次请求
   `forceNoThinking = true`（`takeForceNoThinking()` 一次性传递）。
   同一模型同一配置原样重发必然再次失控——只有换条件重采样才有救；第二次仍失控即止损，
   不空转烧 token。
4. **工具决策步默认不思考**：`AgentConfig.thinkingOnToolSteps`（默认 false）。
   `_buildRequest` 对「上一步没有工具结果」的步下发 `forceNoThinking`；本地路线落为
   原生 `setEnableThinking(false)`（**启用 JNI 里早就存在的不思考注入**），
   finally 按用户设置恢复。组织最终答案的步仍允许思考。设置 → 智能体 → 执行参数
   新增开关「工具步也允许思考」可回退旧行为。
5. 设置文案与真口径同步：滑块提示改为「按**累计**思考字数计」；失败消息带累计字数与
   「本次自动改用不思考重试一次」的用户可见说明。

改动文件：`lib/providers/agent_stream_processor.dart`、`lib/agent/llm/{adapter,local_adapter,openai_adapter}.dart`、
`lib/agent/loop/{failure,config,agent}.dart`、`lib/services/settings_service.dart`、
`lib/providers/{settings_provider,chat_provider}.dart`、`lib/screens/settings_screen.dart`、
`tool/measure_thinking_guard.dart`（新增）、`test/agent/thinking_runaway_test.dart`（新增）。

## 4. 已知边界（诚实记录）

- **S3「无 opener 独白」看不见**：那不是思考块，是正文。兜住它的不是本守卫，而是
  ①每步 token 预算（local 默认 1024/步）＋②工具步不思考（本改动）＋③有界重试后终态报错。
  要做实需内容级反重复判定（采样端 DRY/min_p 或原生 thinking token 硬预算）——
  **属原生改动，需 NDK 重编 + 真机四道门验收，本次未动**（拿不准的 native 改动比不改更危险）。
- **原生层未加思考 token 硬预算**：现由 Dart 侧停流止损（token 流回 Dart 才判定，
  最坏多烧几十 token 级）。若真机仍见原生空转（无 EOS 且 Dart 收不到流），再补 JNI。
- **API 路线的 `forceNoThinking` 只做重采样**：各家服务端关思考的私有参数不一
  （`chat_template_kwargs.enable_thinking` / `thinking_budget` / `thinking_token_budget`…），
  盲传会 400，故不硬塞；本地路线才是真正切换原生开关的那条。

## 5. 验收

- `flutter test test/agent test/providers test/services` → **687 通过 + 2 skip，0 失败**
  （新增 `test/agent/thinking_runaway_test.dart` 12 项：累计口径 5 / LlmRetry 3 / 主循环治理 4）。
  关键用例：跨块累计、寒暄不豁免、已产出工具调用不误杀、失控重试带 `forceNoThinking`、
  连续失控只重试一次、工具步不思考 / 答案步允许思考、配置打开可回退。
- `dart analyze lib/agent lib/providers lib/services` → **0 error**；告警均为改动前既有项
  （`unused_catch_clause` / `unnecessary_non_null_assertion` / `unused_field` 等，行号均不在本次新增行）。
- 机检表见 §2（`tool/measure_thinking_guard.dart` 可重跑）。

## 6. 用户侧怎么用

- 默认即可：工具决策步不再思考，思考累计超 6000 字且还没产出即止损并抢救，
  失败自动关思考重试一次。
- 确实需要长推理的模型：调大「思考失控守卫阈值」，或打开「工具步也允许思考」。
- 反复出现同一模型失控：说明该模型思考质量差，直接在该模型设置里关思考模式
  （失败消息里已写明这条指引）。

## 7. 打包记录（2026-10-23 22:2x，本机 DGX Spark，tool/build_apk.sh 默认 debug+release）

- 目录：/home/jianzengliang/MyWork/TongYi-Lite/TongYi-Lite/build/app/outputs/flutter-apk/
- app-debug.apk 134213753 B（sha256 d81422de8fb7e706…，22:24）
- app-release.apk 67824553 B（sha256 29ba348e364fae4a…，22:26）
- 签名验收：CN=TongYiLite, OU=Dev, O=DGXSpark（脚本自带 apksigner 验收通过）
- 版本：0.3.4+22（沿用工作区现值，未抬版本号，install -r 可覆盖）
- 字符串级验收（AGENTS 铁律，不看时间戳）：
  debug kernel_blob UTF-8 / release libapp.so UTF-16LE 均命中
  已累计思考 / 工具步也允许思考 / 改用「不思考」重试一次 / 按**累计**思考字数计 / 组织最终答案时仍允许思考；
  旧串「思考超长未闭合」「思考块超长未闭合到该字数即主动止损」在两包内均为 0。
- 装包（AGENTS 铁律：覆盖安装，绝不 uninstall）：
  adb -s 100.109.138.2:5555 install -r -t build/app/outputs/flutter-apk/app-debug.apk
