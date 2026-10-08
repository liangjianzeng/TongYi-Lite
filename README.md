# TongYi-Lite 端侧离线 AI 智能体

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![v0.2.9](https://img.shields.io/badge/v0.2.9-8B5CF6)]
[![Flutter](https://img.shields.io/badge/Flutter-3.x-02569B?logo=flutter)](https://flutter.dev)
[![Android](https://img.shields.io/badge/Android-33+-3DDC84?logo=android)](https://developer.android.com)
[![llama.cpp](https://img.shields.io/badge/Engine-llama.cpp%20fork-red)](https://github.com/ggerganov/llama.cpp)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](CONTRIBUTING.md)

> **端到端离线优先的 Android AI 智能体。** 三大支柱：
>
> - **🤖 智能体引擎**——事件日志唯一真相源 + ReactLoopAgent 主循环 + 六段工具流水线 +
>   子代理 / Skills / MCP / 人格 / 计划模式（`/plan` → 审批 → 无人值守续跑）+
>   `AGENTS.md`，模型按需调用工具、工具真实执行并回填结果；
> - **⚙️ 端侧模型引擎**——llama.cpp 上游 `b11267`（0.5.0）+ fork 增强（`spark2_5` / dspark 投机 /
>   PTQ1_0 三元内核 / FWHT / Turnip 直载）JNI 直调 · Vulkan / OpenCL GPU 加速（Adreno 825 支持
>   Turnip 直载）+ KleidiAI CPU 加速 · MTP / dspark 投机解码 · mtmd 视觉 · OOM 内存守卫；
> - **🛠️ Dev Agent 开发执行环境**——内嵌工具沙箱（`dev_shell` + JGit 进程内 git）/
>   Termux 伴侣应用（RUN_COMMAND 免 SSH）/ 远程 PC（SSH）三级后端，
>   任务规划（task/plan）+ 双向同步 + 远端 `AGENTS.md`，让智能体在真机/远端真实写代码。
>
> 另有 OpenAI 兼容远程模型接入、**端侧直连国内六引擎搜索**（零配置，可选自建 SearXNG）、
> **端侧流式语音识别**（sherpa-onnx，完全离线）与 **Edge TTS 语音播报**（免费无 key）。
> 对话与推理数据不出设备；联网能力（搜索 / TTS / API）均为可选项。

---

## 目录

- [功能概览](#功能概览)
- [快速开始](#快速开始)
- [应用功能](#应用功能)
  - [语音输入与播报](#语音输入与播报)
  - [联网搜索](#联网搜索端侧直连--searxng-可选)
  - [Agent 智能体](#agent-智能体工具调用)
  - [Dev Agent 开发模式](#dev-agent-开发模式)
- [模型列表](#模型列表)
- [技术架构](#技术架构)
- [构建与开发](#构建与开发)
- [版本更新](#版本更新)
- [常见问题](#常见问题)
- [贡献指南](#贡献指南)
- [License](#license)

---

## 功能概览

TongYi-Lite 是一个**端侧优先、可完全离线运行**的 Android AI 应用：模型权重完全本地推理，
对话数据不出设备；联网能力（直连搜索 / Edge TTS / 远程 API）均为可选项，按需开启。

| 能力 | 说明 |
|------|------|
| **🤖 智能体引擎** | 事件日志唯一真相源 + ReactLoopAgent 主循环（失败自动恢复）+ 六段工具流水线 + **子代理**（spawn/fork/fan-out/后台化）+ Skills（内置 17 个）/ Hooks / MCP 远程工具 / `AGENTS.md`；30+ 工具按档位与开关注册，沙箱授权 + 逐次审批；**可一键关闭**（关闭 = 简单聊天，本地小模型友好） |
| **🎭 多人格（Persona）** | 标准人格 + 用户自定义人格（名称 + 人设提示词），按场景切换；输入区 🎭 图标一键切换；切换自动重置 KV 缓存 |
| **📋 计划模式 + 无人值守** | `/plan <任务>` 只读规划 → 计划卡提交审批 → 批准后结构化计划落库并**自动逐轮续跑**（goal 驱动，轮数可配）；对话内常驻计划活卡 + 计划面板逐步推进 |
| **⚙️ 端侧模型引擎** | llama.cpp 上游 `b11267`（0.5.0）+ fork 增强（`spark2_5` / dspark / PTQ1_0）JNI 直调（无 HTTP Server）、mmap 加载、批量 prefill、内置采样器；纯 CPU 也可跑 |
| **GPU / CPU 加速** | Vulkan + OpenCL 双 GPU 后端（运行时自动探测 + 手动选择）+ KleidiAI dotprod CPU 内核；Adreno 825 上 Vulkan 经 **Turnip（Mesa gen8）App 内直载**可用；PTQ1_0 三元量化专用 GPU 内核（详见[技术架构](#技术架构)） |
| **投机解码** | **MTP**（多 token 预测）+ **dspark**（整块投机），部分模型支持，设置页按模型单独开启 |
| **模型下载与管理** | 应用内下载（hf-mirror / ModelScope 镜像自动回退 + HTTP Range 断点续传）、加载/卸载、单模型约束、存储信息扫描 |
| **🖼️ 视觉理解** | Qwen3.5 / Gemma 4 视觉模型（`.gguf` + `mmproj` 两文件闭环下载），本地档与 API 档均支持图片输入 |
| **🎙️ 语音输入（端侧 ASR）** | sherpa-onnx 流式 Zipformer 中文 int8（~160MB，首次使用下载），FFI 进程内推理，**完全离线零网络依赖**；微信式按住说话、实时回显、上滑取消；9 类约 290 词热词偏置 + 自定义热词（可查看/编辑，差量存储） |
| **🔊 语音播报（Edge TTS）** | 微软 Edge 免费 neural 音色（免 key），气泡 🔊 点按播报 / 回复后自动播报；音色/语速/音调/音量可配 + 试听；markdown 清洗成可朗读文本、长回复按句分段逐段播放；失败静默降级 |
| **上下文占用圈 + 手动压缩** | 输入框圆形占用环（API `prompt_tokens/n_ctx` 实测 · 本地 KV `kv_used/kv_ctx`），阈值变色；点开详情面板，支持**存储级手动压缩**（清理旧工具结果存摘要，聊天记录不受影响）；回合内 LLM 摘要压缩（专用便宜模型，失败回退确定性摘要） |
| **🌐 联网搜索** | **端侧直连国内六引擎**（必应/百度/搜狗/360/夸克/中国搜索）——零配置默认可用，带每 10 分钟窗口请求预算、指数熔断、UA 池、引擎开关；配置了自建 **SearXNG** 地址则自动切换走实例；`web_search` 支持并发多关键词、每回合搜索上限、同内容去重、新闻意图过滤 |
| **🛠️ Dev Agent 开发模式** | 工作区四级后端（App 沙箱 / 内嵌工具沙箱 / Termux / 远程 PC）+ `dev_shell`（jniLibs busybox）+ **JGit 进程内 git**（clone/commit/push，免系统 git）+ Termux **RUN_COMMAND 免 SSH** 通道 + SSH 多配置向导（密钥自动生成、一键安装、自动执行）+ 任务/规划管理 + `workspace_sync` 双向同步 |
| **远程 API 接入** | OpenAI 兼容 `{baseUrl}/chat/completions`（云端大模型或自建 llama.cpp 服务），本地优先、API 后备；智能体可指定 API 驱动（双场景档），并支持按角色路由不同模型（子代理 / 压缩摘要专用模型） |
| **多会话并发** | 并发会话槽位（1~4）：API 会话可真正并行执行回合；会话抽屉显示每个会话的「● 执行中」状态 |
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

> ✅ **三方依赖已全部直接入库**：llama.cpp（上游 `b11267` 0.5.0 + fork 增强：`spark2_5` /
> dspark 投机 / PTQ1_0 内核 / FWHT / Turnip 直载）、KleidiAI（v1.24.0）、OpenCL-Headers、
> opencl-stub 源码都在 `third_party/` 下；`edge_tts`（纯 Dart TTS 协议栈）与 `dartssh2` fork
> 同样 vendored 在 `third_party/`。clone 后即可编译，不需要 `git submodule update --init --recursive`。

> **真机覆盖安装铁律**：始终 `adb install -r app-debug.apk`（`-r` 覆盖更新，保留已下载的端侧模型缓存）；
> **绝不先卸载再装**（卸载会清掉模型缓存）。设备被 `INSTALL_FAILED_USER_RESTRICTED` 拒绝时加 `-t`。

<details>
<summary><b>Windows 本机快速构建 / debug APK 装不进最新 Dart？（开发机专用）</b></summary>

构建慢的根因与解法、增量/全量耗时分解、flutter SDK 补丁记录见
[`docs/BUILD_ENV_NOTES.md`](docs/BUILD_ENV_NOTES.md)。核心两条：先
`set PATHEXT=.EXE;.COM;.BAT;.CMD;.VBS;.JS;.WSF;.MSC`（本机 PATHEXT 异常导致 PATH 查找全失效），
再走「flutter assemble → 同步 assets → gradle `-x compileFlutterBuild*`」增量路径（约 2 分钟）。

`flutter assemble` 与 gradle 读写的 kernel 路径不一致会导致打包了旧 Dart。每次改 Dart 后必须先把最新
`flutter_assets` 同步覆盖到 gradle 的 intermediates 再打包：

```bash
flutter assemble -o build/flutter-assemble --define=BuildMode=debug --define=TargetPlatform=android-arm64 debug_android_application
xcopy /E /I build\flutter-assemble\flutter_assets\ build\app\intermediates\flutter\debug\flutter_assets\
cd android && .\gradlew.bat assembleDebug -x compileFlutterBuildDebug
```

另注意：Git Bash 的 `cd android && ./gradlew.bat` 执行后 **shell 停在 android/**，后续相对路径
（如检查 `build/...` 产物）会查错位置——产物检查一律用绝对路径。

</details>

---

## 应用功能

### 本地端侧推理

应用内置完整的模型生命周期管理，同一时间只允许一个模型在内存中运行（单模型约束）：

| 状态 | 说明 | UI 表现 |
|------|------|---------|
| `idle`（未加载） | 无模型在内存中 | 灰色「未加载」，聊天页显示 [去加载] |
| `loading`（加载中） | 磁盘 → 内存 | 蓝色进度环 + 模型名，UI 禁用交互 |
| `loaded`（已加载） | 可推理 | 绿色「已加载」，聊天页显示 [卸载] |
| `unloading`（卸载中） | 释放内存 | 橙色进度环 |
| `error`（错误） | 加载失败 | 红色错误信息 + [重试] |

- **存储信息直接扫描磁盘**：设置页「存储信息」按模型候选目录扫描所有 `.gguf`（含 `.mmproj` /
  `.dspark.gguf`），即使模型 ID 不在 catalog 中也能正确显示。
- **推理日志**：`inference_log_screen` 展示加载/卸载/生成全过程，并记录每次交互的性能指标（提示长度、
  历史条数、生成 token 数、**首 token 延迟**、**tok/s**、总耗时、输出字数）与上下文压缩记录；
  `tok/s` 已与 JNI 回传的真实 `n_gen` / `t_gen_ms` 对齐。

### 模型下载与管理

在 **设置 → 模型管理** 页面操作：选择模型 → [下载] → 实时进度 / 暂停·继续 · 断点续传 · [删除]（防误删
弹框），完成后 [加载到内存]。**最多同时下载 2 个模型**。

- **镜像策略**：每个模型的 `mirrors` 数组按顺序尝试，前一个失败自动切下一个（`hf-mirror` 优先，
  `ModelScope` 兜底）。
- **视觉模型下载闭环**：`type=vision` 且带 `mmproj` 的模型先下载主 `.gguf`、再自动下载投影器 `.mmproj`，
  两者完整才算「已缓存」；加载前校验完整性（存在、无残留 `.tmp`、非空），避免原生加载崩溃。
- **模型列表配置驱动**：全部模型定义维护在 `assets/models_catalog.json`，新增/调整/下架只需改这个 JSON，
  无需改代码、无需重新编译（可选把 `remoteUrl` 指向自有 CDN 实现热更新）。

> 详见 [模型列表](#模型列表)。

### 多模态：视觉理解

- **视觉**：Qwen3.5-0.8B/2B/4B、Gemma 4 E2B 等视觉模型带投影器 `mmproj`，支持单图理解；本地编码后端
  跟随主后端（Vulkan / OpenCL / CPU）。
- **API 档视觉**：接入 OpenAI 兼容端点时，图片以 base64 `image_url` content-parts 发送
  （visionCapable 门控、每步重发、8 张 FIFO 编码缓存）；未开启视觉的端点把图片剥离为
  `[图片]` 占位，绝不发送原始图数据。

### 语音输入与播报

**语音输入已于 v0.2.9 前后整体重做**：弃用「录音文件喂给带音频编码器的模型」旧方案
（覆盖面窄且慢），改为 **sherpa-onnx 端侧流式 ASR**——与模型无关、任何对话场景可用。

- **引擎**：sherpa-onnx 流式 Zipformer 中文 int8（`sherpa-onnx-streaming-zipformer-*-zh-int8`，
  ~160MB），FFI 进程内推理，**完全离线零网络依赖**（飞行模式下可验证）。模型不入 APK：
  首次长按触发下载（hf-mirror 主源 + huggingface 兜底，断点续传）。
- **交互**：微信式按住说话——长按 🎤 → 浮层「准备中」→ 实时回显 partial 识别结果 →
  上滑取消 → 松手终稿**直接发送**（自动附加输入框已有文字）。
- **热词偏置**：9 个内置分类约 290 词（智能体开发 / 端侧推理 / 本项目 / 开发调试 / 日常指令 /
  常用应用 / 手机操作 / 生活服务 / 办公学习，全部纯中文），ContextGraph 偏置 + 同音后校正；
  设置页可查看/编辑分类词表（**差量存储**：默认词表改版不顶掉用户编辑）、添加自定义热词、
  开启增强识别模式（beam search）。
- **模型管理**：设置页语音卡可查看就绪状态、下载/删除模型（释放 160MB）。

**语音播报（Edge TTS）**：

- 微软 Edge 免费 neural 语音（`speech.platform.bing.com`，免 API key，`Sec-MS-GEC` 本地 token
  鉴权；纯 Dart vendored 包 `third_party/edge_tts`）。回答气泡 🔊 按钮点按播报 / 回复后自动播报
  （设置可关）；合成/播放失败静默降级不打断聊天。
- 音色（在线拉取 300+，zh 系置顶）、语速（-50%~+100%）、音调（±50Hz）、音量（±50%）
  设置页可配 + 试听。⚠️ 免费接口实测定案：中文音色共 14 个，大陆方言仅辽宁/陕西两个女声
  （Azure 独有方言音色蹭不到）；英文音色读不出中文（混合内容建议选 Multilingual 变体）。
- 管线：markdown 清洗成可朗读文本（代码块/URL/表格符号剔除）→ 按句分段（≤600 字）→
  逐段合成（mp3 按 SHA-256 落缓存复用）→ 逐段播放。

### 远程 API 接入（OpenAI 兼容）

端侧模型之外，App 还支持接入 **OpenAI 兼容**远程端点（`{baseUrl}/chat/completions`），在「设置 → API 接入」
配置。云端大模型（GPT-4o、Qwen 系列）或自建 llama.cpp 服务（`http://127.0.0.1:8080/v1`）均可，与端侧模型
共用同一套聊天界面。

- **本地优先（Local-first）**：本地模型可用则优先本地，仅当本地不可用（未缓存 / 加载失败）才回退到激活的 API；
  若不运行本地模型且未设默认模型，则直接走 API，保证触发。
- **API 档上下文生命周期**：请求带 `stream_options.include_usage` 实测 `prompt_tokens`；溢出按响应体
  特征识别为 `contextWindowExceeded` → 走压缩 → 有界重试（不再一律终态失败）；工具结果投影剪枝
  （超长结果头尾保留、中段省略）；主动压缩预算 `agentApiContextBudget` 可配。
- **SSE 稳定性**：流间停摆看门狗（两个 chunk 之间静默超 120s 即掐断重试，UI 出重试横幅），
  彻底杜绝「无限转圈」；连接/发送超时独立可配。

### 联网搜索（端侧直连 + SearXNG 可选）

`web_search` 工具支持**两层搜索源**，按配置自动选择：

**① 端侧直连国内引擎（默认，零配置）**——纯 Dart 模块 `lib/websearch/`，不依赖任何自建服务：

- **六引擎**：必应中国（RSS 主 + HTML 兜底）、百度（`tn=json` 主 + HTML 兜底）、搜狗、360 搜索、
  夸克、中国搜索（官方 JSON）。结果自动去重合并、内嵌真实 URL 解析（302 / 页内 meta/JS 多策略）。
- **细水长流安全管控**（防引擎风控封禁）：每引擎每 10 分钟窗口请求预算（低风险档默认 6、
  高风险档 sogou/baidu/quark 默认 2，设置页可调）；超预算/被风控跳线由其余引擎覆盖；
  blocked → **指数熔断**（2min×2ⁿ 封顶 15min）+ 清 Cookie 会话 + 换池内 UA
  （UA 会话级稳定，只在换身份时换）；引擎可独立开关。
- **时效与意图**：新闻意图过滤静态页（不拿百科/攻略冒充新闻）、旧闻降权近期优先、
  空返回引擎重试、解析器抓取时间戳。

**② 自建 SearXNG 实例（可选）**——在「设置 → API 接入 → 🌐 联网搜索」配置实例地址，
**配置后自动切换走 SearXNG**；地址/密钥/引擎白名单/语言/条数/超时全配置化 + 一键测试连接 +
保存即热更新。引擎白名单决定延迟（全引擎 21s → 只留可达引擎 2.2s，自建实例实测）。

**`web_search` 工具行为**（两层搜索源共用）：

- **并发多关键词一次调用**：`additional_queries`（最多 3 个）并行搜索合并返回，一个问题的
  多个角度一次提交；
- **每回合搜索上限**（DSH `max_uses` 语义，默认 5）：达到上限拒绝联网、强制基于既有结果回答，
  杜绝端侧小模型反复搜索死循环；同内容查询直接回缓存结果不重复联网；
- **输出有预算**：按 URL 规范化去重、按相关性排序，总 1500 字截断，不挤占端侧本就不大的上下文窗口。

`get_weather` 走 `wttr.in`（路径形态请求，国内直连可用）。

### Agent 智能体（工具调用）

内置工具型智能体循环：**模型按需调用工具 → 工具真实执行并回填结果 → 模型根据结果组织最终回答**（绝不假装执行）。
**智能体模式有总开关**（设置 → 智能体 Tab 首排，输入区 🤖 图标同款）：开启 = 完整智能体循环；
关闭 = 简单聊天直连模型（无系统提示 / 工具定义 / AGENTS.md / Skills），prefill 最小，本地小模型友好；
**模式/人格切换自动重置 KV 缓存**，普通聊天绝不被大提示词污染。

#### 工具集（30+，按档位与开关注册）

- **15 个核心工具**：`get_time` / `calculator` / `todo_write` / `todo_list` / `note_take` /
  `note_list` / `unit_converter` / `memory_get` / `memory_set` / `read_file` / `write_file` /
  `edit_file` / `list_files` / `search_text` / `export_file`（产物导出到 `Download/TongYi-Lite/`）。
- **4 个可选工具**（默认关闭，设置开启）：`web_search` / `get_weather` / `shell_exec` /
  `python_exec`（嵌入式 CPython 3.11，Chaquopy 随 APK 打包，15s 超时 / 输出截断，无运行时优雅降级）。
- **系统工具**：`save_skill`（模型自主沉淀技能）/ `load_skill` / `subagent` / `ask_user_question`
  （智能体提问卡片：选项 chip / 自由回答 / 跳过）/ `run_code`（PTC 编排：脚本内 `agent_tool()`
  组合子工具调用，仅 API 档）。
- **API 档专属**：`exit_plan`（计划提交审批）/ `goal_set` / `goal_complete` / `goal_cancel` /
  `plan_step_update`（计划步骤推进）/ **MCP 远程工具**（`mcp_<server>_<名>`，Streamable HTTP
  JSON-RPC 2.0，设置页「MCP 远程工具」卡管理）。
- **Dev 工具组**（开发模式开启时注册，见 [Dev Agent 开发模式](#dev-agent-开发模式)）。
- **沙箱授权体系**：文件/命令类工具默认在 app workspace 沙盒内运行；确需访问公共目录时，模型携带
  `sandbox_permissions` + `justification` 请求升级，执行前经**用户确认框逐次批准**，拒绝不绕过。
- **必填参数校验**：工具执行前统一校验必填参数，缺失时明确列出缺失项并回填「补全后重试」。

#### 引擎架构与执行纪律

- **会话事件日志（唯一真相源）**：每个对话一本 append-only 事件日志（JSONL、`seq` 严格递增）；模型上下文是
  事件日志的**纯函数投影**；上下文压缩 = 追加摘要 + 影子遮蔽（永不删除原文）；进程崩溃后自动修复未闭合的
  turn/step/工具调用。旧 SQLite 对话一次性导入。
- **主循环 ReactLoopAgent**：显式 turn / step 状态机；失败恢复瀑布（上下文超限 → 先压缩重试；瞬态错误 →
  退避重试；其余 → 明确终止）；**Stop 立即停 turn**；流式增量 150ms 节流上屏；智能体回答附带真实 `tok/s`。
- **执行纪律九件套**（对照主流智能体差距逐项落地）：步数上限收敛注入 + **撞上限自动收尾续跑**；
  【任务执行纪律】系统提示段；`todo_write` 执行期强制（同时多个 in_progress 直接拒绝）；
  read/write/edit 工具描述加厚（先读后改、写后读回）；**回合内插话 steer**（不打断执行）；
  `ask_user_question` 提问；run_code PTC；子代理专用模型；子代理后台化 + `send_message` 续轮。
- **并行工具安全**：`isConcurrencySafe` 语义 = 默认只读可并发、副作用工具显式声明独占；
  回合中断时未完成调用合成「结果未知」占位，保证事件配对完整。
- **重复调用守护**：同一工具本回合第 3/5/8 次追加渐进提醒；同签名去重。
- **六段工具流水线**：pre-execute（allow/deny/ask 瀑布）→ guard → execute（沙箱审批 + 超时）→
  结果投影 → post-execute → 溢写（超长工具输出自动落盘、只回摘要与定位）。

#### 计划模式与无人值守

- **`/plan <任务>`**（输入框前缀或 📋 图标，仅 API 档）：只读规划回合——注册表收窄为「并行安全
  （只读）工具 + exit_plan」，模型调研后提交计划；批准即生成**结构化计划**（标题 + 步骤 + 验证方式）
  落持久目标库。
- **无人值守续跑**：批准后智能体自动逐轮推进——每轮续跑消息带增量进度（✓/◐/○/✗ + 本轮先做哪步），
  完成步骤即时 `plan_step_update` 推进；失败/中断/等待提问不续跑；轮数耗尽落提示终结
  （`agentGoalMaxRounds`，默认 8，可配 1~20）。
- **三处呈现**：对话内**计划活卡**（固定 id 消息，每次变化原位重写，不刷屏）、计划面板
  （点步骤改状态 / 放弃 / 重新规划）、输入区 📋 图标高亮。
- **任务清单（todo）按会话隔离**：`todo_write` 清单按会话落盘，对话内 ☑ 清单卡 + 计划面板同步展示。

#### 人格 / Skills / 上下文工程

- **🎭 多人格**：标准人格（行为不变）+ 用户自定义人格（设置页新增/编辑/删除，输入区 🎭 图标快速切换）；
  人设作为独立【人格设定】段注入系统提示，不覆盖工具纪律；子代理人格自动跟随。
- **Skills（内置 17 个）**：web-research / code-review / translation / writing-polish / summarize /
  data-analysis / email-draft / explain-code / plan-todo / file-report / travel-planner /
  meeting-notes / resume-polish / social-copy / shopping-compare / tutor / skill-creator（元技能）。
  正文均为 20~28 行真执行手册（工作流 + 模板 + 验收清单），`load_skill` 按需加载不占常驻 prefill。
  **用户技能**：设置页整段粘贴 SKILL.md 一键导入 / 逐字段编辑 / 另存内置技能 / 模型对话内 `save_skill`
  自主沉淀；用户同名技能（rank 200）覆盖内置。
- **上下文工程**：中文加权 token 估算器（主动压缩判断不再对中文低估 3 倍）；**回合内 LLM 摘要压缩**
  （专用便宜模型生成旧区摘要，失败/超时回退确定性摘要，压缩永不因摘要模型失败）；**存储级手动压缩**
  （占用圈详情面板入口，清出旧轮工具结果信封、最早一条原位改写为摘要，可见对话不动）；环境快照
  （时间等）从系统提示移出、按 10 分钟桶化以尾部 user 消息追加（prompt-cache 友好）；技能目录文本
  会话内冻结（不破缓存前缀）。
- **质量度量与 eval**：回合指标纯派生自事件日志（零侵入）落 `turn_metrics.jsonl`；轨迹导出
  （`agentTraceExportEnabled`）；`eval/` 12 个基线任务 + 六维离线评分（期望工具/禁用工具/终止原因/
  步数/重复上限/回答断言）。

#### 双场景档与多会话

- **双场景档**：智能体驱动模型可选**本地档**（端侧小模型）或 **API 档**（云端大模型吃满思考）；
  API 档额外注入【任务执行纪律】段、注册 API 专属工具；本地档系统提示逐字节稳定（保 KV 缓存）。
- **多会话并发**：并发会话槽位 1~4（默认 1 = 单会话串行）；API 会话可真正并行执行回合，
  本地回合因引擎单实例彼此互斥；会话抽屉「● 执行中」徽标实时可见。
- **子代理**：`subagent` 支持 `task`（单任务）/ `tasks`（2~4 个独立任务书 fan-out 并行）/ 可选
  `run_in_background`（立即返回 id，完成经系统通知投回父回合）；`send_message` 向已完成的子代理续轮；
  可指定专用 API 模型；本地档门控关闭（端侧小模型自驱收敛性差，prefill 净损失）。

### Dev Agent 开发模式

> 让智能体在真机或远端真实开发：写文件、跑命令、操作 git、管理任务计划。
> 设置 → **开发者** Tab（独立 Tab，工作区 / 连接 / 任务规划 / 安全策略集中管理）。

**工作区四级后端**（按执行环境选择，`targetSdk 34` W^X 约束下的分层设计）：

| 后端 | 说明 |
|------|------|
| `localApp` | App 沙箱内目录，文件工具直接读写 |
| `embedded`（L1 内嵌沙箱） | **`dev_shell`**：cwd 锚定工作区根，PATH 前插 `nativeLibraryDir`——APK jniLibs 内置 **busybox**（aarch64 全静态）装机即点亮全量 applet；**git 全走 JGit 6.10 进程内**（`git_status` / `git_diff` / `git_log` / `git_commit` / `git_push` / `git_clone` 浅克隆，免系统 git 二进制） |
| `termux`（L2 免 SSH） | **RUN_COMMAND intent** 直达 Termux shell（一次性配置 `allow-external-apps=true` 后零粘贴全流程）；intent 优先、SSH 回落；命令超时不回落（防重复执行副作用）；设置页可一键下载安装 Termux |
| `remotePc` | SSH（dartssh2 fork vendored）远程开发机；SFTP 文件读写 + 远程命令 |

**配置自动化**（用户只做最少操作）：

- SSH 密钥**自动生成**（ed25519）+ 一键安装命令展示 + **「自动执行」**按钮（Termux RUN_COMMAND，
  降级为复制粘贴）；用户名从共享文件自动读取；工作区远端目录自动创建；连接失败人话分类诊断
  （sshd 未运行 / 被临时拉黑 / 认证不通过 → 各自的下一步）。
- SSH 多配置管理（按工作区绑定），密钥经 **flutter_secure_storage** 安全存储
  （迁移带回读校验，防密钥丢失）；远端 `AGENTS.md`（SFTP 读取，≤64KB）自动叠加注入。

**任务与规划**：`task_create` / `task_list`（DevTask 实体，绑定工作区）+ `plan_create` / `plan_update`
/ `plan_list`（计划步骤推进）；开发者 Tab「📋 任务与规划」卡（列表 / 当前任务 / 新建规划选工作区）；
`DevContext` 自动注入工作区/计划/记忆段与开发循环指引 + 【如实报告铁律】（工具返回 error 必须如实复述）。

**安全**：危险命令黑名单 deny/ask 策略（dev_shell / ssh_exec / run_tests 全覆盖）；工具逐组开关
（git / ssh / sync / plan / task / verify 六组）；`workspace_sync` 本地镜像 ↔ 远端双向同步
（mtime 判新旧、冲突默认只报告、`.git` 恒跳过）。

### 会话与输入体验

- **标准智能体 composer 输入区**：生成中状态细条（「● 执行中 · N 个工具 · 当前工具名」+ 停止按钮）；
  附件 chips 行（图片缩略图 / 文件名 chip，单个删除）；四态主键（空闲空 = 🎤 长按说话 / 空闲有字 =
  ➤ 发送 / 生成中空 = ⏹ 停止 / 生成中有字 = ➤ 插话）；模式图标 chips（🤖 智能体开关 / 🎭 人格 /
  📋 计划 / 🧠 模型）；**会话草稿**（切会话回来打字还在）。
- **附件**：「+」底部面板统一入口（相册多图 ≤10 / 拍照 / 文件 ≤5 办公格式解析注入）；
  markdown 美化渲染 + 产物汇总卡。
- **会话抽屉**：新建主按钮 + 搜索 + 分组节（置顶/今天/昨天/7 天内/更早）+ 会话摘要行 +
  「● 执行中」徽标 + 置顶 / 重命名 / 删除。
- **消息交互**：user / assistant 气泡均有复制按钮；assistant 附带转发分享、tok/s 统计；
  回合过程总折叠区（完成后工具卡 + 思考存档收进「执行过程」，点开回看）；
  思考流式输出自动展开跟随滚动、答案开始自动闭合；**界面上同时最多一个 spinner**。
- **对话文字整体缩放**：`chatTextScale`（0.7~1.3）滑条。

---

## 模型列表

> 以下模型以 `assets/models_catalog.json` 为准（当前 **18 个**，配置驱动、JSON 增改即生效）。视觉模型
> （`vision`）含投影器 `mmproj`，总下载体积 = 主模型 + 投影器。

| 模型 | 大小 | 类型 | 最低 RAM | 标签 |
|------|------|------|---------|------|
| Qwen3.5-0.8B (MTP UD-Q4_K_XL) | 543 MB (+195 mmproj) | vision | 1 GB | MTP · 🖼️ 视觉 |
| Qwen3.5-0.8BN (Q4_0 MTP) | 497 MB | text | 1 GB | MTP · ⚡ CPU 加速 |
| Qwen3.5-2B (MTP UD-Q4_K_XL) | 1.29 GB (+637 mmproj) | vision | 2 GB | ⭐ 推荐 · MTP · 🖼️ 视觉 |
| Qwen3.5-4B (Q4_K_M MTP) | 2.4 GB (+641 mmproj) | vision | 3.5 GB | ⭐ 推荐 · MTP · 🖼️ 视觉 |
| Qwen3.5-9B (MTP UD-IQ2_M) | 3.7 GB | text | 4 GB | ⚠️ 不推荐 · 👑 限高端旗舰 |
| Ornith-1.5-9B (MTP IQ2_M) | 3.87 GB | text | 4 GB | ⚠️ 不推荐 · MTP · 👑 限高端旗舰 |
| Gemma 3 4B (Q4_K_M) | 2.6 GB | text | 3 GB | ⭐ 推荐 |
| Gemma 4 E2B (Q4_K_M) | 3.1 GB (+531 mmproj) | vision | 4 GB | ⭐ 推荐 · 🖼️ 视觉 |
| LFM 2.5 2.6B (Q4_K_M) | 1.6 GB | text | 2 GB | ⭐ 推荐 · 🤖 智能体 · ⚡ 速度快 |
| LFM 2.5 8B-A1B (UD-IQ3_XXS) | 3.1 GB | text | 4 GB | ⭐ 推荐 · 🤖 智能体 · MoE 高效 |
| Spark-X2.5 4B (Q4_K_M) | 2.4 GB | text | 4 GB | ⭐ 推荐 · 🤖 智能体 · 原生工具调用 · 百万上下文 |
| Bonsai-8B (Q1_0) | 1.2 GB | text | 2 GB | ⭐ 推荐 · 🤖 智能体 · 轻量 |
| NeoHorse-1 4B (Q4_K_M) | 2.5 GB | text | 4 GB | ⭐ 推荐 · 🤖 智能体 · 原生工具调用 |
| MiniCPM5-2B (Q4_K_M) | 1.5 GB | text | 3 GB | ⭐ 推荐 · 🤖 智能体 · 原生工具调用 · ⚡ 速度快 |
| MiniCPM5-2B (Q8_0) | 2.5 GB | text | 4 GB | ⚠️ 不推荐 · 🤖 智能体 · 原生工具调用 · 精度更高 |
| Bonsai-2 27B (PTQ1_0 1.58-bit) | 5.95 GB | text | 16 GB | ⚠️ 不推荐 · 1.58-bit · 🛡️ 需 OOM 守卫（11GB 机 GPU 加载必死机） |
| Bonsai 27B (Q1_0 1-bit) | 3.8 GB | text | 6 GB | 👑 限高端旗舰 · 探索用 |
| Bonsai 27B (Ternary 1.58-bit) | 7.2 GB | text | 10 GB | ⚠️ 不推荐 · 👑 限高端旗舰 |

**标签语义**：`⭐ 推荐`（绿）、`⚠️ 不推荐`（红，体积/内存要求过高）、`👑 限高端旗舰`（金，需大内存旗舰机）、
`🖼️ 视觉`、`⚡ CPU 加速`、`⚡ 速度快`、`🤖 智能体`、`MTP`（多 token 预测投机解码）、
`原生工具调用`（模型自带 function-calling，智能体走原生协议）。

> **语音输入与模型无关**：语音识别走 sherpa-onnx 端侧 ASR（见[语音输入与播报](#语音输入与播报)），
> 不再依赖特定模型的音频编码器（Gemma 4 E2B 的 mmproj 音频编码器在引擎层仍受支持）。

**智能体模型**（LFM 2.5 2.6B / LFM 2.5 8B-A1B / Spark-X2.5 4B / Bonsai-8B / NeoHorse-1 4B /
MiniCPM5-2B Q4/Q8）
内置 `agentCapabilities` 声明（最大上下文、推荐 `n_ctx`、默认开启工具），为端侧 Agent 场景优化；
其中 **Spark-X2.5 4B**（`maxContextTokens=1000000`）与 **NeoHorse-1 / MiniCPM5-2B**
（`nativeToolCall: true`）支持原生工具调用协议，智能体自动切换原生路线。

> 端侧 1-bit / 1.58-bit 量化（Bonsai-27B / Bonsai-2 27B）：Q1_0 / Q2_0 / PTQ1_0 体积小，但解码速度有限
> （Q1_0 约 2.7–2.9 tok/s，PTQ1_0 依赖专用 GPU 内核 + OOM 守卫），适合大上下文/探索用，日常问答优先选
> 4B 以下模型；**Bonsai-2 27B 在 11GB 内存机型上 GPU 加载会打死整机，必须开启 OOM 守卫**。

---

## 技术架构

```
┌────────────────────────────────────────────────────────────────────────────┐
│ Flutter 3.x (Material3) · Riverpod                                        │
│ lib/  screens · providers · widgets · services · models                    │
│       agent · asr · tts · websearch                                        │
│      聊天 / 设置（推理引擎·智能体·API 接入·开发者）/ 推理日志 / 模型管理       │
├────────────────────────────────────────────────────────────────────────────┤
│ ① 智能体引擎（lib/agent/）                    ② 端侧模型引擎                  │
│ ┌────────────────────────────────────────┐  ┌───────────────────────────┐  │
│ │ session/    事件日志唯一真相源          │  │ JNI 直调                  │  │
│ │            （JSONL · 压缩遮蔽不删原文） │  │ tongyilite_jni.cpp        │  │
│ │ loop/      ReactLoopAgent 主循环       │  │ └─ llama.cpp fork         │  │
│ │            （turn/step 状态机 · 失败瀑布）│  │   ├ ggml-cpu             │  │
│ │ tools/     六段工具流水线 · 沙箱审批    │  │   │   + KleidiAI dotprod │  │
│ │ builtin_tools/  15 核心 + 可选 + 系统   │  │   ├ ggml-vulkan          │  │
│ │ llm/       LlmAdapter 接缝             │  │   │   + Turnip 直载      │  │
│ │ protocol/  Prompt-JSON / 原生工具调用   │  │   ├ ggml-opencl          │  │
│ │ subagents/ spawn/fork/fan-out/后台化   │  │   │   + PTQ1_0 三元内核  │  │
│ │ skills/(17) · hooks/ · agents_md/      │  │   ├ mtmd 视觉编码        │  │
│ │ goal/ 计划·无人值守  mcp/ 远程工具      │  │   ├ 投机解码 MTP/dspark  │  │
│ │ metrics/ 回合指标  context_eng/ 压缩    │  │   └ OOM 内存守卫          │  │
│ │ dev/       Dev Agent（工作区/SSH/git）  │  └───────────────────────────┘  │
│ │ web_search/ 直连+SEARXNG · 每回合上限   │                                  │
│ └────────────────────────────────────────┘                                  │
│ ③ 语音（lib/asr sherpa-onnx 流式 ASR · lib/tts Edge TTS）                    │
│ ④ 搜索（lib/websearch 六引擎直连 · 熔断/窗口预算/UA 池）                      │
├────────────────────────────────────────────────────────────────────────────┤
│ 通信：MethodChannel（请求）+ EventChannel（流式 token 回调）· JNI 直调        │
│       无 HTTP Server · OpenAI 兼容 API 走 Dio（可选）                        │
├────────────────────────────────────────────────────────────────────────────┤
│ Android 原生层：Kotlin (InferenceService/MainActivity/DevGitPlugin) → JNI    │
│  ├─ third_party/ 全量入库：llama.cpp b11267+增强 · KleidiAI · OpenCL-Headers│
│  │   · opencl-stub · turnip 驱动 · edge_tts · dartssh2 fork（clone 即编译） │
│  ├─ Chaquopy CPython 3.11（python_exec）· JGit 6.10（进程内 git）           │
│  └─ sherpa-onnx + onnxruntime（端侧 ASR）· jniLibs 内置 busybox/libhardware │
└────────────────────────────────────────────────────────────────────────────┘
```

三大支柱：

**① 智能体引擎（`lib/agent/`）** — 事件驱动智能体（对照主流产品差距分析持续演进）：

- `session/` — **事件日志唯一真相源**：append-only JSONL（`seq` 严格递增）；模型上下文 = 日志纯函数投影；
  压缩 = 追加摘要 + 影子遮蔽（永不删原文）；崩溃自动修复未闭合 turn/step。
- `loop/` — **ReactLoopAgent 主循环**：外层 turn（用户输入 → 最终回答）/ 内层 step（一次模型请求）；
  失败瀑布（上下文超限 → 压缩重试 → 瞬态退避 → 明确终止）；可靠取消；step 级最小日志可观测。
- `tools/` — **六段工具流水线** + 沙箱审批 + 必填校验 + 并行执行（isConcurrencySafe 门控）+ 溢写落盘。
- `llm/` / `protocol/` — **`LlmAdapter` 接缝**：本地引擎 / OpenAI 兼容端点统一接口，每次调用冻结能力快照；
  协议能力驱动选择——本地档 Prompt-JSON、API 档原生工具调用（`nativeToolCall` 探测）。
- `subagents/` / `goal/` / `mcp/` / `metrics/` / `skills/` / `hooks/` / `agents_md/` / `context_eng/` —
  子代理编排、计划与无人值守、MCP 客户端、质量度量、17 内置技能、Hook 接缝（`agent/pre-step` 否决单步、
  `tools/result` 只读审计）、上下文压缩 + 输出溢写。
- `dev/` — **Dev Agent**：工作区（`workspace.dart` + `workspace_store.dart`）、SSH（`ssh/` 三件套 +
  安全存储）、三级执行工具（`tools/`：embedded 内嵌沙箱 + JGit / ssh / git / sync / plan / task /
  verify）、Termux RUN_COMMAND intent（`termux_intent.dart`）、危险命令策略（`safety.dart`）。
- `web_search/` — 直连搜索 provider 接入层（`lib/websearch/` 模块 + SearXNG 可选）。

**② 端侧模型引擎（llama.cpp b11267 + fork 增强 · JNI 直调）** — 全部推理在本机完成：

- **多后端**：ggml-cpu（+ KleidiAI dotprod）、ggml-vulkan（Adreno 825 可经 **Turnip Mesa gen8 直载**）、
  ggml-opencl（+ PTQ1_0 三元量化专用内核，Bonsai-2 27B 全 GPU decode/prefill）；启动探测 + 设置选择，
  探测不到自动回落 CPU。
- **多模态**：mtmd 视觉投影器编码（跟随主后端）。
- **投机解码**：MTP（NextN head 多 token 预测）+ dspark（整块投机），按模型独立开启。
- **OOM 内存守卫**：加载前读 `/proc/meminfo` 预检，权重 + KV 估算超可用内存 → 自动下调 `n_ctx` 或
  **拒绝加载防整机死机**（设置页可调预检/加载后余量，可旁路但风险自担）。
- **模型管理**：`assets/models_catalog.json` 配置驱动 + Dio 断点续传下载 + SQLite 对话持久化。

**③ 语音与搜索**：

- `lib/asr/` — sherpa-onnx 流式 Zipformer ASR（`sherpa_streaming_asr.dart` 单载复用——加载统一收口
  `start()` 按最终形态一次加载，杜绝每会话双载 ~9.5s）+ 按住说话会话（`hold_to_talk.dart`）+
  热词（`default_hotwords.dart` 9 类 + `hotword_corrector.dart` 同音后校正 + 差量编辑）+
  模型管理（`asr_model_manager.dart` 下载/删除）。
- `lib/tts/` — Edge TTS（`edge_tts_service.dart` 单例：合成缓存 + 分段播放 + 代次防回写 +
  音色列表）+ 文本清洗/分段纯函数（`tts_text.dart`）。
- `lib/websearch/` — 纯 Dart（仅依赖 dio）：引擎契约 + 六引擎实现 + Cookie 会话/UA 池
  （`engine_http.dart`）+ 聚合器（`multi_engine_search.dart`：加权轮转/去重/熔断/窗口预算/诊断）+
  链接解析（`link_resolver.dart`）。

### GPU / CPU 推理后端

构建时若满足依赖，APK 会同时包含 `libggml-vulkan.so`（内嵌预编译 SPIR-V 着色器）与
`libggml-opencl.so`（dlopen 转发 stub）。**是否真正用 GPU、用哪个后端，由 App 启动时探测 + 设置页选择
决定**，不靠硬编码：

- **Vulkan + OpenCL 双后端**（仅 `arm64-v8a`）：设置页「GPU 加速」开关（默认开）+ 后端选择（自动 /
  OpenCL / Vulkan）+ 「GPU 层数」滑块（默认 100 = 全量卸载，llama.cpp 自动 clamp）。`auto` 优先 OpenCL，
  探测不到对应后端时回落 CPU。
- **OpenCL（Adreno 推荐）**：骁龙 Adreno 设备上与 Vulkan 吞吐等价；依赖设备 `libOpenCL.so`，无驱动时
  探测到 0 设备自动回落 CPU，不崩溃。
- **天玑 Mali 专项**：天玑系统 `libOpenCL.so` 仅为空壳 ICD 加载器（无 Mali 驱动注册），故设置页在 MediaTek
  SoC 上把 OpenCL **置灰禁用**并提示「优先 Vulkan」。**v0.1.6 起根治天玑 Vulkan 崩溃**：Mali 驱动
  `vkGetDeviceQueue2`（Vulkan 1.2）返回坏 queue → 改用 Vulkan 1.0 的 `vkGetDeviceQueue`（3 处 patch，
  仅 ARM vendor 0x13B5 生效，真机验证通过）。Mali-G68 无矩阵加速单元，Vulkan 解码约为 CPU 的 1/3，属
  **硬件天花板**（大模型上 GPU 卸载仍省内存）。
- **KleidiAI dotprod（纯 CPU 备选）**：`GGML_CPU_ARM_ARCH=armv8.2-a+dotprod` 编译手调 matmul 内核；
  ⚠️ **不加 `+i8mm`**（天玑 Cortex-A78 无 i8mm，`armv8.4-a+dotprod+i8mm` 会 SIGILL 三后端同崩），已降级
  为 `armv8.2-a+dotprod`。
- **SME2（暂未启用）**：目标设备（骁龙 8s Gen 4）仅 1 颗大核有 SME2，异构核分派收益低、收益拐点未到
  （待全核 SME2 平台如天玑 9500）。当前保持 `dotprod`。

#### 骁龙 8s Gen 4（SM8735 / Adreno 825）Vulkan 专项

经历「原厂驱动修复 → OTA 回归弃用 → Turnip 直载 → App 进程内直载打通 → llama.cpp b11267 升级回归」五个阶段：

1. **v0.2.2（2026-09-26）原厂驱动（0800.71）修复**：E031 编译器错误编译 shader 的 `unpack8()`
   （Int8 capability）导致量化模型输出乱码，另存在 subgroup matvec 管线创建失败、图融合 kernel 输出全零、
   dp4a 数值错误、decode 部分管线建不出共 5 个独立问题。修复：shader 层用纯 32 位位操作替换 `unpack8()`
   （21 处调用点 + q8_0 反量化重写，位模式逐位等价），运行时默认注入
   `GGML_VK_NO_SUBGROUP / GGML_VK_DISABLE_FUSION / GGML_VK_NO_MMV / GGML_VK_DISABLE_INTEGER_DOT_PRODUCT=1`
   （JNI 层注入，可用 `/storage/emulated/0/TongYiLite/vk_flags.conf` 覆盖做 A/B）。
2. **OTA 回归定性（2026-09-27）**：2026-08-05 HyperOS OS3.0.305 OTA 后，7 月原味代码 + 新驱动同样拒建
   管线（OTA 时间线与公开 ROM 记录闭环实锤，Bonsai2 实现 / llama.cpp 升级均与故障无关）→ 原厂 Vulkan 弃用。
3. **v0.2.3（2026-09-27）Turnip（Mesa out-of-tree gen8）App 内直载**：免 root、不碰系统分区。该驱动不导出
   任何 `vk_*` 符号，入口是 Android Vulkan HAL 模块（`hw_module_t → vulkan_device_t`，PFN 表偏移 +0x70、
   GetInstanceProcAddr +0x88，逆向确认）；ggml-vulkan 4 处直接 C 符号调用全部改走 dispatcher，
   `GGML_VK_TURNIP=<驱动.so>` 指定直载。数值损坏三根因逐一修复：
   - ① Turnip gen8 **错编 subgroup 算术归约（subgroupAdd）**——一切含归约的算子（matmul / conv）数值错，
     tbo f32 MUL_MAT 203 case 全 FAIL → `GGML_VK_NO_SUBGROUP=1` 后 203/203 全过；
   - ② 我方 `NO_SUBGROUP` 门控有漏网——ssm_scan / gated_delta_net 管线选择直查 `device->subgroup_arithmetic`
     不走 use_subgroups 门控 → 设备能力初始化处直接置 `subgroup_arithmetic=false`，一处覆盖全部 op 级选择；
   - ③ GDN shmem butterfly 的 **S_V=128 lanes 配置错编**（clustered LANES=8 / 全宽 128 均坏）→
     `!subgroup_arithmetic` 时 lanes 钳 64（与已验证的 S_V=64 布局同构）。
   - 验收：tbo GATED_DELTA_NET 36/36、SSM_SCAN 12/12，LFM2.5-2.6B 短生成 5/5 连贯（6~10.6 t/s）、
     n=96 长生成连贯、Qwen3.5-4B 连贯（5.0 t/s，修复前 `?111.111` 乱码）。
4. **v0.2.8（2026-09-29）App 进程内直载打通**：turnip 的 DT_NEEDED 含系统 HAL 库 `libhardware.so`，
   而 App classloader 命名空间无法 dlopen 系统 HAL 库 → Vulkan 全败、回落 CPU。修复：APK 内置极简
   `libhardware.so` stub（仅导出 `hw_get_module` 返回 -ENOENT，推理不走 gralloc 路径故安全），
   dlopen turnip 依赖解析命中 stub → 加载成功。验收铁证：logcat `using Vulkan HAL GetInstanceProcAddr
   from .../libturnip_freedreno.so` + `Found 1 Vulkan devices: Adreno (TM) 825 (turnip Mesa driver)` +
   `backend_ptrs.size()=2` + `loadModel result: true`。
5. **v0.2.8 后续（2026-09-30）llama.cpp b11267 升级 Vulkan 回归修复**：升级到上游
   `b11267`（0.5.0）后 Vulkan 全模型转圈/空输出（三层根因逐一移植修复）：
   - ① 上游移除 `GGML_VK_TURNIP` env → 移植 fork 的 turnip HAL 直载（dlopen + dlsym
     ICD→HAL，HAL 偏移 0x70 PFN 表，`GGML_VK_TURNIP` env 触发）；
   - ② 上游移除 `GGML_VK_NO_SUBGROUP` / `GGML_VK_NO_MMV` → 移植两 env
     （use_subgroups / ggml_vk_should_use_mmvq 首部检查）；
   - ③ b11267 混用裸 Vulkan C 函数（系统 loader 符号）→ turnip device 传入系统函数
     SIGSEGV 启动崩溃 → **11 处裸调用全部 dispatcher 化**
     （`vkGetPhysicalDeviceFeatures2` ×3 / `vkGetInstanceProcAddr` ×7 /
     `vkGetDeviceProcAddr` ×1 → `ggml_vk_default_dispatcher()`）。
   - **升级后新坑提示**：b11267 大重写后混用系统 loader 符号，裸 Vulkan 函数必须
     dispatcher 化；下次动 Vulkan 先查这类。
6. **当前定位**：Turnip 直载在 App 内**已可用**（libturnip_freedreno.so + libhardware.so stub 已入库），
   Adreno 825 日常 GPU 推理默认仍走 OpenCL（吞吐等价、无 Turnip 遗留项）；CONV_2D f32 / FA hsk=192
   为 Turnip 独立勘探遗留，不影响主链路。

> 完整根因链与修复记录：[`docs/vulkan_adreno825_fix_2026-09-26.md`](docs/vulkan_adreno825_fix_2026-09-26.md)。

#### OpenCL PTQ1_0 三元量化内核（Bonsai-2 27B，v0.2.5 / v0.2.6 补齐 prefill）

- Bonsai-2 27B 全模型 402 个 PTQ1_0 张量（GGML `type 143`，-1/0/1 三元，28 B/128 值）；上游 OpenCL 后端
  只有 Q4/Q5/Q8 系列 mul_mv 内核 → 此前全部回退 CPU、decode 极慢。新增
  `mul_mv_ptq1_0_f32.cl`（Adreno 64-wide subgroup、2 trit/lane、subgroup 归约）实现全 GPU decode。
- **v0.2.6 补齐 prefill GEMM**：新增 `mul_mm_ptq1_0_f32_l4_lm.cl`（BM64/BN64/BK32 分块，raw 块布局
  逐元素 staged 三进制解码，BK=32 整除 QK=128 故 K-tile 永不跨量化块）。此前 prefill（n>1）掉进
  逐行 matvec 反复发射路径——桌面 Arc 140T 实测 pp128 **1.14 → 18.89 t/s（16.5×）**；桌面 OpenCL
  数值 tbo 174/174。
- **根治 Adreno OpenCL 编译器对 `__constant` 数组变址的误编**（`pow3[4]` 恒读 0 → 每块 16 trit 全解成 -1，
  数据正确但内积系统性偏差）：弃用 `__constant` 数组索引，改三元表达式。
  ⚠️ 同类坑：Adreno CL 编译器把 `half` 当类型关键字，**不能当变量名**（clBuildProgram err=-11）。
- 真机 `test-backend-ops` MUL_MAT PTQ1_0 套件 **174/174 通过**（含 67 个奇数尾行与 Bonsai 形状）。

> 块结构 / 编码 / 解码 / 内核并行 / Adreno 陷阱定位过程：
> [`docs/ptq1_0_opencl_bonsai2_2026-09-27.md`](docs/ptq1_0_opencl_bonsai2_2026-09-27.md)。
> 双驱动真机验证矩阵（原厂 0800.71 / fork Turnip × 三药；FWHT 门控与 GEMM 大 n 错编定案）：
> [`docs/vulkan_bonsai2_turnip_verify_2026-09-28.md`](docs/vulkan_bonsai2_turnip_verify_2026-09-28.md)。

**验证 CPU 内核是否生效**（编译后查 `compile_commands.json`）：

```bash
grep -c "kai_matmul.*dotprod" android/app/.cxx/Debug/*/arm64-v8a/compile_commands.json   # >0
grep -c "kai_matmul.*i8mm"    android/app/.cxx/Debug/*/arm64-v8a/compile_commands.json    # 预期 0（已禁用）
```

**验证是否真的上了 GPU**（连上设备后）：

```bash
adb logcat -c
adb shell am start -n com.dgxspark.tongyilite/.MainActivity
adb logcat | grep -iE "TongYiLite|ggml_vulkan|OpenCL"
```

> 完整踩坑记录（多轮乱码根因、flash attention 陷阱、量化 GEMM bug 等）见 [版本更新](#版本更新) 与
> [`docs/archive/backend_benchmark_2026-08-04.md`](docs/archive/backend_benchmark_2026-08-04.md)。

---

## 构建与开发

### 前置环境

| 工具 | 版本 | 用途 |
|------|------|------|
| Flutter SDK | 3.x（Dart 3.6+） | Flutter 构建 |
| Android SDK | 34+ (compileSdk 36) | Android 构建 |
| Android NDK | r27 (27.0.12077973) | C++ 原生编译 |
| CMake | 3.22.1 | `CMakeLists.txt` + Gradle `externalNativeBuild` |
| Java JDK | 17 | Gradle / Kotlin（项目 Kotlin 1.9.22） |

> 重量级原生依赖（均随 APK/构建链处理）：Chaquopy 17（CPython 3.11，`python_exec`）、
> JGit 6.10（进程内 git，Dev Agent）、sherpa-onnx + onnxruntime（端侧 ASR，release 包体 +~18MB）、
> flutter_secure_storage（SSH 密钥安全存储）、background_downloader（ASR 模型下载）。

### 构建要点

- **glslc 锁定 shaderc v2026.3**（开发机本地 `_study/vkcli/sdk/vksdk-new`，不入库）：CMakeLists 的
  `Vulkan_GLSLC_EXECUTABLE` 强制覆盖，shader 变更后必须重编。
- **Debug 也强制 `-O3 -DNDEBUG`**：Android debug 默认 `-O0` 会让量化 matmul 内核失去优化（曾导致全模型
  ~1.2 tok/s）。⚠️ 仅设 `CMAKE_C_FLAGS_DEBUG` 不够——NDK 工具链会静默顶掉，正确做法是 NDK 覆盖不了的目录级
  `add_compile_options(-O3)` + `add_compile_definitions(NDEBUG)`。
- **改 CMakeLists / 工具链后必须清 `.cxx` 缓存**（`Remove-Item -LiteralPath 'android\app\.cxx' -Recurse -Force`），
  否则 Gradle 判定 up-to-date 不重编。
- **合并/checkout 带来 native（cpp/CMake）改动时**：gradle 的 up-to-date 判定信任 mtime，
  git 操作不保证 mtime 前进 → APK 里 `.so` 可能是旧版。构建后必须字符串级验证 APK 内
  `libtongyilite_jni.so` 含新增日志串/字段名（`touch` 源文件强制重编）。
- **回归防线**：动智能体循环/协议先跑 `flutter test test/agent`；全量 `flutter test` 当前
  **600 余项 + 4 skip**（test/agent · providers · services · websearch · asr · tts）。

---

## 版本更新

> 版本历史依据 git 提交维护，详细变更见 [`CHANGELOG.md`](CHANGELOG.md)。
> ⚠️ 引擎版本口径：当前 `third_party/llama.cpp` 为 **上游 `b11267`（0.5.0）+ fork 增强树**
> （fe8156f → b11267 一步到位升级，commit `0909603`，保留全部 fork 资产：dspark/spark2_5、
> PTQ1_0 内核、FWHT、Turnip 直载、KleidiAI vendored、MTP）。

| 版本 | 日期 | 要点 |
|------|------|------|
| **v0.2.9**（当前） | 2026-10-06 | **🔊 Edge 在线 TTS 语音播报**（免费无 key，气泡 🔊 点按 / 自动播报，音色/语速/音调/音量可配 + 试听，markdown 清洗 + 按句分段流式播放）+ **输入框圆形上下文占用圈**（点开详情面板：占用数字 / 会话快照 / 压缩记录）+ **存储级手动压缩**（清理旧工具轮结果存摘要，保留最近一轮与全部对话文本）+ **任务清单按会话隔离**（todo v3，旧全局清单一次性迁移）+ SSE 停摆看门狗 / git_clone 修复 / 消息复制按钮 / 计划精简呈现 / KV 占用全链路修复。versionCode 17 |
| **v0.2.8** | 2026-09-29 | **智能体执行顺序渲染 + 思考流式自动展开 + 空响应重试 + 思考泄漏修复**；**Vulkan 全败定案**（turnip dlopen 缺 `libhardware.so` → jniLibs stub 复活，App 内直载打通）；**web_search 并发多关键词一次调用** + **每回合搜索上限**（DSH `max_uses` 语义，杜绝反复搜索死循环）；智能体回答补 **tok/s 指标**；思考流式自动滚动到底。versionCode 16。**2026-09-30 补丁（`0909603`）**：llama.cpp **fe8156f → 上游 `b11267`（0.5.0）一步到位升级**（保留全部 fork 资产）+ **Vulkan 回归修复**（turnip 直载移植 / NO_SUBGROUP·NO_MMV 移植 / 11 处裸 Vulkan 调用 dispatcher 化）；**Bonsai-2 27B OOM 守卫定案**（11GB 机 GPU 加载物理不可能，旁路必死机/崩溃，宁拒绝不死机） |
| **v0.2.7** | 2026-09-29 | **API 视觉接通 + 思考流单独展示 + 工具卡紧凑化**：分支停维护、主干统一（spike 快进合并进 main）；API 路线 `image_url` parts 视觉；思考流独立流式卡（自动展开跟随滚动）；工具卡改单行紧凑行；llama.cpp 主仓树 = spike 完整树（fe8156f 基线），废弃 b11028 半升级方向 |
| **v0.2.6** | 2026-09-28 | **Bonsai-2 双后端补齐 + Turnip 错编双定案**：① OpenCL 补 PTQ1_0 prefill GEMM（桌面 Arc 140T pp128 1.14→18.89 t/s，16.5×）；② Vulkan FWHT subgroup 变体并入三药门控；③ Turnip e2e 乱码根因定案（GEMM 大 n ≥48 编译器错编——App 靠 JNI `n_ubatch=16` 天然避开，`n_ubatch≤32` 为 Turnip 正确性边界）；④ tbo 增补 hadamard/PTQ1_0 大 batch 用例防回归；⑤ 双驱动真机全矩阵验证 |
| **v0.2.5** | 2026-09-27 | **OpenCL 后端支持 PTQ1_0 三元量化（Bonsai-2 27B）**：新增 `mul_mv_ptq1_0_f32.cl`（Adreno 64-wide subgroup、2 trit/lane、subgroup 归约），402 个 PTQ1_0 张量 decode 全 GPU；Adreno `__constant` 数组误编根因定位与修复；真机 174/174 通过 |
| **v0.2.4** | 2026-09-27 | **智能体"迭代一两下就停 / 没正确结果"根治**：① 工具调用块被 token 预算截断 → 静默降级成普通回答（主因）→ 截断三分类 + 自动补全 + 有界重试；② 失败轮回溯历史旧答案冒充本轮回复 → 只取本轮 append；③ system 落在消息中段 → OpenAI 兼容服务端 400 → 恒置队首；思考失控守卫 + 天气工具 wttr.in 路径形态修复 |
| **v0.2.3** | 2026-09-27 | **Vulkan 在 Adreno 825 重新可用（Turnip 直载）**：原厂 0800.71 驱动 OTA 回归实锤后，切换 Mesa out-of-tree gen8 Turnip App 内直载（Vulkan HAL 入口逆向 + ggml-vulkan dispatcher 化）；数值三根因修复——subgroupAdd 错编全局门控、GDN S_V=128 lanes 钳 64；tbo GDN 36/36 + SSM_SCAN 12/12，LFM2.5 / Qwen3.5 e2e 连贯（5~11 t/s） |
| **v0.2.2** | 2026-09-26 | **Vulkan / Adreno 825（8 Elite2）乱码与崩溃根治**：驱动 0800.71 错编 `unpack8()`（Int8）→ shader 层纯 32 位替换（21 处调用点）；subgroup matvec 管线失败 / 图融合全零 / dp4a 数值错 / decode 管线缺失 → 4 个 env 开关默认注入（vk_flags.conf 可覆盖） |
| **v0.2.1** | 2026-09-26 | **智能体引擎全面升级**：事件日志上下文（压缩不丢原文、崩溃自动修复）+ 主循环失败自动恢复 / 可靠停止 + 六段工具流水线（审批 / guard / 溢写 / 并行）+ **子代理**（spawn/fork）+ Skills / Hooks / `AGENTS.md` 指令文件 + 活动面板 UI；**联网搜索全面配置化**（SearXNG 自配 + 测试连接 + 保存即热更新）；llama.cpp 升级 b11028（后废弃回退）；移除启动加载页。**229 项单测全绿** |
| **v0.2.0** | 2026-09-04 | Agent Lite 智能体（工具循环 + 18 工具 + 沙箱授权）、`python_exec`（Chaquopy 17 / CPython 3.11）、MTP 投机解码、远程 API 接入、智能体每轮性能统计 + 长期记忆、代码质量 P0 加固 |
| v0.1.6 | 2026-08-19 | llama.cpp 升级上游 master（`fe8156f`）、天玑 Mali Vulkan 崩溃根治、mmproj 视觉编码后端跟随主后端、天玑 OpenCL 置灰、Gradle 16 核并行 |
| v0.1.3 | 2026-08-04 | 多轮对话正确性修复（KV 缓存跨轮残留等根因）、`tok/s` 口径对齐、`n_ubatch` 按后端动态、助手复制 / 自定义模型名 / 加载进度弹窗 |
| v0.1.2 | 2026-08-03 | 量化 GEMM 路径 / 重复惩罚失效 / flash attention CPU 陷阱修复 |
| v0.1.1 | 2026-08-03 | Vulkan GPU 加速（arm64-v8a）、模型下载系统、设置页 UI、对话 SQLite 持久化 |
| v0.1.0 | 2025-07-29 | 端侧 LLM 推理引擎（llama.cpp）、Flutter Material3 前端、架构设计文档 v2 |

> **v0.2.9 之后的主干演进**（同 versionName 复用策略，详见 CHANGELOG 与 git log）：多会话并发槽位、
> PDF 原生解析（PdfBox）、Dev Agent 全链路（工作区/SSH/JGit/Termux）、执行质量九件套、端侧直连搜索、
> 智能体人格系统、技能库 17 个、规划系统（task/plan）、执行质量全面提升（指标/eval/计划模式/goal/MCP/
> LLM 压缩/并行安全/fan-out）、composer 输入区重构、sherpa-onnx 端侧语音、KV 占用圈/手动压缩、
> Edge TTS——以上均已合入 main 并双真机（小米 13 / 8 Elite）验证。

**下载**（release 签名 `CN=TongYiLite`，Android 13+，arm64-v8a）：

> [⬇️ 下载 `TongYi-Lite-v0.2.9.apk`](https://github.com/liangjianzeng/TongYi-Lite/raw/main/releases/TongYi-Lite-v0.2.9.apk)
> v0.2.9+17 · 71,169,325 B（2026-10-08，含长截图切块与包体瘦身 -14.3MB）
> `SHA-256: e32ac17f949c0e8ceb67cc34e795a06f29417e4dce774a1532dd262415894b83`

> ⚠️ 覆盖安装请用同一签名证书（`CN=TongYiLite`），并保持 versionCode ≥ 已装版本；`adb install -r`
> 可保留已下载模型缓存，切勿先卸载。后续版本发布流程：构建产物拷入 `releases/` 并在此更新链接与 SHA-256。

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

国内网络访问 Google CDN 不稳定。已在 `pluginManagement.repositories` 和 `allprojects.repositories`
添加阿里云镜像：`https://maven.aliyun.com/repository/google` / `public` / `gradle-plugin`。
注意 **JGit 无 aliyun 镜像**，走 repo.maven.apache.org。

</details>

<details>
<summary><b>Q: CMake 找不到 llama.cpp / 路径错误</b></summary>

`CMakeLists.txt` 从 `android/app/src/main/cpp/` 到项目根目录需要 **5 层** `../`。当前配置已验证通过：

```cmake
set(PROJECT_ROOT_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../../../../../../..)
```

</details>

<details>
<summary><b>Q: 如何启用 / 排查 Vulkan GPU 加速？</b></summary>

Vulkan 后端**默认已对 arm64-v8a 启用**（只要构建主机满足依赖）。排查步骤：

1. 确认 LunarG Vulkan SDK 已安装（提供 `glslc` + `SPIRV-Headers` + `<vulkan/vulkan.hpp>`）。
2. 确认 MinGW-w64 可用（`vulkan-shaders-gen` 主机工具需要它预编译着色器）。
3. 改了 CMakeLists / 工具链后**必须清 `.cxx` 缓存**，否则 Gradle 判定 up-to-date 不重编：
   `Remove-Item -LiteralPath 'android\app\.cxx' -Recurse -Force`
4. 运行时 `adb logcat | grep -iE "TongYiLite|ggml_vulkan"`，看 `ggml backend devices` 与 `n_gpu_layers`。

</details>

<details>
<summary><b>Q: 智能体说「沙箱没有 git」？</b></summary>

这是环境事实，分三层：**本地沙箱**（`shell_exec` 跑 app 权限 `sh -c`）永远没有 git 二进制
（Android /system/bin 无 git，W^X 下也不能 exec 任意二进制）——非 Dev 回合里"仅要代码"走 HTTP
（GitHub API + raw）是正确降级。**真 git 在 Dev 工具组**：设置 → 开发者 → 开发模式开启后，
embedded 后端走 JGit 进程内 git（git_clone/commit/push 等），Termux/远程 PC 走系统 git。
**计划模式（/plan）**注册表收窄为只读工具，副作用类（git_clone 等）被禁属设计如此。

</details>

<details>
<summary><b>Q: 语音识别没反应 / 无转写？</b></summary>

1. 首次使用需下载 ASR 模型（~160MB，设置 → 智能体 → 语音输入卡可查看状态）。
2. 长按 🎤 需保持 1 秒以上——单击只弹提示。第一次会话「准备中」约 5s（引擎加载），后续会话瞬时启动。
3. 若浮层有回显但松手后没文字：检查 MIUI 麦克风权限 / 是否被其他应用占用（如相机）。
4. 识别准确率不满意：设置页开启「增强识别模式」、配置热词（支持自定义词表，同音自动校正）。

</details>

<details>
<summary><b>Q: TTS 有些音色不出声？</b></summary>

Edge 免费接口的服务端行为：非 Multilingual 的英文音色读中文一律返回空音频（英文正常）；
大陆方言音色仅辽宁/陕西两个女声。混合语言内容建议选 Multilingual 变体。中文回复配英文音色
自动播报无声属固有限制。

</details>

<details>
<summary><b>Q: 推理速度慢 / 内存溢出</b></summary>

- 使用更小的模型；关闭后台应用释放 RAM；设备需 ≥ 4GB RAM 才能流畅运行 2B 级模型。
- 确保 Vulkan GPU 加速已启用（设置页显示「已完成」）。
- 已优化：批量 prefill + unified KV、内置采样器（消除每 token 150k+ 堆分配）、流式回调批量化、
  mmap 加载、线程按 CPU 拓扑取核。
- 大体积 GPU 模型（如 Bonsai-2 27B）受 OOM 守卫保护：可用内存不足时自动降 ctx 或拒绝加载
  （防整机死机），旁路开关在设置 → 推理引擎，**11GB 机型不建议旁路**。

</details>

<details>
<summary><b>Q: 模型下载失败 / 速度慢</b></summary>

- 应用会自动尝试多个镜像源，无需手动切换。
- 支持断点续传：中断后点击「继续」即可从断点恢复。
- 如所有镜像均不可用，请检查网络连接或开启代理。

</details>

---

## 贡献指南

欢迎提交 Issue 和 Pull Request！请先阅读 [CONTRIBUTING.md](CONTRIBUTING.md)。

相关设计文档：

- [`docs/BUILD_AND_DEBUG_GUIDE.md`](docs/BUILD_AND_DEBUG_GUIDE.md) — 编译与调试指南
- [`docs/BUILD_ENV_NOTES.md`](docs/BUILD_ENV_NOTES.md) — 本机打包构建环境备忘（快速构建）
- [`docs/archive/architecture_design_v2.md`](docs/archive/architecture_design_v2.md) — 架构设计 v2
- [`docs/archive/backend_benchmark_2026-08-04.md`](docs/archive/backend_benchmark_2026-08-04.md) — 三后端实测专报
- [`docs/agent_light_design.md`](docs/agent_light_design.md) — Agent Lite 设计
- [`docs/dsh_gap_analysis_2026-10-01.md`](docs/dsh_gap_analysis_2026-10-01.md) — 智能体能力差距分析（对齐路线图）
- [`docs/vulkan_adreno825_fix_2026-09-26.md`](docs/vulkan_adreno825_fix_2026-09-26.md) — Adreno 825 Vulkan 修复全记录（v0.2.2 / v0.2.3）
- [`docs/ptq1_0_opencl_bonsai2_2026-09-27.md`](docs/ptq1_0_opencl_bonsai2_2026-09-27.md) — PTQ1_0 OpenCL 内核实现机制（v0.2.5）
- [`docs/bonsai2_opencl_oom_2026-09-27.md`](docs/bonsai2_opencl_oom_2026-09-27.md) — Bonsai-2 OpenCL OOM 整机死机定案与守卫
- [`docs/vulkan_bonsai2_turnip_verify_2026-09-28.md`](docs/vulkan_bonsai2_turnip_verify_2026-09-28.md) — 双驱动真机验证矩阵（v0.2.6）
- [`docs/opencl_hadamard_fwht_handoff_2026-09-28.md`](docs/opencl_hadamard_fwht_handoff_2026-09-28.md) — OpenCL FWHT（hadamard）实现交接
- [`docs/llama_cpp_upgrade_plan_b11267.md`](docs/llama_cpp_upgrade_plan_b11267.md) — llama.cpp b11267 升级计划与四道门验收记录（`0909603`）
- [`docs/websearch_direct_2026-10-02.md`](docs/websearch_direct_2026-10-02.md) — 端侧直连搜索引擎模块（实测证据/引擎坑速查，动搜索模块先读）
- [`docs/ssh_agent_environment_2026-10-01.md`](docs/ssh_agent_environment_2026-10-01.md) — Dev Agent 执行环境评估
- [`docs/ai_dev_agent_design_2026-10-01.md`](docs/ai_dev_agent_design_2026-10-01.md) — Dev Agent 设计与实施记录
- [`docs/termux_integration_plan_2026-10-04.md`](docs/termux_integration_plan_2026-10-04.md) — 三级执行环境（L0/L1/L2）施工方案
- [`docs/dartssh2_termux_pitfalls_2026-10-01.md`](docs/dartssh2_termux_pitfalls_2026-10-01.md) — dartssh2 / SshKeyGen / Termux sshd 全部坑点（SSH 排障先读）
- [`docs/python_support.md`](docs/python_support.md) — `python_exec` 支持说明

---

## License

[MIT](LICENSE) — 自由使用、修改和分发。
