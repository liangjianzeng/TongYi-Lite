# TongYi-Lite Agent Lite —— 端侧智能体核心能力整合方案

> 目标：把当前"单轮问答"升级为"具备简单任务执行与工具调用"的轻量智能体，
> 参照 DeepSeek Harness（DSH）开源核心设计，只保留核心基础能力。
>
> **设计总原则：能力驱动 + 协议可插拔 + 全链路可配置。** 不把当前引擎的局限
> （chatml 硬编码、无原生 tool-call）当成永久假设 —— 端侧能力在演进，协议层
> 必须让未来的原生工具调用 / 结构化输出 / 多模型能力直接无缝接入，而不是推倒重来。

---

## 1. DSH 核心设计提炼（我们参考什么）

从 `deepseek-harness-src` 源码提炼出五个可迁移的核心机制，其余（cordis 容器、
scope 作用域、插件体系、会话事件日志、并行调度、审批沙箱、子代理/工作流）
**不做为 v1 必选，但架构预留接入点**：

| DSH 机制 | 源码位置 | 核心要点 | Lite 版取舍 |
|---|---|---|---|
| **Agent Loop（turn/step）** | `packages/core/agent-loop/src/agent.ts` | 每次模型输出 → 若含工具调用则执行 → 结果回填 → 再次调模型 → 直到无工具调用才结束 | ✅ 保留，简化为单线程循环 |
| **统一消息模型** | `packages/llm/llm/src/types.ts` | `ContentBlock`：`text` / `tool-call` / `tool-result`；工具结果以 **user 角色 + tool-result 块**回填模型 | ✅ 保留，映射为 Dart 消息 map |
| **工具注册表** | `packages/core/tools/src/schema.ts` | `defineTool({name, description, parameters, execute})`；给模型的 schema 只暴露 `name/description/parameters`（白名单） | ✅ 保留，支持动态注册/注销 |
| **System Prompt 分段组装** | `packages/core/system-prompt/src/index.ts` | 有序 section（identity / persona / 工具指引）拼接；工具以 JSON Schema 呈现 | ✅ 保留，简化为分段拼接 |
| **工具结果消息** | `packages/llm/llm/src/message.ts` | `createToolResultMessage()`：`{role: user, content: [{type: tool-result, toolCallId, content, isError}]}` | ✅ 保留，映射为对话历史条目 |

**DSH 循环的本质**（核心就这一段，其余都不要）：

```
step(): 模型生成 → finish
  ├─ 无 tool-call → turn 结束（completed）
  └─ 有 tool-call → executeToolCalls()
      ├─ 解析 arguments（JSON）
      ├─ 执行工具 → {content, isError}
      └─ createToolResultMessage() 回填 → 循环回 step()
```

## 2. TongYi-Lite 现状与差距

### 现状
- `ChatNotifier.sendMessage()`（`lib/providers/chat_provider.dart`）：单轮生成，无工具循环。
- 本地引擎（`tongyilite_jni.cpp`）：**当前**硬编码 `"chatml"` 模板 + 纯文本 token 流。
- API 路线（`openai_service.dart`）：OpenAI 兼容 SSE，**未传 `tools` 字段**，不解析 `tool_calls`。
- 消息模型（`chat_message.dart`）：只有 `user/assistant` + `content`。

### 关键差距（三条）
1. 本地引擎**当前**不产出原生 tool-call → 本地路线首版走 prompt-JSON 协议（见 §5）。
2. 消息模型无工具角色字段 → 工具结果要能回填模型历史（§4 扩展）。
3. 无"轮次"概念 → 新增 agent 循环层（§4）。

## 3. 目标范围

**核心必做（v1）：**
- Agent 循环：模型 ↔ 工具 多轮交互（轮次上限可配置，默认 5）
- **协议适配层**：本地 / API 双通道首版落地，未来协议可新增
- 工具注册表：内置工具 + **动态注册/注销** + 按模型/按用户启用清单
- 能力检测：运行时探测引擎能力，自动选择最合适的工具协议
- UI 工具活动反馈

