# TongYi-Lite 智能体模式 × DSH 架构复刻设计方案

> **版本**：v0.1（初稿）
> **依据**：《DeepSeek-Harness 架构精读与扩展开发学习材料》（dsh-v0.1.7-rc.2 逐文件核对版）全部 16 篇精读；TongYi-Lite 现有 `lib/agent/`、`lib/services/`、`lib/providers/` 现状盘点
> **立场**：现有实现允许**全部推翻重构**（用户确认），本文不背负存量包袱，按 DSH 目标架构从头设计，仅保留"能力资产"（工具集、沙箱/审批、协议解析、引擎能力模型）作为迁移输入。

---

## 0. 一句话结论

> **TongYi-Lite 智能体模式 = 事件溯源会话日志（唯一真相源） + 可替换 Agent 主循环 + 六段式工具流水线 + 上下文工程（有界压缩/溢写） + LLM adapter 能力接缝 + 端侧适配的安全三层（沙箱/审批/预设）。**

DSH 的核心选择是"把状态收敛到唯一真相来源（会话日志），把行为发散到插件网络"（Part 15.1）。本方案照抄这一选择，但按端侧约束做三层裁剪：

| 复刻 | 简化（端侧适配） | 裁剪（不做） |
|---|---|---|
| 事件溯源日志 + 崩溃修复 + "模型可见即可重建" | JSONL 不压缩、`assistant/message` 只存最终文本（chunk 不入盘）、compaction 以确定性裁剪为主摘要为辅 | zstd 帧、HMR、动态插件加载 |
| turn/step 主循环 + 失败瀑布 + 有界重试 | 单一会话内串行优先，并行调用作为可选；审批通道收敛为 1 个（沙箱升级） | 多 provider 路由、image offload、image 预算体系 |
| 工具六段流水线 + 并行 + 长任务 | 并行上限 4；job 系统只做内存态 | 工作区变更器、MCP、浏览器/电脑操作类 provider |
| 能力 seam（llm/fs/subprocess/sandbox） | adapter 接缝 + 工具接缝；执行世界不整组替换（移动端无容器/远端） | 远程执行世界、SSH 后端 |
| 子代理 spawn/fork + 能力校验 fail-loud | 仅 in-process 两种 provider、depth≤2、审批恒 `never` | Agent Teams、Ralph、六 provider 全集 |
| 扩展：skill/hooks/指令文件 | skill 简化为 2 级（内置/用户）、hooks 为 Dart 事件订阅 | 自定义命令、MCP、插件市场 |
| 安全：沙箱两层强制 + 审批 allowed-once + 预设 fail-loud | OS 级强制点退化为 Android 权限模型 + 策略围栏 | bwrap/Landlock/Seatbelt/Windows ACL 各实现 |

---

## 1. 学习材料要点回顾（决定复刻什么、为什么）

### 1.1 五条贯穿原则（Part 0）

| # | 原则 | 在本方案中的落点 |
|---|---|---|
| ① | 注册即副作用，副作用必须可逆 | Dart 侧：每个 plugin `apply(ctx)` 返回 disposer；runtime dispose 时逆序拆解 |
| ② | 顺序由依赖决定，不由代码位置决定 | AgentContext 按 `inject` 依赖装配，不依赖文件行序 |
| ③ | Model-visible means logged（模型可见的都是被记录的） | 请求只能由 `session.deriveMessages()` 构造；工具结果必须是 `tool/result` 事件（这是相对现状的最大行为变更） |
| ④ | 用替换表达删除，而不是用删除表达删除 | 压缩/剪枝 = 追加 `surfaceOp: replace` 事件遮蔽旧节点；日志 append-only |
| ⑤ | 失败要么响亮，要么无副作用 | 沙箱 fail-closed、审批 fail-loud、溢写 best-effort 回原文 |

### 1.2 值得抄走的五条（Part 15.2）与复刻决策

1. **事件溯源会话模型** → 复刻（§5），替换现在的 `ChatMessage[]` 消息数组作为"真相源"。
2. **"模型可见即可重建"不变量** → 复刻并**开发期强制**：agent loop 每次发请求前，用独立 `deriveMessages()` 重建比对（assert），而非靠 review。
3. **能力 seam 而非继承** → 复刻（§9）：`LlmAdapter` 接缝 + 工具接缝 + 子代理接缝。
4. **失败策略三分类**（fail-loud / fail-closed / 回原状）→ 复刻（§6/§7/§8），安全三层划分照抄。
5. **组合即配置** → 端侧适配为"能力声明 + 运行时探测"双源（现有 `EngineCapabilities.resolve` 已实现此思想），不引入 profile/bundle/patch 三层配置（移动端无意义）。

### 1.3 代价评估结论（Part 15.3）

DSH 认知负载/装配重量对**单人维护的端侧 App** 偏高，因此本方案：
- 不复制 Cordis 全量原语（effect/inject/pipeline 全实现），只保留其**可复用骨架**：`ctx.on(event, listener)` + `apply/dispose` + 事件命名空间。
- 不复制 profile/bundle/patch 文件组合，用 Dart 侧 `AgentRuntime` 的静态装配 + 能力驱动选择替代。
- 日志格式保持可机器校验，为将来"如果"上 DSH 协议互通留门（事件名保持 DSH 词表）。

---

## 2. 现状盘点与缺口矩阵

### 2.1 现状资产（保留迁移）

| 模块 | 现状 | 处置 |
|---|---|---|
| `lib/agent/builtin_tools/*` | 11 个工具（calculator/file/todo/note/memory/get_time/weather/python_exec/shell_exec/unit_converter/web_search） | 全部保留，适配新工具流水线接口 |
| `AgentStreamProcessor` | 思考块过滤 + tool_call JSON/XML 块增量解析 | 保留，升级为协议层解析核心 |
| `EngineCapabilities` + `ProtocolSelector` | 静态声明 + 运行时探测双源；prompt-JSON / native-tools 选择 | 保留并扩展（加 xml-tool 变体、上下文窗口） |
| `Sandbox` + `agent_approval` | 两模式阶梯、严格更宽校验、allowed-once、拒绝标记 | 基本原样保留（§10） |
| `ToolRegistry` | 全局/模型/用户三层遮蔽 | 保留，扩展为流水线输入 |
| `InferenceService.completionWithMessages` | 本地引擎入口（prompt + messagesJson + image/audio） | 作为 LocalEngineAdapter 的后端 |
| `OpenAiService` | API 路由 | 作为 OpenAiAdapter 的后端 |

### 2.2 缺口矩阵（G1–G12）

| 缺口 | 现状 | 影响 | 对应方案章节 |
|---|---|---|---|
| G1 | 无事件日志，`ChatMessage` 数组是真相源；工具活动是"🔧"前缀 UI 消息，**不入模型上下文** | 多轮工具链不可重放；崩溃后状态残缺；UI 与模型视角割裂 | §5 |
| G2 | 主循环为 flat for-loop，无 turn/step，无 phase（idle/running），无取消 | 无崩溃修复入口；无"本轮中用户新消息"排队；无法表达中止 | §6 |
| G3 | 工具执行无 pipeline（无 pre-execute/guard/post-execute），无并行 | 无法拦截危险命令、无法审计/截断结果、串行低效 | §7 |
| G4 | 无失败恢复：引擎 OOM/超时/API 429 直接失败；`maxTokensPerRound=512` 固定 | 端侧小模型长上下文易溢出即死；API 无退避 | §6.4、§8 |
| G5 | 无上下文工程：历史只靠"截断 200 条 + 排除 🔧"，`maxTokensPerRound` 硬编码 | 长会话质量陡降；token 预算不可控 | §8 |
| G6 | 无 LLM adapter 接缝：`streamFn` 是函数参数，本地/API 逻辑散布在 chat_provider | 换模型/加模型能力（如原生工具调用）要改调用方 | §9 |
| G7 | 无子代理 | 无法委派重活 | §11 |
| G8 | 无扩展机制（skill/hooks/指令） | 能力固化 | §12 |
| G9 | 持久化无格式版本/迁移/损坏恢复 | 日志格式演进必破坏旧会话 | §5.7 |
| G10 | 无并发保护（引擎单请求互斥已有，但 agent 循环无 phase 锁） | 并发发送会串流 | §6.2 |
| G11 | 工具结果 UI 展示与模型视角不一致（🔧 摘要 60 字符） | 模型看不到真实结果（现状靠把完整结果塞 messages，与 UI 双轨） | §7.5、§13 |
| G12 | 无请求可重建保证（开发期/运行期） | 无法审计/回放/调试"模型当时看到了什么" | §6.3 |

---

## 3. 总体架构

### 3.1 四层同心圆（Part 14.1 映射）

| 层 | DSH 术语 | TongYi-Lite 落点 | 是否影响不变量 |
|---|---|---|---|
| 1 进程装配层 | profile/bundle/patch | `AgentRuntime` 静态装配 + `EngineCapabilities`（能力驱动） | 否 |
| 2 容器层 | Cordis（ctx.on/effect/plugin） | `AgentContext`（事件订阅 + 插件 apply/dispose + inject 依赖） | 间接 |
| 3 能力 seam 层 | `ctx.llm` / `ctx.tools` / `ctx.subagents` / `ctx.sandbox` | `LlmAdapter` / `ToolRegistry`+工具 / `SubagentProvider` / `Sandbox`（现有） | 否（契约不变） |
| 4 持久格式层 | SessionEvent + 迁移链 | JSONL 事件日志 + 格式版本 + 导入迁移边 | **是** |

**总原则（Part 14.1）**：能挂在事件上就别改核心，能做成 plugin 就别改 runtime，能走 seam 就别 fork 整条链路。

### 3.2 组件图

