# TongYi-Lite 端侧离线 AI 智能体

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Flutter](https://img.shields.io/badge/Flutter-3.x-02569B?logo=flutter)](https://flutter.dev)
[![Android](https://img.shields.io/badge/Android-33+-3DDC84?logo=android)](https://developer.android.com)
[![llama.cpp](https://img.shields.io/badge/Engine-llama.cpp%20fork-red)](https://github.com/ggerganov/llama.cpp)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](CONTRIBUTING.md)

> **端到端离线的 Android AI 助手。** 本地模型推理（llama.cpp）· Vulkan / OpenCL GPU 加速 + KleidiAI
> CPU 加速 · 应用内模型下载与管理 · Agent 智能体（工具调用）· OpenAI 兼容远程模型
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
| **本地端侧推理** | 基于 llama.cpp 的 JNI 直调推理（无 HTTP Server），mmap 加载、批量 prefill、内置采样器；纯 CPU 也可跑，数据零外传 |
| **GPU / CPU 加速** | Vulkan + OpenCL 双 GPU 后端（运行时自动探测 + 手动选择）+ KleidiAI dotprod CPU 内核；`n_gpu_layers` 全量卸载，运行时可控 |
| **模型下载与管理** | 应用内下载（hf-mirror / ModelScope 镜像自动回退 + HTTP Range 断点续传）、加载/卸载、单模型约束、存储信息扫描 |
| **多模态（视觉 + 语音）** | Qwen3.5 / Gemma 4 视觉模型（`.gguf` + `mmproj` 两文件闭环下载）；Gemma 4 E2B 自带原生语音编码器，支持**按住说话**语音输入 |
| **远程 API 接入** | 兼容 OpenAI `{baseUrl}/chat/completions` 端点（云端大模型或自建 llama.cpp 服务），**本地优先、API 后备**，共用同一套聊天界面 |
| **Agent 智能体（工具调用）** | 18 个内置工具（`shell_exec` / `python_exec` / 联网 / 计算 / 文件 / 待办 / 记忆 / 天气等），模型多轮调用工具 → 回填结果 → 组织回答；沙箱授权 + 逐次审批 |
| **MTP 投机解码** | 部分模型支持多 token 预测（Multi-Token Prediction），可在设置页为该模型单独开启投机解码加速 |
| **智能体可配置** | 循环轮次 / 每轮预算 / 工具超时 / 联网源 / 按模型开启或关闭特定工具，全部持久化；支持原生工具调用能力探测（`nativeToolCall`） |

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
<summary><b>Windows 下 debug APK 装不进最新 Dart？</b></summary>

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
  最大 16k）/工具超时/联网搜索全部可调并持久化（按模型 `agentToolsByModel`）。

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
- **通信**：`MethodChannel`（请求）+ `EventChannel`（流式 token 批量化回调），无 HTTP Server，高效省内存。
- **推理引擎**：llama.cpp（`third_party/` 直接入库），含 ggml-cpu、Vulkan / OpenCL GPU 后端、
  KleidiAI dotprod CPU 内核、mtmd 多模态（视觉 + 语音）支持。
- **模型管理**：`assets/models_catalog.json` 配置驱动 + Dio 断点续传下载 + SQLite 对话持久化。

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

### GPU / CPU 加速

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
- **Debug 也强制 `-O3 -DNDEBUG`**：Android debug 默认 `-O0` 会让量化 matmul 内核失去优化（曾导致全模型
  ~1.2 tok/s）。⚠️ 仅设 `CMAKE_C_FLAGS_DEBUG` 不够——NDK 工具链会静默顶掉，正确做法是 NDK 覆盖不了的目录级
  `add_compile_options(-O3)` + `add_compile_definitions(NDEBUG)`。改 CMake 后必须清 `.cxx` 全量重建。
- **SME2（暂未启用）**：目标设备（骁龙 8s Gen 4）仅 1 颗大核有 SME2，异构核分派收益低、收益拐点未到
  （待全核 SME2 平台如天玑 9500）。当前保持 `dotprod`。

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
> [`docs/backend_benchmark_2026-08-04.md`](docs/backend_benchmark_2026-08-04.md)。

---

## 版本更新

> 版本历史依据 git 提交维护，详细变更见 [`CHANGELOG.md`](CHANGELOG.md)。

| 版本 | 日期 | 要点 |
|------|------|------|
| **v0.2.0** | 2026-09-04 | Agent Lite 智能体（工具循环 + 18 工具 + 沙箱授权）、`python_exec`（Chaquopy 17 / CPython 3.11）、MTP 投机解码、远程 API 接入、智能体每轮性能统计 + 长期记忆、18 内置工具、代码质量 P0 加固 |
| v0.1.6 | 2026-08-19 | llama.cpp 升级上游 master（`fe8156f`）、天玑 Mali Vulkan 崩溃根治、mmproj 视觉编码后端跟随主后端、天玑 OpenCL 置灰、Gradle 16 核并行 |
| v0.1.3 | 2026-08-04 | 多轮对话正确性修复（KV 缓存跨轮残留等根因）、`tok/s` 口径对齐、`n_ubatch` 按后端动态、助手复制 / 自定义模型名 / 加载进度弹窗 |
| v0.1.2 | 2026-08-03 | 量化 GEMM 路径 / 重复惩罚失效 / flash attention CPU 陷阱修复 |
| v0.1.1 | 2026-08-03 | Vulkan GPU 加速（arm64-v8a）、模型下载系统、设置页 UI、对话 SQLite 持久化 |
| v0.1.0 | 2025-07-29 | 端侧 LLM 推理引擎（llama.cpp）、Flutter Material3 前端、架构设计文档 v2 |

**v0.2.0 详细变更**（2026-09-04）：

- **Agent Lite 智能体**：模型 ↔ 工具多轮交互（轮次上限可配，默认 5），工具结果以 user 角色回填后再生成；
  工具注册表分层注册/注销、按模型可见性渲染；`ToolProtocol` 抽象按 `EngineCapabilities` 自动选协议；
  `AgentStreamProcessor` 处理思考块/工具调用块增量隐藏；llama.cpp 换 XHToken fork（`spark2_5` +
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

- [`docs/architecture_design_v2.md`](docs/architecture_design_v2.md) — 架构设计 v2
- [`docs/BUILD_AND_DEBUG_GUIDE.md`](docs/BUILD_AND_DEBUG_GUIDE.md) — 编译与调试指南
- [`docs/backend_benchmark_2026-08-04.md`](docs/backend_benchmark_2026-08-04.md) — 三后端实测专报
- [`docs/agent_light_design.md`](docs/agent_light_design.md) — Agent Lite 设计

---

## License

[MIT](LICENSE) — 自由使用、修改和分发。
