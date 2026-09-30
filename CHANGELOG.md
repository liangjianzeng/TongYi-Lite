# 更新日志

所有重要变更将记录在此文件中。

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.0.0/)。

---

## [0.2.8] — 2026-09-29（当前版本 · versionCode 16）

### 智能体：执行顺序渲染 + 思考流式自动展开 + 空响应重试 + 思考泄漏修复

- **① 执行顺序渲染（timeline markers）**：`AgentUiState` 新增 `timeline: List<UiTimelineMarker>`，
  归约器在事件到达时追加标记（思考落档 → `UiTimelineThinking(i)`；工具卡加入 → `UiTimelineTool(i)`），
  `AgentTurnBlock._timelineWidgets()` 依序交错渲染——不再"思考一律在前、工具一律在后"。
  历史回合 timeline 恒空，仍走存储 🔧 消息顺序。
- **② 思考流式自动展开**：`ThinkingStreamCard` 展开条件改为 `_override ?? (running && !answerVisible)`——
  流式中自动展开跟随滚动（每次重建 `_followStream` animateTo 底部），答案开始/回合结束自动闭合。
- **③ 空响应重试（web_search"不行"主因）**：4B 模型思考中途直接 EOS（思考块未闭合被丢弃 → 空响应），
  本地路线 `emptyResponse` 原本不可重试 → 瀑布直接 giveUp。修复：loop 里 `retryEmptyResponse: true`
  （两条路线都计入可重试档，maxRetries 有界）。
- **④ 思考泄漏修复**：`AgentStreamProcessor` 新增"孤立闭合记号"处理——模型偶发在回答中途再输出
  ` response`（无前置 think），当作**隐式 opener** 重新进入思考态、续写一并丢弃；带保护：
  ` response` 紧跟英文/数字（如 "API response"）不吞，避免误伤英文词。
- **⑤ 工具卡 / 思考流滚动**：ToolActivityCard 单行紧凑行；思考流式长内容 150px 滚动区
  `jumpTo(maxScrollExtent)` 跟随底部，用户上滑暂停。

### Vulkan 全败定案：turnip dlopen 缺 libhardware.so（jniLibs stub 复活）

- **根因**：JNI 把 `GGML_VK_TURNIP` 指向 APK 内置 turnip（libturnip_freedreno.so），dlopen 失败：
  `library "libhardware.so" not found`——turnip 的 DT_NEEDED 含 `libhardware.so`（Android HAL 库），
  **App 进程 classloader 命名空间不能 dlopen 系统 HAL 库** → ggml-vulkan init 失败 → Vulkan 回落 CPU。
  v0.2.6 时代 turnip 验证全在 CLI 测试基建，从没在 App 进程内验证过——入库即埋雷。
- **修复**：`jniLibs/arm64-v8a/libhardware.so` 极简 stub（源码 `stub_hardware.c`，NDK clang 编译，
  仅导出 turnip 实际 import 的 `hw_get_module` 返回 -ENOENT）。dlopen turnip 依赖解析在 app 自己的
  lib 目录命中 stub → 成功。LLM 推理不走 gralloc/AHardwareBuffer 导入路径，-ENOENT 安全。
  SONAME 必须与系统库同名（`-Wl,-soname,libhardware.so`）。
- **验收铁证**：logcat `using Vulkan HAL GetInstanceProcAddr from .../libturnip_freedreno.so`
  + `Found 1 Vulkan devices: Adreno (TM) 825 (turnip Mesa driver)` + `backend_ptrs.size()=2`
  + `loadModel result: true`。
- **坑**：NDK 裸 `clang --target=aarch64-linux-android` 缺 crt 文件，须用带 sysroot 的 wrapper
  （`aarch64-linux-androidXX-clang.cmd`）编译。

### web_search：并发多关键词 + 每回合搜索上限（DSH max_uses 语义）

- **并发搜索**：`web_search` 加可选 `additional_queries: string[]`（最多 3 个），`Future.wait` 并行
  搜索全部关键词，合并返回（每关键词一小节 `[搜索：xxx]`，均分 1500 字预算）。描述教模型
  "一个问题的多个角度一次提交，不必多次调用"。
- **每回合搜索上限**：每次调用消耗 1 次（含重复）；达上限拒绝联网返回
  `ToolResult.error('本轮搜索次数已达上限（N 次）…请直接回答，不要再调用 web_search')`。
- **同内容去重**：主查询归一化（小写/去空白标点）相同 → 直接回缓存结果（`已搜索过，结果同上，
  未重复联网`），重复同样消耗预算尽快逼模型收敛。
- **设置项** `agentMaxSearchesPerTurn`（1~10，默认 5）；系统提示加规则：已有足够结果直接回答；
  收到"已达上限"立即停止调用。

### 智能体回答 tok/s 指标 + 思考流滚动

- agent 路径保存 answer 时补原生 `getInferenceStats()`（末步口径 = 答案步，与普通聊天同公式）；
  API 路线无原生 stats 不显示；首Tok 对多步回合无单步语义 → `firstTokenMs=0` 时整段省略。
- ThinkingStreamCard 内部 150px 滚动区 ScrollController + didUpdateWidget 跟随底部。

**验收**：test/agent + test/providers 全绿（259+ 项）；analyze 无新增告警（既有 4 项为旧代码）。
APK：debug `app-debug.apk` / release `app-release.apk`，字符串级验收过（libhardware.so +
libturnip_freedreno.so 均在 APK）。

---

## [0.2.7] — 2026-09-29（分支停维护 · 主干统一）

### 分支停维护（用户指令）

- `spike/opencl-bonsai2-ptq1-gemm` 快进合并进 main（含 v0.2.6 + PTQ1_0 GEMM + FWHT hadamard +
  Turnip 驱动 + agent 内嵌工作流重构），此后所有开发只在 main 做。