```
┌────────────────────────────────────────────────────────────────────┐
│  UI / Provider 层 (Flutter + Riverpod)                             │
│  Chat UI · ApprovalDialog · AgentActivityCards · CompactionBanner  │
└──────────────────────┬─────────────────────────────────────────────┘
                       │ 会话事件流 / 控制命令 (send, cancel, approve)
┌──────────────────────▼─────────────────────────────────────────────┐
│  AgentRuntime（会话实例，1:1 对应一个 Conversation）               │
│  ┌─────────────┐  ┌─────────────────┐  ┌────────────────────────┐ │
│  │  SessionLog  │  │  ReactLoopAgent  │  │  AgentContext (容器)   │ │
│  │  事件日志     │◄──│  turn/step 主循环│──►  ctx.on / ctx.plugin / │ │
│  │  + 持久化     │  │  + phase 状态机 │    ctx.inject             │ │
│  │  + 投影       │  │  + 失败瀑布      │    (插件注册表)          │ │
│  └──────┬──────┘  └────────┬────────┘  └────────────────────────┘ │
└────────────────────────────┴──────────────────────────────────────┘
            ▲  append / replace            ▲  request
            │                              │
┌───────────┴──────────────────────────────┴────────────────────────┐
│  能力 seam 层                                                      │
│  ┌─────────────────┐ ┌──────────────────┐ ┌────────────────────┐ │
│  │  LlmAdapter     │ │  ToolPipeline    │ │  SubagentProvider  │ │
│  │  LocalEngine    │ │ pre-execute→guards│ │ spawn / fork       │ │
│  │  / OpenAi       │ │ →execute→project │ │ (in-process, Dart) │ │
│  │  + Protocol     │ │ →post-execute    │ └────────────────────┘ │
│  │  (prompt-json / │ │ →finalizeContent │  ┌──────────────────┐ │ │
│  │  native / xml)  │ └──────────────────┘  │  Sandbox +       │ │ │
│  └─────────────────┘                       │  Approval + Guard │ │ │
│  EngineCapabilities (能力驱动协议选择)      │  (现有, §10)      │ │ │
│                                            └──────────────────┘ │ │
└──────────────────────────────────────────────────────────────────┘
```

### 3.3 目录结构（重构后）

```
lib/
├── agent/
│   ├── runtime.dart            # AgentRuntime：会话实例装配入口
│   ├── context.dart            # AgentContext：事件订阅 + 插件 apply/dispose
│   ├── session/
│   │   ├── event.dart          # SessionEvent 信封 + 事件类型枚举 + ignorable
│   │   ├── log.dart            # SessionLog：append/replace/deriveMessages/崩溃修复
│   │   └── store.dart          # JsonlSessionStore：持久化 + 版本 + 导入迁移
│   ├── loop/
│   │   ├── agent.dart          # ReactLoopAgent：turn/step/phase/失败瀑布
│   │   ├── config.dart         # AgentConfig（maxRounds, toolTimeout, compaction, retry…）
│   │   └── failure.dart        # 失败归一化 + 重试策略执行
│   ├── tools/
│   │   ├── pipeline.dart       # 六段流水线
│   │   ├── definition.dart     # ToolDefinition（现有 + 保留）
│   │   ├── registry.dart       # ToolRegistry（现有 + 保留）
│   │   ├── guard.dart          # 单调 deny guard
│   │   └── builtin_tools/      # 工具集（现有 11 个适配）
│   ├── prompt/
│   │   ├── assembler.dart      # 三段：sections → system node0；context；inject
│   │   └── sections.dart       # 分段注册表（身份/工具指引/工作区指引）
│   ├── context_eng/            # 上下文工程
│   │   ├── budget.dart         # 上下文预算推导（自 EngineCapabilities.maxContextTokens）
│   │   ├── compaction.dart     # 两阶段压缩（确定性裁剪 + 摘要）
│   │   └── spill.dart          # 溢写（大工具结果落盘 + locator）
│   ├── llm/
│   │   ├── adapter.dart        # LlmAdapter 抽象 + StreamChunk + GenerateOptions
│   │   ├── local_adapter.dart  # InferenceService 封装
│   │   ├── openai_adapter.dart # API 封装
│   │   └── retry.dart          # llm-retry（有界/always 策略）
│   ├── protocol/               # 现有：prompt-json / native / selector / stream processor
│   ├── subagents/
│   │   ├── provider.dart       # SubagentProvider 契约
│   │   └── in_process.dart     # spawn + fork 实现
│   ├── skills/
│   │   └── provider.dart       # 本地 skill 扫描/注册
│   └── sandbox.dart            # 现有（保留）
├── providers/
│   ├── agent_provider.dart     # AgentRuntime per-conversation 生命周期（替换 chat_provider 里 agent 逻辑）
│   ├── agent_stream_processor.dart  # 现有（保留，供 LocalAdapter 用）
│   └── agent_approval.dart      # 现有（保留）
└── models/
    └── chat_message.dart       # 保留为 UI 投影模型（非真相源）
```

> **迁移原则**：`ChatMessage` 不再作为真相源；它变成"UI 投影"——由 `SessionLog.deriveMessages()` + 工具活动事件投影生成。旧会话首次打开时导入为新格式（§5.8）。

---

## 4. Part 1·会话事件日志（对应 DSH Part 4/5）

### 4.1 设计立场

DSH 的核心选择：**"状态"收敛到唯一真相来源（append-only 会话日志），所有行为（压缩/分支/重放/崩溃修复）都变成日志原语**（Part 15.1）。TongYi-Lite 现状把 `ChatMessage[]`（仅 user/assistant 角色、无 seq/turn/step）当真相源，工具活动完全不入模型视角——这是 G1/G11/G12 的根因。

**本方案：引入 append-only 事件日志，`ChatMessage` 降级为投影。**

### 4.2 事件信封（对应 DSH `SessionEvent`）

```dart
/// 一次会话事件的不可变信封（append-only 写入，永不原地改写）。
final class SessionEvent {
  final String type;          // 事件类型名（DSH 词表，§4.4）
  final int seq;              // 单调递增序列号（会话内全局唯一）
  final DateTime time;        // 事件产生时间（ISO 8601 落盘为 epoch millis）
  final Map<String, String>? source; // 来源：{kind: 'user'|'tool'|'model'|'system', callId?:}
  final String? surfaceOp;    // 'append' | 'replace'（替换/遮蔽声明）
  final int? shadowsEndSeq;   // replace 时遮蔽到哪个 seq（含）
  final Map<String, dynamic> data; // 类型特定载荷
  final bool? ignorable;      // 旧运行时可否安全跳过该类型（格式兼容键）
}
```

**不变量**（对应 DSH Part 4）：
1. **append-only**：`seq` 严格递增，无 delete 原语。"剪掉一句话" = 追加 `surfaceOp: 'replace'` 遮蔽旧节点。
2. **时间戳**：崩溃修复时**复用最后一条真实事件的时间戳**，不伪造（§4.6）。
3. **source 自证**：`tool/result` 的 `source.callId` 必须等于其对应 `assistant/message` 中 tool-call 块的 `id`（配对在**写入期**强制，不在投影期，§4.5）。
4. **可序列化**：`data` 必须满足 `snapshotJsonValue`（拒绝非有限数、循环引用、Date、class 实例等）；落盘前校验（对应 DSH `snapshotJsonValue`）。

### 4.3 投影：`deriveMessages()`（对应 DSH Part 4.6/4.7）

模型看到的"消息历史"是日志的**纯函数投影**，不是存储物：

```dart
/// 从事件日志派生模型可见消息序列。
/// 缓存按 contentGeneration（表面替换代数）失效；append 只做 O(新增) 尾增长。
List<ChatMessage> deriveMessages();

int get contentGeneration;   // 任何 replace 递增；append 不变
int get replaceGeneration;   // 任何 surface replace 递增（压缩"前进性"证明）
```

**投影规则**（对应 DSH `deriveEventMessage`）：

| 事件 | 投影为 | 说明 |
|---|---|---|
| `user/message` | `ChatMessage(role:user, content, attachment?)` | 普通用户消息 |
| `assistant/message` | `ChatMessage(role:assistant, content, stats?)` | 助手最终回答（含推理统计） |
| `assistant/attempt` | 不投影 | 失败尝试（log-only，`deriveMessages` 显式忽略） |
| `tool/call` | 附着在对应 `assistant/message` 的 `toolCalls[]` | 不单独成消息 |
| `tool/result` | `ChatMessage(role:assistant, content=toolResult.content, meta: {callId, isError})` | **模型可见的工具回执**（G1/G11 的修复） |
| `compaction/summary` | `ChatMessage(role:user, content=摘要文本)` | 摘要进历史（DSH 做法） |
| `llm/retry`、`llm/retry-started` | 不投影 | log-only（UI 可单独订阅渲染"重试中"） |
| `turn/start`、`turn/end`、`step/start`、`step/end` | 不投影 | 结构事件，UI 订阅用 |
| `system/message` | `ChatMessage(role:user, content=系统提示, meta:{isSystem:true})` | 见 §4.5：端侧用 user-role 承载（DSH v3+ 做法；端侧不引入 system role 以免与 ChatMessage 现有 `user/assistant` 两角色冲突） |

> **为什么用 user-role 承载 system**：DSH 在 v3 把系统提示词提升为 surface 的 `user-role` 消息（让"换 prompt = surface 替换而非 header 变更"成为可能，Part 10.15）。端侧采用同一技巧：系统提示是**可被压缩遮蔽的普通节点**，而不是不可变的 header。这使压缩后请求仍可字节级重建。

**"模型可见即可重建"不变量**（G12，开发期强制）：

```dart
// ReactLoopAgent._buildRequest() 末尾（debug 构建 assert，release 构建采样校验）：
final expected = _session.deriveMessages();
// 若任何插件绕过 deriveMessages 自拼历史，则 assert 失败。
assert(
  _options.messages == expected,
  'agent request diverges from session log derivation',
);
```

### 4.4 事件类型词表（本方案 v1）

