# TongYi-Lite 端侧离线 AI 智能体

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Flutter](https://img.shields.io/badge/Flutter-3.x-02569B?logo=flutter)](https://flutter.dev)
[![Android](https://img.shields.io/badge/Android-33+-3DDC84?logo=android)](https://developer.android.com)
[![llama.cpp](https://img.shields.io/badge/llama.cpp-b1017+-red)](https://github.com/ggerganov/llama.cpp)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](CONTRIBUTING.md)

> **端到端离线的 Android AI 助手。** 本地模型推理（llama.cpp） · Vulkan GPU / KleidiAI CPU 加速 · 应用内模型下载与管理 · Plugin 热插拔 · 荒野求生游戏化任务
>
> **数据不出设备，隐私安全无忧。**

---

## 目录

- [快速概览](#快速概览)
- [项目结构](#项目结构)
- [前置环境](#前置环境)
- [构建步骤](#构建步骤)
- [模型下载与管理](#模型下载与管理)
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
| **目标平台** | Android APK (API 33+) |
| **推理引擎** | llama.cpp b1017+ (Vulkan GPU / KleidiAI / SME2) |
| **模型管理** | Riverpod ModelState（idle/loading/loaded/unloading/error），单模型约束，聊天界面实时状态栏 |
| **前端框架** | Flutter 3.x (Material3) |
| **通信方式** | JNI 直调 (无 HTTP Server) |
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
├── third_party/llama.cpp/          # llama.cpp 子模块 (b1017+)
│   ├── src/                        # 推理引擎源码
│   ├── ggml/src/ggml-vulkan/       # Vulkan GPU 后端
│   └── ...
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
| Android NDK r29+ | r29 | C++ 原生编译 |
| CMake 3.31+ | 3.31 | CMakeLists 解析 |
| Java JDK 17 | 17 | Gradle/Kotlin |

### 环境变量

```bash
export ANDROID_HOME=$HOME/Library/Android/sdk   # macOS
export ANDROID_SDK_ROOT=$ANDROID_HOME
export ANDROID_NDK_ROOT=$ANDROID_HOME/ndk/29.0.13113456
export JAVA_HOME=$(dirname $(dirname $(readlink -f $(which javac))))
```

### GPU / Vulkan 加速依赖（可选，但推荐）

Vulkan 后端让 llama.cpp 把模型层卸载到设备 GPU（如骁龙 Adreno / Mali），推理速度通常数倍于纯 CPU。
这部分 **仅对 `arm64-v8a` 生效**，且只在构建主机满足以下条件时才启用；不满足时自动回退到
CPU + KleidiAI/SME2，构建本身不会失败。

| 依赖 | 版本 / 路径 | 用途 | 必需 |
|------|------------|------|------|
| LunarG Vulkan SDK | `C:/VulkanSDK/1.4.357.0` | 提供 `glslc` 着色器编译器、`SPIRV-Headers` cmake 包、`<vulkan/vulkan.hpp>` C++ 头 | ✅（开 Vulkan 时） |
| MinGW-w64 (GCC) | `C:/mingw64/bin/{gcc,g++}.exe` | 在 **Windows 构建主机**上编译 `vulkan-shaders-gen` 主机工具（把 `.comp` 着色器预编译成 C++ 头） | ✅（开 Vulkan 时） |
| Android SDK cmake | `...\cmake\3.22.1\bin\ninja.exe` | 主机子构建的 Ninja 生成器（`CMAKE_MAKE_PROGRAM` 已 pin 到它） | ✅ |
| NDK Vulkan 桩库 | `${ANDROID_NDK}/.../aarch64-linux-android/${ANDROID_PLATFORM_LEVEL}/libvulkan.so` | 链接阶段用的 Vulkan loader 桩（运行时由系统提供真实实现） | ✅ |

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

### 1. 克隆 + 子模块

```bash
git clone git@github.com:liangjianzeng/TongYi-Lite.git
cd TongYi-Lite
git submodule update --init --recursive
```

> **注意**：首次 `git submodule update` 会从 GitHub 下载 llama.cpp（约 3000+ 文件），需要网络畅通。国内用户建议使用代理。

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
5. 下载完成后点击 **[加载到内存]** 即可在聊天中使用

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

| 模型 | 大小 | 类型 | 最低 RAM | 镜像 |
|------|------|------|---------|------|
| Qwen3-VL-2B (Q4_K_M) | 1.0 GB | vision | 2.0 GB | ModelScope |
| Qwen3-VL-4B (Q4_K_M) | 2.3 GB | vision | 4.0 GB | ModelScope |
| Gemma 3 4B (Q4_K_M) | 2.6 GB | vision | 3.0 GB | hf-mirror + ModelScope |
| Qwen3.5-4B (Q4_K_M) | 2.7 GB | text | 3.5 GB | hf-mirror + ModelScope |
| Qwen3-0.6B (Q8_0) | 596 MB | text | 1.0 GB | ModelScope |
| Qwen3-1.7B (Q4_K_M) | 2.3 GB | text | 3.0 GB | ModelScope |
| Qwen3-4B (Q4_K_M) | 2.3 GB | text | 4.0 GB | ModelScope |
| Qwen2.5-1.5B (Q4_K_M) | 1.1 GB | text | 1.5 GB | ModelScope |
| Qwen2.5-0.5B (Q4_K_M) | 468 MB | text | 300 MB | ModelScope |
| Qwen2.5-3B (Q4_K_M) | 2.0 GB | text | 3.5 GB | ModelScope |

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
- 最多同时 **1 个并发下载**任务

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

**推理日志**：新增 `inference_log_screen.dart` 查看页，可查看模型加载、卸载、生成的完整过程日志。

---

## 运行

```bash
# 连接 Android 设备后运行
flutter run -d <device_id>

# 查看推理日志
flutter logs | grep TongYiLite
```

### Vulkan GPU 加速

构建时若满足上面的依赖，APK 会包含 `libggml-vulkan.so`（内嵌全部预编译 SPIR-V 着色器）。
**是否在运行时真正用 GPU，由 App 启动时探测决定**，不靠硬编码：

- `tongyilite_jni.cpp` 的 `detect_gpu_layers()` 在加载模型时遍历 ggml 后端注册表
  （`ggml_backend_dev_count()` / `ggml_backend_dev_get()`），打印每个设备的名称 / 类型 / 显存；
- 发现 `GGML_BACKEND_DEVICE_TYPE_GPU`（即 Vulkan 后端枚举到了设备）就设 `n_gpu_layers = 999`
  （全部层卸载到 GPU），否则回落 `0`（纯 CPU 推理）。

这样做的好处：同一个 APK 装在没有 Vulkan 驱动的设备上也不会卡死（以前硬编码 GPU 层数会在
尝试预留显存时挂起）。

**验证是否真的上了 GPU**（连上设备后）：

```bash
adb logcat -c
adb shell am start -n com.dgxspark.tongyilite/.MainActivity
adb logcat | grep -iE "TongYiLite|ggml_vulkan"
```

预期看到：

```
ggml backend devices: N
  device[0] name=... desc=... type=2 ...   # type=2 即 GPU
n_gpu_layers = 999                           # 检测到 GPU
检测到 GPU，启用 Vulkan 加速
```

若 GPU 显存不足以容纳全部层（多见于小内存设备），把 `999` 调小为部分层数（如 `20`）即可分层卸载。

> **注意**：Vulkan 后端目前 **仅 arm64-v8a** 启用（`CMakeLists.txt` 里 `GGML_VULKAN` 只在
> `ANDROID_ABI == arm64-v8a` 时强制 ON）。32 位 / x86 设备仍走 CPU。


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

### P0 已实现 ✅（基于 llama.cpp b1017+ 官方示例验证）

| # | 功能 | 状态 | 说明 |
|---|------|------|------|
| 1 | **JNI 直调** | ✅ | 无 HTTP Server，高效省内存 |
| 2 | **CPU 推理** | ✅ | KleidiAI + SME2 加速（Vulkan 不可用时回退） |
| 3 | **模型下载系统** | ✅ | Dio + HTTP Range 断点续传 + 镜像自动回退（hf-mirror/ModelScope，见 models_catalog.json） |
| 4 | **设置页 UI** | ✅ | 模型选择、下载进度、存储信息展示 |
| 5 | **对话持久化** | ✅ | SQLite (sqflite) 存储对话和消息历史 |
| 6 | **Vulkan GPU 加速** | ✅ | arm64-v8a 启用 ggml-vulkan 后端 + 运行时 GPU 检测（`detect_gpu_layers`），无 GPU 自动回退 CPU |

### P1 计划 🚧

6. **视觉理解**：Qwen3-VL-2B / 4B（Q4_K_M）已纳入模型目录；mmproj 视觉投影器待建模（当前仅文本/单图输入路径）
7. **语音识别**：sherpa-onnx (WeNet) 流式 STT
8. **TTS 播报**：Android TextToSpeech 离线引擎
9. **Plugin 市场**：热插拔、签名验证、沙箱

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

llama.cpp b1017+ 大幅重写了 API，`llama_model*` 相关调用需改用 `llama_vocab*`。已适配所有变更：
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
sdkmanager "ndk;27.0.12077973" "cmake;3.31.6" --install

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