- **主仓 `third_party/llama.cpp` 树 = spike 完整树（fe8156f 基线）；此前「b11028 半升级 +
  PTQ graft」方向废弃**，别再按那条线排查编译错误。

### API 视觉接通

- kick 把 imagePath 写进 user/message 事件，`deriveModelMessages` 投影，OpenAiAdapter
  `attachWireImages` 转 image_url part（visionCapable 门控，每 step 重发；
  OpenAiService.encodeImageFile 带 8 张 FIFO 缓存）。

### 思考流单独展示

- adapter.generate 新增 `onThinking` 通道（全量快照推送）；API 原生路线解析
  `delta.reasoning_content` / `reasoning` + content 内嵌 ` think` 剥离
  （OpenAiNativeStreamAssembler 字符状态机，跨分片安全）；本地/文本协议路线走
  `AgentStreamProcessor.thinking`。chat_provider 节流 120ms 落 `agentUiStateProvider.thinking`；
  UI = agent_workflow.dart ThinkingStreamCard（live 回合内嵌，自动展开跟随滚动，点按头可手动收起）。

### 工具卡压缩

- ToolActivityCard 从 ExpansionTile 卡改为单行紧凑行（~22px：图标+名+参数摘要+执行中），
  点按行内展开参数/结果。

**回归**：test/agent 全绿（phase6_test 点按目标同步更新）；新增 test/agent/vision_thinking_test.dart。

---

## [0.2.6] — 2026-09-28

### Bonsai-2 双后端补齐 + Turnip 错编双定案

**OpenCL：PTQ1_0 prefill GEMM 内核**（此前 decode 有专用内核、prefill 掉进逐行 matvec 反复发射）

- 新增 `mul_mm_ptq1_0_f32_l4_lm.cl`：BM64/BN64/BK32 分块 GEMM，raw `block_ptq1_0` 布局逐元素
  staged 三进制解码（pow3 三元选择规避 Adreno `__constant` 误编），BK=32 整除 QK=128 故
  K-tile 永不跨量化块；host 门控 ne00%128==0 + ne11≥32（与 q1_0 同门槛）。
- 桌面 Arc 140T（OpenCL 3.0 NEO）实测：pp128 **1.14 → 18.89 t/s（16.5×）**，tbo 174/174，
  e2e 答案正确。

**Vulkan：FWHT subgroup 门控 + Turnip 错编双定案**

- FWHT（tied-output 头每 token 必经）的 subgroup 变体判定并入三药门控；新增
  `GGML_VK_FWHT_SUBGROUP=1`（vk_flags.conf 可控）供 A/B。真机实锤：**Turnip shuffle 错编**
  （开启后 MUL_MAT_HADAMARD 8/27），原厂 0800.71 无罪（27/27）——门控默认关，恰好兜住。
- **Turnip e2e 乱码根因定案**：GEMM **大 n（≥48）编译器错编**——PTQ1_0 MMQ 二分
  n=16/24/32 全对、n=48/64/512 全错（ERR≈1.0）；f16 GEMM n=64/512 同错；原厂同 shader
  16/16 全绿；App 的 shader 集（shaderc v2026.3）同错 → 驱动端问题，与 glslc 版本无关。
- **0.2.3 时代 e2e 连贯之谜解开**：App JNI 的 `n_ubatch=16` 限制使 prefill 恒走安全区。
  CLI 复现（默认 ub512 乱码）与闭环（`-ub 16` 连贯）双双落地。
- **生产口径**：App n_ubatch 上限保持 ≤32（现值 16）为 Turnip 正确性必要条件；
  CLI/服务端用 Turnip 跑 Bonsai-2 必须 `-ub ≤32`。

**测试与文档**

- tbo 增补：hadamard 4096/8192 宽度（此前盲区）、PTQ1_0 二分/大 batch（n=64/128/512）、
  f16 大 n——本次定位主力，防回归。
- 新增验证记录 [`docs/vulkan_bonsai2_turnip_verify_2026-09-28.md`](docs/vulkan_bonsai2_turnip_verify_2026-09-28.md)
  （双驱动全矩阵：原厂 0800.71 / fork Turnip × 三药）与 `scripts/cl_enum.cs`（免编译器
  OpenCL 平台枚举探针）。

---

## [0.2.5] — 2026-09-27

### OpenCL 后端支持 PTQ1_0 三元量化（Bonsai-2 27B）

- Bonsai-2 27B 全模型 402 个 PTQ1_0 张量（GGML `type 143`，-1/0/1 三元，28 B/128 值）；上游 OpenCL
  后端只有 Q4/Q5/Q8 系列 mul_mv 内核 → 此前全部回退 CPU、decode 极慢。
- 新增 `mul_mv_ptq1_0_f32.cl`（Adreno 64-wide subgroup、2 trit/lane、subgroup 归约）实现全 GPU decode。
- **根治 Adreno OpenCL 编译器对 `__constant` 数组变址的误编**（`pow3[4]` 恒读 0 → 每块 16 trit 全解成
  -1，数据正确但内积系统性偏差）：弃用 `__constant` 数组索引，改三元表达式。
- 真机 `test-backend-ops` MUL_MAT PTQ1_0 套件 **174/174 通过**（含 67 个奇数尾行与 Bonsai 形状）。

> 块结构 / 编码 / 解码 / 内核并行 / Adreno 陷阱定位过程：
> [`docs/ptq1_0_opencl_bonsai2_2026-09-27.md`](docs/ptq1_0_opencl_bonsai2_2026-09-27.md)。

---

## [0.2.4] — 2026-09-27（智能体卡死路径根治 · v0.2.4-agent-stall-fix）

### 根因 1：工具调用块被 token 预算截断 → 静默降级成普通回答（主因）