| 事件名 | 类别 | 表面 (surfaceOp) | 载荷（关键字段） | 说明 |
|---|---|---|---|---|
| `turn/start` | 结构 | append | `{turn: n}` | 一轮开始（n 从 1） |
| `turn/end` | 结构 | append | `{turn: n, reason: {kind: completed\|error\|interrupted\|max-tokens\|blocked\|user}}` | 一轮结束（DSH `TurnEndReason`） |
| `step/start` | 结构 | append | `{turn: n, step: k}` | 一个模型请求开始 |
| `step/end` | 结构 | append | `{turn: n, step: k}` | 一个模型请求结束（含失败） |
| `user/message` | 表面 | append | `{content, attachmentId?, turn}` | 用户消息（首次/追加） |
| `system/message` | 表面 | append | `{content, turn?}` | 系统提示（可压缩遮蔽） |
| `assistant/message` | 表面 | append | `{content, toolCalls[], stats?, interrupted?}` | 助手消息 + 内嵌工具调用 |
| `assistant/attempt` | log-only | 无 | `{content, toolCalls[], stats?}` | 失败尝试（含 chunk 文本，供调试，不入历史） |
| `tool/call` | 表面 | append | `{turn, step, callId, name, arguments}` | 工具调用开始（DSH `tool/call`） |
| `tool/result` | 表面 | append | `{turn, step, callId, content, isError, meta?, sourceEventSeqs?}` | 工具回执（`sourceEventSeqs:[callSeq]` 配对证明） |
| `compaction/summary` | 表面 | replace（遮蔽旧区） + 新 `user/message` | 遮蔽区 `[startSeq, endSeq]` + 摘要文本 + `{provider, model, maxTokens}` | 压缩事件（DSH 两阶段） |
| `llm/retry` | log-only | 无 | `{retryId, turn, step, retry, delayMs}` | 计划重试（UI 倒计时） |
| `llm/retry-started` | log-only | 无 | `{retryId}` | 退避后开始重试 |
| `spill/locate` | log-only | 无 | `{callId, locator, bytes, bytesOmitted}` | 溢写记录（locator 不透明） |

> **`ignorable` 策略**：所有 log-only 事件（`assistant/attempt`、`llm/retry*`、`spill/locate`）标 `ignorable: true`——未来旧运行时可读而不崩。新增**普通**（surface）事件时必须标 `ignorable`，否则升格式版本（§4.8）。

### 4.5 工具配对保证（对应 DSH Part 4.7）

配对**不在投影函数里**，三层分别保证：
1. **写入期强制**：`assistant/message` 的每个 tool-call 块带 `id`；`tool/result` 写入时校验 `toolCallId == callId && source.kind == 'tool'`，否则拒绝写入（抛错）。
2. **关系期**：`SessionLog` 维护 `pendingCalls` 表（`step/start` 清空；`step/end` 前检查无未销账），崩溃/fork 时用于合成收尾（§4.6）。
3. **投影期**：只按表面顺序投影，不做重排/配对。

### 4.6 崩溃修复（对应 DSH Part 3.12）

进程在 turn 中途退出后，日志有 `turn/start` 无 `turn/end`（残缺）。恢复时**不修改已有事件，只在尾部追加合成事件**：

```
scan events → openTurn / openStep / pendingCalls
seq = last.seq + 1
time = last.time   // 复用最后真实事件时间戳
for each pendingCall in pendingCalls:
    append tool/result { error: started ? 'ToolOutcomeUnknownError' : 'ToolNotStartedError' }
if openStep != null:
    append step/end
if openTurn != null:
    append turn/end { reason: {kind: 'interrupted'} }
```

**区分 `started`**（有 `callSeq` → `TOOL_OUTCOME_UNKNOWN`，工具可能已执行有副作用）与未开始（`TOOL_NOT_STARTED`）——影响模型看到文案（DSH Part 3.12）。

### 4.7 持久化（对应 DSH Part 5）

**格式**：每会话一个 JSONL 文件（一行一个 `SessionEvent` 的 JSON）。

- **不压缩**（端侧文件小、Dart JSONL 读取简单；未来可加 zstd 行级压缩作为独立迁移）。
- **帧**：每行独立 JSON；读取器逐行解析，末行不完整帧（EOF 撕裂）→ 若该行 JSON 可抢救则补，否则丢弃并标记 `recoveredTail`。
- **格式版本**：文件首行前加 `{"version":1,"conversationId":"…","createdAt":…}` header 行。升版本门槛照 DSH：旧运行时**会静默读错**才升版本；加普通事件类型只标 `ignorable: true` 不升版本。
- **存储位置**：`ApplicationSupportDirectory/<conversationId>.jsonl`（app 私有，不受 Android 存储权限限制）。

> **为什么 JSONL 而非 SQLite**：DSH 用 append-only 日志；append-only 天然支持崩溃修复（尾部撕裂可恢复）、审计、追加。SQLite 的 B+tree 无法表达"append-only + 尾部撕裂"的恢复语义。会话文件体积小（几 KB–几百 KB），文件操作足够。

### 4.8 版本兼容与迁移边（对应 DSH Part 5.6）

- **v1（本方案）**：上述 16 类事件。
- **升版本规则**：加可选属性/加 `ignorable` 事件 → 同版本；加必选属性/改 header/删改名 → 升版本并写迁移边。
- **迁移边**：`SessionStore.migrate(version: n, events: ...)` 纯函数，在加载时调用；返回新格式事件或抛错。
- **旧数据导入**（§5.8）：`ChatMessage[]` → v1 日志：每条 user/assistant 映射为 `user/message`/`assistant/message`；`source` 标 `{kind:'import'}`；`turn=1, step=1`。导入是一次性 `ignorable` 标记。

---

## 5. Part 2·Agent 主循环（对应 DSH Part 3）

### 5.1 设计立场

DSH 主循环：`ReactLoopAgent` 只有两个循环——外层 `while (await this.turn()) {}`，内层 `while(true)` step 循环（Part 3.3）。本方案复刻其**结构**，但用 Dart 单线程实现（无 async*，用 `StreamController` + `Completer`）。

**核心数据结构**：

```dart
enum AgentPhase { idle, running }
enum TurnEndReasonKind { completed, error, interrupted, maxTokens, blocked, user }

final class AgentPhaseState {
  final AgentPhase phase;
  final int turn;      // 已完成轮数
  final int step;      // 当前轮内已完成 step 数
  final bool wakeRequested;
}
```

### 5.2 主循环骨架（对应 DSH `ReactLoopAgent`）

```dart
class ReactLoopAgent {
  final SessionLog _session;
  final AgentContext _ctx;
  final LlmAdapter _adapter;
  final ToolRegistry _registry;
  final ToolPipeline _pipeline;
  final AgentConfig _config;
  AgentPhaseState _phase = AgentPhaseState(idle, turn: 0, step: 0);

  /// 进入 running，开始 turn 循环。
  Future<void> kick() async {
    _phase = AgentPhaseState(running, 0, 0, false);
    try {
      while (await _turn()) { _phase = AgentPhaseState(running, _phase.turn, _phase.step, true); }
    } catch (e) {
      // driver 边界错误容器（DSH: catch(_error) — 因为 turn/end 已记录原因）
      _logError(e);
    } finally {
      if (_phase.phase == AgentPhase.running) {
        _phase = AgentPhaseState(idle, _phase.turn, _phase.step, _phase.wakeRequested);
      }
    }
  }

  Future<bool> _turn() async {
    final turn = _phase.turn + 1;
    _session.append('turn/start', {turn: turn});
    _phase = ... step: 0;
    bool turnEnds = false;
    try {
      while (true) {
        _session.append('step/start', {turn: turn, step: _phase.step + 1});
        final decision = await _preStep(turn, _phase.step + 1);
        if (decision == 'reject') break;  // 跳过本 step（DSH PreStepDecision）
        final step = _phase.step + 1;
        final outcome = await _step(turn, step);
        if (outcome == 'end-turn') { turnEnds = true; break; }
        if (outcome == 'retry') continue;  // 同 turn 同 step 重试（DSH overflow recovery）
        // 否则正常：工具执行后回到 while 顶部
        _phase.step = step;
      }
    } finally {
      _session.append('step/end', {turn: turn, step: _phase.step});
      _session.append('turn/end', {turn: turn, reason: ...});
    }
  }
}
```

**turn/step 语义**（DSH Part 3.3）：
- **turn**：一次用户消息 → 一轮完整 agent 处理（可含多次 model 请求 + 工具执行）。
- **step**：一次 model 请求（`assistant/message` + 可能 `tool/call`）。
- 工具执行**在同一 step 内**（模型一次请求可带 N 个 tool-call，全部执行后回到 step 循环顶部再次请求模型）。
- 取消（用户新消息/中断）→ `turn/end { reason: interrupted }`。

> **端侧简化**：DSH 有 `inbox`（turn 内队列新消息）。本方案 v1 简化为**取消式**：用户在 agent 运行中发新消息 → 取消当前 turn（`interrupted`）→ 新消息开新 turn。v2 可扩展为队列式（保留取消式以兼容端侧 UX）。

### 5.3 请求构建（G12：模型可见即可重建）

```dart
Future<GenerateOptions> _buildRequest(turn, step) async {
  // 1. 系统提示（system/message 节点内容）
  final systemContent = _session.systemPromptContent;
  // 2. 工具 schema（header，不入 history）
  final tools = _registry.visibleFor(_modelId).map((t) => t.toSchema()).toList();
  // 3. 历史消息（deriveMessages 纯函数投影）
  final messages = _session.deriveMessages();
  // 4. 组装 GenerateOptions
  final options = GenerateOptions(
    messages: [...messages, userMessage],
    tools: tools,
    temperature: _config.temperature,
    maxTokens: _config.maxTokensPerRound,
    model: _modelId,
  );
  // 5. 开发期不变量：独立重建比对
  assert(_validateRebuild(options), 'request diverges from log');
  return options;
}
```

**关键**：`messages` 只能来自 `deriveMessages()`；任何插件/组件绕过它自拼历史都会 assert 失败。这是 G12 的修复。

