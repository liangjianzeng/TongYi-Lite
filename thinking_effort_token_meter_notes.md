# API 思考强度档位 + 回合 token 读数（2026-10-24）

用户两条需求（原话摘记）：
1. 「给 API 接入的模型加上思考的强度…把目前通用模型比较普遍的那类型作为一个选择去配置，比高中低，统计一下然后实现」
2. 「智能体执行过程中那个状态提示…生成中右边一个停止的按钮，一点卵用都没有。把它实现为生成的 token 数，好统计、让我知道现在到底在干什么、生成了多少，我也知道它是不是一直在做无用功，或者消耗了多少 token」

---

## 1. 统计表：主流通用模型的"思考"到底怎么控制

依据各家公开接口规范（OpenAI Responses/Chat Completions、Anthropic Messages、Google Gemini
generateContent、DeepSeek、DashScope/Qwen3、智谱 GLM、Moonshot Kimi、MiniMax、xAI、以及
vLLM/SGLang 的 OpenAI 兼容扩展）。本仓只说 OpenAI 兼容一种方言，所以关键是**同一种意思各家
发哪个字段**——发错字段在严格端点上是 400，不是"没效果"。

| 族 | 参数名 | 层级 | 取值枚举 | 关思考怎么发 | 备注 |
|---|---|---|---|---|---|
| OpenAI gpt-5 / o 系 | `reasoning_effort` | 顶层 | minimal / low / medium / high（gpt-5 另有 none） | minimal（o 系无 none） | 不支持 budget 数字 |
| xAI grok、MiniMax M2/M1 | `reasoning_effort` | 顶层 | low / medium / high | minimal→最省档 | 与 OpenAI 同形，可复用一族 |
| Anthropic Claude（经 OpenAI 兼容网关） | `thinking.budget_tokens` | 顶层 `thinking` 对象 | token 预算数字；`type`: enabled/disabled | `{"type":"disabled"}` | **budget 必须 < max_tokens**，否则 400 |
| Google Gemini | `thinking_config.thinking_budget` + `include_thoughts` | 顶层 `thinking_config`（extra body） | 0=关，-1=自适应，>0=预算 | `thinking_budget: 0` | 缺省是自适应，档位要可控必须显式发 |
| DeepSeek reasoner / V3.2+、Kimi K2 | `thinking.type` | 顶层 `thinking` 对象 | enabled / disabled | disabled | **只有开关无档位**，三档统一映射成 enabled |
| 智谱 GLM-4.5/4.6 | `thinking.enabled` | 顶层 `thinking` 对象 | true / false | false | 与上面形不同，不能混发 |
| Qwen3（DashScope 兼容） | `enable_thinking` + `thinking_budget` | 顶层 | bool + 预算 | `enable_thinking: false` | 云端官方形态 |
| Qwen3 / 任意模型跑在 vLLM、SGLang | `chat_template_kwargs.enable_thinking`（+ `thinking_budget`） | 嵌套 kwargs；顶层再带一份 bool | bool | false | 自托管形态；SGLang 只认顶层 bool，故两处都发 |
| 族不明 | —— | —— | —— | —— | **什么都不发**（宁无效果，不可把请求打死） |

档位 → 预算（预算制族）：低 1024 / 中 2048 / 高 4096，并夹到 `max_tokens - 256` 以内
（Anthropic 硬性要求，且必须给正文留量）。

**为什么不做成"全局一个开关"**：本仓 MTP 全局 bool 的教训（AGENTS.md 已记）——一个全局值
必然把某些端点配错。思考档位挂在 **每条 ApiModelConfig**（一条配置=一个模型=一个档位），
天然按模型覆盖，也和 `visionCapable`/`contextWindow` 同构。

---

## 2. 实现

| 文件 | 改动 |
|---|---|
| `lib/agent/llm/thinking_effort.dart` | 新增。族/档位枚举、`detectThinkingFamily`（模型名→端点地址两级探测，厂商族优先于 vLLM）、**唯一真源** `thinkingWireFields`、预算夹逼、设置落盘用的字符串往返与中文标签 |
| `lib/models/api_model.dart` | 新增 `thinkingEffort` / `thinkingFamily`（可空串，null=不干预）+ copyWith（含 `clearThinkingEffort`/`clearThinkingFamily`，"关档位"与"不改"可区分）+ toJson/fromJson |
| `lib/services/openai_service.dart` | `chatCompletion` / `chatCompletionEvents` / `_sseDataPayloads` 加 `extraBody`；400/422 兜底重构成 `bodyWithoutRejectedFields`（点名 stream_options 只去掉它；点名/泛化拒绝思考字段则**整组**去掉）；post 抽成局部函数去掉三层嵌套 |
| `lib/agent/llm/openai_adapter.dart` | `_thinkingFields(maxTokens)`：档位=不干预直接空 map；族优先取用户钉死的覆盖，否则自动探测；两条路线（原生 tool_calls / 文本协议）都把字段传下去 |
| `lib/screens/settings_screen.dart` | API 端点编辑框加「思考强度」ChoiceChip（不干预/关/低/中/高）+「参数族」下拉（自动探测 + 各族，括注实际字段名）+ 与「思考字数上限」联动的提示文案 |

安全默认：**旧配置读出来两字段都是 null → 一个思考字段都不发**，请求体与改动前逐字节相同。
族判错最坏结果 = 该端点不认 → 自动去掉思考字段重发（丢档位不丢请求）。