- 模型输出 `{"name":"file_write","arguments":{"content":"……`（写到一半被 `maxTokensPerRound=512`
  拦断），`prompt_json_protocol` 括号不平衡 → **整段当普通文本返回** → 主循环判定"无工具调用 →
  本轮完成"，任务没做还显示得像成功。**这是"迭代一两下就停、没结果"的头号元凶。**
- 修复（`prompt_json_protocol.dart` `_parseText` 第 0 步三分类）：先 `_truncatedToolCall` 判定——
  ① 断在字符串/参数内容内部 → 抛 `LlmFailureCode.toolCallTruncated`（不可伪造执行）；
  ② 仅缺收尾括号且能补全 → 自动补括号照常执行（参数无损）；③ 补完仍非法 = 模型自身语法错误 →
  优雅降级为文本，**不误报截断**误导用户去调设置。`failure.dart` 的 `LlmRetry` 把 toolCallTruncated
  纳入有限重试预算。

### 根因 2：失败轮回溯历史旧答案冒充本轮回复（"重复问候 bug"）

- 第二轮起 turn 内失败 → UI 又显示第一轮的问候，像"模型只会这一句"。
- 修复：`ReactLoopAgent._turnAnswer` **只取本轮 append 的 assistant**，失败置空串绝不穿透历史；
  失败原因走 `_turnError` → chat_provider 明确报「⚠️ 本轮执行失败：…」，不再拿旧回复顶包。

### 根因 3：每轮重建 log 时 system 落在消息中段 → OpenAI 兼容服务端 400 拒收

- 新引擎每轮 importFromMessages 先导入历史，构造 agent 时才 append system → system 不在队首 →
  API 路线 400、本地 chatml 被中段 system 污染 → 表现为"执行不下去"。
- 修复：`SessionLog.deriveModelMessages` **system 恒置队首**（纯投影重排，不破坏事件序不变量）。

### 顺带：思考失控守卫 + 天气工具路径形态

- 思考块超长未闭合到阈值即主动止损（`agentThinkingMaxChars`，默认 6000，可调）。
- `get_weather` 改用 `https://wttr.in/<url-encoded-city>?format=…` 路径形态（`/?q=城市` 返回
  HTTP 500，路径形态 200）。

**回归防线**：test/agent 全绿 241 项（含截断三分类、toolCallTruncated 有界重试后终态 error、
lastTurnAnswer 不回溯、system 晚 append 仍恒队首）。

---

## [0.2.3] — 2026-09-27

### Vulkan 在 Adreno 825 重新可用（Turnip 直载）

- 原厂 0800.71 驱动 OTA 回归实锤后（2026-08-05 HyperOS OS3.0.305 OTA 后 7 月原味代码 + 新驱动同样
  拒建管线），切换 Mesa out-of-tree gen8 Turnip **App 内直载**：免 root、不碰系统分区。该驱动不导出
  任何 `vk_*` 符号，入口是 Android Vulkan HAL 模块（`hw_module_t → vulkan_device_t`，PFN 表偏移
  +0x70、GetInstanceProcAddr +0x88，逆向确认）；ggml-vulkan 4 处直接 C 符号调用全部改走 dispatcher，
  `GGML_VK_TURNIP=<驱动.so>` 指定直载。
- 数值损坏三根因逐一修复：
  - ① Turnip gen8 **错编 subgroup 算术归约（subgroupAdd）**——一切含归约的算子数值错 → 设备能力
    初始化处直接置 `subgroup_arithmetic=false`（一处覆盖全部 op 级选择），tbo f32 MUL_MAT 203/203；
  - ② 我方 `NO_SUBGROUP` 门控漏网——ssm_scan / gated_delta_net 管线选择直查 `device->subgroup_arithmetic`
    不走 use_subgroups 门控 → 直置 false 覆盖；
  - ③ GDN shmem butterfly 的 **S_V=128 lanes 配置错编**（clustered LANES=8 / 全宽 128 均坏）→
    `!subgroup_arithmetic` 时 lanes 钳 64（与已验证的 S_V=64 布局同构）。
- 验收：tbo GDN 36/36 + SSM_SCAN 12/12，LFM2.5-2.6B 短生成 5/5 连贯（6~10.6 t/s）、Qwen3.5-4B
  连贯（5.0 t/s）。

---

## [0.2.2] — 2026-09-26

### Vulkan / Adreno 825（8 Elite2）乱码与崩溃根治

- 驱动 0800.71 错编 `unpack8()`（Int8 capability）→ 量化模型输出乱码，另存在 subgroup matvec 管线
  创建失败、图融合 kernel 输出全零、dp4a 数值错误、decode 部分管线建不出共 5 个独立问题。
- 修复：shader 层用纯 32 位位操作替换 `unpack8()`（21 处调用点 + q8_0 反量化重写，位模式逐位等价），
  运行时默认注入 `GGML_VK_NO_SUBGROUP / GGML_VK_DISABLE_FUSION / GGML_VK_NO_MMV /
  GGML_VK_DISABLE_INTEGER_DOT_PRODUCT=1`（JNI 层注入，可用 `/storage/emulated/0/TongYiLite/vk_flags.conf`
  覆盖做 A/B）。

---

## [0.2.1] — 2026-09-26

### 变更：联网搜索改为「用户自配 SearXNG 实例」

- **不再预置任何搜索实例**：`SearXNGSearchProvider.kDefaultBaseUrl` 与设置项默认值全部中立（留空 =
  未配置）。未配置时 `available()` 直接回「未配置 SearXNG 地址：请在 设置 → API 接入 → 联网搜索 填写」，
  而不是拿 `127.0.0.1` 去连手机自己再报一句误导性的"不可达"。