### 5.4 失败恢复（G4：对应 DSH Part 3.10-3.12）

**失败归一化**（DSH Part 3.10）：adapter 报告**事实**（不含策略）：

```dart
final class LlmFailure {
  final String code;        // 'CONTEXT_WINDOW_EXCEEDED' | 'RATE_LIMIT' | 'SERVER' | 'TIMEOUT' | 'TRANSPORT' | 'NO_ADAPTER' | 'UNKNOWN'
  final String message;
  final int? status;
  final int? providerRetryAfterMs;
  final String? requestId;
}
```

**失败瀑布**（`agent/request-error` waterfall）：

```
模型请求失败
  → 落 assistant/attempt（失败尝试，log-only）
  → 跑 agent/request-error 瀑布（按序，第一个返回非-undefined 接管）：
    1. compaction（若 code == CONTEXT_WINDOW_EXCEEDED）→ 压缩后 {kind:'retry'}
    2. llm-retry（若 retryPolicy 允许该 code）→ 退避后 {kind:'retry'}
    3. 默认 undefined → 保持终态失败（turn/end {reason:error}）
```

**llm-retry 插件**（DSH Part 9.9 + 3.10）：

```dart
final class LlmRetry {
  static const Map<String, List<String>> _defaultRetryableCodes = {
    'local': ['TIMEOUT', 'TRANSPORT'],        // 本地引擎：超时/传输
    'api': ['RATE_LIMIT', 'SERVER', 'TIMEOUT', 'TRANSPORT', 'EMPTY_RESPONSE'],  // API
  };
  int maxRetries = 3;
  Duration initialDelay = const Duration(milliseconds: 500);
  Duration maxDelay = const Duration(seconds: 10);
  
  Future<RetryDecision> decide(LlmFailure f, Route route) async {
    if (!f.retryable) return RetryDecision.none();
    if (_retriesExceeded()) return RetryDecision.none();
    _session.append('llm/retry', {retryId:…, turn:…, step:…, retry: n, delayMs: d});
    await Future.delayed(delay);
    _session.append('llm/retry-started', {retryId:…});
    return RetryDecision.retry();
  }
}
```

**有界恢复**（DSH Part 3.10）：每次失败尝试后 `maxRetries++`；`turn/end` 时重置。`maxRetries` 默认 3（端侧），API 可配 5。

**overflow 恢复**（G4 关键，DSH Part 10.12）：

```dart
// 当 LlmFailure.code == CONTEXT_WINDOW_EXCEEDED 时
Future<CompactionResult?> compaction.decide(agent, turn, step, signal) {
  final budget = _budget.remaining();
  final prune = _pruneToolResults(turn);  // 确定性裁剪（先于摘要）
  if (prune.reduced && budget.isOk()) return CompactionResult.success();
  if (_summaryCallsExceeded(turn)) return CompactionResult.failure();
  final summary = await _summarize(turn, step);
  _session.replace(shadowsEndSeq, summary.content);  // replaceGeneration++
  if (_session.replaceGeneration > genBefore) return CompactionResult.success();
  return CompactionResult.failure();
}
```

> **前进性证明**：`replaceGeneration` 递增才允许 retry（DSH Part 3.10）。裁剪未推进 generation 时不 retry，避免死循环。

### 5.5 取消与 phase 状态机（G10）

```dart
Future<void> cancel(String reason) {
  // 仅当 phase == running
  if (_phase.phase != AgentPhase.running) return;
  // 发 abort signal（cancel controller）
  _abortController.cancel();
  // 当前 step 内：中断 model stream → 落 assistant/message {interrupted:true}
  // 退出 turn 循环 → turn/end {reason: interrupted}
}
```

**phase 状态机**：
- `idle` → 用户发消息 → `running`（`turn/start`）
- `running` → turn 完成 → `idle`
- `running` → 用户取消 → `idle`（`turn/end {interrupted}`）
- `running` → 错误 → `idle`（`turn/end {error}`）

**并发保护**：`idle` 时才可 `kick()`；`running` 时发新消息 → `cancel()` 而非排队（v1 简化）。

### 5.6 端侧简化与差异表

| DSH 原语 | 本方案对应 | 差异 | 原因 |
|---|---|---|---|
| `inbox`（turn 内消息队列） | 取消式（cancel + 新 turn） | 无队列 | 端侧 UX：用户发新消息应中断当前处理，不是排队（队列会显得"卡住"） |
| `agent/status`（idle/running） | `phase` 字段（直接） | 无独立事件 | 端侧 UI 用 Riverpod 状态，不需要事件流 |
| `turn-stopping`（Serial agent/turn-stopping） | 无（v1） | 省略 | 端侧场景"收口前干预"价值低 |
| `forked` turn reason | 无 | 省略 | 子代理用 spawn/fork provider，不 fork turn |

---

## 6. Part 3·工具流水线（对应 DSH Part 6）

### 6.1 六段流水线（对应 DSH Part 6）

DSH 工具流水线（Part 6）：

```
pre-execute → guards → execute → projectContent → post-execute → finalizeContent → result
```

本方案复刻其**语义**，简化为 Dart 实现：

| 段 | 可返回决策 | 能否否决执行 | 能否改输入 | 能否改输出 | 对应 DSH |
|---|---|---|---|---|---|
| 1 `pre-execute` | allow / deny / ask | ✅ deny 跳过执行 | ❌ 不能改参数（DSH deferred） | ❌ | `tools/pre-execute` |
| 2 `guards`（单调 deny） | deny / abstain | ✅ 只 deny（never force-allow） | ❌ | ❌ | `ctx.tools.guard()` |
| 3 `execute` | 结果 | ❌ | ❌（输入已记录，改则 history/audit/UI 不一致） | ❌ | `tools/execute` |
| 4 `projectContent` | 投影内容 | ❌ | ❌ | ✅ 展示格式（预格式化） | `projectContent` |
| 5 `post-execute` | accept / block / replace / attach | ✅ block 改 isError | ❌ | ✅ 最终内容 | `tools/post-execute` |
| 6 `finalizeContent` | — | — | — | ✅ 最终落盘（meta） | `finalizeContent` |

**端侧简化**：段 4/6 合并为"结果落盘"；段 5 简化为 `post-execute`（accept/block + content 替换）。保留段 1/2/3 完整语义。

### 6.2 流水线骨架（Dart）

```dart
class ToolPipeline {
  final List<ToolPreExecuteListener>? _preListeners;   // waterfall，可 deny/ask
  final List<ToolGuard>? _guards;                      // 单调 deny
  final ToolRegistry _registry;
  final Sandbox _sandbox;
  final AgentSandboxApprover? _approver;

  Future<ToolResult> execute(ToolCall call, Map<String, dynamic> args, String modelId) async {
    // 1. pre-execute（waterfall）
    for (var i = 0; i < _preListeners!.length; i++) {
      final decision = await _preListeners![i](call, args);
      if (decision == 'deny') return ToolResult.error('Denied: ' + call.name);
      if (decision == 'ask') {
        final approved = await _approver?.request(call, args) ?? false;
        if (!approved) return ToolResult.error('Not approved');
      }
    }
    // 2. guards（单调 deny）
    for (var guard in _guards!) {
      final guardDecision = guard.call(call, args);
      if (guardDecision == 'deny') return ToolResult.error(guard.reason);
    }
    // 3. execute
    final tool = _registry.lookup(call.name, modelId: modelId);
    if (tool == null) return ToolResult.error('Unknown tool: ' + call.name);
    // 沙箱（现有逻辑：检查 escalation）
    final escalation = extractEscalation(args);
    if (escalation != null) {
      final approved = await _approver?.request(escalation, call.name) ?? false;
      if (!approved) return ToolResult.error('Sandbox escalation denied');
    }
    try {
      final result = await tool.execute(args);
      return result;  // 4/5/6：结果落盘
    } catch (e) {
      return ToolResult.error('Tool execution failed: $e');
    }
  }
}
```

### 6.3 工具并行执行（G3）

DSH `maxParallelToolCalls`（Part 6.6）：模型一次可带 N 个 tool-call，若 `isConcurrencySafe` 则并行执行。

```dart
/// 按并发安全性分组执行工具调用。
Future<Map<String, ToolResult>> executeCalls(List<ToolCall> calls, int maxParallel) async {
  final safe = calls.where((c) => _registry.lookup(c.name)!.concurrencySafeFor(c.arguments ?? {}));
  final unsafe = calls.where((c) => !_registry.lookup(c.name)!.concurrencySafeFor(c.arguments ?? {}));
  // unsafe 串行；safe 按 maxParallel 分组并发
  final safeResults = await _batch(safe.toList(), maxParallel);
  final unsafeResults = await _serial(unsafe.toList());
  // 合并（按模型返回顺序）
}
```

**端侧默认**：`maxParallelToolCalls = 4`（Dart 单线程，事件驱动并发无真并行，但 I/O 可并发）。

### 6.4 工具结果三去向（对应 DSH Part 6.9）

| 去向 | 内容 | 来源 |
|---|---|---|
| 模型 | `content` + `isError`（`tool/result` 事件） | `finalizeContent` |
| 日志 | `content` + `meta` + `isError` | `tool/result` 事件（`sourceEventSeqs:[callSeq]`） |
| UI | `args`（命令/参数）+ `content`（展示）+ `meta`（状态） | `tool/call` + `tool/result` 事件订阅 |

**规范 value 不落库**（DSH Part 6.9）：`ToolResult.value`（如文件字节、结构化数据）只存于内存/执行期局部，落库的是 `content`（文本）+ `meta`（摘要）。这使日志不膨胀。

### 6.5 端侧 guard 示例

