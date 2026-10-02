# TongYi-Lite 智能体 vs DSH 原版差距分析（2026-10-01）

> 对照基线：`E:\deepseek-harness`（DSH 0.1.7-rc.2，约 60 packages）。
> 本方：`lib/agent/`（ReactLoopAgent + SessionLog + 双路线 adapter）。
> 定位修正：**本地模型只承担简单对话，智能体模式的主力是 API 路线**——
> 差距分析以 API 档为主视角；local 档预算小是端侧省 token 的既定策略，不算缺陷。

## 0. 已对齐的部分（骨架不虚）

| 机制 | DSH | 我们 | 状态 |
|---|---|---|---|
| 事件溯源会话日志 | session/* 事件 append-only JSONL | `session/log.dart` + `store.dart` | ✅ 同构 |
| ReactLoop 两层循环 | turn/step、无工具调用即完成 | `loop/agent.dart` | ✅ |
| 失败瀑布 | compaction → llm-retry → giveUp | `loop/failure.dart` | ✅ 结构一致 |
| 空响应重试 | EMPTY_RESPONSE 可重试码 | `retryEmptyResponse` | ✅ |
| 失败反思注记 | assistant/attempt 落日志 | failure-note 投影 `[上次尝试失败:…]` | ✅ |
| 工具结果外置 | spill（maxInlineTokens 12500） | `context_eng/spill.dart`（4096 tok → 落盘 + read_file 回读） | ✅ |
| 崩溃恢复 | interruptedTurnClosers | `SessionLog.closeOpenTurns` | ✅（有实现） |
| 子代理 | subagent seam + in-process | `subagents/in_process.dart` | ✅ 简化版 |
| 技能系统 | SKILL.md + 目录注入 + skill 工具 | `skills/`（10 内置 + load_skill 仅 API） | ✅ 简化版 |
| max_uses 强制收敛 | web_search max_uses=5 | web_search_tool 回合级预算 + 去重 | ✅ |
| 审批/沙箱 | fail-closed + 三档 | workspace-write/danger + ApprovalDialog | ✅ 两档 |
| AGENTS.md 注入 | 65KB 预算、system-reminder 帧 | agents_md/（全局+工作区） | ✅ 简化版 |
| 上下文预算参数 | headroom 65536 tok | API 档 8192 tok/步、16~100 步、并行 4 | ✅ 量级接近 |

**结论：API 档的"骨架参数"已对齐 DSH 量级。差距在下面的三档。**

## 1. Tier 1 —— API 档上下文生命周期管理（本次已修，见 §4）

修复前三连实锤：

1. **主动压缩被显式关闭**：`chat_provider.dart` 曾是 `contextTokenBudget: useApi ? null : …`。
2. **被动压缩是断的**：溢出时服务端返回 HTTP 400，`mapApiStatus` 把所有 4xx 归
   `invalidRequest`（不可重试、不触发 CompactionPlugin）——而 OpenAI 兼容端点的
   溢出详情在 400 响应体里（`"maximum context length is … tokens"`），
   `openai_service._friendlyDioError` 只取 HTTP reason phrase，**响应体在这一层就被丢弃**。
   长会话撞溢出 = 直接"本轮执行失败"，且那正是最该压缩重试的时刻。
3. **工具结果投影剪枝缺失**：API 档工具结果内联后永不裁剪，历史无界增长，加速撞溢出。

DSH 对应机制：compaction-basic（80% 阈值 + 65K headroom + 暖前缀事务式压缩）、
tool-result-pruner（>8192 字符 → 头 4096 + middle pruned + 尾 1024，原文留日志）、
token-meter 统一计量。

## 2. Tier 2 —— 与路线无关的 harness 机制缺口

按投入产出排序：

| # | 缺口 | DSH 做法 | 我们现状 | 成本 |
|---|---|---|---|---|
| 1 | 时间/环境注入 | 每 eligible step 注入 ISO 时间+时区+距上条耗时（user-role 快照，10 分钟节流） | 靠模型自觉调 get_time；系统提示只有一句"实时信息→调 get_time" | 极低（本次已做 API 档系统提示尾注入） |
| 2 | 通用重复调用守护 | repeat-tool-reminder：同工具+同参数 3/5/8 次渐进提醒 | 仅回合内签名去重 + web_search max_uses | 低（推广即可） |
| 3 | Prompt-cache 友好装配 | section ordering：稳定前缀在前、runtime 快照在后；"工具目录不变以稳 request cache" | 每回合重建提示词，无稳定/易变分区意识（DeepSeek context caching 费用×延迟双输） | 中 |
| 4 | steer 回合中转向 | followup/steer/inject 三级输入通道 | 回合中只能取消或等，跑偏无法纠偏 | 中高 |
| 5 | 计划模式 + goal 续跑 | plan-mode section + exit_plan_mode；持久 goal + goal-round-driver 无人值守续轮 | 只有 todo_write；撞 maxSteps 直接"任务未完成" | 中高 |
| 6 | 记忆自动注入 | AGENTS.md 全局+项目（65KB 预算） | memory_set/get 默认关，无自动注入 | 低 |
| 7 | 主动压缩的"值得吗"判断 | token-meter 计价 + 暖前缀复用（压缩只重放增量） | 压缩后 prefix 全变 → 端侧全量重 prefill；API 档无此顾虑 | — |

## 3. Tier 3 —— DSH 独有编排能力（API 档反而最该有）

- **PTC（run_code）**：模型写 TS 程序批量编排工具（子调用走完整管线、并发上限 10）。
  我们执行器侧 `maxParallel=4` 与 `isConcurrencySafe` 预留都在，缺工具 + SDK 注入段；
  照 load_skill 的"仅 API 注册"门控即可。
- **按步模型路由**：每 step 可换 provider/effort（压缩用便宜模型、规划用强模型）。
- **子代理后台化 + send_message 续轮 + workflow fan-out**。
- **并行工具调度语义**：exclusive barrier + 有界池 + 按模型序提交 + abort 合成占位结果
  （我们批间串行已够用，缺 abort 占位与 isConcurrencySafe 消费）。

## 4. 本次落地（2026-10-01，工作区未提交）

1. **修①溢出分类**：`openai_service` 4xx 时读取响应体（提取 `error.message`/`message`
   JSON 字段，最多 4KB）并入异常 message；`base_engine_adapter.mapApiStatus` 增加可选
   `message` 参数，命中溢出文案（context length / context_length / maximum context /
   prompt is too long / too many input tokens / 上下文长度 / 超出上下文 …）→
   `LlmFailureCode.contextWindowExceeded` → 失败瀑布第一步走压缩 → 有界重试。
2. **修②API 主动压缩**：新设置 `agentApiContextBudget`（默认 32768 tok，滑条 4k~128k）；
   `chat_provider` API 档 `contextTokenBudget = min(设置值, 端点 contextWindow×7/8)`
   （配置过 contextWindow 时）。
3. **修③工具结果投影剪枝**：`SessionLog.deriveModelMessages` 对 >8192 字符的
   tool/result 投影为头 4096 + `[…中间省略 N 字符，完整结果见会话日志…]` + 尾 1024；
   存储与 UI 视图（deriveChatMessages）不动。
4. **④时间注入（仅 API 档）**：`buildSystemPrompt` 新增 `environmentNote` 可选参，
   chat_provider API 档传"当前时间：…（星期X）"；local 档不传（系统提示逐字节稳定，
   保 KV 前缀复用）。

## 5. 后续分期建议

- **P1（小成本）**：通用 repeat 守护（全工具 3/5/8 提醒）；记忆默认开 + 自动注入段；
  prompt-cache 分区（稳定段冻结、易变段后置）。
- **P2（结构性）**：steer 转向（回合中插话进 next-step inbox）；撞 maxSteps 自动合成
  续跑提示（"继续"一键接跑）；并行工具 abort 占位结果。
- **P3（编排）**：PTC run_code（仅 API）；压缩摘要走便宜模型（按步路由的最小形态）；
  子代理后台化。