---

## 3. 状态条改成"看得懂在干什么"的 token 读数

`lib/agent/observability/turn_meter.dart`（新增，纯函数，UI 只拼装）：

- `estimateTokens`：中日韩（含假名/谚文/全角标点）一字记 1，其余按 4 字符记 1，空白不计。
  流式期间本地无逐 token 出口、API usage 只在末块，所以**只能估**；有 usage 时由
  `fromServerUsage` 覆盖并去掉「约」字。
- 读数：`第 N 步 · 约 X/Y tok · 思考 Z 字 · 工具 K · 重试 R`
  （产出 = 答案 + 各工具调用参数 + 工具参数生成中字符；思考 = 正在流的 + 已落档各步，
  与思考失控守卫同用「字」口径，用户可对照设置项）。
- **无用功判据** `looksWasteful`：思考 ≥600 tok 且可见产出 < 思考的 5% 且不在重试 →
  追加 `⚠️只想不写` 并把文字变 tertiary 色。判据刻意保守，免得每次"刚开始想"就闪警告。

`home_screen._buildTurnStatusStrip` 改为喂 `TurnMeter`：本步产出取当前会话里 `isStreaming`
那条 assistant 消息，思考/工具取自 `AgentUiState`（含 `toolGen.chars`），预算按当前档取
`agentTokensPerRound` / `agentApiTokensPerRound`。
**普通聊天（`ui.step == 0`）不显示预算**：聊天走的是聊天档 `max_tokens`，挂智能体预算是假数字
——那时只显示「产出 约 N tok」。

### 停止按钮为什么"没反应"——三个洞（都修了，回归见 `test/agent/stop_generation_test.dart`）

1. `loop/agent.dart` 捕获 `LlmFailure` 时不区分"取消导致的中止"：取消常以
   `transport`（Dio request cancelled）形态到达，而 `transport` 在重试器里**是可重试的**
   → 按下停止，循环自己又发一次生成。现在：`_cancelCompleted` 时直接收为 `interrupted`，
   不进瀑布、不落失败注记。
2. `cancel()` 只在 `_cancelCompleter != null`（正在 generate）时才置位 → **步与步之间**
   （工具执行中、状态回调里）按下停止，`_cancelCompleted` 仍是 false，下一步的取消检查
   放行，继续烧 token。现在：无条件先置位，再 completer、再 `adapter.cancel()`。
3. `chat_provider.stopGeneration` 用 `agent.isRunning` 当门槛：相位在工具执行/步间隙时
   `isRunning` 为 false，于是**落到普通聊天分支**，只停掉当前一次生成，主循环随后自己
   接着发起下一步。现在：`agent != null` 即取消（`cancel()` 幂等），不再落普通分支。

另：`_handleFailure` 顶部加取消短路——已停止时连压缩都不做（压缩会改写会话并再发一次请求）。

**取消是回合级的**：`kick()` 开新回合会清 `_cancelCompleted`，所以上一回车的停止不会把
下一回合憋死（这条也有用例钉住）。

---

## 4. 验收

- `flutter test test/agent test/providers test/services` → **714 passed + 2 skipped，0 失败**
  （较改动前 687 增 27：思考映射 23 + 回合读数 9 + 停止链 4 + 400 兜底/落盘 8，含对既有
  stream_options 兜底的回归）。
- 新增用例文件：`test/agent/thinking_effort_test.dart`（23）、
  `test/agent/turn_meter_test.dart`（9）、`test/agent/stop_generation_test.dart`（4）、
  `test/services/openai_service_thinking_test.dart`（8）。
  其中「映射结果里绝不出现别家族专属字段」是**遍历全族 × 全档位**的白名单断言，防以后加族时
  把 Claude 的 budget 发给 Qwen 之类的事故。
- `dart analyze lib` → **0 error**，44 issues 全为改动前既有告警（数量未变）。

## 5. 已知限制 / 待办

1. **族探测靠模型名与端点地址**：自托管换皮模型名（如 `my-super-llm`）会落到 `none`
   （不发思考字段）。设置里「参数族」下拉可手工钉死，抓包看请求体即可自查。
2. **档位精度受端点限制**：开关制族（DeepSeek/Kimi/GLM）只有开关，低/中/高对它们等价——
   UI 上不假装能区分（发出去的字段就一个 bool）。
3. **token 是估算**：本地路线流式期间没有逐 token 出口，读数用于看趋势、不当账本；
   回合结束后答案气泡上的 tok/s 仍走原生 `getInferenceStats`（末步口径）。API 路线的
   `usage.completion_tokens` 覆盖（去掉「约」字）已留接口位，尚未接入 `AgentUiState`。
4. **未做**（需真机四道门，见 AGENTS.md）：原生侧思考 token 硬上限、sampler 抗重复。
5. 真机验证要点：① 设置里给某条 API 配「高」，logcat 看 `[AgentLlm] 思考档位 … 族=… → {…}`
   一行确认发出去的字段；② 拿一个严格端点（会 400 的）验证"去字段重发"仍然出答案；
   ③ 智能体长任务中途按停止，logcat 应出现 `已取消…不进重试 → interrupted` 且**不再**出现
   新的 `request (events=…)` 行；④ 观察细条读数：思考字数狂涨而产出 tok 不动时应显
   `⚠️只想不写`。