- **设置页「API 接入」新增 🌐 联网搜索配置卡**（`_WebSearchCard`）：启用开关、实例地址、API Key
  （可切换明文显示；http 明文传密钥到非回环地址时告警）、引擎白名单、搜索语言、最多条数、超时，
  以及「测试连接」——用输入框里的**草稿值**直接发一次真实搜索，回显条数 / 耗时 / 具体失败原因，
  不必先保存。数字项保存后回显真正生效的值（`SettingsNotifier` 会夹紧到合法区间）。
- **新增设置项与 setter**（`InferenceSettings` + `SettingsNotifier`）：
  `webSearchSearXngBaseUrl` / `ApiKey` / `Engines` / `Language` / `MaxResults` / `TimeoutMs`，
  全部随 settings JSON 持久化；每项 setter 保存后热更新到 `WebSearchSeam`，改地址无需重启应用。
- **provider 复用不打断连接池**：`applySearXNGProviderFromSettings` 先比 `configSignature`
  （由配置内容计算，非实例身份），内容未变直接复用现有实例；`WebSearchSeam.registerProvider`
  同签名也复用，避免每轮对话重建 Dio / 释放 HttpClient。

### 修复：搜索链路 4 处「静默失效」（不报错，只是搜不到或必超时）

- **URL 构造**：旧实现 `Uri.replace(query: …)` 生成 `host:8080?q=…`（空 path），依赖实例 308 跳到
  `/search` 才勉强能用，换成不跳转的实例就彻底失效。现在 `buildRequestUri` 自行补齐 `/search`
  （尾斜杠 / 已写 `/search` 均不会重复拼），并把查询参数合并进 `Uri.queryParameters`
  （`q` / `format=json` / `language` / `categories` / `engines`）。
- **HTTP 状态判定是死代码**：Dio 默认 `validateStatus` 只放过 2xx，`statusCode >= 400` 分支永远进不去。
  现在请求带 `validateStatus: (_) => true` 自行判定，并按状态码给出原因（401 未授权 / 403 被拒 /
  404 baseURL 多写路径 / 429 限流 / 400·422 引擎不被接受 / 5xx 实例内部错误）。
- **HTML 被误报成"不可达"**：Dio 只在 Content-Type 是 JSON 时才解码，实例未开 `format=json` 时
  `assureResponse<String>` 抛类型错，界面显示「SearXNG 不可达」把排查指向网络。现在按
  `ResponseType.plain` 收响应、自行 `jsonDecode`，明确提示「需在实例 settings.yml 的 `search.formats`
  加 json」；坏 JSON 单独报「响应不是合法 JSON」。
- **工具超时从未生效**：`ToolDefinition.timeout` 没有任何地方消费，且 `WebSearchSeam.search` 写死
  15s 默认值会覆盖设置项里的超时 → 慢实例上搜索必然超时。现在接缝的 `timeout` 默认为 null
  （null = 用 provider 自身配置），`ToolExecutor` 与旧 `agent_loop` 均改为 `tool.timeout ?? timeout`，
  `web_search` 声明 30s、provider 默认 30s、`connectTimeout` 6s。

### 优化：搜索质量、上下文预算与诊断

- **结果去重与排序**：URL 规范化（去 `utm_*` / `from` / fragment / 尾斜杠、scheme+host 小写）后去重，
  按 SearXNG `score` 降序，`take(maxResults)`；原始条数 > 映射条数时置 `WebSearchResult.truncated`，
  提示模型"换更具体关键词"。
- **回填文本预算**：单条摘要截到 200 字、整体截到 1500 字（`kSnippetMaxChars` / `kResultMaxChars`），
  够了就停 —— 端侧 `n_ctx` 常见 8k，8 条长摘要既挤占上下文也拖慢手机 prefill。
- **引擎白名单被拒自愈**：白名单里有该实例不认识的引擎时 SearXNG 返回 400/422，provider 去掉
  `engines` 参数自动重试一次（`kWebEngineRejected`），不会一错到底。
- **诊断挖到根**：`_describeDioError` 区分连接超时 / 接收超时 / 发送超时 / 取消 / 连接错误，并把被
  Dio 塞进 `DioException.error` 的真实 `SocketException`（含 `osError` 错误码）挖出来展示，附带
  `host:port` 与已耗时（实测不可达地址 2.0s 报「远程计算机拒绝网络连接。(1225)」）。
- **延迟来自引擎**：SearXNG 会等待实例上每一个引擎，存在访问不到的引擎时整次搜索被拖到超时
  （一台自建实例实测全引擎 21s，只留可达引擎 2.2s）。引擎白名单因此做成设置项并在界面上写明。

### 测试

- 新增 `test/agent/web_search_provider_test.dart` **21 项**（注入可编程 `HttpClientAdapter`，
  覆盖 URL 构造 3 类 base 变体、5 类错误分类、引擎被拒重试、URL 去重、score 排序 + truncated、
  摘要/总量预算、接缝不遮蔽 provider 超时、`ToolDefinition.timeout` 生效与全局超时兜底、
  provider 复用/重建、设置项 toJson/fromJson 往返、默认值中立）。
- 新增 `test/agent/web_search_live_test.dart`：真实实例连通性验收（打印条数/耗时/引擎/摘要长度）+
  不可达地址快速失败，**默认跳过**（需设 `SEARX_LIVE_URL`），不污染常规测试与 CI。
- 与本改动相关的用例全绿；改动涉及文件 `dart analyze` 无 error。

### 已知无关问题

- 全量 `flutter test` 另有 3 个测试文件（`loop_test` / `pipeline_test` / `subagents_test`）编译失败，
  根因是 `lib/agent/skills/*`、`lib/agent/agents_md/*`、`lib/agent/loop/agent.dart` 中尚未完成的
  WIP 语法/类型错误，与本次联网搜索改动无关。

