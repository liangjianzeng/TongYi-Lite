# TongYi-Lite 端侧离线 AI 智能体

![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)
![v0.3.5](https://img.shields.io/badge/v0.3.5-8B5CF6)
![Flutter](https://img.shields.io/badge/Flutter-3.x-02569B?logo=flutter)
![Android](https://img.shields.io/badge/Android-33+-3DDC84?logo=android)
![llama.cpp](https://img.shields.io/badge/Engine-llama.cpp%20fork-red)
![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)

> **端到端离线优先的 Android AI 智能体。** 四大支柱：
>
> - **🤖 智能体引擎**——事件日志唯一真相源 + ReactLoopAgent 主循环 + 30+ 工具真实执行 +  
>   子代理 / Skills / 插件 / 人格 / 计划模式（`/plan` → 审批 → 无人值守续跑）/ MCP / `AGENTS.md`；  
>   一键关闭 = 纯净简单聊天（本地小模型友好）；
> - **⚙️ 端侧模型引擎**——llama.cpp 上游 `0.7.0` + fork 增强 JNI 直调 · Vulkan / OpenCL GPU 加速 +  
>   KleidiAI CPU 加速 · MTP / dspark 投机解码 · 多轮 KV checkpoint/restore · mtmd 视觉 · OOM 内存守卫；
> - **🚀 自研 OpenCL batched MoE**——MUL_MAT_ID 单 dispatch gather（设备端 ids 直读），绕开 Adreno  
>   驱动级数值 bug，MoE 模型**全 GPU decode/prefill**（内核级通用能力，q4_0 / q4_K / q4_1 已真机验证）；
> - **🛠️ Dev Agent 开发执行环境**——工作区四级后端（App 沙箱 / 内嵌工具沙箱 `dev_shell` + JGit 进程内 git /  
>   Termux 伴侣应用 RUN_COMMAND 免 SSH / 远程 PC SSH），让智能体在真机/远端真实写代码。
>
> 另有 OpenAI 兼容远程模型接入、**端侧直连国内六引擎搜索**（零配置，可选自建 SearXNG）、  
> **端侧流式语音识别**（sherpa-onnx，完全离线）与 **Edge TTS 语音播报**（免费无 key）。  
> 对话与推理数据不出设备；联网能力（搜索 / TTS / API）均为可选项。

---

## 目录

- [功能概览](#功能概览)
- [快速开始](#快速开始)
- [应用功能](#应用功能)
- [模型列表](#模型列表)
- [技术架构](#技术架构)
- [构建与开发](#构建与开发)
- [下载](#下载)
- [版本更新](#版本更新)
- [常见问题](#常见问题)
- [贡献指南](#贡献指南)
- [License](#license)

---

> 📁 **docs/ 已迁移至私有仓库** [`TongYi-Lite-docs`](https://github.com/liangjianzeng/TongYi-Lite-docs)
> （工程笔记/排障档案/内部文档，仅仓库所有者可见；公开克隆中 docs 为空指针。正文内文档链接均指向该私有仓，公开访问者打不开，所有者登录后直接可点）。

## 功能概览

TongYi-Lite 是一个**端侧优先、可完全离线运行**的 Android AI 应用：模型权重完全本地推理，  
对话数据不出设备；联网能力（直连搜索 / Edge TTS / 远程 API）均为可选项，按需开启。

| 能力 | 说明 |
| --- | --- |
| **🤖 智能体引擎** | 事件日志唯一真相源 + ReactLoopAgent 主循环（失败自动恢复）+ 六段工具流水线 + **子代理**（spawn/fork/fan-out/后台化）+ Skills（内置 18 个）/ 插件 / Hooks / MCP 远程工具 / `AGENTS.md`；30+ 工具按档位与开关注册，沙箱授权 + 逐次审批；**一键关闭 = 简单聊天** |
| **🎭 多人格（Persona）** | 标准人格 + 用户自定义人格，聊天页左栏人格侧栏切换/新建/编辑/删除；切换自动重置 KV 缓存 |
| **📋 计划模式 + 无人值守** | `/plan <任务>` 只读规划 → 计划卡提交审批 → 批准后**自动逐轮续跑**（轮数可配）；对话内计划活卡 + 计划面板逐步推进 |
| **⚙️ 端侧模型引擎** | llama.cpp 上游 `0.7.0` + **fork 增强树** JNI 直调（无 HTTP Server，流式直通）：`spark2_5` / **dspark 整块投机** / **MTP 多 token 预测**（按模型开关）、**PTQ1_0 三元量化专用 GPU 内核**、FWHT、Turnip 直载、mtmd 视觉、OOM 内存守卫；mmap 加载 + 批量 prefill + 线程按 CPU 拓扑取核 |
| **GPU / CPU 加速** | Vulkan + OpenCL 双 GPU 后端（启动探测 + 手动选择）+ KleidiAI dotprod CPU 内核；Adreno 推荐 OpenCL；**KV 精度三档**（Q4/Q8/F16，混合架构模型选 F16） |
| **🚀 OpenCL batched MoE** | 单 dispatch gather 绕开 Adreno 驱动级 MUL_MAT_ID 数值 bug，MoE **全 GPU decode/prefill**；Adreno 830 实测 prefill 149 t/s / decode 14–22 t/s；740（小米13）· ling-3.0-tiny decode **5.3 t/s**（v0.3.5 基线） |
| **🧠 智能 MoE 拆分加载（split-MoE）** | 权重剥离 `.experts/` 或 **in-place GGUF 整包直读**（LFM2.5-24B 官方单文件直下直读，专家 I/O 1902 MiB/s）+ LES 前瞻调度（下一层 router 预测）；35B 级大模型上机 |
| **⏩ 多轮 KV checkpoint/restore** | 长对话边界 checkpoint，恢复后仅对增量 token prefill——多轮对话二次 TTFT **34s → 4.4s** |
| **投机解码** | **MTP** + **dspark**（整块投机），部分模型支持，设置页按模型单独开启 |
| **模型下载与管理** | 应用内下载（hf-mirror / ModelScope 镜像自动回退 + 断点续传，最多并发 2）、视觉 `mmproj` 闭环下载、catalog JSON 配置驱动（可指向自有 CDN 热更新） |
| **🖼️ 视觉理解** | Qwen3.5 / Gemma 4 / MiniCPM-V 视觉模型（`.gguf` + `mmproj` 两文件闭环下载）；本地档与 API 档均支持图片输入 |
| **🎙️ 语音输入（端侧 ASR）** | sherpa-onnx 流式 Zipformer 中文 int8（~160MB 首次下载），FFI 进程内推理，**完全离线零网络依赖**；微信式按住说话、实时回显、上滑取消；9 类约 290 词热词偏置 + 同音校正（差量存储） |
| **🔊 语音播报（Edge TTS）** | 微软 Edge 免费 neural 音色（免 key，**Sec-MS-GEC v2** token 本地算、**IPv4 优先**连接），气泡 🔊 点按播报 / 回复后自动播报；音色/语速/音调/音量可配 + 试听；markdown 清洗 + 按句分段播放；手动失败上 SnackBar（自动播报保持静默） |
| **上下文占用圈 + 压缩** | 输入框圆形占用环（API `prompt_tokens/n_ctx` 实测 · 本地 KV `kv_used/kv_ctx`），阈值变色；**回合内 LLM 摘要压缩**（失败回退确定性摘要）+ **存储级手动压缩** |
| **🌐 联网搜索** | **端侧直连国内六引擎**（必应/百度/搜狗/360/夸克/中国搜索）——零配置默认可用，每 10 分钟窗口请求预算、指数熔断、UA 池、引擎开关；配置自建 **SearXNG** 自动切换；`web_search` 并发多关键词、每回合上限、同内容去重 |
| **🛠️ Dev Agent 开发模式** | 工作区四级后端 + `dev_shell`（jniLibs busybox）+ **JGit 进程内 git** + Termux **RUN_COMMAND 免 SSH** + SSH 多配置向导（密钥自动生成、secure storage 存储）+ 任务/规划管理 + `workspace_sync` 双向同步 |
| **远程 API 接入** | OpenAI 兼容 `{baseUrl}/chat/completions`，本地优先、API 后备；每条 API 配置独立**「思考强度」档位**（OpenAI/Claude/Gemini/DeepSeek/GLM/Qwen/vLLM 一族一字段，被拒自动去字段重发） |
| **多会话并发** | 并发会话槽位（1~4）：API 会话真正并行执行回合，本地回合互斥；会话抽屉「● 执行中」徽标 |
| **质量度量** | 回合指标纯派生自事件日志（步数/工具调用/重复/重试/终止原因）落 JSONL；轨迹导出 + 离线 eval 评分（12 个基线任务） |

---

## 快速开始

```bash
# 1. 克隆（三方依赖已全部直接入库，无需子模块、无需联网）
git clone git@github.com:liangjianzeng/TongYi-Lite.git
cd TongYi-Lite

# 2. 获取 Flutter 依赖
flutter pub get

# 3. 构建调试 APK
flutter build apk --debug
# 输出：build/app/outputs/flutter-apk/app-debug.apk

# 4. 连接 Android 设备后运行
flutter run -d <device_id>
```

> ✅ **三方依赖已全部直接入库**：llama.cpp（上游 `0.7.0` + fork 增强）、KleidiAI、OpenCL-Headers、  
> opencl-stub、`edge_tts`（纯 Dart TTS 协议栈）、`dartssh2` fork、`mesa-kgsl/`（全 GPU 卸载 Mesa 路线的  
> 构建配方与补丁集）都在 `third_party/` 下。clone 后即可编译，不需要 `git submodule update`。

> **真机覆盖安装铁律**：始终 `adb install -r app-debug.apk`（`-r` 覆盖更新，保留已下载的端侧模型缓存）；  
> **绝不先卸载再装**（卸载会清掉模型缓存）。设备被 `INSTALL_FAILED_USER_RESTRICTED` 拒绝时加 `-t`。

<details>

<summary><b>Windows 本机构建细节 / debug APK 装不进最新 Dart？（开发机专用）</b></summary>

构建慢的根因与解法、增量/全量耗时分解、flutter SDK 补丁记录见  
[`docs/BUILD_ENV_NOTES.md`](https://github.com/liangjianzeng/TongYi-Lite-docs/blob/main/BUILD_ENV_NOTES.md)。

`flutter assemble` 与 gradle 读写的 kernel 路径不一致，每次改 Dart 后必须先同步 assets 再打包：

```bash
flutter assemble -o build/flutter-assemble --define=BuildMode=debug --define=TargetPlatform=android-arm64 debug_android_application
xcopy /E /I build\flutter-assemble\flutter_assets\ build\app\intermediates\flutter\debug\flutter_assets\
cd android && .\gradlew.bat assembleDebug -x compileFlutterBuildDebug
```

</details>

---

## 应用功能

> **导航**：聊天页左栏（rail）集中了 会话 / 智能体 / 人格 / 计划 / 模型 / 引擎 / 技能 / 插件 / API /  
> Dev Agent / 搜索 / 能力与实验 / 存储与日志 / 更多 等面板；设置页七个 Tab：  
> **模型管理 / API 接入 / 推理引擎 / 智能体 / 能力 / 开发者 / 关于**。

### 本地端侧推理与模型管理

同一时间只允许一个模型在内存中运行（单模型约束）：

| 状态               | 说明      | UI 表现               |
| ---------------- | ------- | ------------------- |
| `idle`（未加载）      | 无模型在内存中 | 灰色「未加载」，聊天页显示 [去加载] |
| `loading`（加载中）   | 磁盘 → 内存 | 蓝色进度环 + 模型名，UI 禁用交互 |
| `loaded`（已加载）    | 可推理     | 绿色「已加载」，聊天页显示 [卸载]  |
| `unloading`（卸载中） | 释放内存    | 橙色进度环               |
| `error`（错误）      | 加载失败    | 红色错误信息 + [重试]       |

- **模型列表配置驱动**：全部模型定义维护在 `assets/models_catalog.json`（当前 21 个，见[模型列表](#模型列表)），  
  新增/调整/下架只需改这个 JSON，无需改代码；`mirrors` 数组按序回退（hf-mirror 优先，ModelScope 兜底）、  
  HTTP Range 断点续传、最多并发下载 2 个。
- **视觉模型闭环**：`type=vision` 且带 `mmproj` 的模型自动连投影器一起下载，两者完整才算「已缓存」，  
  加载前校验完整性避免原生崩溃。
- **推理日志**：加载/卸载/生成全过程 + 每次交互性能指标（提示长度、生成 token 数、首 token 延迟、tok/s 等），  
  `tok/s` 与 JNI 回传的真实 `n_gen` / `t_gen_ms` 对齐。
- **存储信息**：按候选目录扫描所有 `.gguf`（含 `.mmproj` / `.dspark.gguf`），即使模型不在 catalog 中也能显示。

### 多模态：视觉理解

- **本地视觉**：Qwen3.5-0.8B/2B/4B、Gemma 4 E2B、MiniCPM-V 4.7 等带 `mmproj` 的模型支持单图理解；  
  本地编码后端跟随主后端（Vulkan / OpenCL / CPU）。
- **API 档视觉**：图片以 base64 `image_url` content-parts 发送（visionCapable 门控、每步重发、  
  8 张 FIFO 编码缓存）；未开启视觉的端点把图片剥离为 `[图片]` 占位，绝不发送原始图数据。

### 语音输入与播报

**语音输入（端侧 ASR，v0.2.9 起整体重做）**：sherpa-onnx 流式 Zipformer 中文 int8（~160MB，首次使用下载），  
FFI 进程内推理，完全离线（飞行模式可验证）；与推理模型无关，任何对话场景可用。

- **交互**：微信式按住说话——长按 🎤 → 实时回显 partial 结果 → 上滑取消 → 松手终稿直接发送。
- **热词偏置**：9 个内置分类约 290 词（全中文），ContextGraph 偏置 + 同音后校正；设置页可查看/编辑分类词表  
  （差量存储：默认词表改版不顶掉用户编辑）、添加自定义热词、开启增强识别模式（beam search）。
- **模型管理**：语音设置卡可查看就绪状态、下载/删除模型（释放 160MB）。

**语音播报（Edge TTS）**：微软 Edge 免费 neural 音色（`speech.platform.bing.com`，免 API key；  
纯 Dart vendored 包 `third_party/edge_tts`）。

- **鉴权 = `Sec-MS-GEC` v2 token**（微软 2026-10-10 起强制，v1 一律 403）：本地按当前时间计算，  
  与 `Sec-MS-GEC-Version` 的 `2-` 前缀**成对**下发；实现对照上游 `edge-tts` golden 向量钉死  
  （`test/tts/sec_ms_gec_v2_test.dart`）。
- **IPv4 优先连接**：国内网络常见 IPv6 半死通道（TCP 连得上、TLS 被 RST），IPv4 优先规避；  
  IPv6 留作兜底，纯 IPv6-only 网络照常可用。
- **失败可见**：`classifyTtsError` 归类 鉴权/网络/空音频/播放 四类，手动点 🔊 或试听失败上 SnackBar  
  并给可行动提示；**自动播报保持静默**，绝不打断聊天。
- 音色（在线拉取 300+，zh 系置顶）、语速（-50%~+100%）、音调（±50Hz）、音量（±50%）可配 + 试听；  
  管线：markdown 清洗 → 按句分段（≤600 字）→ 逐段合成（SHA-256 缓存复用）→ 逐段播放。
- ⚠️ 免费接口实测定案：中文音色共 14 个，大陆方言仅辽宁/陕西两个女声；英文音色读不出中文  
  （混合内容建议选 Multilingual 变体）。排障工具 `tool/tts_diag_probe.dart` 等 5 个（`dart run`）。

### 远程 API 接入（OpenAI 兼容）

在「API 接入」配置 OpenAI 兼容端点（`{baseUrl}/chat/completions`）：云端大模型或自建 llama.cpp 服务均可，  
与端侧模型共用同一套聊天界面。

- **本地优先**：本地模型可用则优先本地，不可用才回退激活的 API。
- **API 档上下文生命周期**：请求带 `stream_options.include_usage` 实测 `prompt_tokens`；溢出按响应体特征  
  识别为 `contextWindowExceeded` → 走压缩 → 有界重试；工具结果投影剪枝（超长结果头尾保留、中段省略）；  
  主动压缩预算 `agentApiContextBudget` 可配。
- **「思考强度」档位**：每条 API 配置独立 `thinkingEffort`（不设置 = 请求体逐字节与从前相同），一族一字段  
  （OpenAI/grok/MiniMax `reasoning_effort`、Claude `thinking.budget_tokens`、Gemini `thinking_config`、  
  DeepSeek/Kimi/GLM/Qwen/vLLM 各自形态）；字段被严格端点拒绝 → 自动去字段重发。
- **SSE 稳定性**：流间停摆看门狗（两个 chunk 之间静默超 120s 即掐断重试），杜绝「无限转圈」。

### 联网搜索（端侧直连 + SearXNG 可选）

`web_search` 工具支持两层搜索源，按配置自动选择：

**① 端侧直连国内引擎（默认，零配置）**——纯 Dart 模块 `lib/websearch/`，不依赖任何自建服务：

- **六引擎**：必应中国（RSS 主 + HTML 兜底）、百度（`tn=json` 主 + HTML 兜底）、搜狗、360 搜索、夸克、  
  中国搜索（官方 JSON）；结果去重合并、内嵌真实 URL 解析（302 / 页内 meta/JS 多策略）。
- **细水长流安全管控**（防引擎风控封禁）：每引擎每 10 分钟窗口请求预算（低风险档默认 6、高风险档  
  sogou/baidu/quark 默认 2，可调）；blocked → 指数熔断（2min×2ⁿ 封顶 15min）+ 清 Cookie + 换池内 UA；  
  引擎可独立开关。实测结论与各引擎坑速查见  
  [`docs/websearch_direct_2026-10-02.md`](https://github.com/liangjianzeng/TongYi-Lite-docs/blob/main/websearch_direct_2026-10-02.md)。

**② 自建 SearXNG 实例（可选）**——配置实例地址后自动切换；地址/密钥/引擎白名单/语言/条数/超时全配置化 +  
一键测试连接 + 保存即热更新（引擎白名单决定延迟：全引擎 21s → 只留可达引擎 2.2s）。

**`web_search` 工具行为**（两层共用）：并发多关键词一次调用（`additional_queries` ≤3 并行合并）、  
**每回合搜索上限**（默认 5，达上限强制基于既有结果回答，杜绝死循环）、同内容查询回缓存不重复联网、  
输出按 URL 去重 + 相关性排序 + 1500 字截断。`get_weather` 走 `wttr.in` 路径形态（国内直连可用）。

### Agent 智能体（工具调用）

**模型按需调用工具 → 工具真实执行并回填结果 → 模型根据结果组织最终回答**（绝不假装执行）。  
**智能体模式有总开关**（设置 → 智能体 Tab 首排，输入区 🤖 图标同款）：开启 = 完整智能体循环；  
关闭 = 简单聊天直连模型（无系统提示/工具定义/AGENTS.md/Skills，prefill 最小）；**模式/人格切换自动重置 KV**。

#### 工具集（30+，按档位与开关注册）

- **15 个核心工具**：`get_time` / `calculator` / `todo_write` / `todo_list` / `note_take` / `note_list` /  
  `unit_converter` / `memory_get` / `memory_set` / `read_file` / `write_file` / `edit_file` / `list_files` /  
  `search_text` / `export_file`（产物导出到 `Download/TongYi-Lite/`）。
- **4 个可选工具**（默认关闭）：`web_search` / `get_weather` / `shell_exec` / `python_exec`  
  （嵌入式 CPython 3.11，Chaquopy 随 APK 打包，15s 超时 / 输出截断）。
- **系统工具**：`save_skill`（模型自主沉淀技能）/ `load_skill` / `subagent` / `ask_user_question`  
  （提问卡片：选项 chip / 自由回答 / 跳过）/ `run_code`（PTC 编排，仅 API 档）。
- **API 档专属**：`exit_plan` / `goal_set` / `goal_complete` / `goal_cancel` / `plan_step_update` /  
  **MCP 远程工具**（`mcp_<server>_<名>`，Streamable HTTP JSON-RPC 2.0）。Dev 工具组见下文。
- **沙箱授权**：文件/命令类工具默认在 app workspace 沙盒内；确需访问公共目录时模型携带  
  `sandbox_permissions` + `justification` 请求升级，执行前经用户确认框逐次批准，拒绝不绕过。

#### 引擎架构与执行纪律

- **会话事件日志（唯一真相源）**：每对话一本 append-only JSONL（`seq` 严格递增）；模型上下文是日志的  
  **纯函数投影**；压缩 = 追加摘要 + 影子遮蔽（永不删除原文）；进程崩溃后自动修复未闭合 turn/step。
- **主循环 ReactLoopAgent**：显式 turn/step 状态机；失败恢复瀑布（上下文超限 → 压缩重试；瞬态错误 →  
  退避重试；其余 → 明确终止）；Stop 立即停 turn（回合级幂等）；流式增量 150ms 节流；回答附带真实 tok/s。
- **执行纪律**：步数上限收敛注入 + **撞上限自动收尾续跑**；【任务执行纪律】系统提示段（API 档）；  
  `todo_write` 执行期强制（同时多个 in_progress 直接拒绝）；read/write/edit 描述加厚；**回合内插话 steer**  
  （不打断执行）；`ask_user_question` 提问；**思考失控根治**（跨块累计守卫 + 止损先抢救再判死 +  
  forceNoThinking 重试，工具决策步默认不思考）；重复调用守护（同工具第 3/5/8 次渐进提醒 + 同签名去重）。
- **并行工具安全**：`isConcurrencySafe` = 默认只读可并发、副作用工具显式独占；回合中断合成「结果未知」  
  占位保证事件配对完整。
- **六段工具流水线**：pre-execute（allow/deny/ask 瀑布）→ guard → execute（沙箱审批 + 超时）→ 结果投影 →  
  post-execute → 溢写（超长输出自动落盘、只回摘要与定位）。

#### 计划模式与无人值守

- **`/plan <任务>`**（输入框前缀或 📋 图标，仅 API 档）：只读规划回合——注册表收窄为「并行安全（只读）  
  工具 + exit_plan」，调研后提交计划；批准即生成**结构化计划**（标题 + 步骤 + 验证方式）落持久目标库。
- **无人值守续跑**：批准后自动逐轮推进——每轮续跑消息带增量进度（✓/◐/○/✗），完成步骤即时  
  `plan_step_update`；失败/中断/等待提问不续跑；轮数耗尽落提示终结（`agentGoalMaxRounds` 默认 8，可配 1~20）。
- **三处呈现**：对话内计划活卡（原位重写不刷屏）、计划面板（点步骤改状态/放弃/重新规划）、📋 图标高亮；  
  任务清单（todo）按会话隔离落盘。

#### 人格 / Skills / 插件 / 上下文工程

- **🎭 多人格**：标准人格（行为不变）+ 用户自定义人格；聊天页左栏**人格侧栏**统一切换/新建/编辑/删除；  
  人设作为独立【人格设定】段注入系统提示，不覆盖工具纪律；子代理人格自动跟随。
- **Skills（内置 18 个）**：web-research / summarize / translation / writing-polish / data-analysis /  
  file-report / plan-todo / code-review / explain-code / email-draft / meeting-notes / resume-polish /  
  social-copy / shopping-compare / travel-planner / tutor / **stock-research** / skill-creator（元技能）。  
  正文均为真执行手册（工作流 + 模板 + 验收清单），`load_skill` 按需加载不占常驻 prefill；用户技能整段粘贴  
  SKILL.md 一键导入 / 编辑 / 另存内置技能 / 模型对话内 `save_skill` 沉淀；用户同名技能（rank 200）覆盖内置。
- **插件平台**：「能力」Tab 三层梯队（原生能力 → 插件 → 技能），内置英语听写等插件；插件宿主契约冻结  
  见 [`docs/插件平台_契约冻结清单_2026-10-23.md`](https://github.com/liangjianzeng/TongYi-Lite-docs/blob/main/插件平台_契约冻结清单_2026-10-23.md)。
- **上下文工程**：中文加权 token 估算器（压缩判断不再对中文低估 3 倍）；回合内 LLM 摘要压缩（专用便宜模型，  
  失败回退确定性摘要）+ 存储级手动压缩；环境快照按 10 分钟桶化尾部追加（prompt-cache 友好）；技能目录文本  
  会话内冻结（不破缓存前缀）。
- **质量度量与 eval**：回合指标零侵入落 `turn_metrics.jsonl`；轨迹导出；`eval/` 12 个基线任务 + 六维离线评分。

#### 双场景档与多会话

- **双场景档**：智能体驱动模型可选**本地档**（端侧小模型）或 **API 档**（云端大模型吃满思考）；API 档额外注入  
  【任务执行纪律】段并注册专属工具；本地档系统提示逐字节稳定（保 KV 缓存）。
- **多会话并发**：并发会话槽位 1~4（默认 1）；API 会话真正并行，本地回合因引擎单实例彼此互斥；会话抽屉  
  「● 执行中」徽标实时可见。
- **子代理**：`subagent` 支持单任务 / 2~4 任务 fan-out 并行 / `run_in_background`（完成经系统通知投回父回合）；  
  `send_message` 向已完成子代理续轮；可指定专用 API 模型；本地档门控关闭。

### Dev Agent 开发模式

> 让智能体在真机或远端真实开发：写文件、跑命令、操作 git、管理任务计划。  
> 入口：设置 → **开发者** Tab，或聊天页左栏 **Dev Agent** 面板。

**工作区四级后端**（`targetSdk 34` W^X 约束下的分层设计）：

| 后端 | 说明 |
| --- | --- |
| `localApp` | App 沙箱内目录，文件工具直接读写 |
| `embedded`（L1 内嵌沙箱） | **`dev_shell`**：cwd 锚定工作区根，PATH 前插 `nativeLibraryDir`——APK jniLibs 内置 busybox（aarch64 全静态）点亮全量 applet；git 全走 **JGit 6.10 进程内**（status/diff/log/commit/push/浅克隆，免系统 git 二进制） |
| `termux`（L2 免 SSH） | **RUN_COMMAND intent** 直达 Termux shell（一次性配置 `allow-external-apps=true` 后零粘贴全流程）；intent 优先、SSH 回落；设置页可一键下载安装 Termux |
| `remotePc` | SSH（dartssh2 fork vendored）远程开发机；SFTP 文件读写 + 远程命令 |

- **配置自动化**：SSH 密钥自动生成（ed25519）+ 一键安装命令 + 「自动执行」按钮；用户名自动读取；  
  远端工作区目录自动创建；连接失败人话分类诊断（sshd 未运行 / 被临时拉黑 / 认证不通过 → 各自下一步）。  
  排障先读 [`docs/dartssh2_termux_pitfalls_2026-10-01.md`](https://github.com/liangjianzeng/TongYi-Lite-docs/blob/main/dartssh2_termux_pitfalls_2026-10-01.md)。
- **SSH 多配置**（按工作区绑定），密钥经 flutter_secure_storage 安全存储；远端 `AGENTS.md`（SFTP，≤64KB）  
  自动叠加注入。
- **任务与规划**：`task_create` / `task_list` + `plan_create` / `plan_update` / `plan_list`；DevContext 自动注入  
  工作区/计划/记忆段 + 【如实报告铁律】（工具返回 error 必须如实复述）。
- **安全**：危险命令黑名单 deny/ask 策略（dev_shell / ssh_exec / run_tests 全覆盖）；工具逐组开关；  
  `workspace_sync` 本地镜像 ↔ 远端双向同步（mtime 判新旧、冲突默认只报告）。

### 会话与输入体验

- **聊天页左栏（rail）**：会话/智能体/人格/计划/模型/引擎/技能/插件/API/Dev Agent/搜索/能力与实验/  
  存储与日志/更多 全部入口收纳于左栏。
- **composer 输入区**：生成中状态细条（「● 执行中 · N 个工具」+ 停止）+ 实时 token 计量（含工具参数，  
  「⚠️只想不写」告警）；四态主键（空闲空 = 🎤 长按说话 / 有字 = ➤ 发送 / 生成中空 = ⏹ 停止 / 有字 = ➤ 插话）；  
  模式图标 chips（🤖 智能体 / 🎭 人格 / 📋 计划 / 🧠 模型）；**会话草稿**（切会话回来打字还在）。
- **附件**：「+」底部面板统一入口（相册多图 ≤10 / 拍照 / 文件 ≤5 办公格式解析注入，PDF 走 PdfBox 原生解析）；  
  markdown 美化渲染 + 产物汇总卡。
- **会话抽屉**：新建 + 搜索 + 分组节 + 「● 执行中」徽标 + 置顶 / 重命名 / 删除。
- **消息交互**：复制 / 转发分享 / tok/s 统计；回合过程总折叠区（工具卡 + 思考存档收进「执行过程」，  
  折叠行显示结果/思考首行概要）；底部会话统计条（步数 / 工具耗时 / 首 token + tok/s / 输入输出 tok /  
  上下文占用）；**界面上同时最多一个 spinner**。
- **对话文字整体缩放**：`chatTextScale`（0.7~1.3）。

---

## 模型列表

全部模型定义在 [`assets/models_catalog.json`](assets/models_catalog.json)（配置驱动，可指向自有 CDN 热更新）。  
`最低内存` 仅为下载参考元数据，真正的闸门是引擎 **OOM 守卫**（可用内存不足自动降 ctx 或拒绝加载）。

| 模型 | 大小 | 最低内存 | 特性 |
| --- | --- | --- | --- |
| Bonsai 27B (Q1_0 智能体 + dspark 加速) | 3.8 GB | 6 GB | 推荐 · 智能体 · dspark 加速 |
| Bonsai 27B (Ternary 1.58-bit) | 7.2 GB | 10 GB | 限高端旗舰 |
| Bonsai 2 27B (PTQ1_0 1.58-bit 纯文本) | 5.9 GB | 16 GB | 限高端旗舰 · 需 ≥16GB 内存（11GB 机型 GPU 加载会 OOM 死机） |
| Gemma 3 4B (Q4_K_M) | 2.6 GB | 3 GB | 推荐 |
| Gemma 4 E2B (Q4_K_M 视觉+语音) | 3.1 GB | 4 GB | 推荐 · 视觉+语音 |
| Qwen3.5-0.8B (MTP UD-Q4_K_XL) | 543 MB | 1 GB | 视觉 · MTP |
| Qwen3.5-0.8BN (Q4_0 MTP) | 497 MB | 1 GB | CPU 加速 · MTP |
| Qwen3.5-2B (MTP UD-Q4_K_XL) | 1.29 GB | 2 GB | 推荐 · 视觉 · MTP |
| Qwen3.5-4B (Q4_K_M MTP 视觉) | 2.8 GB | 3.5 GB | 推荐 · 视觉 · MTP |
| LFM 2.5 2.6B (Q4_K_M) | 1.6 GB | 2 GB | 推荐 · 速度快 |
| Spark-X2.5 4B (Q4_K_M 智能体) | 2.4 GB | 4 GB | 推荐 · 智能体 · 百万上下文 |
| LFM 2.5 8B-A1B (Q4_K_M 智能体) | 4.8 GB | 8 GB | 推荐 · 智能体 · MoE 高效 |
| Ling 3.0 Tiny (Q4_K_M) | 4.5 GB | 8 GB | 推荐 · MoE 高效 |
| Ling 3.0 Tiny (Q4_0 GPU加速) | 4.4 GB | 8 GB | GPU 加速 · MoE 高效（batched MoE） |
| LFM 2.5 8B-A1B (Q4_0 GPU加速) | 4.6 GB | 8 GB | GPU 加速 · MoE 高效（batched MoE） |
| Bonsai-8B (Q1_0 智能体) | 1.2 GB | 2 GB | 推荐 · 智能体 · 轻量 |
| NeoHorse-1 4B (Q4_K_M 智能体) | 2.5 GB | 4 GB | 推荐 · 智能体 |
| MiniCPM5 2B (Q4_K_M 智能体) | 1.5 GB | 3 GB | 推荐 · 智能体 · 速度快 |
| MiniCPM5 2B (Q8_0 智能体) | 2.5 GB | 4 GB | 智能体 · 精度更高 |
| MiniCPM-V 4.7 35B-A3B (拆分 MoE 智能加载) | 1.7 GB | 8 GB | 超大 MoE · 拆分流式（实验） · 视觉 |
| LFM 2.5 24B-A2B (Q4_0 智能MoE 整包原地读) | 12.6 GB | 8 GB | 超大 MoE · 官方整包原地流式读 |

> MoE 模型标注「GPU 加速」的量化（Q4_0）开箱即走 OpenCL batched MoE 全 GPU 路径；  
> 未验证量化自动回退 dense-loop / CPU 专家混合，正确性优先。

---

## 技术架构

```
┌────────────────────────────────────────────────────────────────────────────┐
│ Flutter 3.x (Material3) · Riverpod                                        │
│ lib/  screens · providers · widgets · services · models                    │
│       agent · asr · tts · websearch · plugins                              │
│      聊天（左栏 rail）/ 设置（模型·API·引擎·智能体·能力·开发者·关于）        │
├────────────────────────────────────────────────────────────────────────────┤
│ ① 智能体引擎（lib/agent/）                    ② 端侧模型引擎                  │
│ ┌────────────────────────────────────────┐  ┌───────────────────────────┐  │
│ │ session/    事件日志唯一真相源          │  │ JNI 直调                  │  │
│ │            （JSONL · 压缩遮蔽不删原文） │  │ tongyilite_jni.cpp        │  │
│ │ loop/      ReactLoopAgent 主循环       │  │ └─ llama.cpp fork(0.7.0)  │  │
│ │            （turn/step 状态机 · 失败瀑布）│  │   ├ ggml-cpu             │  │
│ │ tools/     六段工具流水线 · 沙箱审批    │  │   │   + KleidiAI dotprod │  │
│ │ builtin_tools/  15 核心 + 可选 + 系统   │  │   ├ ggml-vulkan          │  │
│ │ llm/       LlmAdapter 接缝             │  │   │   + Turnip 直载      │  │
│ │ protocol/  Prompt-JSON / 原生工具调用   │  │   ├ ggml-opencl          │  │
│ │ subagents/ spawn/fork/fan-out/后台化   │  │   │   + PTQ1_0 三元内核  │  │
│ │                                           │  │   │   + batched MoE      │  │
│ │ skills/(18) · plugins/ · hooks/        │  │   ├ mtmd 视觉编码        │  │
│ │ agents_md/ · goal/ 计划·无人值守       │  │   ├ 投机解码 MTP/dspark  │  │
│ │ mcp/ 远程工具  metrics/ 回合指标       │  │   ├ KV checkpoint/rest.│  │
│ │ context_eng/ 压缩  dev/ Dev Agent      │  │   └ OOM 内存守卫          │  │
│ │ web_search/ 直连+SEARXNG · 每回合上限   │  └───────────────────────────┘  │
│ └────────────────────────────────────────┘                                  │
│ ③ 语音（lib/asr sherpa-onnx 流式 ASR · lib/tts Edge TTS）                    │
│ ④ 搜索（lib/websearch 六引擎直连 · 熔断/窗口预算/UA 池）                      │
├────────────────────────────────────────────────────────────────────────────┤
│ 通信：MethodChannel（请求）+ EventChannel（流式 token 回调）· JNI 直调        │
│       无 HTTP Server · OpenAI 兼容 API 走 Dio（可选）                        │
├────────────────────────────────────────────────────────────────────────────┤
│ Android 原生层：Kotlin (InferenceService/MainActivity/DevGitPlugin) → JNI    │
│  ├─ third_party/ 全量入库：llama.cpp 0.7.0+增强 · KleidiAI · OpenCL-Headers│
│  │   · opencl-stub · turnip 驱动 · edge_tts · dartssh2 fork（clone 即编译） │
│  ├─ Chaquopy CPython 3.11（python_exec）· JGit 6.10（进程内 git）           │
│  └─ sherpa-onnx + onnxruntime（端侧 ASR）· jniLibs 内置 busybox/libhardware │
└────────────────────────────────────────────────────────────────────────────┘
```

### 智能体引擎（`lib/agent/`）

- `session/` 事件日志唯一真相源（append-only JSONL，上下文 = 纯函数投影，压缩遮蔽不删原文，崩溃自修复）·  
  `loop/` ReactLoopAgent（turn/step 状态机 + 失败瀑布 + 可靠取消）· `tools/` 六段工具流水线 + 沙箱审批 +  
  溢写落盘 · `llm/`+`protocol/` LlmAdapter 接缝（本地 Prompt-JSON / API 原生工具调用，按能力快照选择）。
- `subagents/` 子代理编排 · `goal/` 计划与无人值守 · `mcp/` MCP 客户端 · `metrics/` 回合指标 ·  
  `skills/` 内置 18 技能 · `plugins/` 插件宿主 · `hooks/` Hook 接缝 · `agents_md/` 指令文件 ·  
  `context_eng/` 压缩 + 溢写 · `dev/` Dev Agent（工作区/SSH/git/Termux）· `web_search/` 搜索 provider 接入层。

### 端侧模型引擎（llama.cpp 0.7.0 + fork 增强 · JNI 直调）

- **多后端**：ggml-cpu（+ KleidiAI dotprod）、ggml-vulkan（Adreno 可经 **Turnip Mesa gen8 直载**）、  
  ggml-opencl（+ PTQ1_0 三元内核 + batched MoE）；启动探测 + 设置选择，探测不到自动回落 CPU。
- **🚀 OpenCL batched MoE**：上游 MUL_MAT_ID 在 Adreno 830 全量化数值损坏（驱动级 bug）→ 自研  
  `kernel_mul_mat_id_*_batched` 单 dispatch gather + 设备端 ids 直读 + 专家桶排序（L2 复用）。  
  **内核级通用能力**：按量化类型逐个验证上线——**q4_0（v0.3.0）→ q4_K（v0.3.1 host 预计算有效 scale）→  
  q4_1（v0.3.5 路由行）**，IQ2 / IQ3 在路线图；未验证量化自动回退。配套 KV checkpoint/restore、  
  BUFT placement 探针默认批量 1、M-R1 融合路由算子 `GGML_FUSED_MOE_TOPK`（CLI kernel 1498→1199、  
  host 提交 -24%、+6~20% tok/s；App 侧 env 门默认关待验收）。
- **🧠 split-MoE + LES**：权重剥离 `.experts/`（40 分片 + manifest）或 **in-place GGUF 直读**（免剥离，  
  LFM2.5-24B 官方整包单文件直下直读，1902 MiB / zerocopy 100%）+ slot bank 流式供给专家 + LES 下一层  
  router 预测；830 机型跑 MiniCPM-V 4.7 35B-A3B 热稳态 **8.07 t/s**、740 3.0–3.4 t/s。
- **📊 GPU decode 路线与 Mesa 全 GPU 卸载线**：OpenCL per-op 提交税 9µs（CPU 0.34µs）且 Adreno 驱动不暴露  
  `cl_khr_command_buffer`，decode 混合图多 split/跨后端拷贝 → decode 阶段 CPU 混合守擂（830：CPU bank  
  8.07 vs GPU 最优 5.46 t/s）；batched MoE 收益主战场在 **prefill 大分块 GEMM**。Mesa（rusticl + freedreno  
  + kgsl）整图单提交路线已立项：740 正确性战役 op 级全绿、测量接管后 L3 裁决 **Mesa 全 GPU decode ≈ CPU bank  
  的 17.5–20%**（提交层封死，头号嫌疑 = 42% 形状每 token 落 CPU 往返）。  
  深读：[`docs/全GPU卸载_Mesa自研路线总档_2026-10-16.md`](https://github.com/liangjianzeng/TongYi-Lite-docs/blob/main/全GPU卸载_Mesa自研路线总档_2026-10-16.md)、  
  [`docs/全GPU卸载_Mesa线_状态快照_2026-10-24.md`](https://github.com/liangjianzeng/TongYi-Lite-docs/blob/main/全GPU卸载_Mesa线_状态快照_2026-10-24.md)、  
  [`docs/全GPU卸载_全景地图与网格计划_2026-10-25.md`](https://github.com/liangjianzeng/TongYi-Lite-docs/blob/main/全GPU卸载_全景地图与网格计划_2026-10-25.md)。
- **KV 精度三档**（Q4/Q8/F16，设置页可选）：混合架构（GDN+注意力，如 Ling）选 Q4 K 会把注意力链踢回 CPU 岛，  
  选 **F16 恢复 decode 3-split 结构**（CPU-embed 头 + GPU 整网 + CPU-lm_head 尾）；V 尺寸不齐建不了 ctx 时  
  JNI 自动回退 F16 重试。
- **多模态**：mtmd 视觉投影器编码（跟随主后端）· **投机解码**：MTP（NextN head）+ dspark（整块投机）·  
  **多轮 KV checkpoint/restore**（二次 TTFT 34s → 4.4s）· **OOM 内存守卫**（加载前读 `/proc/meminfo` 预检，  
  权重 + KV 估算超可用 → 自动降 n_ctx 或拒绝加载防整机死机）。

### GPU / CPU 推理后端

构建时若满足依赖，APK 同时包含 `libggml-vulkan.so`（内嵌预编译 SPIR-V）与 `libggml-opencl.so`  
（dlopen 转发 stub）。**是否真正用 GPU、用哪个后端，由 App 启动探测 + 设置选择决定**：

- **Vulkan + OpenCL 双后端**（仅 arm64-v8a）：「GPU 加速」开关（默认开）+ 后端选择（自动/OpenCL/Vulkan）+  
  「GPU 层数」滑块（默认 100 全量卸载）。`auto` 优先 OpenCL，探测不到回落 CPU。
- **OpenCL（Adreno 推荐）**：与 Vulkan 吞吐等价；依赖设备 `libOpenCL.so`，无驱动时自动回落 CPU 不崩溃。
- **天玑 Mali**：系统 `libOpenCL.so` 为空壳 ICD，MediaTek 上 OpenCL 置灰提示优先 Vulkan；Mali Vulkan 崩溃  
  （`vkGetDeviceQueue2` 坏 queue）已根治（v0.1.6，仅 ARM vendor 生效）。Mali-G68 无矩阵加速单元，  
  Vulkan 解码约为 CPU 的 1/3，属硬件天花板。
- **KleidiAI dotprod（CPU 备选）**：`GGML_CPU_ARM_ARCH=armv8.2-a+dotprod`；⚠️ 不加 `+i8mm`  
  （Cortex-A78 无 i8mm，会 SIGILL 三后端同崩）。SME2 内核族已随 KleidiAI v1.31 入包（运行时派发，  
  当前设备收益未到）。

#### Adreno Vulkan Turnip 直载（摘要）

原厂驱动（0800.71）E031 编译器错编 shader（`unpack8()` 等 5 个独立问题）且 OTA 后回归 → 弃用；  
v0.2.3 起改 **Turnip（Mesa out-of-tree gen8）App 内直载**（免 root）：Vulkan HAL 入口逆向 + ggml-vulkan  
全部裸 Vulkan 调用 dispatcher 化 + 数值三根因修复（subgroupAdd 错编全局门控 / GDN lanes 钳 64 /  
`libhardware.so` stub 解决 App 命名空间 dlopen 系统 HAL 库）；llama.cpp 升级 0.5.0 时三层回归逐一移植。  
当前 Adreno 日常 GPU 推理默认走 OpenCL（吞吐等价、无 Turnip 遗留项）。  
完整根因链见 [`docs/vulkan_adreno825_fix_2026-09-26.md`](https://github.com/liangjianzeng/TongYi-Lite-docs/blob/main/vulkan_adreno825_fix_2026-09-26.md)。

#### OpenCL PTQ1_0 三元量化内核（摘要）

Bonsai-2 27B 的 402 个 PTQ1_0 张量（GGML type 143，-1/0/1 三元）上游只有 Q4/Q5/Q8 内核 → 自研  
`mul_mv_ptq1_0_f32.cl`（decode）+ `mul_mm_ptq1_0_f32_l4_lm.cl`（prefill GEMM，桌面 Arc 实测 pp128  
1.14 → 18.89 t/s，16.5×）；根治 Adreno 编译器 `__constant` 数组变址误编与 `half` 保留字坑；  
真机 test-backend-ops **174/174 通过**。详见 [`docs/ptq1_0_opencl_bonsai2_2026-09-27.md`](https://github.com/liangjianzeng/TongYi-Lite-docs/blob/main/ptq1_0_opencl_bonsai2_2026-09-27.md)。

**验证 CPU 内核 / GPU 是否生效**：

```bash
grep -c "kai_matmul.*dotprod" android/app/.cxx/Debug/*/arm64-v8a/compile_commands.json   # >0
adb logcat -c && adb shell am start -n com.dgxspark.tongyilite/.MainActivity
adb logcat | grep -iE "TongYiLite|ggml_vulkan|OpenCL"    # 看 backend devices 与 n_gpu_layers
```

---

## 构建与开发

### 前置环境

| 工具          | 版本                  | 用途                                              |
| ----------- | ------------------- | ----------------------------------------------- |
| Flutter SDK | 3.x（Dart 3.6+）      | Flutter 构建                                      |
| Android SDK | 34+ (compileSdk 36) | Android 构建                                      |
| Android NDK | r27 (27.0.12077973) | C++ 原生编译                                        |
| CMake       | 3.22.1              | `CMakeLists.txt` + Gradle `externalNativeBuild` |
| Java JDK    | 17                  | Gradle / Kotlin（项目 Kotlin 1.9.22）               |

> 重量级原生依赖（随 APK/构建链处理）：Chaquopy 17（CPython 3.11）、JGit 6.10、sherpa-onnx + onnxruntime  
> （release 包体 +~18MB）、flutter_secure_storage、background_downloader。

### 构建要点

- **Debug 也强制 `-O3 -DNDEBUG`**：NDK 工具链会静默顶掉 `CMAKE_C_FLAGS_DEBUG`，正确做法是目录级  
  `add_compile_options(-O3)` + `add_compile_definitions(NDEBUG)`（否则量化 matmul 内核 `-O0`，全模型 ~1.2 tok/s）。
- **改 CMakeLists / 工具链后必须清 `.cxx` 缓存**，否则 Gradle 判定 up-to-date 不重编；**合并/checkout 带来  
  native 改动时**同样要 `touch` 源文件强制重编（git 操作不保证 mtime 前进），构建后字符串级验证 APK 内  
  `libtongyilite_jni.so` 含新增日志串。
- **回归防线**：动智能体循环/协议先跑 `flutter test test/agent`；全量 `flutter test` 当前 **700+ 项**  
  （test/agent · providers · services · websearch · tts · asr）。
- **一键打包**：Windows `tool/build_apk.ps1`，DGX Spark（Linux aarch64）`tool/build_apk.sh`——默认 debug +  
  release 一起打，自带环境自检（`--check`）、apksigner 签名验收（非 `CN=TongYiLite` 直接判失败）、  
  `--install` **覆盖安装**（绝不 uninstall）、`--clean-native` 强制重编 NDK；产物在 `build/app/outputs/flutter-apk/`。  
  打包验收唯一真源 `tool/verify_apk.sh`（`--verify-only` 只验产物）。
- **App tok/s 一键测量**：`tool/measure_toks.sh`（Dart VM service 通道 + `vk_flags.conf` 任意 env 注入：  
  HOST_TIMING / SCHED_DEBUG / UBATCH，免重编免 root）。
- 编译排错（Gradle plugin 复合构建 / 阿里云镜像 / CMake 路径）见 [常见问题](#常见问题) 与  
  [`docs/BUILD_AND_DEBUG_GUIDE.md`](https://github.com/liangjianzeng/TongYi-Lite-docs/blob/main/BUILD_AND_DEBUG_GUIDE.md)。

---

## 下载

**最新 release**（签名 `CN=TongYiLite`，Android 13+，arm64-v8a）：

> [⬇️ 下载 `TongYi-Lite-v0.3.5.apk`](https://github.com/liangjianzeng/TongYi-Lite/raw/main/releases/TongYi-Lite-v0.3.5.apk)  
> v0.3.5+23 · 72,114,342 B（2026-10-25，GPU 全卸载产品化第一轮 + UI rail 重构 + 单主线收敛；  
> 追加：外观浅色/深色/跟随系统、产物另存到任意目录、简单聊天流式思考卡、  
> 滚动焦点拖拽仲裁（上翻释放/回底截获）、API 档占用窗口路由修复）  
> `SHA-256: dcb53cd9b1a49578d42d20642fe6ae2fb1d4df9e76d8e9204a2b8cf1ff1774f8`

> ⚠️ 覆盖安装需同一签名证书（`CN=TongYiLite`）且 versionCode ≥ 已装版本；`adb install -r` 可保留已下载  
> 模型缓存，切勿先卸载。历史版本见 [`releases/`](releases/) 目录或按[构建与开发](#构建与开发)自行构建。

---

## 版本更新

> 版本历史依据 git 提交维护，详细变更见 [`CHANGELOG.md`](CHANGELOG.md)。  
> 引擎口径：`third_party/llama.cpp` = **上游 `0.7.0` + fork 增强树**（2026-10-18 四道门升级；历史：  
> fe8156f → b11267(0.5.0) → 0.7.0，保留全部 fork 资产：dspark/spark2_5、PTQ1_0 内核、FWHT、Turnip 直载、  
> KleidiAI vendored、MTP）。

| 版本 | 日期 | 要点 |
| --- | --- | --- |
| **v0.3.5**（当前） | 2026-10-25 | **GPU 全卸载产品化第一轮**：KV 精度加 F16 档（混合架构恢复 GPU 整网）、M-R1 融合路由算子并入、BUFT 探针默认批量 1、q4_1 batched MoE（CLI decode 累计 2.97→8.38 t/s = 2.8×）、740 基线 decode 5.3 t/s；**UI rail 重构**（引擎独立面板/人格侧栏/能力 Tab/统计条重写）；**仓库单主线收敛**（删 temp/spike/tongyi-r2）；UI 补充批：外观主题三档切换、产物「另存」到任意目录（SAF）、简单聊天流式思考卡、统计条流式 tok 实时估算。versionCode 23 |
| v0.3.4+ | 2026-10-20~24 | Mesa 测量接管 + L3 裁决（Mesa ≈ CPU bank 17.5–20%，提交层封死）；智能体思考失控根治（跨块累计守卫）；API「思考强度」档位 + 实时 token 读数 + 停止按钮三洞修复；调试机型分级定案（740 主力 / 830 参考 / 650 冒烟） |
| v0.3.4+ | 2026-10-20 | Edge TTS 恢复播报（Sec-MS-GEC v2 强制 + 手机 IPv6 半死通道 → v2 token 移植 + IPv4 优先） |
| v0.3.4 | 2026-10-18 | llama.cpp 0.5.0 → **0.7.0 四道门升级**（47 冲突 hunk、KleidiAI v1.31、REGC 宏守卫修复）；740 基准 decode +27%、首 Tok -49% |
| v0.3.3+ | 2026-10-17 | FD740 rusticl 正确性战役（M1）：subgroup 三铁律 + 20+ 内核修复，op 级全绿（MUL_MAT 1001/1009 等） |
| v0.3.3 | 2026-10-16 | LFM2.5-24B-A2B **官方整包 in-place 直读**（免 PC 打包/免分片，专家 I/O 1902 MiB/s）；小米13 实测 decode 1.6 t/s（+78%） |
| v0.3.2 | 2026-10-15~16 | split-MoE + LES 落地（830 热稳态 8.07 t/s）；SCHED_STATS + probe9 提交税探针 → decode CPU 混合守擂定案 |
| v0.3.1 | 2026-10-14 | q4_K batched MoE 修复上线（host 预计算有效 scale dodge，11/11 形状 NMSE=0~1e-6） |
| v0.3.0 | 2026-10-14 | **OpenCL batched MoE（q4_0）**：Adreno 830 prefill 149 t/s / decode 14–22 t/s；KV checkpoint/restore（34s → 4.4s）；moe_probe 探针 |
| v0.2.9 | 2026-10-06 | Edge TTS 首版 + 上下文占用圈 + 存储级手动压缩 + 任务清单会话隔离 + SSE 看门狗 |
| v0.2.9+ | 2026-10-06~08 | sherpa-onnx 端侧流式 ASR、多会话并发槽位、Dev Agent 全链路、端侧直连六引擎搜索、人格系统、计划模式无人值守、composer 重构、eval 12 基线 |
| v0.2.8 | 2026-09-29~30 | Vulkan App 内直载打通（libhardware stub）；llama.cpp b11267 升级 + Vulkan 回归修复；web_search 每回合上限；Bonsai-2 OOM 守卫定案 |
| v0.2.7 | 2026-09-29 | API 视觉 + 思考流独立展示 + 工具卡紧凑化；分支停维护、主干统一 |
| v0.2.6 | 2026-09-28 | PTQ1_0 prefill GEMM（桌面 16.5×）；Turnip e2e 乱码根因定案（GEMM 大 n 错编，n_ubatch≤32 边界） |
| v0.2.5 | 2026-09-27 | OpenCL PTQ1_0 decode 内核（Bonsai-2 27B 全 GPU，真机 174/174） |
| v0.2.4 | 2026-09-27 | 智能体「迭代一两下就停」三根因根治（截断三分类 / 旧答案回溯 / system 队首） |
| v0.2.3 | 2026-09-27 | Turnip（Mesa gen8）App 内直载——Adreno 825 Vulkan 重生；数值三根因修复 |
| v0.2.2 | 2026-09-26 | 原厂驱动 unpack8() 错编 shader 层修复 + 4 个 env 开关默认注入 |
| v0.2.1 | 2026-09-26 | 智能体引擎全面升级：事件日志唯一真相源 + 失败自动恢复 + 六段工具流水线 + 子代理 + Skills/Hooks/AGENTS.md |
| v0.2.0 | 2026-09-04 | Agent Lite 智能体（18 工具 + 沙箱授权）、python_exec（Chaquopy）、MTP 投机解码、远程 API |
| v0.1.x | 2026-07-29~08-19 | 端侧 LLM 推理引擎起步：Vulkan GPU 加速、模型下载、SQLite 持久化、多轮正确性修复、天玑 Mali Vulkan 崩溃根治、llama.cpp fe8156f 基线 |

---

## 常见问题

<details>

<summary><b>Q: 构建时报 Gradle plugin "dev.flutter.flutter-gradle-plugin" not found</b></summary>

该插件不发布到任何公开 Maven 仓库，必须通过 `includeBuild` 复合构建从 Flutter SDK 本地解析。确保  
`settings.gradle.kts` 中包含：

```kotlin
pluginManagement {
    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")
}
```

</details>

<details>

<summary><b>Q: dl.google.com 连接超时 / Maven 依赖下载失败</b></summary>

已在 `pluginManagement.repositories` 和 `allprojects.repositories` 添加阿里云镜像  
（`https://maven.aliyun.com/repository/google` / `public` / `gradle-plugin`）。  
注意 **JGit 无 aliyun 镜像**，走 repo.maven.apache.org。

</details>

<details>

<summary><b>Q: CMake 找不到 llama.cpp / 路径错误</b></summary>

`CMakeLists.txt` 从 `android/app/src/main/cpp/` 到项目根目录需要 **5 层** `../`：

```cmake
set(PROJECT_ROOT_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../../../../../../..)
```

</details>

<details>

<summary><b>Q: 如何启用 / 排查 Vulkan GPU 加速？</b></summary>

1. 确认 LunarG Vulkan SDK 已安装（`glslc` + SPIRV-Headers）与 MinGW-w64 可用（vulkan-shaders-gen 需要）。
2. 改了 CMakeLists / 工具链后**必须清 `.cxx` 缓存**：`Remove-Item -LiteralPath 'android\app\.cxx' -Recurse -Force`。
3. 运行时 `adb logcat | grep -iE "TongYiLite|ggml_vulkan"`，看 `ggml backend devices` 与 `n_gpu_layers`。

</details>

<details>

<summary><b>Q: 智能体说「沙箱没有 git」？</b></summary>

本地沙箱（`shell_exec`）永远没有 git 二进制（Android W^X 不能 exec 任意二进制）——非 Dev 回合里  
"仅要代码"走 HTTP（GitHub API + raw）是正确降级。**真 git 在 Dev 工具组**：Dev 模式开启后，embedded 后端走  
JGit 进程内 git，Termux/远程 PC 走系统 git。**计划模式（/plan）**注册表收窄为只读工具，副作用类被禁属设计如此。

</details>

<details>

<summary><b>Q: 语音识别没反应 / 无转写？</b></summary>

1. 首次使用需下载 ASR 模型（~160MB，聊天页左栏 → 更多（基础配置）的语音卡可查看状态）。
2. 长按 🎤 需保持 1 秒以上——单击只弹提示。第一次会话「准备中」约 5s（引擎加载），后续瞬时启动。
3. 浮层有回显但松手后没文字：检查麦克风权限 / 是否被其他应用占用。
4. 准确率不满意：开启「增强识别模式」、配置热词（支持自定义词表，同音自动校正）。

</details>

<details>

<summary><b>Q: TTS 完全不出声 / 某些音色不出声？</b></summary>

1. **微软换了 token 算法**——合成 WebSocket 握手 403（音色列表却 200，易误判网络问题）。  
   跑 `dart run tool/tts_diag_probe.dart`：全音色 403 + 时钟 0 偏差 = token 版本落后，需对照上游  
   python `edge-tts` 的 `drm.py` 移植并**成对**翻转 `Sec-MS-GEC-Version` 前缀。
2. **手机 IPv6 通道半死**（TCP 连上、TLS 被 RST）——已用 IPv4 优先连接规避；连接层可用  
   `dart run tool/tts_conn_probe.dart` 验。

手动点 🔊 / 试听失败会有 SnackBar 说明原因；自动播报按设计静默。**个别音色不出声**属服务端行为：  
非 Multilingual 的英文音色读中文一律空音频；大陆方言音色仅辽宁/陕西两个女声。

</details>

<details>

<summary><b>Q: 推理速度慢 / 内存溢出</b></summary>

- 使用更小的模型；关闭后台应用释放 RAM；设备需 ≥ 4GB RAM 才能流畅运行 2B 级模型。
- 确保 GPU 加速已启用（Adreno 推荐 OpenCL；MoE 模型 Q4_0 量化走 batched MoE 全 GPU 路径；  
  混合架构模型 KV 精度选 **F16**）。
- 已优化：批量 prefill + 多轮 KV checkpoint/restore（34s → 4.4s）、内置采样器、流式回调批量化、  
  mmap 加载、线程按 CPU 拓扑取核。
- 大体积 GPU 模型受 **OOM 守卫**保护：可用内存不足时自动降 ctx 或拒绝加载（防整机死机）；  
  旁路开关在推理引擎面板（聊天页左栏 → 引擎），**11GB 机型不建议旁路**。

</details>

<details>

<summary><b>Q: 模型下载失败 / 速度慢</b></summary>

- 应用自动尝试多个镜像源，无需手动切换；断点续传：中断后点「继续」即可恢复。
- 所有镜像均不可用时检查网络连接或开启代理。

</details>

---

## 贡献指南

欢迎提交 Issue 和 Pull Request！请先阅读 [CONTRIBUTING.md](CONTRIBUTING.md)。

关键设计文档（过程性深读，均存于私有仓 [TongYi-Lite-docs](https://github.com/liangjianzeng/TongYi-Lite-docs)，仅所有者可访问）：

**构建 / 环境**

- [`docs/BUILD_AND_DEBUG_GUIDE.md`](https://github.com/liangjianzeng/TongYi-Lite-docs/blob/main/BUILD_AND_DEBUG_GUIDE.md) — 编译与调试指南
- [`docs/BUILD_ENV_NOTES.md`](https://github.com/liangjianzeng/TongYi-Lite-docs/blob/main/BUILD_ENV_NOTES.md) — Windows 本机打包构建环境备忘
- [`docs/python_support.md`](https://github.com/liangjianzeng/TongYi-Lite-docs/blob/main/python_support.md) — `python_exec` 支持说明

**GPU / 推理引擎专项**

- [`docs/全GPU卸载_Mesa自研路线总档_2026-10-16.md`](https://github.com/liangjianzeng/TongYi-Lite-docs/blob/main/全GPU卸载_Mesa自研路线总档_2026-10-16.md) — Mesa（rusticl+freedreno+kgsl）全 GPU 卸载路线总档
- [`docs/全GPU卸载_Mesa线_状态快照_2026-10-24.md`](https://github.com/liangjianzeng/TongYi-Lite-docs/blob/main/全GPU卸载_Mesa线_状态快照_2026-10-24.md) — Mesa 线当前状态与解锁即动手清单
- [`docs/全GPU卸载_全景地图与网格计划_2026-10-25.md`](https://github.com/liangjianzeng/TongYi-Lite-docs/blob/main/全GPU卸载_全景地图与网格计划_2026-10-25.md) — 三模式×三栈全景地图与 A/B 网格计划
- [`docs/fork升级v0.7.0主线方案_2026-10-18.md`](https://github.com/liangjianzeng/TongYi-Lite-docs/blob/main/fork升级v0.7.0主线方案_2026-10-18.md) — llama.cpp 0.7.0 四道门升级
- [`docs/vulkan_adreno825_fix_2026-09-26.md`](https://github.com/liangjianzeng/TongYi-Lite-docs/blob/main/vulkan_adreno825_fix_2026-09-26.md) — Adreno 825 Vulkan / Turnip 修复全记录
- [`docs/ptq1_0_opencl_bonsai2_2026-09-27.md`](https://github.com/liangjianzeng/TongYi-Lite-docs/blob/main/ptq1_0_opencl_bonsai2_2026-09-27.md) — PTQ1_0 OpenCL 内核实现机制
- [`docs/bonsai2_opencl_oom_2026-09-27.md`](https://github.com/liangjianzeng/TongYi-Lite-docs/blob/main/bonsai2_opencl_oom_2026-09-27.md) — Bonsai-2 OOM 整机死机定案与守卫
- [`docs/vulkan_bonsai2_turnip_verify_2026-09-28.md`](https://github.com/liangjianzeng/TongYi-Lite-docs/blob/main/vulkan_bonsai2_turnip_verify_2026-09-28.md) — 双驱动真机验证矩阵
- [`docs/llama_cpp_upgrade_plan_b11267.md`](https://github.com/liangjianzeng/TongYi-Lite-docs/blob/main/llama_cpp_upgrade_plan_b11267.md) — llama.cpp b11267 升级计划与四道门验收

**智能体 / 周边**

- [`docs/websearch_direct_2026-10-02.md`](https://github.com/liangjianzeng/TongYi-Lite-docs/blob/main/websearch_direct_2026-10-02.md) — 端侧直连搜索引擎模块（实测证据/引擎坑速查）
- [`docs/termux_integration_plan_2026-10-04.md`](https://github.com/liangjianzeng/TongYi-Lite-docs/blob/main/termux_integration_plan_2026-10-04.md) — 三级执行环境（L0/L1/L2）施工方案
- [`docs/dartssh2_termux_pitfalls_2026-10-01.md`](https://github.com/liangjianzeng/TongYi-Lite-docs/blob/main/dartssh2_termux_pitfalls_2026-10-01.md) — dartssh2 / SshKeyGen / Termux sshd 全部坑点（SSH 排障先读）
- [`docs/插件平台_契约冻结清单_2026-10-23.md`](https://github.com/liangjianzeng/TongYi-Lite-docs/blob/main/插件平台_契约冻结清单_2026-10-23.md) — 插件宿主契约冻结清单
- [`docs/archive/backend_benchmark_2026-08-04.md`](https://github.com/liangjianzeng/TongYi-Lite-docs/blob/main/archive/backend_benchmark_2026-08-04.md) — 三后端实测专报
- [`docs/archive/architecture_design_v2.md`](https://github.com/liangjianzeng/TongYi-Lite-docs/blob/main/archive/architecture_design_v2.md) — 架构设计 v2

---

## License

[MIT](LICENSE) — 自由使用、修改和分发。