**架构预留（默认关闭，能力成熟后逐项打开，不推倒重来）：**
- 并行工具调度（DSH `isConcurrencySafe` / `maxParallelToolCalls`）
- 工具执行审批 / 沙箱（DSH approval / sandbox）
- 会话工具轨迹持久化（DSH session event log）
- 子代理 / 多智能体（DSH subagent / workflow）
- 原生 function-calling 改造（本地引擎换模型原生模板）→ 见 §5 协议适配层，只是新增一个 adapter

## 4. 架构设计（新增 `lib/agent/` 目录）

```
lib/agent/
├── capability.dart          # EngineCapabilities：运行时能力探测（协议选择的依据）
├── tool_definition.dart     # ToolDefinition / ToolResult / ToolCall 模型
├── tool_registry.dart       # 注册表：动态注册/注销、层级（全局/按模型/用户启用）、schema 生成
├── agent_loop.dart          # 核心循环（唯一心智负担），循环参数全部来自 AgentConfig
├── agent_prompt.dart        # 系统提示分段组装（identity / persona / 工具指引）
├── protocol/
│   ├── tool_protocol.dart   # ToolProtocol 抽象：协议可插拔的边界
│   ├── prompt_json_protocol.dart  # 本地：prompt-JSON 文本协议
│   ├── native_tools_protocol.dart # API / 未来本地：原生 tools 协议
│   └── protocol_selector.dart     # 按 EngineCapabilities 自动选协议
└── builtin_tools/           # 内置工具实现（todo/time/calc/search/...）
```

### 核心类型定义（Dart）

```dart
// capability.dart —— 能力探测 = 静态声明 + 运行时探测 双源合并
class EngineCapabilities {
  final bool nativeToolCall;       // 原生工具调用（API 天然支持；本地看引擎/模型模板）
  final bool structuredOutput;     // grammar/结构化约束采样
  final bool jsonMode;             // JSON 约束
  final int maxParallelToolCalls;  // 0 = 不支持并行，>0 = 可并行轮数
  final int maxContextTokens;      // 模型原生上下文上限（如 Spark-X2.5 = 1M）
  final String? toolTemplate;      // 原生工具调用模板/格式标识（native-tools 协议选变体）
}

// capability_source.dart —— 双源合并：模型目录静态声明 → 引擎加载后运行时上报覆盖
EngineCapabilities resolveCapabilities({
  ModelCatalogEntry catalog,   // 静态：models_catalog.json 的能力字段（加载前可预估协议）
  EngineProbe probe,           // 动态：getModelInfo()/新增 probe 扩展返回的真实能力
}) {
  // 合并规则：静态声明为"预期"，运行时探测为"事实"；探测缺失的字段回退静态声明。
  // 这样新模型入目录即可工作；原生改造后引擎一上报，协议自动切换，无需改代码。
}

// tool_definition.dart
class ToolDefinition {
  final String name;
  final String description;
  final Map<String, dynamic> parameters; // JSON Schema（参照 DSH 白名单原则）
  final Future<ToolResult> Function(Map<String, dynamic> args) execute;
  bool isConcurrencySafe(Map<String, dynamic> args) => false; // DSH 并行预留
  Duration? timeout;                                          // DSH 超时预留
}

class ToolResult {
  final String content;   // 回填模型的文本
  final bool isError;
}

class ToolCall {
  final String id;        // 参照 DSH CallId，用于结果关联
  final String name;
  final Map<String, dynamic>? arguments;
}

// agent_loop.dart —— 循环参数全部可配置
class AgentConfig {
  final int maxRounds;            // 默认 5，可配 1~20；达到上限提示而非死循环
  final int maxTokensPerRound;    // 每轮生成预算（可随轮次递减）
  final Duration toolTimeout;     // 单工具超时
  final bool allowParallelTools;  // 预留：并行工具调用（依赖能力 + 工具声明）
  final bool persistTrajectory;   // 预留：工具轨迹持久化
}

// protocol/tool_protocol.dart —— 协议可插拔的边界
abstract class ToolProtocol {
  String get id;                                        // 'prompt-json' | 'native-tools' | ...
  bool supports(EngineCapabilities caps);               // 能力匹配
  int priority(EngineCapabilities caps);                // 选优：原生 > 结构化 > JSON 文本
  String buildToolSection(ToolRegistry registry);       // 提示侧：注入文本 or 原生 tools 字段
  Future<StreamOutcome> parseStream(Stream<String> stream); // 生成侧：解析文本中的工具调用
}
```