---

## [0.2.0] — 2026-09-04

### 新增：端侧 Agent Lite 智能体

- **Agent 循环（参照 DSH agent-loop step() 简化）**：模型 ↔ 工具多轮交互，轮次上限可配置（默认 5），
  工具结果以 user 角色消息回填后再生成，直到无工具调用返回最终回答。
- **协议可插拔**：`ToolProtocol` 抽象 + 按 `EngineCapabilities` 自动选协议；本地/API 首版统一走
  prompt-JSON/XML 文本协议（`PromptJsonProtocol` 双格式解析），原生 tools 留待能力探测后新增 adapter。
- **工具注册表**：分层（全局/按模型/用户）动态注册/注销、按模型可见性渲染清单；内置
  get_time/calculator/todo_write/todo_list/web_search/note/memory/shell/file/unit/weather 等工具。
- **设置页「智能体」Tab**：驱动模型选择（本地/API/跟随默认）、总开关、循环轮次/每轮预算/工具超时/
  智能体上下文/并行工具/联网搜索全部可调并持久化（按模型 `agentToolsByModel`）。
- **流式处理 `AgentStreamProcessor`**：思考块过滤（HTML/Qwen 双风格，含 Qwen3.5 不带 ing 的 ` think`）
  + XML/JSON 工具调用块增量隐藏。
- **llama.cpp fork 升级**：`third_party/llama.cpp` 换为 XHToken 官方 fork（`spark2_5` 架构 +
  function-calling），NDK 全量重建成功；旧版 b10176 仅本地备份不入库。
- **根治工具调用"缺参数"**（对照 DSH `defineTool/validateArgs` 落地）：工具执行前统一必填校验，
  错误信息明确列出缺失参数名与用途并回填"补全后重试"；工具清单渲染带必填参数提示
  （如 `shell_exec（必填: command）`），让模型知道带参数工具必须给出哪些参数。
- 修复真机工具遵循率问题：提示语规则段与 XML 协议口径一致、强调必填参数、XML 数组参数解码、
  todo_write 兼容 JSON 字符串形态。**101 项单测全绿。**

### 新增：端侧 Python 执行（python_exec，Chaquopy 17.0.0 / CPython 3.11）

- **嵌入式 CPython 3.11**：Chaquopy 17.0.0 集成，APK 内嵌 `libpython3.11.so` + 标准库（stdlib .imy），
  `agent_runner.py` 经 MethodChannel（`com.dgxspark.tongyilite/python`）执行脚本，
  15s 超时 / 4KB 输出截断；无运行时优雅降级为明确错误，不影响其他工具。
- **沙箱授权体系（对照 DSH escalation）**：严格更宽阶梯 `workspace-write` →
  `danger-full-access`；模型带 `sandbox_permissions` + `justification` 请求升级，
  agent 循环执行前经**用户确认框逐次批准**（allowed-once）；拒绝/升级标记与 DSH 同文案
  （`[sandbox: file access denied under ...]` / `[sandbox: escalation available ...]`）。
- **设置页新增开关**：「Python 执行（python_exec）」与「完整文件访问授权」
  （danger-full-access 前置，依赖 MANAGE_EXTERNAL_STORAGE / All-Files-Access）。
- **123 项单测全绿**（新增 sandbox 阶梯/审批/字段声明/降级 22 项）；debug APK 已含 Python 运行时。

### 修复（代码质量评估 P0 隐患加固）

- **消息 role 反序列化崩溃**：`MessageRole.values...first` 三处直接抛 `StateError`——历史脏数据
  或将来新增 role（如 system）会让整个会话列表/消息读取崩溃。新增 `messageRoleFromName()`
  安全解析（未知 role 回落 user），`ChatMessage.fromMap` 与 SQLite 行映射统一替换。
- **语音消息 audioPath 持久化**：模型字段存在但 messages 表无该列，语音消息重进会话后
  「语音」标记全部丢失。数据库 **v2→v3** 迁移补列（`ALTER TABLE messages ADD COLUMN audioPath`），
  `saveMessage` 写入、行映射读取；顺带把 getMessages/getAllMessages 两份重复行映射收敛为
  `_mapMessageRow`。
- **原生消息 JSON 解析器重写**：`parseMessagesJson` 原用 `find('}')` 截取对象——内容含
  `{`/`}`（贴代码/JSON）被截成空内容、`\n`/`\"` 不解码（多行提问以字面量 `\n` 喂给模型）、
  结尾转义反斜杠的内容丢失。重写为结构化解析 + 完整 JSON 字符串解码（`\uXXXX` 含代理对
  → UTF-8）；宿主机编译 + 11 个行为用例全过（覆盖三个旧失效场景）。
- **设置写入原子化**：`SettingsService.save` / `ModelDisplayNameService.save` 改为
  先写 `.tmp` 再 rename——崩溃/断电不再留半截 JSON 导致用户配置静默回默认。
- **假数据 stub 移除**：`getAvailableSpace`（恒 64GB）、`hasEnoughMemory`（恒 true）、
  `checkAllModels`（假 5120MB 空闲）均无消费者，删除；「清空日志」按钮空实现改为真实清空
  （`ModelManagerNotifier.clearLogs()`）。
- **日志页「刷新」按钮移除**：原实现 `ref.invalidate(modelManagerProvider)` 会重建 notifier
  并把状态复位为 idle，让已加载的模型在 UI 上显示「未加载」。
- **死代码/过期注释清理**：`g_callback_obj`（从未赋值 + 两处无效 DeleteGlobalRef）、
  `reportLoadingLog` 重复前置声明、`ModelStateExtension`（调用即抛 UnimplementedError）、
  `_migrateLegacyMtp` 同分支冗余、model_provider 过期 vision 注释。

