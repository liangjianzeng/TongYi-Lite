# TongYi-Lite 端侧离线 AI 智能体

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![v0.2.6](https://img.shields.io/badge/v0.2.6-8B5CF6)]
[![Flutter](https://img.shields.io/badge/Flutter-3.x-02569B?logo=flutter)](https://flutter.dev)
[![Android](https://img.shields.io/badge/Android-33+-3DDC84?logo=android)](https://developer.android.com)
[![llama.cpp](https://img.shields.io/badge/Engine-llama.cpp%20fork-red)](https://github.com/ggerganov/llama.cpp)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](CONTRIBUTING.md)

> **端到端离线的 Android AI 助手。** 本地模型推理（llama.cpp b11028）· Vulkan / OpenCL GPU 加速 + KleidiAI
> CPU 加速 · 应用内模型下载与管理 · **新一代 Agent 智能体**（事件日志架构 · 工具流水线 · 子代理 ·
> Skills/Hooks）· OpenAI 兼容远程模型
>
> **数据不出设备，隐私安全无忧。**

---

## 目录

- [功能概览](#功能概览)
- [快速开始](#快速开始)
- [应用功能](#应用功能)
- [模型列表](#模型列表)
- [技术架构](#技术架构)
- [构建与开发](#构建与开发)
- [版本更新](#版本更新)
- [常见问题](#常见问题)
- [贡献指南](#贡献指南)
- [License](#license)

---

## 功能概览

TongYi-Lite 是一个**纯端侧、可离线运行**的 Android AI 应用：模型权重完全本地推理，网络请求仅用于
下载模型与可选的联网搜索/天气，**对话数据不出设备**。

| 能力 | 说明 |
|------|------|
| **本地端侧推理** | llama.cpp JNI 直调（无 HTTP Server），mmap 加载、批量 prefill、内置采样器；纯 CPU 也可跑，数据零外传 |
| **GPU / CPU 加速** | Vulkan + OpenCL 双 GPU 后端（运行时自动探测 + 手动选择）+ KleidiAI dotprod CPU 内核；Adreno 825 上 Vulkan 经 **Turnip（Mesa gen8）直载** 重新可用（详见[技术架构](#技术架构)） |
| **模型下载与管理** | 应用内下载（hf-mirror / ModelScope 镜像自动回退 + HTTP Range 断点续传）、加载/卸载、单模型约束、存储信息扫描 |
| **多模态（视觉 + 语音）** | Qwen3.5 / Gemma 4 视觉模型（`.gguf` + `mmproj` 两文件闭环下载）；Gemma 4 E2B 自带原生语音编码器，支持**按住说话** |
| **远程 API 接入** | OpenAI 兼容 `{baseUrl}/chat/completions`（云端大模型或自建 llama.cpp 服务），本地优先、API 后备 |
| **联网搜索（自建实例）** | `web_search` / `get_weather` 走**用户自己部署的 SearXNG**，全配置化 + 一键测试连接；App **不预置任何搜索服务** |
| **Agent 智能体（工具调用）** | 事件日志上下文引擎 + 失败自动恢复主循环 + 六段工具流水线 + **子代理**（spawn/fork）+ Skills/Hooks/`AGENTS.md`；18 个内置工具，沙箱授权 + 逐次审批 |
| **MTP 投机解码** | 部分模型支持多 token 预测（Multi-Token Prediction），设置页按模型单独开启 |
| **智能体可配置** | 循环轮次 / 每轮预算 / 工具超时 / 联网源 / 按模型开关特定工具，全部持久化；支持原生工具调用能力探测（`nativeToolCall`） |

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

> ✅ **三方依赖已全部直接入库**：llama.cpp（XHToken 官方 fork，`spark2_5` 架构 + function-calling）、
> KleidiAI（v1.24.0）、OpenCL-Headers、opencl-stub 源码都在 `third_party/` 下，clone 后即可编译，
> 不再需要 `git submodule update --init --recursive`。

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

- **存储信息直接扫描磁盘**：设置页「存储信息」直接扫描 `models/` 下所有 `.gguf`，即使模型 ID 不在
  catalog 中也能正确显示（避免重装 APK 后已下载模型消失）。
- **推理日志**：`inference_log_screen` 展示加载/卸载/生成全过程，并记录每次交互的性能指标（提示长度、
  历史条数、生成 token 数、**首 token 延迟**、**tok/s**、总耗时、输出字数）；`tok/s` 已与 JNI 回传的
  真实 `n_gen` / `t_gen_ms` 对齐。

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

### 多模态：视觉 + 语音

- **视觉**：Qwen3.5-0.8B/2B/4B、Gemma 4 E2B 等视觉模型带投影器 `mmproj`，支持单图理解；编码后端跟随
  主后端（Vulkan / OpenCL / CPU）。
- **语音（按住说话）**：聊天输入区长按麦克风录音，松开即发送；由 mmproj 自带的原生语音编码器理解（仅对
  带 🎧 语音能力的模型如 Gemma 4 E2B 开放）。`RECORD_AUDIO` 权限不足时引导前往系统设置；JNI 加载时用
  `mtmd_support_audio` 探测语音编码器，无编码器的模型自动禁用麦克风。

### 远程 API 接入（OpenAI 兼容）

端侧模型之外，App 还支持接入 **OpenAI 兼容**远程端点（`{baseUrl}/chat/completions`），在「设置 → API 接入」
配置。云端大模型（GPT-4o、Qwen 系列）或自建 llama.cpp 服务（`http://127.0.0.1:8080/v1`）均可，与端侧模型
共用同一套聊天界面。

- **本地优先（Local-first）**：本地模型可用则优先本地，仅当本地不可用（未缓存 / 加载失败）才回退到激活的 API；
  若不运行本地模型且未设默认模型，则直接走 API，保证触发。
- **视觉处理**：开启视觉的端点以 OpenAI content-parts（base64 `image_url`）发送带图消息；未开启的端点把
  图片剥离为纯文本 `[图片]` 占位，绝不发送原始图数据。
- 配置明文保存在与本地推理设置同一个 settings JSON 里（`lib/models/api_model.dart`），适合本地个人使用。

### 联网搜索（SearXNG 自建实例）

`web_search` / `get_weather` 走**你自己部署的 [SearXNG](https://docs.searxng.org/) 实例**，在
**「设置 → API 接入 → 🌐 联网搜索」**配置。App **不预置任何搜索实例**（不内置第三方搜索地址、
也不内置别人的服务器），地址留空就是"未配置"，`web_search` 会直接回明确诊断并指向这个设置页。

| 配置项 | 说明 |
|--------|------|
| 实例地址 | 手机能直接访问即可（局域网 IP、Tailscale 地址、https 域名均可）；`/search` 路径自动补 |
| API Key | 仅私有实例需要（以 `Bearer` 发送）；用 http 明文传密钥到非回环地址时界面会告警 |
| 引擎白名单 | 留空 = 实例全部引擎。**实例上存在访问不到的引擎时，把可达引擎填进来可把搜索从二十秒级降到秒级**（自建实例实测 21s → 2.2s） |
| 语言 / 最多条数 / 超时 | 数字项保存后回显真正生效的值（自动夹紧到合法区间） |
| 测试连接 | 用输入框里的当前内容（无需先保存）打一次真实搜索，回显条数、耗时与具体失败原因 |

- **保存即生效**：每项保存后立刻热更新搜索 provider（配置未变则复用实例，不打断连接池），改地址无需重启。
- **失败可诊断**：HTTP 状态码 / 实例未开 `format=json` / 引擎白名单被拒 / 连接被拒（含系统错误码）
  分别给出对应原因与下一步，不再统一显示"不可达"。
- **给模型的输出有预算**：结果按 URL 规范化去重、按相关性排序，单条摘要 200 字、总 1500 字截断，
  不挤占端侧本就不大的上下文窗口。
- 实例侧只需在 `settings.yml` 的 `search.formats` 里加上 `json`。

### Agent 智能体（工具调用）

内置工具型智能体循环：**模型按需调用工具 → 工具真实执行并回填结果 → 模型根据结果组织最终回答**（绝不假装执行）。

- **18 个内置工具**：核心（`get_time` / `calculator` / `todo_write` / `todo_list` / `note_take` /
  `note_list` / `unit_converter` / `memory` / `read_file` / `write_file` / `edit_file` / `list_files` /
  `search_text`）+ 可选（`web_search` / `get_weather` / `shell_exec` / `python_exec`，默认关闭，设置开启）。
- **`shell_exec`**：执行 shell 命令（app 沙盒内）。
- **`python_exec`**：嵌入式 CPython 3.11（Chaquopy 17.0.0，`libpython3.11.so` 随 APK 打包），`agent_runner.py`
  经 MethodChannel 执行脚本，15s 超时 / 输出截断；无运行时优雅降级为明确错误。
- **沙箱授权体系**：文件/命令类工具默认在 app workspace 沙盒内运行；确需访问公共目录时，模型携带
  `sandbox_permissions` + `justification` 请求升级，循环执行前经**用户确认框逐次批准**（allowed-once），
  拒绝不绕过。
- **必填参数校验**：工具执行前统一校验必填参数，缺失时明确列出缺失项并回填「补全后重试」；工具清单渲染
  带必填参数提示（如 `shell_exec（必填: command）`）。
- **设置页「智能体」Tab**：驱动模型选择（本地/API/跟随默认）、总开关、循环轮次/每轮预算（默认 512，
  最大 16k）/工具超时全部可调并持久化（按模型 `agentToolsByModel`）；联网搜索工具在此开关，
  **其实例地址在「API 接入」页配置**（见[联网搜索](#联网搜索searxng-自建实例)）。

#### 智能体引擎（v0.2.1 升级）

上下文以**事件日志**为唯一真相源、主循环带失败自动恢复与可靠停止、工具执行走六段流水线，
并新增**子代理**、Skills / Hooks / `AGENTS.md` 指令文件与活动面板 UI。

- **会话事件日志（唯一真相源）**：每个对话一本 append-only 事件日志（JSONL、`seq` 严格递增）；模型上下文是
  事件日志的**纯函数投影**（"模型看到的 = 日志能重建的"）；上下文压缩 = 追加摘要 + 影子遮蔽（永不删除原文）；
  进程崩溃后自动修复未闭合的 turn/step/工具调用（合成"结果未知"回执）。旧 SQLite 对话一次性导入，标记来源。
- **主循环 ReactLoopAgent**：显式 turn / step / phase 状态机；失败恢复瀑布（上下文超限 → 先压缩重试；
  瞬态错误 → 退避重试；其余 → 明确终止）；**Stop 立即停 turn、UI 状态可靠恢复**；流式增量 150ms 节流上屏。
- **六段工具流水线**：pre-execute（allow/deny/ask 瀑布）→ guard（单调 deny）→ execute（沙箱审批 + 超时）→
  结果投影 → post-execute（可改写）→ 溢写（超长工具输出自动落盘、只回摘要与定位）。支持并行工具执行（可配）。
- **LLM Adapter 接缝**：本地引擎与 OpenAI 兼容端点统一在 `LlmAdapter` 接口后，每次调用冻结能力快照
  （`prepareCall`），协议按能力驱动选择（prompt-JSON 落盘，XML-tool / native-tools 预留位）——
  **换模型 / 加模型不改调用方代码**。
- **子代理（Subagents）**：`subagent` 工具支持 `spawn` / `fork` 两种模式（进程内、复用同模型同工具集），
  嵌套深度 ≤ 2、每层独立预算，子代理审批恒 `never`（沙箱升级自动拒绝，恒 workspace-write），
  fork 种子按上下文预算截断。
- **Skills / Hooks / 指令文件**：内置 Skill（`web-research` / `code-review`）以 `<available_skills>` 注入
  系统提示；用户可在 `ApplicationSupport/skills/<name>/SKILL.md` 添加自己的 Skill（用户级 rank 高于内置，
  同名覆盖）；Hook 接缝 `agent/pre-step`（可否决单步）与 `tools/result`（只读审计）、流水线 pre/post-execute
  监听全部开放；全局 `AGENTS.md` 指令文件自动注入（`<workspace:guidance>`）。
- **智能体活动 UI**：输入框上方新增活动面板——结构化工具卡片（状态图标 + 参数摘要，展开看完整参数/结果）、
  「上下文已压缩」横幅、「重试中…（N）」指示、标题栏运行徽章；工具审批（沙箱升级 / pre-execute `ask`）
  弹确认框逐次批准。原「🔧」过程文本由结构化卡片取代。

---

## 模型列表

> 以下模型以 `assets/models_catalog.json` 为准（当前 13 个）。视觉模型（`vision`）含投影器 `mmproj`，
> 总下载体积 = 主模型 + 投影器。

| 模型 | 大小 | 类型 | 最低 RAM | 标签 |
|------|------|------|---------|------|
| Qwen3.5-0.8B (MTP UD-Q4_K_XL) | 543 MB (+195 mmproj) | vision | 1 GB | MTP · 🖼️ 视觉 |
| Qwen3.5-0.8BN (Q4_0 MTP) | 497 MB | text | 1 GB | MTP · ⚡ CPU 加速 |
| Qwen3.5-2B (MTP UD-Q4_K_XL) | 1.29 GB (+637 mmproj) | vision | 2 GB | ⭐ 推荐 · MTP · 🖼️ 视觉 |
| Qwen3.5-4B (Q4_K_M MTP) | 2.4 GB (+641 mmproj) | vision | 3.5 GB | ⭐ 推荐 · MTP · 🖼️ 视觉 |
| Qwen3.5-9B (MTP UD-IQ2_M) | 3.7 GB | text | 4 GB | ⚠️ 不推荐 · 👑 限高端旗舰 |
| Ornith-1.5-9B (MTP IQ2_M) | 3.87 GB | text | 4 GB | ⚠️ 不推荐 · MTP · 👑 限高端旗舰 |
| Gemma 3 4B (Q4_K_M) | 2.6 GB | text | 3 GB | ⭐ 推荐 |
| Gemma 4 E2B (Q4_K_M) | 3.1 GB (+531 mmproj) | vision | 4 GB | ⭐ 推荐 · 🖼️ 视觉 · 🎧 语音 |
| LFM 2.5 2.6B (Q4_K_M) | 1.6 GB | text | 2 GB | ⭐ 推荐 · ⚡ 速度快 |
| LFM 2.5 8B-A1B (UD-IQ3_XXS) | 3.1 GB | text | 4 GB | ⭐ 推荐 · 🤖 智能体 · MoE 高效 |
| Spark-X2.5 4B (Q4_K_M) | 2.4 GB | text | 4 GB | ⭐ 推荐 · 🤖 智能体 · 百万上下文 |
| Bonsai-8B (Q1_0) | 1.2 GB | text | 2 GB | ⭐ 推荐 · 🤖 智能体 · 轻量 |
| Bonsai 27B (Q1_0 1-bit) | 3.8 GB | text | 6 GB | 👑 限高端旗舰 · 探索用 |
| Bonsai 27B (Ternary 1.58-bit) | 7.2 GB | text | 10 GB | ⚠️ 不推荐 · 👑 限高端旗舰 |

**标签语义**：`⭐ 推荐`（绿）、`⚠️ 不推荐`（红，体积/内存要求过高）、`👑 限高端旗舰`（金，需大内存旗舰机）、
`🖼️ 视觉`、`🎧 语音`、`⚡ CPU 加速`、`⚡ 速度快`、`🤖 智能体`、`MTP`（多 token 预测投机解码）。

**智能体模型**（LFM 2.5 8B-A1B / Spark-X2.5 4B / Bonsai-8B）内置 `agentCapabilities` 声明（原生工具调用、
最大上下文、推荐 `n_ctx`、默认开启工具），为端侧 Agent 场景优化；其中 Spark-X2.5 4B 支持**百万级上下文**
（`maxContextTokens=1000000`，推荐 `n_ctx=32768`）。

> 端侧 1-bit / 1.58-bit 量化（Bonsai-27B）：Q1_0 与 Ternary Q2_0 体积小，但主分支 llama.cpp 的 CPU/GPU
> 内核无专用 1-bit 解码加速，实测约 2.7–2.9 tok/s，适合作为大上下文/探索用，日常问答优先选 4B 以下模型。

---

## 技术架构

```
┌──────────────────────────────────────────────────────────┐
│  Flutter 3.x (Material3)  ·  Riverpod 状态管理            │
│  lib/  screens · providers · services · agent · models     │
├──────────────────────────────────────────────────────────┤
│  通信：MethodChannel + EventChannel（JNI 直调，无 HTTP）    │
├──────────────────────────────────────────────────────────┤
│  Android 原生层                                            │
│  Kotlin (InferenceService/MainActivity) → JNI               │
│  └─ llama.cpp (third_party)  ·  ggml-cpu / ggml-vulkan /   │
│     ggml-opencl / KleidiAI / mtmd(视觉+语音)               │
└──────────────────────────────────────────────────────────┘
```

- **前端**：Flutter 3.x (Material3)，Riverpod 状态管理。
- **智能体层（`lib/agent/`）**：`session/`（事件日志唯一真相源 + JSONL 存储）· `loop/`（ReactLoopAgent
  主循环 + 失败瀑布）· `tools/`（六段流水线）· `llm/`（`LlmAdapter` 接缝：本地 / OpenAI）·
  `protocol/`（能力驱动协议选择）· `subagents/`（子代理）· `hooks/` `skills/` `agents_md/`（扩展生态）·
  `context_eng/`（压缩 + 溢写）。
- **通信**：`MethodChannel`（请求）+ `EventChannel`（流式 token 批量化回调），无 HTTP Server，高效省内存。
- **推理引擎**：llama.cpp（`third_party/` 直接入库），含 ggml-cpu、Vulkan / OpenCL GPU 后端、
  KleidiAI dotprod CPU 内核、mtmd 多模态（视觉 + 语音）支持。
- **模型管理**：`assets/models_catalog.json` 配置驱动 + Dio 断点续传下载 + SQLite 对话持久化。

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

经历「原厂驱动修复 → OTA 回归弃用 → Turnip 直载」三个阶段：

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
4. **当前定位**：**勘探后端**（CONV_2D f32 独立 bug、FA hsk=192 遗留，`[turnip-step]` 诊断探针清理后才能
   出正式 APK），日常 GPU 推理仍走 OpenCL。

> 完整根因链与修复记录：[`docs/vulkan_adreno825_fix_2026-09-26.md`](docs/vulkan_adreno825_fix_2026-09-26.md)。

#### OpenCL PTQ1_0 三元量化内核（Bonsai-2 27B，v0.2.5 / v0.2.6 补齐 prefill）

- Bonsai-2 27B 全模型 402 个 PTQ1_0 张量（GGML `type 143`，-1/0/1 三元，28 B/128 值）；上游 OpenCL 后端
  只有 Q4/Q5/Q8 系列 mul_mv 内核 → 此前全部回退 CPU、decode 极慢。分支 `spike/opencl-bonsai2` 新增
  `mul_mv_ptq1_0_f32.cl`（Adreno 64-wide subgroup、2 trit/lane、subgroup 归约）实现全 GPU decode。
- **v0.2.6 补齐 prefill GEMM**：新增 `mul_mm_ptq1_0_f32_l4_lm.cl`（BM64/BN64/BK32 分块，raw 块布局
  逐元素 staged 三进制解码，BK=32 整除 QK=128 故 K-tile 永不跨量化块）。此前 prefill（n>1）掉进
  逐行 matvec 反复发射路径——桌面 Arc 140T 实测 pp128 **1.14 → 18.89 t/s（16.5×）**；桌面 OpenCL
  数值 tbo 174/174。
- **根治 Adreno OpenCL 编译器对 `__constant` 数组变址的误编**（`pow3[4]` 恒读 0 → 每块 16 trit 全解成 -1，
  数据正确但内积系统性偏差）：弃用 `__constant` 数组索引，改三元表达式。
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
| Flutter SDK | 3.x | Flutter 构建 |
| Android SDK | 34+ (compileSdk 36) | Android 构建 |
| Android NDK | r27 (27.0.12077973) | C++ 原生编译 |
| CMake | 3.22.1 | `CMakeLists.txt` + Gradle `externalNativeBuild` |
| Java JDK 17 | 17 | Gradle / Kotlin |

### 构建要点

- **glslc 锁定 shaderc v2026.3**（开发机本地 `_study/vkcli/sdk/vksdk-new`，不入库）：CMakeLists 的
  `Vulkan_GLSLC_EXECUTABLE` 强制覆盖，shader 变更后必须重编。
- **Debug 也强制 `-O3 -DNDEBUG`**：Android debug 默认 `-O0` 会让量化 matmul 内核失去优化（曾导致全模型
  ~1.2 tok/s）。⚠️ 仅设 `CMAKE_C_FLAGS_DEBUG` 不够——NDK 工具链会静默顶掉，正确做法是 NDK 覆盖不了的目录级
  `add_compile_options(-O3)` + `add_compile_definitions(NDEBUG)`。
- **改 CMakeLists / 工具链后必须清 `.cxx` 缓存**（`Remove-Item -LiteralPath 'android\app\.cxx' -Recurse -Force`），
  否则 Gradle 判定 up-to-date 不重编。

---

## 版本更新

> 版本历史依据 git 提交维护，详细变更见 [`CHANGELOG.md`](CHANGELOG.md)（0.2.1 及更早）。

| 版本 | 日期 | 要点 |
|------|------|------|
| **v0.2.6** | 2026-09-28 | **Bonsai-2 双后端补齐 + Turnip 错编双定案**：① OpenCL 补 PTQ1_0 prefill GEMM（`mul_mm_ptq1_0_f32_l4_lm`，raw 块布局 + staged 三进制解码；桌面 Arc 140T pp128 1.14→18.89 t/s，16.5×）；② Vulkan FWHT subgroup 变体并入三药门控 + `GGML_VK_FWHT_SUBGROUP` A/B 开关——真机实锤 Turnip shuffle 错编（8/27）原厂无罪（27/27），门控恰好兜住；③ **Turnip e2e 乱码根因定案**：GEMM 大 n（≥48）编译器错编（f16+MMQ 双中招，ERR≈1.0；原厂 16/16 全绿）——App 靠 JNI `n_ubatch=16` 天然避开，`n_ubatch≤32` 为 Turnip 正确性边界（`-ub 16` e2e 连贯闭环）；④ tbo 增补 hadamard 4096/8192、PTQ1_0 二分/大 batch、f16 大 n 用例防回归；⑤ 双驱动真机全矩阵验证（原厂 0800.71 / fork Turnip × 三药）记录于 [`docs/vulkan_bonsai2_turnip_verify_2026-09-28.md`](docs/vulkan_bonsai2_turnip_verify_2026-09-28.md) |
| **v0.2.5** | 2026-09-27 | **OpenCL 后端支持 PTQ1_0 三元量化（Bonsai-2 27B）**：新增 `mul_mv_ptq1_0_f32.cl`（Adreno 64-wide subgroup、2 trit/lane、subgroup 归约），402 个 PTQ1_0 张量 decode 全 GPU；Adreno `__constant` 数组误编根因定位与修复（三元表达式替代数组索引）；真机 174/174 通过 |
| **v0.2.3** | 2026-09-27 | **Vulkan 在 Adreno 825 重新可用（Turnip 直载）**：原厂 0800.71 驱动 OTA 回归实锤后，切换 Mesa out-of-tree gen8 Turnip App 内直载（Vulkan HAL 入口逆向 + ggml-vulkan dispatcher 化 + 4 处直接调用修复）；数值三根因修复——subgroupAdd 错编全局门控（`subgroup_arithmetic=false` 直置覆盖 ssm_scan/GDN 漏网）、GDN S_V=128 lanes 钳 64；tbo GDN 36/36 + SSM_SCAN 12/12，LFM2.5 / Qwen3.5 e2e 连贯（5~11 t/s） |
| **v0.2.2** | 2026-09-26 | **Vulkan / Adreno 825（8 Elite2）乱码与崩溃根治**：驱动 0800.71 错编 `unpack8()`（Int8）→ shader 层纯 32 位替换（21 处调用点）；subgroup matvec 管线失败 / 图融合全零 / dp4a 数值错 / decode 管线缺失 → 4 个 env 开关默认注入（vk_flags.conf 可覆盖） |
| **v0.2.1** | 2026-09-26 | **智能体引擎全面升级**：事件日志上下文（压缩不丢原文、崩溃自动修复）+ 主循环失败自动恢复 / 可靠停止 + 六段工具流水线（审批 / guard / 溢写 / 并行）+ **子代理**（spawn/fork）+ Skills / Hooks / `AGENTS.md` 指令文件 + 活动面板 UI；**联网搜索全面配置化**（SearXNG 自配 + 测试连接 + 保存即热更新）；llama.cpp 升级 b11028；移除启动加载页。**229 项单测全绿** |
| **v0.2.0** | 2026-09-04 | Agent Lite 智能体（工具循环 + 18 工具 + 沙箱授权）、`python_exec`（Chaquopy 17 / CPython 3.11）、MTP 投机解码、远程 API 接入、智能体每轮性能统计 + 长期记忆、代码质量 P0 加固 |
| v0.1.6 | 2026-08-19 | llama.cpp 升级上游 master（`fe8156f`）、天玑 Mali Vulkan 崩溃根治、mmproj 视觉编码后端跟随主后端、天玑 OpenCL 置灰、Gradle 16 核并行 |
| v0.1.3 | 2026-08-04 | 多轮对话正确性修复（KV 缓存跨轮残留等根因）、`tok/s` 口径对齐、`n_ubatch` 按后端动态、助手复制 / 自定义模型名 / 加载进度弹窗 |
| v0.1.2 | 2026-08-03 | 量化 GEMM 路径 / 重复惩罚失效 / flash attention CPU 陷阱修复 |
| v0.1.1 | 2026-08-03 | Vulkan GPU 加速（arm64-v8a）、模型下载系统、设置页 UI、对话 SQLite 持久化 |
| v0.1.0 | 2025-07-29 | 端侧 LLM 推理引擎（llama.cpp）、Flutter Material3 前端、架构设计文档 v2 |

**下载**（release 签名 `CN=TongYiLite`）：

> [⬇️ 下载 `TongYi-Lite-v0.2.0.apk`](https://github.com/liangjianzeng/TongYi-Lite/raw/main/releases/TongYi-Lite-v0.2.0.apk)
> `SHA-256: FB:BE:1B:6C:F8:79:AB:94:1A:65:CD:D7:A7:A8:DD:6F:5A:6B:B6:40:41:2D:E3:8C:43:CB:89:4F:08:88:69:92`

> ⚠️ 2026-09-05 重新发布：修正为 `CN=TongYiLite` 官方签名证书（原 `652245B5…` 非官方证书）。
> 后续版本发布流程：构建产物拷入 `releases/` 并在此更新链接与 SHA-256。

**v0.2.1 详细变更**（2026-09-26，智能体引擎 / 联网搜索的功能说明见上文[应用功能](#应用功能)）：

- **联网搜索改为用户自配 SearXNG**：设置页「API 接入」新增联网搜索配置卡（地址 / 密钥 / 引擎白名单 /
  语言 / 条数 / 超时 + 测试连接）；App 不预置任何搜索实例，地址留空即"未配置"并明确诊断指向设置页。
- **修复 4 处「静默失效」**：① `/search` 路径缺失时请求拼成 `host:8080?q=…`（原依赖实例 308 跳转才侥幸
  可用）→ 自行补齐且不重复拼接；② Dio `validateStatus` 吞掉 4xx/5xx（原判断是死代码）→ 自行判定并
  分类报因；③ 实例未开 `format=json` 返回 HTML 被误报「不可达」→ 明确提示在 `settings.yml` 加 json；
  ④ 工具声明超时从未消费、被写死 15s 覆盖 → 声明超时优先于全局 `toolTimeout`。
- **搜索质量与上下文预算**：URL 规范化去重（`utm_*` / fragment / 尾斜杠 / 大小写）+ 按 score 排序 +
  超上限 `truncated` 提示；单条摘要 200 字 / 总 1500 字。
- **引擎白名单提速**：全引擎 21s → 只留可达引擎 2.2s（自建实例实测）；填了实例不认识的引擎被拒（400）
  时自动去参重试一次。
- **诊断挖到根**：把 Dio error 里真实 `SocketException`（含系统错误码、host:port、耗时）挖出来展示。
- **llama.cpp 升级 b11028**：API 漂移全修（mtmd helper 第 4 参、`MTMD_BACKEND_DEVICE` 删除 →
  `mtmd_context_params.device`、OpenCL stub 转发补齐、KleidiAI vendored 项目名双写兜底）；模型加载
  全链路修复（视觉报错文案不再甩锅 mmproj，真凶看引擎日志）。
- **移除启动加载页**：冷启动直接进首页，模型目录与原生引擎初始化后台进行。
- **测试**：智能体新增 79 项、联网搜索 21 项，全仓库 229 项全绿，`flutter analyze` 0 error。

**v0.2.0 详细变更**（2026-09-04）：

- **Agent Lite 智能体**：模型 ↔ 工具多轮交互（轮次上限默认 5），工具结果以 user 角色回填后再生成；
  工具注册表分层注册/注销、按模型可见性渲染；`ToolProtocol` 按 `EngineCapabilities` 自动选协议；
  `AgentStreamProcessor` 增量隐藏思考块/工具调用块；llama.cpp 换 XHToken fork（`spark2_5` +
  function-calling）。
- **根治工具「缺参数」**：执行前统一必填校验，错误信息列出缺失参数名与用途并回填；工具清单渲染带必填提示。
- **`python_exec`（Chaquopy 17.0.0 / CPython 3.11）**：嵌入式运行时随 APK 打包，MethodChannel 执行脚本，
  15s 超时 / 4KB 输出截断；沙箱授权 `workspace-write` → `danger-full-access` 严格更宽阶梯，逐次批准。
- **MTP 投机解码**：按模型独立开关（模型列表 `mtp` 标记），默认关闭；空 draft 崩溃修复、`n_draft_max` 默认 2。
- **远程 API 接入**：设置页新增 API TAB，本地优先 / API 后备路由，视觉 content-parts 处理。
- **智能体增强**：每轮性能统计、长期记忆开关（默认关闭）、工具调用坏格式容错、投影器加载开关、
  GPU/CPU 占用率监控线、联网工具换国内可达源、每轮预算放宽至 16k。
- **代码质量 P0 加固**：消息 role 反序列化安全回落、SQLite v3（`audioPath` 列迁移）、原生消息 JSON 解析器
  重写、设置原子写入、假数据 stub 与死代码移除。**101–123 项单测全绿**。

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

1. 确认 LunarG Vulkan SDK 已安装到 `C:/VulkanSDK/1.4.357.0`（提供 `glslc` + `SPIRV-Headers` +
   `<vulkan/vulkan.hpp>`）。
2. 确认 MinGW-w64 在 `C:/mingw64`（`vulkan-shaders-gen` 主机工具需要它预编译着色器）。
3. 改了 CMakeLists / 工具链后**必须清 `.cxx` 缓存**，否则 Gradle 判定 up-to-date 不重编：
   `Remove-Item -LiteralPath 'android\app\.cxx' -Recurse -Force`
4. 运行时 `adb logcat | grep -iE "TongYiLite|ggml_vulkan"`，看 `ggml backend devices` 与 `n_gpu_layers`。

</details>

<details>
<summary><b>Q: JNI 编译报 "unknown type name 'common_chat_templates'" / API 不兼容</b></summary>

llama.cpp 大幅重写了 API，`llama_model*` 相关调用需改用 `llama_vocab*`：

- `llama_new_context_with_model()` → `llama_init_from_model()`
- `llama_tokenize(model, ...)` → `llama_tokenize(vocab, ...)`
- `llama_token_eos(model)` → `llama_vocab_eos(vocab)`
- 手动实现 temperature + top-p 采样（`llama_sampler_init_simple` 不存在）

</details>

<details>
<summary><b>Q: 推理速度慢 / 内存溢出</b></summary>

- 使用更小的模型；关闭后台应用释放 RAM；设备需 ≥ 4GB RAM 才能流畅运行 2B 级模型。
- 确保 Vulkan GPU 加速已启用（设置页显示「已完成」）。
- 已优化：批量 prefill + unified KV、内置采样器（消除每 token 150k+ 堆分配）、流式回调批量化、
  mmap 加载、线程按 CPU 拓扑取核。

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
- [`docs/agent_mode_dsh_replication_design.md`](docs/agent_mode_dsh_replication_design.md) — 智能体引擎架构设计（v0.2.1）
- [`docs/vulkan_adreno825_fix_2026-09-26.md`](docs/vulkan_adreno825_fix_2026-09-26.md) — Adreno 825 Vulkan 修复全记录（v0.2.2 / v0.2.3）
- [`docs/ptq1_0_opencl_bonsai2_2026-09-27.md`](docs/ptq1_0_opencl_bonsai2_2026-09-27.md) — PTQ1_0 OpenCL 内核实现机制（v0.2.5）
- [`docs/bonsai2_vulkan_research_2026-09-27.md`](docs/bonsai2_vulkan_research_2026-09-27.md) — Bonsai-2 Vulkan 调研
- [`docs/python_support.md`](docs/python_support.md) — `python_exec` 支持说明
- [`docs/agent_accessibility_方案.md`](docs/agent_accessibility_方案.md) — 智能体无障碍方案

---

## License

[MIT](LICENSE) — 自由使用、修改和分发。