### 核心循环（参照 DSH step() 的简化 Dart 版）

```dart
// agent_loop.dart
Future<String> runAgent({
  required List<Map<String, String>> history, // 现有 {role, content} 历史
  required String userPrompt,
  required ToolRegistry registry,
  required ToolProtocol protocol,             // 由 protocol_selector 按能力选出
  required AgentStream streamFn,              // 注入：本地 or API 的流式函数
  AgentConfig config = const AgentConfig(),
}) async {
  final messages = [...history, {'role': 'user', 'content': userPrompt}];
  final activities = <String>[];              // 供 UI 展示的工具活动

  for (var round = 0; round < config.maxRounds; round++) {
    // 1. 生成（协议注入工具呈现），返回文本 + 解析出的工具调用
    final (text, calls) = await streamFn(messages, protocol);

    // 2. 无工具调用 → 返回最终答案
    if (calls.isEmpty) return text;

    // 3. 逐个执行工具（参照 executeToolCalls；并行预留按 config.allowParallelTools）
    for (final call in calls) {
      ToolResult result;
      try {
        final tool = registry.lookup(call.name);
        if (tool == null) {
          result = ToolResult(content: '未知工具 "$call.name"', isError: true);
        } else {
          result = await tool.execute(call.arguments ?? {});
        }
      } catch (e) {
        result = ToolResult(content: '工具执行失败: $e', isError: true);
      }
      // 4. 结果回填为 user 角色消息（参照 createToolResultMessage）
      messages.add({
        'role': 'user',
        'content': '工具调用结果(${call.name}):\n${result.content}',
        'toolCallId': call.id,                  // 预留：原生协议回填的关联键
      });
      activities.add('${call.name} → ${result.isError ? "失败" : "成功"}');
    }
  }
  return '[已达到工具调用轮次上限 ${config.maxRounds}，请简化任务]';
}
```

## 5. 协议适配层（核心：不把当前局限当永久假设）

**协议选择 = 运行时能力探测，而不是写死"本地=JSON、API=原生"。**

```
protocol_selector.select(caps):
  1. caps.nativeToolCall         → native-tools 协议（API 天然可用；本地原生改造后自动切换）
  2. caps.structuredOutput       → grammar/结构化约束 JSON 协议（预留）
  3. 默认                         → prompt-JSON 文本协议（当前本地引擎的兜底）
```

### 协议 A：native-tools（API 首版；本地原生改造后无缝复用）
- 扩展 `OpenAiService`：请求体加 `tools: [{name, description, parameters}]`（参照 DSH `GenerateOptions.tools`），SSE 解析 `delta.tool_calls` 增量拼装，`finish_reason: "tool_calls"` 时返回 `ToolCall[]`。
- 本地引擎一旦支持原生 tool-call（v2 原生改造，见 §11 Phase 4），**同一协议对象直接复用**，循环零改动。

### 协议 B：prompt-JSON（当前本地引擎的兜底，能力演进后自动降级为备用）
```
[系统提示注入]
你可以调用以下工具：{"name": "...", "description": "...", "parameters": {...}}
当需要调用工具时，只输出一个 JSON 对象，不要任何多余文字：
{"tool_call": {"name": "get_time", "arguments": {}}}
调用后等待工具结果，再给出最终回答。
```
- 流式收集中检测完整 JSON 块（复用现有 thinking 过滤器的状态机模式）。
- 解析失败/无 JSON → 视为普通回答直接返回（**优雅降级**，模型没学会调用也不阻塞）。
- 每轮把协议指令放进 system 段，工具 schema 序列化为 JSON 文本。