## [0.1.6] — 2026-08-19

### 引擎升级

- **llama.cpp 升级到上游 master**：vendored 从 `f5b9bd3`（b10173，2026-07-29）升级到
  `fe8156f`（2026-08-19，含 333 个上游 commit）。API 适配：`llama_sampler_init_penalties`
  新签名（增加 `n_vocab` 参数，JNI 两处调用点已同步）；`LLAMA_INSTALL_VERSION` →
  `LLAMA_VERSION_BASE`（上游 CMake 变量改名，项目 CMake mtmd 段已适配）。

### 天玑 / Mali Vulkan 崩溃根治（真机验证）

**症状**：天玑（MediaTek Mali-G68）上选 Vulkan 后端，加载模型或首次推理即 SIGSEGV
（`vulkan::api::QueueSubmit+0`，fault addr 0x0）。Adreno 正常。

**排查过程（逐项排除）**：验证层（APK 内 13MB `libVkLayer_khronos_validation.so`，
Flutter debug 打包带入，已从打包排除）→ `GGML_VK_DISABLE_INTEGER_DOT_PRODUCT/F16/ASYNC`
→ `internallySynchronizedQueues` 特性 → 均非根因。

**最终根因**：Mali 驱动的 `vkGetDeviceQueue2`（Vulkan 1.2）返回 dispatch 表为 NULL 的坏
queue → 首次 `vkQueueSubmit` 崩在 loader trampoline。**改用 Vulkan 1.0 的 `vkGetDeviceQueue`
修复**（Impeller 同款路径）。

**最终 patch（3 处，仅 ARM vendor 0x13B5 生效，ggml-vulkan.cpp）**：
1. `ggml_vk_create_queue`：Mali 用 `device.getQueue(family, index)` 替代 `getQueue2`；
2. `has_internally_synchronized_queues` 在 Mali 强制 false；
3. `buffer_device_address` 在 Mali 强制 false（驱动上报 true 但 `getBufferAddress` 崩）。

> 注意：**不要**调用 `VULKAN_HPP_DEFAULT_DISPATCHER.init(device)`——Mali 上会把
> `vkQueueSubmit` 等 loader trampoline 覆盖为 NULL，引入新崩溃（已验证）。

### 其他修复与优化

- **mmproj 视觉编码后端跟随主后端**：原来写死 `MTMD_BACKEND_DEVICE=OpenCL`（Adreno 时代
  遗留），选 Vulkan 时显示矛盾、天玑上 OpenCL 不可用。现按 `enable_gpu` + `backend` 选择
  CPU/OpenCL/Vulkan，天玑上正确显示「图像理解 (Vulkan GPU 编码)」。
- **天玑 OpenCL 设置置灰**：检测到 MediaTek SoC 时，GPU 后端 OpenCL 选项禁用并提示
  「天玑芯片不支持 OpenCL，优先 Vulkan」（真机实证：天玑 `libOpenCL.so` 仅为 72KB
  Khronos ICD 加载器空壳，`/vendor/etc/OpenCL/vendors/` 无驱动注册 → 枚举 0 平台）。
- **标题栏字体调小**：`TongYi-Lite` 标题从默认 AppBar 大字号改为标准大小。
- **Gradle 16 核并行构建**：`-Xmx8g` + `workers.max=16` + `parallel=true`，NDK 全量重编
  从 20+ 分钟降到 ~2 分钟。
- **设备信息通道**：新增 `getDeviceInfo` MethodChannel（暴露 SoC 硬件信息），供设置页
  按芯片判断 OpenCL 可用性。

### 性能说明（天玑）

- 天玑 900（Mali-G68）Vulkan 解码实测 ~5.7 tok/s（0.8B），约为 CPU 的 1/3——这是
  **Mali-G68 无矩阵加速单元的硬件天花板**（社区 PR #18493/#27163 佐证，均未合入主线），
  非软件 bug。大模型（4B+）上 GPU 卸载仍可省内存。
- 恢复 `GGML_VK_DISABLE_INTEGER_DOT_PRODUCT` 等临时排查开关（非崩溃根因，纯性能杀手）；
  保留 Mali 实测较稳的路径（BDA / internal-sync 禁用由 vendor 判断自动生效）。

## [0.1.3] — 2026-08-04

### 体验优化

- **助手消息复制**：气泡右下角新增小号复制图标，点击即复制全文并提示「已复制回复内容」。
- **性能指标标签精简**：消息底部统计由「首Token / 总耗时」改为紧凑的「首Tok / 耗时」
  （如 `首Tok 1.2s · 耗时 5.3s · 14.5 tok/s`）。
- **Bonsai27B 等大模型下载断点续传修复**：旧逻辑每次失败都删除 `.tmp` 残留、且探测用
  `GET` 把整个多 GB 文件拉进内存，大文件网络抖动即反复失败/断开。改为最多 8 次自动重试
  + 失败保留 `.tmp` + 按 HTTP `Range` 断点续传（`hf-mirror`/`huggingface` 均支持 206），
  探测改为 `Range: bytes=0-0` 仅取 1 字节；错误文案不再误导「CDN 不支持续传」。
- **自定义模型名称**：设置页每个模型卡片底部新增可编辑名称框（持久化到
  `model_display_names.json`）；聊天页右上角加载后优先显示自定义名，未设置则回落「模型就绪」。
- **切换模型不再红屏（友好提示 + 安全切换）**：推理中点击切换模型先弹友好确认框
  （橙色信息图标「已有模型正在运行」），确认后先 `stopGeneration()` 停止生成，再卸载旧模型、
  加载新模型，避免卸载正在推理的模型导致原生引擎崩溃红屏。
- **大模型加载实时进度弹窗**：点击「加载到内存」后弹出不可取消的「正在加载模型…」对话框，
  实时展示原生层最新加载日志；加载完成走原成功/失败提示路径。