```dart
/// 保护模型缓存（AGENTS.md 铁律：卸载会清掉已下载模型）
final class ModelCacheGuard extends ToolGuard {
  @override
  GuardDecision call(ToolCall call, Map<String, dynamic> args) {
    if (call.name == 'shell_exec') {
      final cmd = (args['command'] as String?).toLowerCase();
      if (cmd.contains('rm') && (cmd.contains('model_cache') || cmd.contains('models/'))) {
        return GuardDecision.deny('Model cache is protected. Use model_manager to delete models.');
      }
    }
    if (call.name == 'write_file' || call.name == 'edit_file') {
      final path = (args['path'] as String?)?.toLowerCase();
      if (path != null && path.contains('/model_cache/')) {
        return GuardDecision.deny('Model cache directory is protected.');
      }
    }
    return GuardDecision.abstain();
  }
}
```

### 6.6 工具 schema 增强（对应 DSH Part 6.2）

现有 `ToolDefinition` 增加：
- `description` 增强：按模型能力动态渲染（小模型用更短描述；大模型可用详细描述）
- `parameters` 增强：必填字段标 `required`（现有 `validateRequiredArguments`）+ 类型提示
- `isConcurrencySafe`（现有预留）
- `timeout`（现有预留）→ 流水线超时

---

## 7. Part 4·上下文工程（对应 DSH Part 10）

### 7.1 设计立场（G5）

DSH 上下文工程：**一条组装路径 + 三条注入通道 + 四根可重建支柱 + 有界压缩/溢写**（Part 10.1）。本方案复刻其**语义**，按端侧预算（8K–32K context，tokens/s 1-10）做**两阶段压缩**（确定性裁剪为主，摘要为辅）。

**端侧关键约束**：
- 摘要调用模型 = 额外 token 成本（小模型 tokens/s 低）→ 默认**不开摘要**，仅确定性裁剪；摘要为可选开关。
- 上下文窗口由 `EngineCapabilities.maxContextTokens` 驱动（现有）。
- 压缩后请求仍须字节级重建（§4.2 不变量）。

### 7.2 三注入通道（对应 DSH Part 10.1）

| 通道 | 落地形态 | 排序 | 保前缀缓存 | 代表内容 | 端侧默认 |
|---|---|---|---|---|---|
| ① sections（system node 0） | `system/message`（surface node 0） | `SECTION_ORDERS`（-1000…10200） | ✅ | 身份/工具指引/工作区指引 | 启用 |
| ② `systemPrompt.context()` | user-role 快照（历史尾部） | `CONTEXT_ORDERS`（110/115/120） | ✅（放尾部保缓存） | 当前时间/沙箱策略/审批策略 | 启用（时间） |
| ③ `agent/pre-step` / `agent.inject()` | durable `user/message` | 到达顺序 | ✅（追加历史） | 工具可见性变更/AGENTS.md 链 | 启用（AGENTS.md） |

**端侧默认 sections**（`lib/agent/prompt/sections.dart`）：

```dart
final sections = [
  // 身份段（order: 0）
  Section(name: 'harness:identity', order: 0, text: (ctx) => '你是 TongYi-Lite 智能体，由 ${ctx.model} 驱动。'),
  // 工具指引段（order: 100）
  Section(name: 'tool:guidance', order: 100, text: (ctx) => _toolGuidance(ctx.tools)),
  // 工作区指引段（order: 200）— 可选（AGENTS.md 内容）
  Section(name: 'workspace:guidance', order: 200, text: (ctx) => ctx.agentsMd ?? ''),
];
```

### 7.3 组装路径（对应 DSH Part 10.2）

```
assemble() → renderPrompt() → 追加 system/message（node 0）
```

**唯一组装路径**：任何插件绕过 `assemble()` 自拼 prompt 会破坏"压力测量 prompt = 上线 prompt"（DSH Part 10.17 不变量 11）。本方案用 assert 强制（§5.3）。

### 7.4 上下文预算（对应 DSH Part 10.6）

```dart
final class ContextBudget {
  final int window;        // EngineCapabilities.maxContextTokens
  final int overhead;      // 系统提示 + 工具 schema + 固定开销（~512 tokens）
  final int reserve;       // 保留给回复的 tokens（~512）
  
  int get threshold => (window * 0.8).toInt();  // 压力阈值（DSH: floor(min(W*0.8, W-O-B))）
  int get remaining => window - overhead - currentUsage;
}
```

### 7.5 两阶段压缩（对应 DSH Part 10.8 + 7.4.4）

**阶段 1：确定性裁剪**（无模型调用，免费）：
- 按 `tool/call`/`tool/result` 配对裁剪旧工具结果（保留尾部 N 轮完整，旧轮工具结果截断为 `[omitted]`）
- 保留 user/assistant 消息完整（模型需要对话上下文）
- 裁剪后 `replaceGeneration++`（前进性证明）

**阶段 2：模型摘要**（可选，`config.useSummary`）：
- 若阶段 1 后仍超预算 → 调用模型摘要（同模型，`maxTokens=1024`）
- 摘要文本 → `user/message`（进历史，DSH 做法）
- 摘要事件 → `compaction/summary`（log-only，含 `{provider, model, maxTokens}`）
- 摘要失败 → 不 retry（`replaceGeneration` 未前进）
- 摘要次数上限：每 turn 最多 1 次（端侧）

```dart
class Compaction {
  final bool _useSummary;  // 端侧默认 false
  int _summaryCallsPerTurn = 0;
  
  Future<CompactionResult> decide(turn, step, signal) async {
    _summaryCallsPerTurn = 0;  // 每 turn 重置
    // 阶段 1：确定性裁剪
    final prune = _pruneToolResults(turn);
    _session.replace(shadowsEndSeq: prune.endSeq, prune.newContent);  // replaceGeneration++
    if (_budget.isOk()) return CompactionResult.success();
    // 阶段 2：摘要（可选）
    if (!_useSummary || _summaryCallsPerTurn >= 1) return CompactionResult.failure();
    final summary = await _summarize(turn, step, signal);
    _session.replace(shadowsEndSeq: prune.endSeq, summary);
    _summaryCallsPerTurn++;
    if (_session.replaceGeneration > genBefore) return CompactionResult.success();
    return CompactionResult.failure();
  }
}
```

### 7.6 工具输出溢写（对应 DSH Part 10.13）

DSH 溢写：best-effort，失败保留原文；`read` 结果跳过防循环；`maxInlineTokens` 旋钮。

**端侧实现**：
```dart
class Spill {
  final int maxInlineTokens = 4096;  // 端侧预算小，默认 4K
  Future<SpillDecision> decide(ToolCall call, ToolResult result) async {
    if (call.name == 'read_file') return SpillDecision.inline();  // 防 read/spill 循环
    final tokens = estimateTokens(result.content);
    if (tokens <= maxInlineTokens) return SpillDecision.inline();
    final path = await _store(result.content);
    _session.append('spill/locate', {callId: call.id, locator: path, bytes: result.content.length});
    return SpillDecision.spill(locator: path, bytesOmitted: tokens - maxInlineTokens);
  }
}
```

**模型看到**：`[Omitted N bytes. Full result stored at: <locator>]` + 可 `read_file` 回读（DSH 做法）。

**端侧适配**：`read_file` 工具描述增强："若结果被截断，可用 read_file 指定 offset 读取完整内容"。

### 7.7 附件（对应 DSH Part 10.14）

DSH：附件只引用不内联；图片是内容、文件是地址文本。

**端侧现状**：`ChatMessage.imagePath` / `audioPath`；`completionWithMessages(imagePath: …)`。

**适配**：
- 图片/音频作为 `user/message` 事件的 `attachment` 字段（`{type:'image'|'audio', id: hash, bytes, width?, height?}`）
- 日志只存**引用**（`id` + 元数据），字节在 app 私有目录（`attachment/`）
- 纯文本模型 → `[image omitted because this model accepts text only]`（DSH 做法）

### 7.8 端侧压缩策略表（对应 DSH Part 10.8）

| 场景 | DSH 策略 | 端侧策略 |
|---|---|---|
| 压力（超阈值 80%） | 裁剪 → 摘要 → retry | 裁剪（默认）→ 摘要（可选）→ retry |
| 溢出（`CONTEXT_WINDOW_EXCEEDED`） | 裁剪 → 一次摘要 → retry | 裁剪（默认）→ 摘要（可选）→ retry |
| 摘要失败 | 不 retry（`replaceGeneration` 未前进） | 同 |
| 溢出不可修复（信封超窗） | 抛错 | 抛错 + UI 提示"上下文已满，请新建会话" |

---

## 8. Part 5·LLM Adapter Seam（对应 DSH Part 9）

### 8.1 设计立场（G6）

DSH `LlmAdapter`：`stream()` 唯一 abstract，其余 6 个方法有默认实现（Part 9.5）。本方案复刻其**契约**，用 Dart 实现。

### 8.2 Adapter 契约（Dart）

```dart
abstract class LlmAdapter {
  /// 唯一 abstract：流式生成。
  Stream<StreamChunk> stream(GenerateOptions options);
  
  /// 默认实现（可覆写）：
  LlmProviderInfo get providerInfo => LlmProviderInfo(id: modelId, name: modelId);
  List<LlmModelInfo> listModels() => [];  // advisory
  LlmModelInfo resolveModel(String model) => LlmModelInfo(id: model, name: model);
  PreparedLlmCall prepareCall(String model) => PreparedLlmCall(adapter: this, model: model);
}

final class StreamChunk {
  final String text;       // 文本
  final List<ToolCall>? toolCalls;  // 工具调用（native-tools 协议）
  final Usage? usage;      // token 用量（端侧引擎无 usage，null）
  final bool isFinal;      // 是否最终
}
```

### 8.3 两个 Adapter

**LocalEngineAdapter**（`lib/agent/llm/local_adapter.dart`）：
```dart
class LocalEngineAdapter implements LlmAdapter {
  final InferenceService _engine;
  final EngineCapabilities _caps;
  final ProtocolProtocol _protocol;  // prompt-json / native / xml
  
  @override
  Stream<StreamChunk> stream(GenerateOptions options) {
    final stream = _engine.completionWithMessages(
      prompt: options.prompt,
      messagesJson: _protocol.buildMessagesJson(options),
      maxTokens: options.maxTokens,
      temperature: options.temperature,
    );
    // 用 AgentStreamProcessor 解析 tokens → StreamChunk
    final processor = AgentStreamProcessor();
    return stream.map((token) {
      processor.add(token);
      return StreamChunk(text: processor.visibleText, isFinal: false);
    });
  }
}
```