### 协议 C（预留）：grammar / 结构化约束
- 端侧引擎支持 grammar 采样时，可把工具调用约束为合法 JSON，遵循率显著提升 —— 只新增一个 adapter。

## 6. 系统提示组装（参照 DSH 分段）

```dart
// agent_prompt.dart —— 分段 + 变量注入
String buildSystemPrompt({
  required String modelName,
  required ToolRegistry registry,
  required ToolProtocol protocol,     // 协议决定工具呈现方式
}) {
  return [
    '你是 TongYi-Lite 智能体，由 ${modelName} 模型驱动。',            // 身份(identity)
    '你可以调用工具完成任务；调用后你会收到工具结果，再据此回答。',   // 工具指引
    protocol.buildToolSection(registry),                             // 工具清单（协议呈现）
  ].join('\n\n');
}
```
- 分段注册表预留：未来第三方/自定义分段（参照 DSH `section({name, order, text})`）可扩展，不做死拼接。

## 7. 工具注册表（分层 + 动态）

参照 DSH `register()`（返回注销器）+ `restrict()`（allow/deny）的层级思想：

```dart
class ToolRegistry {
  // 层级：全局内置 → 按模型 → 用户启用（近层遮蔽远层，参照 DSH scoped layers）
  void register(ToolDefinition tool);        // 动态注册，返回 disposer
  void unregister(String name);
  void restrictModel(String modelId, {Set<String>? allow, Set<String>? deny});
  void restrictUser({Set<String>? allow, Set<String>? deny});
  List<ToolDefinition> visibleFor(String modelId); // 某模型可见的工具集
  ToolDefinition? lookup(String name);
}
```

### 工具分层策略
- **全局内置**：`get_time` / `calculator` 等零依赖工具，默认全模型可见。
- **按模型**：模型目录（`assets/models_catalog.json`）可为每个模型声明能力、默认工具集与
  **推荐 agent 配置**（如智能体模型挂 web_search / todo；纯聊天模型只挂零依赖工具）。
- **用户配置**：设置页逐工具启用/禁用（参照现有 `mtpEnabledByModel` 的按模型 Map 持久化教训）。

### 模型目录扩展字段（`assets/models_catalog.json` 每个模型新增）

```jsonc
{
  "id": "spark-x2.5-4b",
  "name": "星火 X2.5-4B（智能体）",
  "agentCapabilities": {
    "nativeToolCall": true,          // 原生工具调用（加载前即可选协议）
    "maxContextTokens": 1000000,     // 原生 1M 上下文
    "recommendedNctx": 32768,        // 手机端实际建议 n_ctx（内存权衡，见 §13）
    "toolTemplate": "spark-native",  // 原生工具格式变体 → native-tools 协议选 adapter
    "mtpSupported": false            // 无 NextN 层则 MTP 开关对该模型无效
  },
  "agentDefaults": {
    "maxRounds": 4,
    "tokensPerRound": 384,
    "enabledTools": ["todo_write", "web_search", "get_time", "calculator"]
  }
}
```

## 8. 内置工具清单（对齐 DSH 能力，注册表可扩展）

> 端侧能力向强扩展，不自我设限：核心工具默认全启用；网络/脚本类默认开、可设置关闭。
> 工具按类别分组，与 DSH 的 todo/search/文件/脚本/shell 能力对齐。

