# TongYi-Lite 端侧离线 AI 智能体

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Flutter](https://img.shields.io/badge/Flutter-3.x-02569B?logo=flutter)](https://flutter.dev)
[![Android](https://img.shields.io/badge/Android-33+-3DDC84?logo=android)](https://developer.android.com)
[![llama.cpp](https://img.shields.io/badge/llama.cpp-b10173-red)](https://github.com/ggerganov/llama.cpp)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](CONTRIBUTING.md)

> **端到端离线的 Android AI 助手。** 本地模型推理（llama.cpp） · Vulkan / OpenCL GPU 加速 + KleidiAI CPU 加速 · 应用内模型下载与管理 · Plugin 热插拔 · 荒野求生游戏化任务
>
> **数据不出设备，隐私安全无忧。**

---

## 目录

- [快速概览](#快速概览)
- [项目结构](#项目结构)
- [前置环境](#前置环境)
- [构建步骤](#构建步骤)
- [模型下载与管理](#模型下载与管理)
- [API 接入（OpenAI 兼容远程模型）](#api-接入openai-兼容远程模型)
- [运行](#运行)
- [远程任务 + Plugin（荒野求生模式）](#远程任务--plugin荒野求生模式)
- [架构决策记录](#架构决策记录)
- [常见问题](#常见问题)
- [贡献指南](#贡献指南)
- [License](#license)

---

## 快速概览

| 维度 | 说明 |
|------|------|
| **当前版本** | **v0.1.6**（2026-08-19；versionCode 7） |
| **目标平台** | Android APK (API 33+) |
| **推理引擎** | llama.cpp 上游 master（vendored `fe8156f`，2026-08-19；批量预填充 + 内置采样器 + **Vulkan/OpenCL 双 GPU 后端** + KleidiAI dotprod CPU；含天玑 Mali Vulkan 崩溃修复，见「GPU 加速」） |
| **模型管理** | Riverpod ModelState（idle/loading/loaded/unloading/error），单模型约束，聊天界面实时状态栏；支持**最多 2 个模型并行下载**、暂停/继续/删除、断点续传 |
| **前端框架** | Flutter 3.x (Material3) |
| **通信方式** | JNI 直调（批量 EventChannel 回调） |
| **模型下载源** | hf-mirror.com → ModelScope（自动回退，见 `assets/models_catalog.json`） |

---

## 项目结构

```
TongYi-Lite/
├── android/                          # Android 原生层
│   ├── app/
│   │   ├── build.gradle.kts          # Gradle 配置
│   │   └── src/main/
│   │       ├── cpp/
│   │       │   ├── CMakeLists.txt    # llama.cpp NDK 构建（含 Vulkan）
│   │       │   ├── tongyilite_jni.cpp      # JNI 桥接层（运行时 GPU 检测 + Vulkan offload）
│   │       │   └── host-toolchain-mingw.cmake  # 主机工具链（vulkan-shaders-gen 用 MinGW-w64）
│   │       ├── java/com/dgxspark/tongyilite/
│   │       │   ├── MainActivity.kt           # Flutter + MethodChannel
│   │       │   ├── InferenceEngine.kt        # Kotlin 推理封装
│   │       │   └── service/InferenceService.kt  # 前台服务（保活）
│   │       └── AndroidManifest.xml
│   ├── build.gradle.kts
│   ├── gradle.properties
│   └── settings.gradle.kts
├── third_party/llama.cpp/          # llama.cpp 源码（b10173，已直接入库，非子模块）
│   ├── src/                        # 推理引擎源码
│   ├── ggml/src/ggml-vulkan/       # Vulkan GPU 后端
│   └── ...
├── third_party/kleidiai/           # KleidiAI CPU 加速库（vendored, v1.24.0）
│   └── kai/                        # 手调 matmul/dotprod/i8mm 内核源码
│                                     (llama.cpp 默认 FetchContent 联网拉取，
│                                      本项目改为本地 vendored 规避构建期联网)
├── lib/                              # Flutter Dart 层
│   ├── main.dart                     # 入口（初始化 JNI + 加载模型目录 + ProviderScope）
│   ├── models/
│   │   ├── model_info.dart           # ModelConfig / MirrorEntry / DownloadTask（含 fromJson）
│   │   ├── model_catalog.dart        # 模型目录加载器（读 assets/models_catalog.json / 可选远程）
│   │   ├── chat_message.dart         # 聊天消息模型
│   │   └── conversation.dart         # 会话模型
│   ├── services/
│   │   ├── inference_service.dart    # JNI 推理桥接（MethodChannel + EventChannel）
│   │   ├── download_service.dart     # Dio 下载核心（断点续传 + 镜像回退）
│   │   ├── model_manager.dart        # 模型缓存 / 内存检测
│   │   ├── model_storage_service.dart       # 磁盘模型存储管理
│   │   ├── storage_permission_service.dart  # Android 存储权限申请
│   │   └── storage_service.dart      # SQLite 持久化（对话/消息）
│   ├── providers/
│   │   ├── chat_provider.dart        # Riverpod 聊天状态 + 当前模型选择
│   │   ├── download_provider.dart    # Riverpod 下载任务状态管理
│   │   └── model_provider.dart       # Riverpod ModelState（idle/loading/loaded/unloading/error）
│   ├── screens/
│   │   ├── home_screen.dart          # 聊天主页面（含实时模型状态栏 + 推理脉冲动画）
│   │   ├── settings_screen.dart      # 设置页（模型选择 + 下载进度 + 存储信息磁盘扫描）
│   │   └── inference_log_screen.dart # 推理日志查看页（加载/卸载/生成过程日志）
│   └── widgets/
│       └── chat_bubble.dart          # 消息气泡组件
├── docs/                             # 设计文档
│   ├── architecture_design_v2.md     # 架构设计 v2
│   ├── plugin_architecture.md        # Plugin 插件架构
│   ├── implementation_plan.md        # 实施方案
│   ├── mobile_llm_benchmark_report_v2.md  # 移动端 LLM 基准报告
│   ├── backend_benchmark_2026-08-04.md    # 三后端（Vulkan/OpenCL/CPU）实测专报
│   ├── BUILD_AND_DEBUG_GUIDE.md      # 编译与调试指南
│   └── archive/                      # v1 归档文档
├── .github/                          # GitHub 项目配置
│   ├── CODEOWNERS
│   ├── PULL_REQUEST_TEMPLATE.md
│   └── ISSUE_TEMPLATE/
├── pubspec.yaml                      # Flutter 依赖
├── .gitignore
├── LICENSE
├── CONTRIBUTING.md
├── CHANGELOG.md
└── README.md
```

---

## 前置环境

| 工具 | 最低版本 | 用途 |
|------|---------|------|
| Flutter SDK | 3.x | Flutter 构建 |
| Android SDK | 34+ (compileSdk 36) | Android 构建 |
| Android NDK | r27（本机验证 r27.0.12077973；未显式 pin，取 SDK 默认） | C++ 原生编译 |
| CMake | 3.22.1 | `CMakeLists.txt` 的 `cmake_minimum_required` + Gradle `externalNativeBuild.cmake.version` |
| Java JDK 17 | 17 | Gradle/Kotlin |

### 环境变量

```bash
export ANDROID_HOME=$HOME/Library/Android/sdk   # macOS
export ANDROID_SDK_ROOT=$ANDROID_HOME
export ANDROID_NDK_ROOT=$ANDROID_HOME/ndk/27.0.12077973
export JAVA_HOME=$(dirname $(dirname $(readlink -f $(which javac))))
```

### GPU / Vulkan 加速依赖（可选，但推荐）

Vulkan 后端让 llama.cpp 把模型层卸载到设备 GPU（如骁龙 Adreno / Mali），推理速度通常数倍于纯 CPU。
这部分 **仅对 `arm64-v8a` 生效**，且只在构建主机满足以下条件时才启用；不满足时自动回退到
CPU + KleidiAI（dotprod），构建本身不会失败。

| 依赖 | 版本 / 路径 | 用途 | 必需 |
|------|------------|------|------|
| LunarG Vulkan SDK | `C:/VulkanSDK/1.4.357.0` | 提供 `glslc` 着色器编译器、`SPIRV-Headers` cmake 包、`<vulkan/vulkan.hpp>` C++ 头 | ✅（开 Vulkan 时） |
| MinGW-w64 (GCC) | `C:/mingw64/bin/{gcc,g++}.exe` | 在 **Windows 构建主机**上编译 `vulkan-shaders-gen` 主机工具（把 `.comp` 着色器预编译成 C++ 头） | ✅（开 Vulkan 时） |
| Android SDK cmake | `...\cmake\3.22.1\bin\ninja.exe` | 主机子构建的 Ninja 生成器（`CMAKE_MAKE_PROGRAM` 已 pin 到它） | ✅ |
| NDK Vulkan 桩库 | `${ANDROID_NDK}/.../aarch64-linux-android/${ANDROID_PLATFORM_LEVEL}/libvulkan.so` | 链接阶段用的 Vulkan loader 桩（运行时由系统提供真实实现） | ✅ |
| 设备 Vulkan 运行时 | **Vulkan 1.1+** | Adreno 825 / Mali 等；NDK 链接桩须 **≥ API 28**（Vulkan 1.1 符号 `vkGetPhysicalDeviceFeatures2`，API 24 桩仅导出 1.0 会链接失败） | ✅（运行期） |

> **为什么需要 MinGW？** ggml-vulkan 用 `ExternalProject_Add` 在构建主机上编一个叫
> `vulkan-shaders-gen` 的小工具，用 `glslc` 把 compute shader 预编译成 `.comp.h`。主机上需要一份
> **原生 C++17** 编译器（支持 `<windows.h>` / `<filesystem>` / `<thread>`）。本仓库已附带
> `host-toolchain-mingw.cmake` 指向 `C:/mingw64` 的 GCC；若你用 MSVC，把该文件里的编译器路径
> 改成 `cl.exe` 即可。
>
> **路径是硬编码的**：`CMakeLists.txt` 与 `host-toolchain-mingw.cmake` 里的 SDK / MinGW / NDK 路径
> 都是本机（Windows）绝对路径。换机器需同步修改这两处，或改为从环境变量读取。
>
> **本机验证环境**：NDK r27.0.12077973、CMake 3.22.1、Vulkan SDK 1.4.357.0、MinGW-w64 GCC 16.x。

---

## 构建步骤

### 1. 克隆仓库

```bash
git clone git@github.com:liangjianzeng/TongYi-Lite.git
cd TongYi-Lite
```

> ✅ **三方依赖已全部直接入库，无需子模块、无需联网下载**：llama.cpp（b10173）、
> KleidiAI（v1.24.0）、OpenCL-Headers、opencl-stub 源码都提交在 `third_party/` 下，
> clone 后即可编译，不再需要 `git submodule update --init --recursive`。

> 以下命令仅用于**更新**某依赖的版本时重新 vendor（日常构建不需要执行）。若目录缺失，CMake
> 配置会以 `FATAL_ERROR` 明确提示：
> ```bash
> git clone --depth 1 --branch v1.24.0 \
>     https://github.com/ARM-software/kleidiai \
>     third_party/kleidiai
> ```

### 2. 获取 Flutter 依赖

```bash
flutter pub get
```

### 3. 构建调试 APK

```bash
flutter build apk --debug
```

输出: `build/app/outputs/flutter-apk/app-debug.apk`

### 4. 构建发布 APK (AAB)

```bash
flutter build appbundle --release
```

输出: `build/app/outputs/bundle/release/app-release.aab`

---

## 模型下载与管理

应用内置完整的模型下载系统，无需手动下载。在 **设置** 页面即可操作：

### 使用方式

1. 打开 App → 点击右上角 ⚙️ **设置**
2. 在"模型管理"区域选择需要的模型，点击 **[下载]**
3. 下载过程中可实时查看进度条、百分比和预估剩余时间
4. 支持 [暂停] / [继续] 操作，网络中断后自动断点续传
5. 下载中可点 **[删除]** 取消任务并移除半成品文件（弹框确认，防误删）
6. **最多同时下载 2 个模型**（第 3 个会被拒绝）
7. 下载完成后点击 **[加载到内存]** 即可在聊天中使用
8. 每个模型卡片带能力标签：**🖼️ 视觉**（支持视觉理解）/ **💬 文本**

> **视觉模型下载闭环**：`type=vision` 且带 `mmproj` 的模型（Qwen3.5-0.8B/2B/4B、
> Gemma 4 E2B）会先下载主 `.gguf`、再自动下载投影器 `.mmproj`，两者都完整才算"已缓存"。
> 若主模型已下、缺投影器，再次点击 **[下载(含投影器)]** 会跳过完整主模型、只补下投影器。
> 加载前还会校验 mmproj 完整（存在、无残留 `.tmp`、非空），损坏/缺失时提示重新下载完整模型，
> 避免原生加载崩溃。

### 镜像策略（HuggingFace 优先走国内）

> 每个模型的可用镜像写在该模型的 `mirrors` 数组里（见 `assets/models_catalog.json`），
> App 按数组顺序依次尝试，前一个失败时自动切换下一个源。

当前内置模型的镜像顺序为：

```
1. hf-mirror.com     → HuggingFace 国内 CDN（最快，支持 Range 续传）
2. ModelScope        → 阿里云模型社区（兜底回退）
```

如需增加 `huggingface.co` 直连等其它源，只需在对应模型的 `mirrors` 里追加一项即可。

> **多线程断点续传**：hf-mirror.com 基于 `aria2c`（官方 `hfd.sh` 工具）支持多线程（`-x`）+ 断点续传（`-c`）；App 内 Dio 也通过 HTTP `Range` 头实现真正的断点续传（网络中断后从断点继续，不会从头重下）。ModelScope 直链不支持 `Range`，仅作为兜底回退源。

### 模型目录（配置文件驱动）

> ⚠️ **模型列表不再写死在代码里。** 全部模型定义维护在 **`assets/models_catalog.json`**，
> 由 `lib/models/model_catalog.dart` 在应用启动时加载（`ModelManager().init()`）。
> **新增 / 调整 / 下架模型只需修改这个 JSON，无需改代码、无需重新编译。**

**当前内置模型（以 `assets/models_catalog.json` 为准）：**

| 模型 | 大小 | 类型 | 最低 RAM | 标签 | 镜像 |
|------|------|------|---------|------|------|
| Qwen3.5-0.8B (MTP UD-Q4_K_XL) | 543 MB | vision | 1.0 GB | MTP · 🖼️ 视觉 | hf-mirror + ModelScope |
| Qwen3.5-0.8BN (Q4_0 MTP) | 497 MB | text | 1.0 GB | MTP · ⚡ CPU 加速 | hf-mirror + ModelScope |
| Qwen3.5-2B (MTP UD-Q4_K_XL) | 1.29 GB | vision | 2.0 GB | ⭐ 推荐 · MTP · 🖼️ 视觉 | hf-mirror + ModelScope |
| Qwen3.5-4B (Q4_K_M MTP 视觉) | 2.4 GB | vision | 3.5 GB | ⭐ 推荐 · MTP · 🖼️ 视觉 | hf-mirror + ModelScope |
| Qwen3.5-9B (MTP UD-IQ2_M) | 3.7 GB | text | 4.0 GB | MTP · ⚠️ 不推荐 · 👑 限高端旗舰 | hf-mirror + ModelScope |
| LFM 2.5 2.6B (Q4_K_M) | 1.6 GB | text | 2.0 GB | ⭐ 推荐 · ⚡ 速度快 | ModelScope |
| Gemma 3 4B (Q4_K_M) | 2.6 GB | text | 3.0 GB | ⭐ 推荐 | hf-mirror + ModelScope |
| Gemma 4 E2B (Q4_K_M 视觉+语音) | 3.1 GB | vision | 4.0 GB | ⭐ 推荐 · MTP · 🖼️ 视觉 · 🎧 语音 | hf-mirror + ModelScope |
| Bonsai 27B (Q1_0 1-bit) | 3.8 GB | text | 6.0 GB | 探索用 | hf-mirror + huggingface |
| Bonsai 27B (Ternary 1.58-bit) | 7.2 GB | text | 10.0 GB | ⚠️ 不推荐 · 👑 限高端旗舰 | hf-mirror + huggingface |

> 视觉模型（`vision`）含投影器 mmproj：Qwen3.5-0.8B/2B/4B 为 `text + mmproj` 两文件形态；
> Gemma 4 E2B 的 mmproj 还自带 **原生语音编码器**（🎧 语音理解，配合麦克风按住说话拾音）。
> 总下载体积 = 主模型 + 投影器。UI 上的 **🖼️ 视觉** 标签即对应此类模型。

> **标签语义**：`⭐ 推荐`（绿，官方推荐）、`⚠️ 不推荐`（红，体积/内存要求过高不适合日常）、
> `👑 限高端旗舰`（金，需大内存旗舰机）、`🖼️ 视觉`、`🎧 语音`、`⚡ CPU 加速`、`⚡ 速度快`、
> `MTP`（支持多 token 预测投机解码）。

> 带 **MTP** 的模型支持多 token 预测（Multi-Token Prediction），可在设置页为该模型单独开启
> 投机解码加速。

> 端侧 1-bit / 1.58-bit 量化（Bonsai-27B）：Q1_0（±1，每 128 权重共享 1 个 FP16 scale）与
> Ternary Q2_0（三值，1.58-bit）。这类超低位模型体积小，但**主分支 llama.cpp CPU/GPU 内核
> 无专用 1-bit 解码加速**（官方快照依赖 PrismML fork 的 CUDA/Metal 内核），在本机 Adreno 825 +
> OpenCL 全量卸载实测约 2.7-2.9 tok/s（Vulkan 2.83 tok/s，两后端等价），适合作为大上下文/探索用，日常问答优先选 4B 以下模型。

**新增一个模型只需在 JSON 的 `models` 数组追加一项：**

```json
{
  "id": "my-model-q4_k_m",
  "name": "My Model (Q4_K_M)",
  "type": "text",
  "mirrors": [
    { "url": "https://hf-mirror.com/owner/repo/resolve/main/model-Q4_K_M.gguf", "source": "hf-mirror" },
    { "url": "https://modelscope.cn/api/v1/models/owner/repo/resolve/main/model-Q4_K_M.gguf", "source": "modelscope" }
  ],
  "sizeGB": 2.7,
  "sizeMBDisplay": "2.7 GB",
  "recommended": false,
  "minRamMB": 3500,
  "sha256Hash": null
}
```

（可选）把 `lib/models/model_catalog.dart` 里的 `remoteUrl` 指向自有 CDN 上的同名 JSON，
即可在发版后**热更新模型列表**，连重新打包都不需要。

### 技术实现

- **Dio** HTTP 客户端 + `onReceiveProgress` 回调实时上报进度
- **HTTP Range** 头实现断点续传（检查 `.tmp` 文件长度后从断点继续）
- **Riverpod StateNotifier** 管理下载状态，UI 自动响应更新
- **最多同时 2 个并发下载**任务（容量守卫 + 界面计数双重限制）
- 下载中支持 **[暂停]** / **[删除]**：删除会取消当前传输并清理主模型 / mmproj 及其 `.tmp` 残留

### 模型加载与管理

应用支持完整的模型生命周期管理：

| 状态 | 说明 | UI 表现 |
|------|------|---------|
| `idle`（未加载） | 无模型在内存中 | 灰色 "未加载"，聊天界面显示 [去加载] 按钮 |
| `loading`（加载中） | 正在从磁盘加载到内存 | 蓝色进度环 + 模型名，UI 禁用交互 |
| `loaded`（已加载） | 模型已在内存中可推理 | 绿色 "已加载"，聊天界面显示 [卸载] 按钮 |
| `unloading`（卸载中） | 正在释放内存 | 橙色进度环 |
| `error`（错误） | 加载失败 | 红色错误信息 + [重试] 按钮 |

**单模型约束**：同一时间只允许一个模型在内存中运行，切换或加载新模型时自动卸载旧模型。

**存储信息直接扫描磁盘**：设置页"存储信息"区域直接扫描 `models/` 目录下的所有 `.gguf` 文件，即使模型 ID 不在 catalog JSON 中也能正确显示（避免重装 APK 后已下载模型消失）。

**推理日志**：`inference_log_screen.dart` 查看页展示模型加载、卸载、生成的完整过程日志，并针对每次
大模型交互记录请求/响应概况与性能指标（提示长度、历史条数、生成 token 数、**首 token 延迟**、
**tok/s**、总耗时、输出字数），便于排查速度与正确性问题。**tok/s 口径已对齐真实值**：JNI 回传
`n_gen`（llama.cpp 真实 decode token 数，中文 1 汉字≈1.5-2 token）与 `t_gen_ms`（纯生成耗时，不含
prefill），聊天气泡显示的 tok/s 与 logcat 完全一致。

---

## API 接入（OpenAI 兼容远程模型）

> 端侧模型之外，App 还支持接入 **OpenAI 兼容**的远程推理端点（`{baseUrl}/chat/completions`），
> 在「设置 → API 接入」标签页配置。云端大模型（如 GPT-4o、Qwen 系列）与本地自建的
> llama.cpp 服务（如 `http://127.0.0.1:8080/v1`）均可接入，与端侧模型共用同一套聊天界面。

### 配置项

每个 API 模型包含：**名称**、**baseUrl**（端点根地址，如 `https://api.openai.com/v1`）、
**API Key**、**远端模型名**（如 `gpt-4o`、`qwen2.5-7b-instruct`）、**温度**、**输出上限**，
以及**是否支持视觉**（手动勾选——远程端点能力无法自动探测）。

> 配置以明文保存在与本地推理设置同一个 settings JSON 里（`lib/models/api_model.dart`），
> 适合本地个人使用。

### 路由策略（本地优先）

- 激活某个 API 模型后，聊天默认 **Local-first**：本地模型可用则优先本地，仅当本地
  **不可用**（未缓存 / 加载失败）时才回退到激活的 API。
- 若用户**不运行本地模型**且**未设置默认模型**（无本地意图），则直接走 API 接入，
  不再自动去加载本地模型——保证 API 一定会被触发。
- 支持在设置页随时 **启用 / 停用** API 接入，停用后聊天仅使用本地模型。

### 视觉处理

- 开启视觉（`visionCapable`）的端点：带图消息以 OpenAI content-parts 形式（base64
  `image_url`）发送，历史中的带图消息同样转换；
- 未开启视觉的端点：图片剥离为纯文本 `[图片]` 占位，**绝不发送原始图数据**。

---

## 运行

```bash
# 连接 Android 设备后运行
flutter run -d <device_id>

# 查看推理日志
flutter logs | grep TongYiLite
```

### GPU 加速（Vulkan / OpenCL 双后端）

构建时若满足上面的依赖，APK 会同时包含 `libggml-vulkan.so`（内嵌预编译 SPIR-V 着色器）与
`libggml-opencl.so`（附 OpenCL 运行时 dlopen 转发 stub，见下方说明）。
**是否在运行时真正用 GPU、用哪个后端，由 App 启动时探测 + 用户在设置页选择决定**，不靠硬编码：

- `tongyilite_jni.cpp` 在加载模型时遍历 ggml 后端注册表（`ggml_backend_dev_count()` /
  `ggml_backend_dev_get()`），打印每个设备名称 / 类型 / 显存，并按用户所选后端初始化。
- 在「设置 → 推理引擎」标签页：
  - **「GPU 加速」开关（默认开启）** 与 **GPU 后端选择（自动 / OpenCL / Vulkan）**：
    - 开关关闭 → 强制纯 CPU（`n_gpu_layers = 0`）；
    - 开关开启 → 按所选后端卸载到 GPU（`auto` 优先 OpenCL，探测不到对应后端时回落 CPU）。
  - **「GPU 层数」滑块（默认 100 = 全量卸载）**：llama.cpp 会按模型实际层数自动 clamp；
    全量卸载已实测正确且最快（混合 CPU+GPU 部分卸载会引入串行同步，不加速且未验证正确性）。
  - **「上下文大小」滑块（默认 4096，范围 1024~65536）**：控制 KV 缓存按 `n_ctx` 预分配的大小，
    短对话可调小省内存、长对话/长上下文任务调大。
  - 设置经 `MethodChannel → Kotlin → JNI` 透传给原生层，实时生效、重启保留。

**OpenCL 后端（Adreno 推荐）**：在 Adreno（骁龙 7+ 系）设备上 OpenCL 驱动优化充分，与 Vulkan
解码吞吐几乎等价（实测 4B/27B 两模型下相差 <2%）。OpenCL 依赖设备 `libOpenCL.so`，通过
`third_party/opencl-stub/opencl_stub.c` 的 **dlopen 转发 stub** 动态加载：设备无驱动时后端探测到
0 设备 → 自动回落 CPU，不会因缺少 OpenCL 而崩溃。

**OpenCL 版本 / 依赖要求**（构建与运行）：
- **构建期**：须本地 vendored 两份依赖——`third_party/OpenCL-Headers`（Khronos 头文件，header-only）
  与 `third_party/opencl-stub`（仅提供链接期 `cl*` 弱符号桩，运行时由设备 `libOpenCL.so` 覆盖）。
  Android NDK 不自带 OpenCL SDK，故二者不可省略。
- **目标 GPU**：`GGML_OPENCL_USE_ADRENO_KERNELS`（默认 ON）为 **Adreno 700+** 提供优化内核；
  其他 GPU 走通用路径（性能/正确性未经本机验证）。
- **运行期**：设备须提供 `libOpenCL.so`（经 dlopen 加载）；无驱动则探测到 0 设备 → 自动回落 CPU，不崩溃。
- 同样**仅 `arm64-v8a` 启用**（见下方注意）。

**Vulkan 后端（天玑 Mali 专项修复 · v0.1.6）**：v0.1.6 前在 MediaTek 天玑（Mali-G68 等）
上选 Vulkan 后端，加载模型或首次推理即 SIGSEGV。真机定位根因：**Mali 驱动的
`vkGetDeviceQueue2`（Vulkan 1.2）返回 dispatch 表为 NULL 的坏 queue**，首次
`vkQueueSubmit` 崩在 loader trampoline（`vulkan::api::QueueSubmit+0`）。v0.1.6 在
`ggml-vulkan.cpp` 内对 **ARM vendor（0x13B5）** 做了 3 处 patch（真机验证通过）：
改用 Vulkan 1.0 的 `vkGetDeviceQueue` 获取 queue、强制禁用 `internallySynchronizedQueues`
特性、强制禁用 `buffer_device_address`（驱动上报 true 但 `getBufferAddress` 崩溃）。
排查中排除的项：APK 内 Vulkan 验证层（Flutter debug 打包带入的 13MB
`libVkLayer_khronos_validation.so`，已从打包排除）、`GGML_VK_DISABLE_*` 系列开关。

> **天玑上 OpenCL 不可用是硬件生态现实，非 bug**：天玑系统内的 `libOpenCL.so` 仅为 72KB
> Khronos ICD 加载器空壳（`clGetPlatformIDs` 走 `khrIcdInitialize` 后枚举 0 平台），
> `/vendor/etc/OpenCL/vendors/` 无任何 Mali 驱动注册——联发科未在 Android 上打包
> ARM 专有的 Mali OpenCL 驱动（高通 Adreno 则完整打包）。因此设置页在 MediaTek SoC 上
> 将 OpenCL 选项**置灰禁用**并提示「天玑芯片不支持 OpenCL，优先 Vulkan」。

> **性能提示（天玑）**：Mali-G68 无矩阵加速单元，llama.cpp Vulkan 后端在其上解码约
> 为 CPU 的 1/3（0.8B 实测 ~5.7 vs ~17 tok/s），属硬件天花板（社区 PR #18493/#27163
> 佐证，均未合入主线）。GPU 卸载在 4B+ 大模型上仍可显著省内存；日常小模型建议 CPU。

**验证是否真的上了 GPU**（连上设备后）：

```bash
adb logcat -c
adb shell am start -n com.dgxspark.tongyilite/.MainActivity
adb logcat | grep -iE "TongYiLite|ggml_vulkan|OpenCL"
```

预期看到（默认开启 GPU、设备有对应后端驱动时）：

```
ggml backend devices: 2
  device[0] name=Adreno 825        type=2 mem=.../... MiB   # Vulkan 后端把 Adreno 枚举为 IGPU (type=2)，不是 GPU
  device[1] name=QUALCOMM Adreno(TM) type=1 mem=.../... MiB   # OpenCL 后端枚举为 GPU (type=1)
auto -> OpenCL                                          # 默认 auto 优先 OpenCL；手动选 OpenCL 才打印 "OpenCL selected"
n_gpu_layers = 100                                       # 使用设置页设定的层数（llama.cpp 自动 clamp 到模型层数）
n_ubatch = 512 (GPU backend)                             # GPU 路径放大 prefill batch（CPU 模式为 16，见「已知问题」）
```

> 设备名 / 显存因机型而异，上面是骁龙 8s Gen 4（Adreno 825）的示例。**关键**：Android 上
> Vulkan 把移动 GPU 枚举为 `IGPU (type=2)`、OpenCL 枚举为 `GPU (type=1)`，与桌面端相反；
> 后端选择日志取决于设置（`auto` 优先 OpenCL、`vulkan` 打印 `Vulkan selected …`、`opencl`
> 打印 `OpenCL selected`、两者都无则 `auto -> no GPU backend found, CPU fallback`）。

> **注意**：Vulkan/OpenCL 后端目前 **仅 arm64-v8a** 启用（`CMakeLists.txt` 里两个后端只在
> `ANDROID_ABI == arm64-v8a` 时强制 ON）。32 位 / x86 设备仍走 CPU。

### CPU 加速（KleidiAI）

即使不开 GPU，纯 CPU 推理也通过 KleidiAI + 微架构调优保持可用速度：

- **KleidiAI dotprod 内核**：`CMakeLists.txt` 通过 `GGML_CPU_ARM_ARCH=armv8.2-a+dotprod`
  让 ggml 为本机 Adreno/Snapdragon 编译 dotprod 手调 matmul 内核（这是**正确做法**；直接往
  `CMAKE_C_FLAGS` 塞 `-march` 不会传到 kai 源文件，会导致内核被静默跳过）。
  ⚠️ **不要加 `+i8mm`**：天玑 8200 / 920 的 Cortex-A78（ARMv8.2-A）支持 dotprod 但不支持
  i8mm（需 ARMv8.6-A/ARMv9），在 `armv8.4-a+dotprod+i8mm` 下执行 `i8mm` 指令会 **SIGILL**，
  崩溃发生在共享的 CPU 加载/repack 路径，表现为"三后端全崩"。已降级为 `armv8.2-a+dotprod`，
  dotprod 内核仍可用，代价仅是 i8mm 量化内核不可用（性能影响可接受）。
- **Debug 构建也强制 `-O3 -DNDEBUG`**：Android debug 变体默认 `-O0` 且无 `NDEBUG`，会让 llama.cpp 的
  量化 matmul 内核完全失去优化（曾导致 0.5B 模型仅约 0.6 tok/s，0.8B 约 1.2 tok/s）。
  ⚠️ **坑：仅设 `CMAKE_C_FLAGS_DEBUG "-O3 -DNDEBUG"` 不够**——Android NDK 工具链会在 Debug 配置重新套上
  自己的 `-g`，**静默顶掉该变量**（实测 2026-08-07：compile_commands 里 180 个 ggml-cpu/kleidiai 源文件
  只有 `-march`、完全没有 `-O3`/`-DNDEBUG`，全部模型同等降速到 ~1.2 tok/s，即"像没做 KleidiAI"）。
  **正确做法**：改用 NDK 覆盖不了的目录级 `add_compile_options(-O3)` + `add_compile_definitions(NDEBUG)`，
  它会传给 llama/ggml-cpu/kleidiai/mtmd 所有子目录目标。`NDEBUG` 附带让越界的 `get_logits_ith` 返回
  `nullptr` 而非中止进程。改 CMake 后必须清 `.cxx` 全量重建，并核对 compile_commands 同时含
  `-O3 -DNDEBUG -march`。
- **版本与微架构要求**：KleidiAI 固定 vendored **v1.24.0**——llama.cpp b10173 的 FetchContent 默认拉取
  `kleidiai-v1.24.0-src.tar.gz`，本项目改为本地 vendored **同一 tag** 以离线构建（版本须与 llama.cpp
  对应 release 匹配）。其 dotprod 内核要求 CPU 具备 **Armv8.2-a + dotprod** 特性
  （Cortex-A78 / A720 / X4 / A520 等）；不满足时 ggml-cpu 静默回退到通用 NEON，CPU 推理仍可跑但无加速。
  KleidiAI 内部仅接管 Q4_0/Q8_0 的 matmul 派发，本项目 Q4_K_M 不直连其派发，但仍受益于该路径的 dotprod 加速。

验证 CPU 内核是否真生效（编译后查 `compile_commands.json`，dotprod 计数应 >0、i8mm 为 0）：

```bash
grep -c "kai_matmul.*dotprod" android/app/.cxx/Debug/*/arm64-v8a/compile_commands.json
grep -c "kai_matmul.*i8mm"    android/app/.cxx/Debug/*/arm64-v8a/compile_commands.json  # 预期 0（已禁用）
```

### SME2（暂未启用 · 决策记录，2026-08-05）

vendored 代码里 **SME2 内核确实存在且可用**：`ggml-cpu/CMakeLists.txt` 支持 `GGML_INTERNAL_SME`
（设 `ARM_MCPU=armv9.2-a` + `GGML_USE_SME`），并把 **KleidiAI 的 SME/SME2 4-bit 权重 matmul 内核**
（`qsi4c32p4vlx4` 等，正覆盖本项目的 Q4_K_M）编进多架构变体——**但本构建根本没有走这条路**：

- 本 `CMakeLists.txt` 用 `set(GGML_CPU_ARM_ARCH armv8.2-a+dotprod CACHE STRING "" FORCE)` 把 arch
  **钉死**，ggml-cpu 直接走 `else` 分支、跳过 SME/SVE 自动探测与多变体编译；
- 根因是交叉编译：构建主机（Windows/MinGW）用 `check_cxx_source_runs` 探测 aarch64 特性必然失败，
  故改用显式 arch 传参——SME2 源文件因此在本 build 中是死代码。

**决策：暂不启用 / 实现 SME2。依据：**

1. **当前设备拓扑受限**：骁龙 8s Gen 4（SM8735 / Adreno 825）仅 1 颗 Cortex-X4 大核有 SME2，
   其余 7 颗 A720 无。ggml 线程池铺满 8 核时，SME2 内核要么因"并非所有核支持"整体回退到 dotprod（等于没加速），
   要么在 A720 上 SIGILL 崩溃——可用面被极大压缩。
2. **主推理路径不经 CPU matmul**：默认 `gpuLayers=100` 全量卸载到 GPU（OpenCL/Vulkan），CPU 仅做少量
   残差。SME2 只能加速纯 CPU fallback 路径，而该路径本就非推荐配置，`dotprod` 已够用。
3. **价值拐点尚未到来**：SME2 的显著收益需等到 **全核 SME2 同构设备**，例如
   **天玑 9500（Arm Lumex C1，Ultra/Premium/Pro/Nano 全系集成 SME2）** 及后续同构平台。
   在此之前开启 SME2 需改 `GGML_CPU_ALL_VARIANTS` 交叉编 SME2 汇编内核 + 解决异构核分派，投入高、回报低。

> 结论：保持现状 `dotprod`（正确、稳定、已验证；i8mm 已因 Cortex-A78 设备 SIGILL 禁用）。
> 待目标设备为全核 SME2（如天玑 9500 级）或确需榨干纯 CPU 推理时，再重开 SME2 这条路。

### 麦克风按住说话拾音（语音输入 · 2026-08-08）

聊天输入区支持**按住说话**直接语音输入，模型侧由 mmproj 自带的原生语音编码器理解
（仅对带 🎧 语音能力的模型开放，如 Gemma 4 E2B）：

- **交互**：长按麦克风按钮录音，松开即发送；UI 带波形动画 + 计时 + 聆听反馈。
  用 `GestureDetector` + `ValueNotifier` 实现，规避 `Tooltip` 抢占长按手势。
- **原生链路**：`RECORD_AUDIO` 权限（不足时引导前往系统设置）→ `AudioRecorder.kt`
  按模型要求的采样率录 **16-bit PCM → 44 字节头 WAV**（缓存目录）→ 走
  `completion_with_media` 多媒体路径（按魔数自动识别图片/音频）→ 原生编码后回复。
- **能力门控**：JNI 加载时用 `mtmd_support_audio` / `mtmd_get_audio_sample_rate` 探测
  mmproj 是否带语音编码器，`supportsAudio` / `audioSampleRate` 透传 Dart；无音频编码器的
  模型自动禁用麦克风，避免误送音频导致原生崩溃。
- 音频回复的 **"听音时间"**（`t_audio_ms`，音频编码 wall time）随每次交互一并入日志与统计。

---

## 远程任务 + Plugin（荒野求生模式）

见 [`docs/plugin_architecture.md`](docs/plugin_architecture.md) 设计文档。

远程指令通过 WebSocket / HTTP 推送至设备，Plugin 引擎离线执行后回传结果。支持：

- **视觉任务** — 拍照分析
- **语音任务** — 录音转写
- **文本任务** — LLM 处理
- **文件任务** — 本地处理

---

## 架构决策记录

### P0 已实现 ✅（基于 llama.cpp b10173 官方示例验证）

| # | 功能 | 状态 | 说明 |
|---|------|------|------|
| 1 | **JNI 直调** | ✅ | 无 HTTP Server，高效省内存 |
| 2 | **CPU 推理** | ✅ | KleidiAI dotprod（`GGML_CPU_ARM_ARCH=armv8.2-a+dotprod`）+ 微架构调优 + Debug `-O3`；Vulkan 不可用时回退 |
| 3 | **模型下载系统** | ✅ | Dio + HTTP Range 断点续传 + 镜像自动回退（hf-mirror/ModelScope，见 models_catalog.json） |
| 4 | **设置页 UI** | ✅ | 模型选择、下载进度、存储信息展示 |
| 5 | **对话持久化** | ✅ | SQLite (sqflite) 存储对话和消息历史 |
| 6 | **Vulkan GPU 加速** | ✅ | arm64-v8a 启用 ggml-vulkan 后端；实际卸载层数由设置页 gpuLayers 透传（默认 100=全量，llama.cpp 自动 clamp 到模型层数），无 GPU 自动回退 CPU；**v0.1.6 起含天玑 Mali 专项修复**（`vkGetDeviceQueue2`→`vkGetDeviceQueue` 等 3 处 patch，真机验证不崩） |
| 7 | **批量预填充 + unified KV** | ✅ | prefill 用大 batch（n_batch=512）+ unified KV 缓存；**`n_ubatch` 按后端动态**：GPU 路径 512（加速 prefill）、CPU 路径 16（规避 ggml-cpu 量化 GEMM 路径 bug，见「已知问题」） |
| 8 | **内置采样器** | ✅ | `llama_sampler_chain`：penalties → top_k(128) → top_p → temp → dist，采样后 `llama_sampler_accept` 回喂历史（重复惩罚生效、防退化循环） |
| 9 | **流式回调批量化** | ✅ | `on_token` 回调按 8 字节（≈2 个 CJK 字符）批量发送，兼顾逐字流式观感与 JNI 往返开销 |
| 10 | **mmap 加载** | ✅ | 模型加载从全量读入 RAM 改为 mmap，降低峰值内存与 OOM 风险 |
| 11 | **flash attention + 线程策略** | ✅ | flash_attn_type 当前 DISABLED（AUTO 在 CPU 后端会实际启用且多轮乱码，见「已知问题」）；`n_threads` 按 `/proc/cpuinfo` CPU part 识别大小核拓扑，全大核 SoC 用全部核（如 SM8735 用 8），big.LITTLE 只调度大核 |

### P1 计划 🚧

6. **视觉理解增强**：mmproj 视觉投影器已支持单图理解（v0.1.3+，编码后端跟随主后端选择，
   Vulkan/OpenCL/CPU 均可）；待增强：多图理解、视频帧输入
7. **语音识别**：sherpa-onnx (WeNet) 流式 STT
8. **TTS 播报**：Android TextToSpeech 离线引擎
9. **Plugin 市场**：热插拔、签名验证、沙箱

---

## 已知问题与踩坑记录

### 多轮对话第二轮乱码（已修复 · 2026-08-04）

**症状**：第一轮对话（如"你好"）回复正常；第二轮（如"你是谁"，带历史上下文）输出
`rekl bytesRead,}` / `oother民nedbish枉叶` 等乱码，且生成上百 token 不停（无 EOS）。

**根因**（真机日志 + 反汇编逐步定位）：

1. **量化 GEMM 路径计算出错**：`n_ubatch=512` 时，prompt 超过 32 tokens 的 prefill 会进入
   ggml-cpu 的量化 GEMM 路径，而该路径在本 build 下产生垃圾 logits。
   第一轮 "你好" 仅 15 tokens（<32，走 vec_dot 路径）所以正常 —— 与 flash attention、KleidiAI
   均无关（KleidiAI 只支持 Q4_0/Q8_0，本项目模型为 Q4_K_M 不会接管）。
2. **重复惩罚失效**：采样循环缺 `llama_sampler_accept()`，penalties sampler 的 token 历史
   永远为空 → repeat penalty 永不生效 → 模型陷入退化循环（如 token 9841/57699 反复出现）。

**修复**：`n_ubatch` **按后端动态分设**——CPU 路径保留 `16`（强制走正确的 vec_dot 路径，首 token 延迟略增但输出正确），GPU 路径放大到 `512`（prefill 走 GPU kernel，不踩 CPU 量化 GEMM bug，显著提速 prefill）；采样后补 `llama_sampler_accept(smpl_chain, new_token)`。GEMM 路径的底层 bug 需后续在 ggml-cpu 侧修复后才能让 CPU 也恢复大 ubatch。已真机验证：GPU 512 / CPU 16 双路径均正确、多轮无乱码。

### Flash Attention 陷阱（2026-08-04）

`flash_attn_type=LLAMA_FLASH_ATTN_TYPE_AUTO` 在本 build 的 **CPU 后端也会实际启用**（ggml-cpu
实现了 FLASH_ATTN_EXT op），并非注释所说的"CPU 上静默 no-op"。该组合在 seq_rm 清空 KV 后
第二轮 prefill 产生垃圾 logits。当前 `DISABLED`，待验证状态重置后可按需恢复。

### 采样器链必须以 dist 收尾（2026-08-04）

`llama_sampler_chain` 只有 top_k/top_p/temp 时，`llama_sampler_sample()` 会命中
`GGML_ASSERT(cur_p.selected >= 0)` 直接 SIGABRT（debug 构建，`llama-sampler.cpp:870`）。
链末必须追加 `llama_sampler_init_dist(seed)` 实际抽样并设置 `selected`。
采样链完整顺序：`penalties → top_k(128) → top_p → temp → dist`。

### 视觉模型 mmproj 缺失/损坏闪退（已修复 · 2026-08-08）

**症状**：下载文本模型后未自动补全视觉投影器 mmproj，加载时提示"缺少 mmproj"后闪退。

**根因**：加载路径只检查 `mmproj` 文件 `existsSync()`，损坏/不完整的投影器（下载中断残留的
`.mmproj.tmp`、0 字节、或 catalog 估算体积与实际不符导致提前 rename）也会放行进原生
`mtmd_init_from_file`，视觉推理时崩溃。

**修复**：① 视觉模型下载闭环——主 `.gguf` 与 `.mmproj` 顺序下载，两者完整才算"已缓存"，
缺投影器时点击 **[下载(含投影器)]** 只补下投影器；② 加载前做完整性复核（存在、无 `.tmp`、
非空），不合格则优雅提示"缺少或不完整的 mmproj，请重新下载完整模型"，不再闪退。

---

## 常见问题

<details>
<summary><b>Q: 构建时报 Gradle plugin "dev.flutter.flutter-gradle-plugin" not found</b></summary>

该插件不发布到任何公开 Maven 仓库，必须通过 `includeBuild` 复合构建从 Flutter SDK 本地解析。确保 `settings.gradle.kts` 中包含：
```kotlin
pluginManagement {
    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")
}
```

</details>

<details>
<summary><b>Q: dl.google.com 连接超时 / Maven 依赖下载失败</b></summary>

国内网络访问 Google CDN 不稳定。已在 `pluginManagement.repositories` 和 `allprojects.repositories` 中添加阿里云镜像：
- `https://maven.aliyun.com/repository/google`
- `https://maven.aliyun.com/repository/public`
- `https://maven.aliyun.com/repository/gradle-plugin`

</details>

<details>
<summary><b>Q: CMake 找不到 llama.cpp / 路径错误</b></summary>

CMakeLists.txt 中从 `android/app/src/main/cpp/` 到项目根目录需要 **5 层** `../`。当前配置已验证通过：
```cmake
set(PROJECT_ROOT_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../../../../../../..)
```

</details>

<details>
<summary><b>Q: 如何启用 / 排查 Vulkan GPU 加速？</b></summary>

Vulkan 后端 **默认已对 arm64-v8a 启用**（只要构建主机满足依赖）。若编译或运行仍走 CPU，按以下排查：

1. **确认 LunarG Vulkan SDK 已安装**到 `C:/VulkanSDK/1.4.357.0`（提供 `glslc` + `SPIRV-Headers` + `<vulkan/vulkan.hpp>`）。可在 PowerShell 验证：
   ```powershell
   Test-Path 'C:\VulkanSDK\1.4.357.0\Bin\glslc.exe'
   Test-Path 'C:\VulkanSDK\1.4.357.0\Include\vulkan\vulkan.hpp'
   ```
2. **确认 MinGW-w64 在 `C:/mingw64`**（提供 `gcc.exe` / `g++.exe`）。`vulkan-shaders-gen` 主机工具需要它来预编译着色器。
3. **改了 CMakeLists / 工具链后必须清 `.cxx` 缓存**，否则 Gradle 判定 up-to-date 不重编：
   ```powershell
   Remove-Item -LiteralPath 'android\app\.cxx' -Recurse -Force
   ```
4. **运行时确认**：`adb logcat | grep -iE "TongYiLite|ggml_vulkan"`，看 `ggml backend devices` 与 `n_gpu_layers`。若 `n_gpu_layers = 0` 说明设备未枚举到 GPU。

构建主配置成功时会打印 `Vulkan ENABLED (GPU backend) for arm64-v8a` 与 `Vulkan shaders-gen host toolchain -> ...`。

</details>

<details>
<summary><b>Q: JNI 编译报 "unknown type name 'common_chat_templates'" / API 不兼容</b></summary>

llama.cpp b10173 大幅重写了 API，`llama_model*` 相关调用需改用 `llama_vocab*`。已适配所有变更：
- `llama_new_context_with_model()` → `llama_init_from_model()`
- `llama_tokenize(model, ...)` → `llama_tokenize(vocab, ...)`
- `llama_token_eos(model)` → `llama_vocab_eos(vocab)`
- 手动实现 temperature + top-p 采样（`llama_sampler_init_simple` 不存在）

</details>

<details>
<summary><b>Q: NDK / CMake 错误</b></summary>

确保已安装以下工具：
```bash
# Android SDK cmdline-tools (含 sdkmanager)
sdkmanager "ndk;27.0.12077973" "cmake;3.22.1" --install

# 验证
echo $ANDROID_NDK_ROOT
echo $ANDROID_HOME
```

</details>

<details>
<summary><b>Q: 推理速度慢 / 内存溢出</b></summary>

- 尝试使用更小的模型（如 Qwen3-0.6B 或 Qwen3-1.7B Q3_K_M）
- 关闭后台应用释放 RAM
- 设备需 ≥ 4GB RAM 才能流畅运行 1.7B 模型
- 确保 Vulkan GPU 加速已启用（检查设置页是否显示"已完成"状态）
- 已优化：批量预填充 + unified KV（n_batch=512；GPU 路径 n_ubatch=512 / CPU 路径 16，长 prompt 下 TTFT 较旧版降 10-30×）、flash attention 当前 DISABLED（AUTO 在 CPU 后端会实际启用且多轮乱码，见「已知问题」）、线程按 CPU 拓扑取核（`detect_big_core_count`：全大核 SoC 用全部核、big.LITTLE 只调度大核；旧"核心数/2"启发式已废弃）、内置采样器（消除每 token 150k+ 堆分配）、流式回调批量化（减少跨语言往返）、mmap 加载（降低峰值内存）

</details>

<details>
<summary><b>Q: 模型下载失败 / 速度慢</b></summary>

- 应用会自动尝试多个镜像源，无需手动切换
- 如所有镜像均不可用，请检查网络连接或开启代理
- 支持断点续传：中断后点击"继续"即可从断点恢复

</details>

<details>
<summary><b>Q: 如何添加自定义 Plugin？</b></summary>

参考 `docs/plugin_architecture.md` 中的 Plugin 开发指南。每个 Plugin 需实现统一接口并通过签名验证。

</details>

---

## 贡献指南

欢迎提交 Issue 和 Pull Request！请先阅读 [CONTRIBUTING.md](CONTRIBUTING.md)。

---

## License

[MIT](LICENSE) — 自由使用、修改和分发。