**OpenAiAdapter**（`lib/agent/llm/openai_adapter.dart`）：
```dart
class OpenAiAdapter implements LlmAdapter {
  final OpenAiService _api;
  @override
  Stream<StreamChunk> stream(GenerateOptions options) {
    // 用 API 原生 tools（若选项）或 prompt-JSON
    // 解析流式 response → StreamChunk
  }
}
```

### 8.4 `prepareCall`（对应 DSH Part 9.7）

DSH `prepareCall` 绑定注册代际（HMR 安全）。端侧无 HMR，简化为**能力快照**：

```dart
final class PreparedLlmCall {
  final LlmAdapter adapter;
  final String model;
  final EngineCapabilities capabilities;  // 加载时快照
}
```

**用途**：协议选择在 `prepareCall` 时固化（能力驱动），避免运行中换模型导致协议不一致。

### 8.5 协议层（现有 + 扩展）

| 协议 | 支持 | 端侧状态 |
|---|---|---|
| prompt-JSON | ✅ | 本地默认（小模型无原生工具） |
| xml-tool | ✅（`AgentStreamProcessor` 已解析） | 本地 Qwen 默认（Spark 训练分布） |
| native-tools | ✅（selector 已有） | API 默认；本地待引擎支持 |

**协议选择**（现有 `ProtocolSelector`，保留）：
```
capabilities.nativeToolCall → native-tools
capabilities.toolTemplate == 'spark-xml' → xml-tool
否则 → prompt-JSON
```

### 8.6 Adapter 只报告事实（DSH Part 9.9 不变量）

```dart
// Adapter 失败 → LlmFailure（事实，不含策略）
// 重试策略由 llm-retry 插件决定（DSH Part 9.9 I-8）
```

---

## 9. Part 6·安全：沙箱 + 审批 + Guard（对应 DSH Part 7）

### 9.1 设计立场（G7/G8）

DSH 安全三层：**沙箱（事实层，fail-closed）→ 审批（授权层，fail-loud）→ 预设（呈现层，fail-loud）**（Part 7.15）。现有 `Sandbox` + `agent_approval` 已实现其**语义**，本方案**原样保留**，仅做端侧适配。

### 9.2 端侧沙箱适配（对应 DSH Part 7.3）

| DSH 强制点 | 端侧对应 | 说明 |
|---|---|---|
| 子进程 `ctx.sandbox.confine()`（bwrap/Landlock/Seatbelt/Windows ACL） | Android 权限模型（无内核级 confinement） | 端侧无 bwrap；`danger-full-access` = Android 运行时权限（存储）+ SAF grant |
| `SandboxedFileSystem.checkedTarget()`（进程内策略边界） | `SandboxedPath.check()`（策略围栏） | 保留（现有）：workspace-write = app 私有目录；danger-full-access = 公共存储（需权限） |
| denial marker（`[sandbox: file access denied under ...]`） | 保留同字符串 | 模型兼容（DSH 同措辞） |

**端侧威胁模型**（DSH Part 7.3）：
- 无 "对抗性宿主内核"（Android 沙箱已有），威胁是"模型可控路径写错地方" → 策略围栏 + deny guard 足够。

### 9.3 审批（DSH Part 7.10）

现有实现保留：
- `allowed-once`：批准后仅本次调用
- `never`（子代理）：子代理审批恒 `never`（DSH Part 7.11 不变量 10）
- 无 answerer → `unavailable`（fail-closed，不执行）

**端侧适配**：审批 UI（`ApprovalDialog`）；无 agent 时（非 agent 模式）审批不可用 → `unavailable`。

### 9.4 Guard（DSH Part 6.4）

新增（§6.3 已有示例）。Guard 只能 deny/abstain（never force-allow，DSH Part 12.5 不变量 11）。

### 9.5 端侧安全不变量（从 DSH 26 条选 10 条关键）

| # | 不变量 | 端侧落点 |
|---|---|---|
| 1 | 沙箱无可用后端 → `SANDBOX_UNAVAILABLE`，不静默直通 | 端侧：无权限 → `unavailable` |
| 2 | 审批无 answerer → `unavailable`（非允许） | 现有 |
| 3 | `never` 在 service 内部内联判定，先于 waterfall | 子代理审批 `never` |
| 4 | runner 失败优先于 denial | 端侧：命令执行失败 vs 沙箱拒绝归因独立 |
| 5 | not-strictly-wider 升级 → 抛；同模式 → 不审批 | 现有 |
| 6 | 授权只作用于问的那一次动作，不持久化 | 现有（allowed-once） |
| 7 | 委派子 agent 审批钉 `never` | §11 |
| 8 | 进程内强制而非意图闸门 | 端侧：策略围栏在 `write_file`/`edit_file`/`shell_exec` 入口 |
| 9 | 存储不可变性（deep-freeze + detach） | 端侧：`SessionEvent` 不可变 |
| 10 | `danger-full-access` 消费者 spawn 原 argv、不调 `ctx.sandbox` | 端侧：`danger-full-access` 时跳过策略围栏 |

---

## 10. Part 7·子代理（对应 DSH Part 11）

### 10.1 设计立场（G9）

DSH 子代理：**多实现共存的能力接缝**（Part 11.1）。本方案复刻其**语义**，端侧简化为**单实现（in-process）+ 两种模式（spawn/fork）**。

### 10.2 Provider 契约（DSH Part 11.1）

```dart
final class SubagentCapabilities {
  final bool agentOptions;    // 能否覆盖 provider/model/maxTokens
  final bool outputSchema;    // 能否要求结构化输出
  final bool depthLimit;      // 能否限制委派深度
  final bool toolFilter;      // 能否裁剪子代理工具集
  final bool persona;         // 能否注入 per-child 人设
}

abstract class SubagentProvider {
  final String name;          // 'spawn' | 'fork'
  final SubagentCapabilities capabilities;
  final bool inheritsParentContext;  // 仅 fork 为 true
  
  Future<SubagentRun> start(SubagentStartRequest request);
}

final class SubagentRun {
  final String id;
  final SessionLog session;    // 子代理会话
  final Future<SubagentResult> result;
  void dispose();
}
```

### 10.3 两种模式（DSH Part 11.3）

| 模式 | seed | 端侧实现 | 审批 |
|---|---|---|---|
| `spawn` | 空白（`inheritsParentContext = false`） | 新建 `SessionLog`，独立 `AgentRuntime` | `never` |
| `fork` | 父会话日志中"到最后一个 `turn/end` 为止"的已完成前缀 | 读取父 `SessionLog`，截取 `turn/end` 前事件，作为子 seed | `never` |

**fork seed 切法**（DSH Part 11.3）：
```dart
List<SessionEvent> completedTurnPrefix(SessionLog events) {
  final lastEnd = events.lastWhere((e) => e.type == 'turn/end', orElse: () => null);
  if (lastEnd == null) return [];
  return events.where((e) => e.seq <= lastEnd!.seq).toList();
}
```

### 10.4 子代理调用（工具）

```dart
final class SubagentTool extends ToolDefinition {
  const SubagentTool({required this.providerName}) : super(
    name: 'subagent',
    description: 'Delegate a task to a subagent. Use fork to give context.',
    parameters: { /* provider, prompt, mode */ },
    execute: (args) async {
      final provider = _ctx.subagents.get(providerName);
      final run = await provider.start(request);
      final result = await run.result;
      return ToolResult(content: result.output, isError: result.isError);
    }
  );
}
```

**子代理审批 `never`**（DSH Part 7.11 不变量 10）：子代理不能请求沙箱升级；若子代理工具被 deny，直接失败。

**子代理深度限制**：`maxDepth = 2`（DSH Part 11.10 不变量 6：深度取 `delegationDepth` 与 `subagentDepth` 较大值；本方案固定 2）。

### 10.5 子代理结果 → 工具结果

| DSH `SubagentRun.result` | 端侧映射 |
|---|---|
| `stopReason: completed` | `ToolResult.isError = false` |
| `stopReason: error` | `ToolResult.isError = true`（模型/传输失败以 `stopReason:'error'` resolve，DSH Part 11.3） |
| `stopReason: max-tokens` | `ToolResult.isError = true` |
| `diagnostic`（≤4096 bytes） | `ToolResult.meta['diagnostic']` |

### 10.6 端侧成本控制

| 维度 | 策略 |
|---|---|
| 模型共享 | 子代理用同模型（无额外成本，但 token 消耗翻倍） |
| 轮次上限 | 子代理 `maxRounds = 5`（默认） |
| 上下文预算 | 子代理 `maxContextTokens = 4096`（fork 时裁剪 seed） |
| 触发方式 | 模型自主调用 `subagent` 工具（DSH 做法）；v2 可加用户显式触发 |
| 审批 | 恒 `never` |

---

## 11. Part 8·扩展生态（对应 DSH Part 12）

### 11.1 设计立场

DSH 扩展五条通道（Skill/MCP/Hooks/指令文件/自定义命令）+ 两层动态插件（Part 12.1）。本方案**裁剪**：保留 Skill/Hooks/指令文件，裁剪 MCP/自定义命令/动态插件（端侧无意义）。

### 11.2 保留：Skills（DSH Part 12.2/12.3）

**端侧简化**：
- 6 级 rank → 2 级：内置（`assets/skills/`，rank 100）+ 用户（`ApplicationSupport/skills/`，rank 200）
- 格式：`<name>/SKILL.md`（frontmatter: `name/description/whenToUse/invocation`）
- 注册：`SkillProvider`（现有 `ctx.skills` 思想简化）
- 模型面：首次 `agent/pre-step` 注入 `<available_skills>`（name + description 转义）；后续 step 应用精确工具可见性