| 类别 | 工具 | 参数 | 说明 | 依赖 / 配置 |
|---|---|---|---|---|
| 核心 | `get_time` | 无 | 返回当前时间/日期 | 无 |
| 核心 | `calculator` | `expression` | 安全求值（白名单字符，禁 eval） | 无 |
| 任务 | `todo_write` / `todo_list` | `todos` / 无 | 全量替换任务清单（DSH todo 语义） | 内存 |
| 任务 | `note_take` / `note_list` | `title`,`content` / 无 | 便签（进程内） | 内存 |
| 换算 | `unit_converter` | `value`,`from`,`to` | 长度/重量/温度/时间/数据/速度换算 | 无 |
| 记忆 | `memory_set` / `memory_get` | `key`,`value` / 无 | 长期记忆（跨会话持久化 JSON） | workspace 文件 |
| 文件 | `read_file` / `write_file` | `path` / `path`,`content` | 读写工作区文件（沙盒内） | workspace 文件 |
| 文件 | `edit_file` | `path`,`oldString`,`newString` | 文本替换（oldString 必须唯一） | workspace 文件 |
| 文件 | `list_files` | `pattern` | 递归 glob 查找（DSH glob） | workspace 文件 |
| 文件 | `search_text` | `pattern` | 正则内容搜索（DSH grep） | workspace 文件 |
| 脚本 | `shell_exec` | `command` | `sh -c` 执行（app 权限内，超时+截断） | 默认开，可设关 |
| 网络 | `web_search` | `query` | 搜索 API 返回结果摘要 | 网络，默认关 |
| 网络 | `get_weather` | `city` | 免费天气接口（wttr.in，无密钥） | 网络，默认关 |

**安全原则**：核心/文件/脚本工具默认启用（能力不设限）；文件操作限制在
`documents/workspace` 沙盒内（路径规范化防 `../` 逃逸）；shell 以 app 权限运行
+ 超时/截断保护。未来更危险的能力（系统级/安装类）走审批层（架构预留）。

**协议双格式**：模型输出兼容 JSON（`{"tool_call":...}`）与 llama.cpp 原生
XML（`<tool_call>name<arg_key>k<arg_value>v</tool_call>`），解析失败优雅降级为文本。

## 9. 配置项（并入 `InferenceSettings` / settings JSON）

```jsonc
{
  "agentEnabled": true,                    // 智能体模式总开关
  "agentMaxRounds": 5,                     // 工具循环上限（1~20，可调）
  "agentTokensPerRound": 512,              // 每轮生成预算
  "agentToolTimeoutMs": 15000,             // 单工具超时
  "agentAllowParallelTools": false,        // 预留：并行工具调用
  "agentToolsByModel": {                   // 按模型工具启用（参照 mtpEnabledByModel 教训）
    "qwen3.5-2b-mtp-ud-q4_k_xl": ["todo_write", "get_time", "calculator"],
    "spark-x2.5-4b": ["todo_write", "web_search", "get_time", "calculator"]
  },
  "agentByModel": {                        // 按模型 agent 配置（模型目录 agentDefaults 合并到用户设置）
    "spark-x2.5-4b": { "maxRounds": 4, "tokensPerRound": 384, "nctx": 32768 }
  },
  "webSearchEnabled": false                // 联网工具（默认关）
}
```

## 10. 风险与边界（全部有配置出口，不自我设限）

| 风险 | 缓解 |
|---|---|
| 端侧 ~1-6 tok/s，多轮循环体验差 | `agentMaxRounds`/`agentTokensPerRound` 可调；每轮预算可随轮次递减 |
| 当前 chatml 无原生 tool-call | prompt-JSON 兜底 + 优雅降级；能力探测到原生支持后自动切协议 |
| 2B 模型工具遵循率有限 | 工具数量少、参数简单、协议示例贴近训练分布；grammar 协议预留 |
| 工具执行注入风险 | calculator 白名单校验；危险工具默认不在注册表，未来走审批层 |
| KV 缓存跨轮一致性 | 循环内共享同一历史 JSON，一次 resetContext 后连续生成（复用现有跨轮 KV） |
| 协议演进断代 | 协议适配层 + 能力探测，新协议=新增 adapter，循环/存储零改动 |

## 11. 实施步骤（分阶段，每阶段可独立验收）

### Phase 1：基础设施（不动现有对话路径）✅ 已完成
1. 新增 `lib/agent/`：类型 / 注册表（含分层与动态注册）/ 循环 / 提示 / 能力模型 / 协议抽象。
2. 内置 `get_time` + `calculator` 两个零依赖工具。
3. 单测：循环在"注入工具调用文本 → 执行 → 回填 → 再生成"路径下的正确性；协议选择逻辑按能力矩阵覆盖。