### 修复（2026-08-04 晚 · 真机验证）

- **tok/s 口径对齐真实值**：聊天气泡的 tok/s 此前数的是「字符数」且分母含 prefill，与 logcat
  对不上。现由 JNI 回传真实 `n_gen`（decode token 数）与 `t_gen_ms`（纯生成耗时），UI 与
  logcat 完全一致（实测 10.2 / 8.7 / 8.5 tok/s 三档全对齐）。
- **n_ubatch 按后端动态分设**：GPU 路径 `n_ubatch=512`（prefill 走 GPU kernel，规避 CPU 量化
  GEMM bug 并显著提速 prefill，实测 4B 多轮 prefill 1.4s）；CPU 路径保留 `16` 保正确。
- **聊天顺序改为标准「上旧下新」**：去掉 `ListView reverse`（此前导致最旧的显示在底部、最新的
  在顶部），最新消息固定在下；流式输出期间自动滚到底部保持可见，用户上滑读历史后暂停跟随。

## [0.1.2] — 2026-08-03

### 补充修复（2026-08-04 · 真机验证）

- **量化 GEMM 路径计算出错（根因 5）**：`n_ubatch=512` 时，prompt ≥32 tokens 的 prefill
  进入 ggml-cpu 量化 GEMM 路径产生垃圾 logits（第一轮 15 tokens 走 vec_dot 正常，第二轮
  37+ tokens 乱码 `oother民nedbish枉叶`）。`n_ubatch` 调回 `16` 强制走正确的 vec_dot 路径
  （首 token 延迟略增，GEMM bug 待 ggml-cpu 侧修复后恢复）。
- **重复惩罚失效（根因 6）**：采样循环缺 `llama_sampler_accept()`，penalties 的 token
  历史永不更新 → repeat penalty 永不生效 → 退化循环（9841/57699 反复、无 EOS）。采样后
  补 `llama_sampler_accept(smpl_chain, new_token)`。
- **flash attention CPU 陷阱**：`LLAMA_FLASH_ATTN_TYPE_AUTO` 在 CPU 后端会实际启用
  （ggml-cpu 实现了 FLASH_ATTN_EXT op），seq_rm 清空 KV 后第二轮 prefill 乱码。当前
  `DISABLED`，待状态重置验证后恢复。
- **流式输出块化**：`on_token` 回调批处理从 64 字节（≈21 个 CJK 字符）改为 8 字节
  （≈2 字），恢复逐字流式观感。

### 修复（多轮对话正确性 · 重大）

彻底修复「第一轮正常、第二轮起输出乱码 / 死循环（"魔魔魔…"）/ 空回复 / 只出两个字」的问题。
真机（Xiaomi onyx，Qwen3-0.6B Q4_K_M）连续三轮对话已验证正常。

- **KV 缓存跨轮残留（根因 1）**：`llama_memory_clear()` 在本版 llama.cpp 上对
  hybrid/unified 后端是**空操作**，不重置每序列长度计数器；从位置 0 重新解码只是
  「叠加」在上一轮的陈旧 KV 之上，注意力被污染 → 从第二轮起坍缩为退化循环。
  改用 `llama_memory_seq_rm(mem, 0, 0, n_ctx)` 真正清空序列 0。
- **`kv_unified = true` 强制走 hybrid memory（根因 2）**：该路径的 `seq_rm` 只要
  recurrent 部分不支持就整体返回 `false`，注意力 KV 长度计数清不掉。Qwen3 是纯
  Transformer，无需 unified，改回 `kv_unified = false`（llama.cpp 官方默认值），
  经典 KV 的 `seq_rm` 可靠生效。
- **`decode_pos` off-by-one（根因 3）**：`n_gen++` 原本在计算 `decode_pos` 之前执行，
  导致每轮生成位置跳格、KV 出现空洞，表现为"每轮只出两个字"。`n_gen++` 挪到
  `llama_decode()` 之后，保证 `decode_pos = kv_position + n_gen` 连续。
- **prompt 多 token 批量解码写坏 KV（根因 4）**：13 token 的短 prompt 侥幸正常、
  33 token 的第二轮 prompt 解码后 logits 被压平（top5 全部落在 12.0~12.6 一条直线，
  对比正常轮的 42.18 / 38.60 / 35.47）。改为**逐 token 解码 prompt**，与已验证可用的
  生成循环走同一条单 token 路径。
- **`llama_batch_get_one()` 返回 pos=nullptr 导致 SIGSEGV**：本版该函数只借用 token
  指针，`pos / n_seq_id / seq_id / logits` 全为 `nullptr`，手动填充即崩溃。改用
  `llama_batch_init(n, 0, 1)` 分配真实批次并自行填写各字段。
- **`llama_get_logits_ith()` 下标越界导致 SIGABRT**：该下标是**相对最近一次 decode 的
  batch**，不是全局 token 位置。改为逐 token 解码后最后一批只有 1 行，旧代码仍用
  `n_prompt-1` 取值 → `ggml_abort` 整个进程挂掉（debug 构建下 `GGML_ABORT` 而非
  `return nullptr`，兜底判断永不生效）。统一改用 `-1`（源码明确支持负下标 =
  最后一个输出行），与 batch 大小解耦。
- **消息重复注入**：Dart 侧已把当前消息一并存入历史再整体下发，JNI 侧又 append 了一次
  → 移除 JNI 的重复拼接。

### 新增

- **`resetContext()` 全链路**：Dart `InferenceService.resetContext()` → MethodChannel →
  Kotlin `InferenceEngine.nativeResetContext()` → JNI `g_engine.resetContext()`。
  `ChatNotifier` 记录 `_currentKvConvId`，检测到切换会话时主动清空 KV，避免跨会话污染。