**端侧内置 skill 示例**：
```markdown
# web-research
description: 联网搜索并总结。
whenToUse: 用户问实时信息/新闻/价格。
---
## 使用
调用 web_search 工具，获取来源后总结。
```

### 11.3 保留：Hooks（DSH Part 12.5）

**端侧简化**：Dart 事件订阅（`ctx.on('tools/pre-execute', listener)`）。

**可用 hook**：
- `agent/pre-step`：否决 step（返回 `reject`）
- `tools/pre-execute`：deny/ask
- `tools/post-execute`：观察/审计
- `tools/result`：同步通知（只读）

**端侧内置 hook 示例**：
```dart
// 限制 shell_exec 的 rm -rf
ctx.on('tools/pre-execute', (call, args) {
  if (call.name == 'shell_exec') {
    final cmd = (args['command'] as String?) ?? '';
    if (cmd.contains('rm -rf') || cmd.contains('rm -r')) {
      return 'deny';
    }
  }
  return 'allow';
}, prepend: true);
```

### 11.4 保留：指令文件（DSH Part 12.6）

**端侧简化**：
- 路径：`ApplicationSupport/AGENTS.md`（用户全局）+ `workspace/AGENTS.md`（工作区，若存在）
- 优先级：全局 → 工作区（后覆盖前）
- 内容：低权威 workspace guidance（DSH Part 12.6）
- 注入：作为 `workspace:guidance` section（§7.2）

### 11.5 裁剪

| DSH 扩展 | 裁剪原因 |
|---|---|
| MCP | 需网络；端侧场景网络不可靠；web_search 工具已覆盖类似需求 |
| 自定义命令 | 端侧 UX 无 slash command；用户交互走 UI 按钮 |
| 动态插件 / HMR | 移动端无运行时加载；安全/复杂度不值得 |
| 插件市场 | 同上 |

---

## 12. Part 9·UI 集成（对应 DSH Part 13）

### 12.1 设计立场

DSH 五种 profile（web/headless/sdk/acp）→ 五种人机界面（Part 13.1）。本方案**单一 profile（Android app）**，UI 层直接驱动 `AgentRuntime`。

### 12.2 UI 状态（Riverpod）

```dart
// AgentRuntime 暴露的状态（Riverpod StateProvider）
final agentStateProvider = StateNotifierProvider<AgentStateNotifier, AgentState>((ref) { ... });

final class AgentState {
  final AgentPhase phase;       // idle/running
  final int turn;
  final int step;
  final List<ChatMessage> messages;  // deriveMessages 投影
  final List<ToolActivity> toolActivities;  // tool/call + tool/result 事件
  final bool? compactionActive;   // 压缩中
  final String? lastError;        // turn/end {error} 信息
}
```

### 12.3 UI 组件（对应 DSH Part 13.8 事件订阅）

| UI 组件 | 事件来源 | 说明 |
|---|---|---|
| ChatMessageBubble | `user/message`、`assistant/message`、`compaction/summary` | 普通消息 |
| ToolActivityCard | `tool/call` + `tool/result` | 工具活动（命令/参数 + 结果/错误） |
| CompactionBanner | `compaction/summary` | "上下文已压缩"提示 |
| RetryIndicator | `llm/retry` + `llm/retry-started` | "重试中…（N）"倒计时 |
| ApprovalDialog | `tools/pre-execute {ask}` / `sandbox` 审批 | 沙箱升级确认 |
| AgentStatusBadge | `phase` | 运行中/空闲 |

### 12.4 UI 数据流

```
用户输入 → AgentRuntime.kick() → turn/step 事件 → SessionLog
                                            ↓
                              deriveMessages() + 工具活动事件
                                            ↓
                              Riverpod AgentStateNotifier
                                            ↓
                              UI 组件（ChatMessageBubble + ToolActivityCard + …）
```

### 12.5 端侧 UI 差异

| DSH UI 元素 | 端侧对应 | 说明 |
|---|---|---|
| 插件市场 | 无 | 裁剪 |
| 自定义命令 | 无 | 裁剪 |
| 多 profile | 单一 profile | Android app |
| 多 session 并行 | 单 session 串行 | 端侧 UX（一个对话一个 agent） |
| 工具卡片 | ToolActivityCard | 现有"🔧"升级为结构化卡片 |

---

## 13. Part 10·实现路线图

### 13.1 阶段划分

| 阶段 | 内容 | 验收标准 | 预计工作量 |
|---|---|---|---|
| **Phase 0**：会话日志基础 | `SessionLog` + `SessionEvent` + `JsonlSessionStore` + `deriveMessages()` + 崩溃修复 + 导入迁移 | 旧会话可导入；崩溃后恢复；`deriveMessages()` 纯函数 | 中 |
| **Phase 1**：主循环重构 | `ReactLoopAgent`（turn/step/phase）+ 失败瀑布 + `llm-retry` + 请求可重建不变量 | 替换现有 `runAgent`；工具调用正常；错误恢复正常 | 中大 |
| **Phase 2**：工具流水线 | 六段流水线 + 并行执行 + 结果三去向 + 溢出压缩 + 溢写 | 工具拦截/审计正常；并行正常；长会话不溢出 | 中 |
| **Phase 3**：Adapter seam | `LlmAdapter` + `LocalEngineAdapter` + `OpenAiAdapter` + `prepareCall` + 协议选择 | 换模型/加模型能力不改调用方 | 小 |
| **Phase 4**：子代理 | `SubagentProvider` + spawn/fork + 子代理工具 + 审批 `never` | 子代理可调用；结果回填正常 | 中 |
| **Phase 5**：扩展生态 | Skills + Hooks + 指令文件 | 内置 skill 生效；hook 拦截正常 | 小 |
| **Phase 6**：UI 集成 | 新 UI 组件 + AgentState + 数据流 | 全 UI 切换；旧 UI 保留（并行） | 中 |

**总预计**：3-4 周（单人，不含真机调试）。

### 13.2 阶段依赖

```
Phase 0（日志） → Phase 1（主循环） → Phase 2（流水线）
                                    → Phase 3（Adapter）
Phase 4（子代理） 依赖 Phase 1 + Phase 3
Phase 5（扩展） 依赖 Phase 1 + Phase 2
Phase 6（UI）  依赖 Phase 0 + Phase 1 + Phase 2
```

### 13.3 迁移策略

| 阶段 | 迁移方式 |
|---|---|
| Phase 0 | 旧会话导入（一次性，标记 `imported`） |
| Phase 1 | 新 agent 逻辑替换旧 `runAgent`；旧逻辑保留（`if (settings.useNewAgentMode)`） |
| Phase 2 | 新流水线替换旧 `executeToolCalls` |
| Phase 3 | 新 Adapter 替换旧 `streamFn` |
| Phase 4-6 | 增量新增 |

**回退**：每阶段保留旧逻辑（feature flag）；新逻辑 bug 可快速回退。

### 13.4 阶段验收测试

| 阶段 | 关键测试 |
|---|---|
| Phase 0 | 崩溃恢复测试（模拟进程退出后恢复）；导入测试（旧会话可读）；`deriveMessages()` 纯函数测试 |
| Phase 1 | 多轮工具调用测试；错误恢复测试（API 429/500）；请求可重建测试（assert 通过） |
| Phase 2 | 工具拦截测试（危险命令 deny）；并行测试；长会话压缩测试；溢写测试 |
| Phase 3 | 换模型测试；协议切换测试（native-tools 启用） |
| Phase 4 | 子代理 spawn/fork 测试；子代理审批 `never` 测试 |
| Phase 5 | skill 注入测试；hook 拦截测试 |
| Phase 6 | UI 全功能测试 |

---

## 14. 不变量清单（fail-loud 检查表）

### 14.1 会话日志不变量

| # | 不变量 | 检查时机 |
|---|---|---|
| 1 | `seq` 严格递增 | append 时 |
| 2 | `tool/result` 的 `toolCallId == callId` | append 时 |
| 3 | `replace` 遮蔽范围合法（`startSeq <= endSeq`） | replace 时 |
| 4 | `replaceGeneration` 仅在 replace 时递增 | replace 时 |
| 5 | 日志无循环引用/非有限数（`snapshotJsonValue`） | append 时（debug） |
| 6 | 旧会话导入后 `seq` 连续 | 导入时 |

### 14.2 主循环不变量

| # | 不变量 | 检查时机 |
|---|---|---|
| 7 | `turn/start` 必有对应 `turn/end` | 崩溃修复 |
| 8 | `step/start` 必有对应 `step/end` | 崩溃修复 |
| 9 | `phase` 仅在 `idle` 时可 `kick()` | kick 时 |
| 10 | 请求只能由 `deriveMessages()` 构造 | 每次请求（assert） |
| 11 | 失败重试必须 `replaceGeneration` 前进 | retry 决策 |

### 14.3 工具不变量

| # | 不变量 | 检查时机 |
|---|---|---|
| 12 | `pre-execute` deny 后不执行 | 流水线 |
| 13 | guard 只 deny（never force-allow） | 流水线 |
| 14 | 未知工具 → `UnknownToolError` | 流水线 |
| 15 | 工具结果三去向一致（模型/日志/UI） | 流水线 |

### 14.4 安全不变量

| # | 不变量 | 检查时机 |
|---|---|---|
| 16 | 沙箱无可用后端 → `unavailable` | 沙箱解析 |
| 17 | 审批 `never` 时不请求 UI | 子代理审批 |
| 18 | `danger-full-access` 不跳过策略围栏（除危险操作） | 沙箱解析 |

---

## 15. 风险与权衡

### 15.1 主要风险