### Phase 2：接入本地路线（prompt-JSON 协议）✅ 已完成
4. `prompt_json_protocol.dart` + `protocol_selector`（当前能力 → 默认选中 JSON 协议）。
5. `ChatNotifier` 上游接入循环；流式 JSON 块检测（新增 `AgentStreamProcessor`：
   thinking 过滤 + 工具 JSON 块增量隐藏，状态机按字符处理跨 token 边界）。
6. 真机验证：两台天玑 + 高通 8s Gen 4，确认多轮循环不崩、KV 不串。**（本轮打包后执行）**

### Phase 3：接入 API 路线 + 工具补全 ✅ 已完成（原生 tools 留待能力探测）
7. ~~`native_tools_protocol.dart` + `OpenAiService` 支持 `tools`~~：当前本地/API 统一走
   prompt-JSON 协议（协议可插拔，探测到 API 原生 tools 时新增 adapter 即切换，循环零改动）。
8. `todo_write`（内存态）+ `todo_list` + `web_search`（DuckDuckGo 免费接口，默认关）+ 按模型工具启用配置。
9. 设置页新增「智能体」Tab：驱动模型选择（本地/API/跟随默认）、总开关、
   循环轮次/每轮预算/工具超时/智能体上下文/并行工具/联网搜索全部可调并持久化。

### Phase 4（原生演进，能力成熟后打开）进行中：XHToken/llama.cpp fork 已落地
10. **llama.cpp fork（XHToken 官方 fork）**：已下载并替换 `third_party/llama.cpp`
    （旧版备份 `third_party/llama.cpp.b10176`）。fork 含 `spark2_5` 架构
    （`LLM_ARCH_SPARK2_5`）+ `spark2_5-function-calling` PR。NDK 全量重建成功
    （PYTHONUTF8=1 解决 ggml-opencl autogen 的 gbk 编码问题），libllama.so 含 `spark2_5` ✓。
11. **工具调用双格式解析**：Spark-X2.5 真机实测输出 llama.cpp 原生
    `<tool_call>name<arg_key>k<arg_value>v</tool_call>` XML 格式（非提示词约定的 JSON）。
    `PromptJsonProtocol` 已扩展同时支持 JSON + XML；`AgentStreamProcessor` 流式隐藏 XML 块；
    `finish()` 收尾恢复未闭合块为普通文本。**94 单测全绿。**
12. **待验证**：真机 Spark-X2.5 工具调用端到端（web_search → 工具执行 → 结果回填 → 最终回答）。
    - 真机会话（2026-09-03）已跑通：模型输出 `<tool_call>web_search</tool_call>` XML、
      agent 循环执行并把结果回填（工具活动消息进会话）。发现两处遵循率问题：
      ① web_search 调用漏带 `query` 参数；② todo 请求未实际调用 `todo_write`（模型仅文字回答）。
    - 已修：提示语规则段与 XML 协议口径一致、强调必填参数、新增数组参数示例；
      XML 解析器对数组/对象参数 JSON 解码（todo_write 的 todos）；todo_write 兼容 JSON 字符串形态。
    - 真机端到端复验**待设备在线后执行**（新 APK 已含全部修复）。
    验证通过后，能力探测/原生工具模板（`toolTemplate: spark-native`）作为 Phase 4 后续演进。

## 12.5 Python 脚本支持（能力延伸）✅ 已实现

> 集成 Chaquopy 16.1.0（Android 嵌入式 CPython + pip），`python_exec` 工具经
> MethodChannel（`com.dgxspark.tongyilite/python`）调用 `agent_runner.py` 执行脚本；
> 无运行时优雅降级为明确错误。设置页可关（与 shell_exec 同「脚本执行」组）。
> 与 shell_exec 互补：Python 是沙盒内高级脚本，shell 是命令直通；均默认开启。

## 12.6 沙箱授权体系（对照 DSH escalation）✅ 已实现