### 变更

- 设置页「GPU 层数」滑块在 GPU 开启时置灰不可调，并说明：本设备（Adreno 825）**部分卸载
  会输出崩坏**，故 GPU 模式固定为全量卸载。

---

## [0.1.1] — 2026-08-03

### 新增

- **Vulkan GPU 加速**（端侧 LLM 上 GPU）：arm64-v8a 启用 ggml-vulkan 后端
  - `CMakeLists.txt` 在 `ANDROID_ABI == arm64-v8a` 时强制 `GGML_VULKAN=ON`，构建主机用
    LunarG Vulkan SDK（glslc + SPIRV-Headers + `<vulkan/vulkan.hpp>`）预编译着色器
  - 新增 `host-toolchain-mingw.cmake`：在 Windows 构建主机用 MinGW-w64 (GCC) 编译
    `vulkan-shaders-gen` 主机工具（完全静态链接，零 DLL 依赖）
  - `tongyilite_jni.cpp` 新增 `detect_gpu_layers()`：**运行时**探测 ggml 后端注册表，
    发现 GPU 设备才启用卸载，否则回落 `0`（纯 CPU），同一 APK 可在无 Vulkan 驱动的设备上安全运行
  - **推理引擎设置 UI**：设置页「推理引擎」标签页新增「启用 GPU 加速」开关（默认开启）
    与「GPU 层数」滑块（默认 20）。关闭开关即纯 CPU 推理；开启时把用户设定的层数传给原生层
    （`enableGpu` / `gpuLayers` 经 MethodChannel → Kotlin → JNI 透传），实现运行时可控的 GPU offload
  - 依赖链 `libggml.so → libggml-vulkan.so → libvulkan.so`（系统运行时提供）
  - CPU 优化（KleidiAI + SME2）作为 Vulkan 不可用时的备选方案
- **模型下载系统**：完整的模型选择、下载和缓存管理
  - 多镜像源优先（hf-mirror → ModelScope → HuggingFace），HTTP Range 断点续传
  - Riverpod 状态管理 + UI 实时进度，SHA256 完整性校验，磁盘空间检测
- **设置页 UI**：模型管理界面（卡片展示、下载进度、状态芯片、存储信息）
- **对话持久化**：SQLite (sqflite) 存储对话和消息历史

### 修复

- **Android 构建环境**：Gradle plugin 通过 `includeBuild` 复合构建解析，阿里云 Maven 镜像解决 dl.google.com 超时
- **NDK + CMake**：安装 NDK r27.0.12077973 + CMake 3.31.6，修正 CMakeLists.txt 路径（5 级 `../`）与 Vulkan 编译依赖（SPIRV-Headers / Vulkan include / NDK Vulkan 桩库按 minSdk API 级别）
- **C++ JNI bridge**：适配 llama.cpp b1017+ 新 API（`llama_model*` → `llama_vocab*`、`llama_init_from_model`、`llama_token_eos(vocab)` 等），手动实现 temperature + top-p 采样
- **Dart 编译错误**：修复 `ConsumerStateNotifier`、`const DateTime(0)`、`as int? == 1` 运算符优先级、重复 `ModelConfig` 类冲突等约 50 个错误
- **Android 资源缺失**：创建 ic_launcher mipmap + Theme.TongYiLite style + colors.xml
- **Kotlin import**：修复 MainActivity.kt / InferenceService.kt 缺少 Intent/Context import

### 修复（运行时稳定性 · 重大）

- **推理正确性**：彻底修复大模型"答非所问 / 乱码 / 一直转圈"
  - 每次生成前 `llama_memory_clear` 清空 KV cache，避免多轮后上下文污染导致 padding token（151935）无限循环
  - 修复 `parseMessagesJson` 悬垂指针（`llama_chat_message` 只存 `const char*`，改用 `deque<string>` 持有字符串）
  - 修复 `llama_batch.n_tokens` 漏设（首 token 后 decode 失败）与 `llama_get_logits_ith` 越界（SIGABRT）
  - 修复 Qwen3 思考模式空思考块注入 off-by-one（`"assistant\n"` 长度 10 误写 11），并新增「思考模式」开关（默认关=直接作答）
  - 修复 top-p nucleus 采样退化成贪心（cumsum 早停）
- **GPU 加速默认关闭**：ggml-vulkan 在小米 onyx（Adreno 825）上卸载层数后第 2 个 token 起数值崩坏（已知 GPU 后端数值 bug），故「启用 GPU 加速」默认改为关闭，回退稳定纯 CPU 推理；开关变更需重新加载模型生效
- **CPU 推理提速**：采样改用 `partial_sort` top-K(K=128) + top-K softmax（替代全词表 sort），显式设置线程数 `min(硬件并发, 8)`

---

## [0.1.0] — 2025-07-29

### 新增

- **端侧 LLM 推理引擎**：基于 llama.cpp b1017+，支持 KleidiAI + SME2 优化
- **Flutter 前端**：Material3 设计，聊天界面、设置页面、模型管理
- **Plugin 插件架构**：支持视觉/语音/文本/文件任务的热插拔 Plugin 系统
- **荒野求生游戏化任务**：远程指令推送 + Plugin 离线执行 + 结果回传
- **架构设计文档 v2**：完整的系统架构与技术选型说明
- **编译与调试指南**：BUILD_AND_DEBUG_GUIDE.md

### 技术栈

- Flutter 3.x + Riverpod 状态管理
- Android NDK r29 + CMake 3.31
- JNI 直调通信（无 HTTP Server）
- Qwen3-1.7B-Instruct Q4_K_M 默认模型

### 文档

- 架构设计 v2
- Plugin 架构设计
- 实施方案
- 移动端 LLM 基准报告 v2
- 编译与调试指南