| 风险 | 影响 | 缓解 |
|---|---|---|
| 摘要压缩成本（端侧 tokens/s 低） | 压缩慢，用户等待 | 默认不开摘要，仅确定性裁剪；摘要为可选开关 |
| JSONL 文件体积（长会话） | 存储占用 | 溢写（工具结果落盘）；压缩（旧轮工具结果截断） |
| 单线程并发（Dart） | 并行工具执行延迟 | 并行上限 4；I/O 并发（网络/文件） |
| 引擎无 usage 反馈 | 上下文预算估计不准 | `EngineCapabilities.maxContextTokens` + 保守预算 |
| 崩溃修复复杂度 | 恢复失败 → 会话不可用 | 崩溃修复只追加不修改；保留旧会话备份 |
| 工具结果模型可见（行为变更） | 小模型可能被长工具结果干扰 | 溢写 + 压缩 + 截断 |

### 15.2 权衡

| 决策 | 选 A（DSH 全量） | 选 B（端侧简化） | 选 B 理由 |
|---|---|---|---|
| 压缩 | 模型摘要为主 | 确定性裁剪为主，摘要可选 | 摘要成本高（端侧 tokens/s 低） |
| 工具并行 | 无上限（DSH `maxParallelToolCalls`） | 上限 4 | 单线程；I/O 并发足够 |
| 子代理 | 6 provider + Teams | spawn/fork only, depth≤2 | 端侧无远程执行；Teams 复杂度高 |
| 扩展 | MCP + 自定义命令 + 动态插件 | Skill + Hooks + 指令 | 网络不可靠；运行时加载复杂度高 |
| 日志格式 | zstd 压缩 JSONL | 纯 JSONL | 简单；文件小；未来可迁移 |
| 崩溃修复 | 完整（DSH 26 条） | 核心 6 条 + 崩溃修复 | 端侧崩溃少；核心足够 |

### 15.3 开放问题

| 问题 | 建议 |
|---|---|
| 摘要模型选择 | 同模型（无额外下载）；v2 可加小模型（0.5B）专用于摘要 |
| 子代理触发方式 | v1 模型自主；v2 用户显式（"让子代理处理"按钮） |
| 多 session 并行 | 端侧 UX 单 session；v2 可支持多会话并行（需 engine 并发支持） |
| 工具结果 UI 展示 | 结构化卡片（命令/参数/结果/错误）；v2 可加折叠 |
| 崩溃修复备份 | 每次 `turn/end` 前备份 session 文件（v2） |

---

## 16. DSH 概念 → TongYi-Lite 术语对照表

| DSH 术语 | TongYi-Lite 对应 | 说明 |
|---|---|---|
| `ReactLoopAgent` | `ReactLoopAgent`（`lib/agent/loop/agent.dart`） | 主循环 |
| `SessionLog` | `SessionLog`（`lib/agent/session/log.dart`） | 事件日志 |
| `SessionEvent` | `SessionEvent`（`lib/agent/session/event.dart`） | 事件信封 |
| `deriveMessages()` | `deriveMessages()`（`SessionLog`） | 投影 |
| `LlmAdapter` | `LlmAdapter`（`lib/agent/llm/adapter.dart`） | Adapter 契约 |
| `ToolPipeline` | `ToolPipeline`（`lib/agent/tools/pipeline.dart`） | 六段流水线 |
| `SubagentProvider` | `SubagentProvider`（`lib/agent/subagents/provider.dart`） | 子代理接缝 |
| `Sandbox` | `Sandbox`（`lib/agent/sandbox.dart`） | 现有保留 |
| `Approval` | `AgentSandboxApprover`（`lib/providers/agent_approval.dart`） | 现有保留 |
| `Compaction` | `Compaction`（`lib/agent/context_eng/compaction.dart`） | 两阶段压缩 |
| `Spill` | `Spill`（`lib/agent/context_eng/spill.dart`） | 溢写 |
| `EngineCapabilities` | `EngineCapabilities`（`lib/agent/capability.dart`） | 现有保留 |
| `ProtocolSelector` | `ProtocolSelector`（`lib/agent/protocol/protocol_selector.dart`） | 现有保留 |
| `AgentStreamProcessor` | `AgentStreamProcessor`（`lib/providers/agent_stream_processor.dart`） | 现有保留 |
| `ChatMessage` | `ChatMessage`（UI 投影，非真相源） | 降级 |
| `AgentRuntime` | `AgentRuntime`（`lib/agent/runtime.dart`） | 会话实例 |
| `AgentContext` | `AgentContext`（`lib/agent/context.dart`） | 事件订阅 + 插件 |

---

## 17. 结论

本方案照抄 DSH 的**核心选择**（事件溯源会话日志 + 能力 seam + 失败策略三分类 + 组合即配置），按端侧约束做**三层裁剪**（压缩/并行/子代理简化），保留现有**能力资产**（工具集/沙箱/审批/协议/能力模型）作为迁移输入。

**关键行为变更**（相对现状）：
1. **工具结果进模型上下文**（`tool/result` 事件，G1/G11）
2. **事件日志替换消息数组**（G1/G12）
3. **崩溃修复**（G2）
4. **失败恢复**（G4）
5. **上下文工程**（G5）
6. **Adapter seam**（G6）
7. **子代理**（G9）

**实施优先级**：Phase 0（日志）→ Phase 1（主循环）→ Phase 2（流水线）→ Phase 3（Adapter）→ Phase 4（子代理）→ Phase 5（扩展）→ Phase 6（UI）。

**验收标准**：每阶段有明确测试；旧逻辑保留（feature flag）可回退；新逻辑与旧逻辑并行（v1）。

---

## 附录 A：事件类型 master table（v1）

| 事件名 | 类别 | 表面 | 关键载荷 | 说明 |
|---|---|---|---|---|
| `turn/start` | 结构 | append | `{turn}` | 一轮开始 |
| `turn/end` | 结构 | append | `{turn, reason:{kind}}` | 一轮结束 |
| `step/start` | 结构 | append | `{turn, step}` | 一个模型请求开始 |
| `step/end` | 结构 | append | `{turn, step}` | 一个模型请求结束 |
| `user/message` | 表面 | append | `{content, attachmentId?, turn}` | 用户消息 |
| `system/message` | 表面 | append | `{content, turn?}` | 系统提示（可压缩遮蔽） |
| `assistant/message` | 表面 | append | `{content, toolCalls[], stats?, interrupted?}` | 助手消息 + 工具调用 |
| `assistant/attempt` | log-only | 无 | `{content, toolCalls[], stats?}` | 失败尝试 |
| `tool/call` | 表面 | append | `{turn, step, callId, name, arguments}` | 工具调用开始 |
| `tool/result` | 表面 | append | `{turn, step, callId, content, isError, meta?, sourceEventSeqs?}` | 工具回执 |
| `compaction/summary` | 表面 | replace | `{shadowsEndSeq, content, provider, model, maxTokens}` | 压缩 |
| `llm/retry` | log-only | 无 | `{retryId, turn, step, retry, delayMs}` | 计划重试 |
| `llm/retry-started` | log-only | 无 | `{retryId}` | 开始重试 |
| `spill/locate` | log-only | 无 | `{callId, locator, bytes, bytesOmitted}` | 溢写 |
| `imported` | log-only | 无 | `{originalId, originalRole, originalContent, originalTimestamp}` | 导入标记 |
| `fs/observed` | log-only | 无 | `{operation, path, bytes, time}` | 文件观察（v2） |

---

## 附录 B：最小代码骨架（Dart）

### B.1 SessionLog.append

```dart
class SessionLog {
  final List<SessionEvent> _events = [];
  int _seq = 0;
  int _contentGeneration = 0;
  int _replaceGeneration = 0;
  
  void append(String type, Map<String, dynamic> data, {String? source, String? surfaceOp}) {
    _seq++;
    final event = SessionEvent(
      type: type, seq: _seq, time: DateTime.now(),
      source: source, surfaceOp: surfaceOp, data: data,
    );
    _events.add(event);
    if (surfaceOp == 'replace') { _contentGeneration++; _replaceGeneration++; }
    _store.append(event);  // 持久化
  }
}
```

### B.2 SessionLog.deriveMessages

```dart
class SessionLog {
  List<ChatMessage> deriveMessages() {
    final messages = <ChatMessage>[];
    final pendingToolCalls = <Map<String, ToolCall>>{};
    for (final event in _events) {
      switch (event.type) {
        case 'user/message':
          messages.add(ChatMessage(role: user, content: event.data['content']));
        case 'assistant/message':
          final msg = ChatMessage(role: assistant, content: event.data['content']);
          // 附着 toolCalls
          pendingToolCalls.addAll((event.data['toolCalls'] as List?)?.cast<Map<String, dynamic>>() ?? []);
          messages.add(msg);
        case 'tool/result':
          messages.add(ChatMessage(role: assistant, content: event.data['content'],
            meta: {
              'callId': event.data['callId'],
              'isError': event.data['isError'],
            }));
        case 'compaction/summary':
          messages.add(ChatMessage(role: user, content: event.data['content'],
            meta: {'isCompaction': true}));
        // 其他事件不投影
      }
    }
    return messages;
  }
}
```

### B.3 ReactLoopAgent.kick（简化）

```dart
class ReactLoopAgent {
  Future<void> kick() async {
    _phase = AgentPhaseState(running, 0, 0, false);
    while (await _turn()) {}
    _phase = AgentPhaseState(idle, _phase.turn, _phase.step, false);
  }
  
  Future<bool> _turn() async {
    final turn = _phase.turn + 1;
    _session.append('turn/start', {turn: turn});
    _phase = ... step: 0;
    try {
      while (true) {
        final step = _phase.step + 1;
        _session.append('step/start', {turn: turn, step: step});
        final outcome = await _step(turn, step);
        _phase.step = step;
        if (outcome == 'end-turn') { _session.append('turn/end', {turn: turn, reason: ...}); return true; }
        if (outcome == 'retry') continue;
        // 工具执行后回到 while 顶部
      }
    } finally {
      _session.append('step/end', {turn: turn, step: _phase.step});
      _session.append('turn/end', {turn: turn, reason: ...});
    }
  }
}
```

---

*文档版本 v0.1；基于 DSH 学习材料 + 项目现状盘点；实施前需按 Phase 0-6 逐步验证。*