> **严格更宽阶梯**：`workspace-write`（默认，app workspace 沙盒）→
> `danger-full-access`（app 权限内完整文件系统，含公共目录）。
> 模型带 `sandbox_permissions` + `justification` 请求升级 → agent 循环执行前经
> 用户确认框逐次批准（allowed-once）；设置页「完整文件访问授权」为前置开关
> （依赖 MANAGE_EXTERNAL_STORAGE / All-Files-Access，已在 manifest 声明）。
> 拒绝/升级标记与 DSH 同一套文案：`[sandbox: file access denied under ...]`、
> `[sandbox: escalation available ...]`。

## 12. 验收标准

- [ ] 「帮我记 3 个待办：A、B、C」→ 自动 `todo_write` → 返回确认，无需人工干预。
- [ ] 「现在几点？帮我算 12×7+3」→ 连续两次工具调用，最终回答引用工具结果。
- [ ] API 路线走原生 `tools`，本地路线走 JSON 协议 —— **由能力探测自动选择，非写死**。
- [ ] 同一模型/引擎能力变化（如原生改造后）→ 协议自动切换，循环代码零改动。
- [ ] 工具调用失败（未知工具/执行异常）不崩溃，回填错误并继续。
- [ ] 达到 `agentMaxRounds` 上限时给出提示而不是死循环；上限/预算/工具集全部可在设置调整。
- [ ] 按模型工具启用与全局启用互不干扰（参照 mtpEnabledByModel 教训）。
- [ ] 关闭智能体开关后，行为与现状完全一致（零回归）。

## 13. 模型选型：Spark-X2.5 适配与候选对比

> 用户计划用 **星火 X2.5-4B**（讯飞词元星火 2026-09 开源）驱动 Agent 能力。
> 本节给出适配清单、与现有 Qwen 路线的差异、以及候选模型对比。

### 13.1 Spark-X2.5 关键事实（据公开资料）

