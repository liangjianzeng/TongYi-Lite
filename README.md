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
| **默认模型** | Qwen3-1.7B-Instruct Q4_K_M (~1.2 GB) |
| **前端框架** | Flutter 3.x (Material3) |
| **通信方式** | JNI 直调 (无 HTTP Server) |
| **模型下载源** | hf-mirror.com → ModelScope → HuggingFace（自动回退） |

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
│   │       │   └── tongyilite_jni.cpp  # JNI 桥接层（GPU offload -1）
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
│   ├── main.dart                     # 入口（初始化 JNI + ProviderScope）
│   ├── models/
│   │   ├── model_info.dart           # ModelConfig / MirrorEntry / DownloadTask
│   │   ├── chat_message.dart         # 聊天消息模型
│   │   └── conversation.dart         # 会话模型
│   ├── services/
│   │   ├── inference_service.dart    # JNI 推理桥接（MethodChannel + EventChannel）
│   │   ├── download_service.dart     # Dio 下载核心（断点续传 + 镜像回退）
│   │   ├── model_manager.dart        # 模型缓存 / 内存检测
│   │   └── storage_service.dart      # SQLite 持久化（对话/消息）
│   ├── providers/
│   │   ├── chat_provider.dart        # Riverpod 聊天状态 + 当前模型选择
│   │   └── download_provider.dart    # Riverpod 下载任务状态管理
│   ├── screens/
│   │   ├── home_screen.dart          # 聊天主页面
│   │   └── settings_screen.dart      # 设置页（模型选择 + 下载进度）
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

```
1. hf-mirror.com     → HuggingFace 国内 CDN（最快）
2. ModelScope        → 阿里云模型社区（备选）
3. huggingface.co    → 直连（最后手段）
```

自动检测镜像可用性，失败时无缝切换下一个源。

### 支持的模型

| 模型 | 大小 | 类型 | 最低 RAM |
|------|------|------|---------|
| Qwen3-0.6B (Q4_K_M) | 420 MB | text | 500 MB |
| Qwen3-1.7B (Q4_K_M) | 1.2 GB | text | 1.2 GB |
| Qwen3-1.7B (Q5_K_M) | 1.5 GB | text | 1.5 GB |
| Qwen3.5-4B (Q4_K_M) | 2.5 GB | vision | 3.5 GB |

### 技术实现

- **Dio** HTTP 客户端 + `onReceiveProgress` 回调实时上报进度
- **HTTP Range** 头实现断点续传（检查 `.tmp` 文件长度后从断点继续）
- **Riverpod StateNotifier** 管理下载状态，UI 自动响应更新
- 最多同时 **2 个并发下载**任务

---

## 运行

```bash
# 连接 Android 设备后运行
flutter run -d <device_id>

# 查看推理日志
flutter logs | grep TongYiLite
```

### Vulkan GPU 加速

当设备支持 Vulkan 1.2+ 时，所有模型层自动卸载到 GPU（`n_gpu_layers = -1`），可获得显著的性能提升。Vulkan 不可用时自动回退到 CPU + KleidiAI/SME2 优化。

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
| 3 | **模型下载系统** | ✅ | Dio + HTTP Range 断点续传 + hf-mirror/ModelScope/HF 镜像自动回退 |
| 4 | **设置页 UI** | ✅ | 模型选择、下载进度、存储信息展示 |
| 5 | **对话持久化** | ✅ | SQLite (sqflite) 存储对话和消息历史 |

### P1 计划 🚧

6. **视觉理解**：Qwen3-VL-3B + mmproj（模型已就绪）
7. **语音识别**：sherpa-onnx (WeNet) 流式 STT
8. **TTS 播报**：Android TextToSpeech 离线引擎
9. **Plugin 市场**：热插拔、签名验证、沙箱
10. **Vulkan GPU 加速**：需安装 LunarG Vulkan SDK（glslc）后可启用

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
<summary><b>Q: CMake 报 Vulkan glslc not found</b></summary>

Vulkan GPU 加速需要 LunarG Vulkan SDK（含 `glslc` shader compiler）。当前构建已禁用 Vulkan，使用 CPU + KleidiAI/SME2 推理。如需启用 GPU 加速：
1. 安装 LunarG Vulkan SDK（https://vulkan.lunarg.com）
2. 取消注释 CMakeLists.txt 中的 `set(GGML_VULKAN ON)`

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