- **定位**：端侧"智能体模型"，官方强调"能真干活"（工具调用 / 任务执行强化）。
- **原生百万上下文**（1M tokens），端侧首个；支持 llama.cpp / LM Studio 部署，LLaMA-Factory 微调。
- **XHToken tokenizer**（讯飞词元）；模型权重在 [GitHub](https://github.com/XHToken/Spark-X2.5) 与
  [HuggingFace](https://huggingface.co/collections/XHToken/spark-x25) 开源；API 走讯飞星辰 MaaS。
- 4B 与 1.7B 两个规格；llama.cpp 原生支持意味着 GGUF 可行。

### 13.2 适配清单（相对当前 Qwen 路线要补的）

| # | 适配点 | 现状（Qwen 路线） | Spark-X2.5 需要补 |
|---|---|---|---|
| 1 | **原生工具调用** | 本地无（chatml 硬编码） | 验证 X2.5 原生 tool-call 模板/格式 → 按 `toolTemplate` 选 native-tools adapter；能力探测自动切换（§4/§5） |
| 2 | **上下文窗口** | n_ctx 默认 4096，上限 65536 | 1M 原生上限 ≠ 手机端可用；按 `recommendedNctx`（建议 16k~32k 起步）配置；KV 内存预算重估 |
| 3 | **tokenizer/模板** | chatml + Qwen 特殊 token | 验证 XHToken 模板是否兼容硬编码 chatml；不兼容则 **Phase 4 原生改造提前**（换模型自带模板） |
| 4 | **MTP 加速** | 为 Qwen NextN 设计 | 目录声明 `mtpSupported=false`（无 NextN 则开关无效）；速度预算按无 MTP 评估 |
| 5 | **模型目录** | 现有模型条目 | 新增能力字段 + `agentDefaults`（§7 目录扩展） |
| 6 | **工具集默认** | 2B 默认轻量 | 智能体模型默认启用 web_search/todo（目录声明，用户可改） |
| 7 | **性能预算** | 2B 约 1-6 tok/s | 4B 更慢 → `tokensPerRound`/`maxRounds` 按模型收紧（§9 agentByModel） |
| 8 | **多模态** | mtmd + mmproj | X2.5 若为文本模型则无 mmproj；视觉/语音工具按能力声明挂载 |

### 13.3 候选模型对比（端侧手机智能体，2026 年市场）

| 模型 | 规模 | 智能体/工具调用 | 上下文 | 端侧适配成本 | 备注 |
|---|---|---|---|---|---|
| **星火 X2.5-4B / 1.7B** | 4B / 1.7B | 原生强化（官方定位"能干活"） | **1M 原生** | 中：新 tokenizer/模板 + 能力验证 | 讯飞词元星火开源，llama.cpp 支持；本项目主选。目录条目 `spark-x2.5-4b-q4_k_m`（Q4_K_M ≈2.4GB）已就绪 |
| **腾讯 Hunyuan 系列** | 0.5B~7B | **RL 强化 agent 能力**（规划/工具/反思），手机可跑 | 长文 | 中 | 2025-08 开源四款，agent 定位与 X2.5 同级备选。目录条目 `hunyuan-4b-q4_k_m`（Q4_K_M ≈2.4GB，bartowski/社区量化）已就绪 |
| **Qwen3.5-4B** | 4B | 工具调用成熟 | 长上下文 | **低**：MTP/模板/生态已深度适配 | 现项目延续，迁移成本最低 |
| **Qwen3.5-2B（现用）** | 2B | 工具遵循率一般 | 中等 | 零 | 当前默认，非 agent 聊天兜底 |
| MiniCPM3-4B | 4B | 支持工具调用 | 32k | 高 | 较老，生态一般 |
| Gemma 3 4B | 4B | 一般 | 中等 | 高 | 中文/工具调用非强项 |

### 13.4 选型建议（结合本项目）

1. **主选**：`Spark-X2.5-4B` 作为 Agent 主力 —— 原生智能体训练 + 1M 上下文，与方案"能力驱动 + 原生协议"最契合。
2. **备选**：腾讯 Hunyuan 4B —— 若 X2.5 工具格式/模板落地成本高，Hunyuan 的 agent 强化定位同级可替代。
3. **兜底**：现有 Qwen3.5-2B 保持默认聊天模型，agent 开关关闭时零回归；Qwen3.5-4B 作为"低迁移成本"的第二梯队。
4. **决策依据**（落地前先做）：在真机三后端（CPU/OpenCL/Vulkan）上加载 X2.5-4B 的 GGUF，
   - 验证：原生工具调用是否可用（模板/特殊 token）、1M 上下文下的 KV 内存实测、
     无 MTP 时 4B 的 tok/s、XHToken 模板与硬编码 chatml 的兼容性。
   - 验证结果直接写进模型目录能力字段 → 协议选择自动生效，**代码零改动**。
   - **下载已就绪**：X2.5-4B 与 Hunyuan-4B 的 Q4_K_M GGUF 均已写入模型目录
     （`spark-x2.5-4b-q4_k_m` / `hunyuan-4b-q4_k_m`，约 2.4GB），下载后可立即真机验证，
     无需等发版。

---

## 附：与 DSH 源码的对应关系（实现时对照）

| Lite 概念 | DSH 对照文件 |
|---|---|
| ToolDefinition / ToolResult | `packages/core/tools/src/schema.ts`（defineTool） |
| ToolSchema 白名单 | `packages/core/tools/src/index.ts`（wireSchemas） |
| 工具注册表分层/动态 | `packages/core/tools/src/index.ts`（register / restrict / ScopedLayers） |
| Agent 循环 step() | `packages/core/agent-loop/src/agent.ts`（step()） |
| 工具执行与结果回填 | `packages/core/agent-loop/src/tool-calls.ts`（executeToolCalls） |
| 工具结果消息 | `packages/llm/llm/src/message.ts`（createToolResultMessage） |
| 系统提示分段 | `packages/core/system-prompt/src/index.ts`（section/assemble） |
| 并行调度预留 | `packages/core/agent-loop/src/tool-calls.ts`（maxParallelToolCalls / isConcurrencySafe） |
| todo 工具语义 | `packages/todo/tool-todo/src/index.ts` |
