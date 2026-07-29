# TongYi-Lite 端侧离线 AI 智能体

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

端到端离线的 Android AI 助手。支持本地模型推理、视觉理解、语音识别、TTS 播报，内置 Plugin 系统和荒野求生游戏化任务。数据不出设备。

## 快速概览

| 维度 | 说明 |
|------|------|
| **目标平台** | Android APK (API 33+) |
| **推理引擎** | llama.cpp b1017+ (CPU/KleidiAI/SME2) |
| **默认模型** | Qwen3-1.7B-Instruct Q4_K_M (~1.2 GB) |
| **前端框架** | Flutter 3.x (Material3) |
| **通信方式** | JNI 直调 (无 HTTP Server) |
| **模型下载源** | ModelScope (阿里) |

## 项目结构

```
TongYi-Lite/
├── android/                          # Android 原生层
│   ├── app/build.gradle.kts          # Gradle 配置
│   ├── settings.gradle.kts
│   ├── gradle.properties
│   └── app/src/main/
│       ├── cpp/CMakeLists.txt        # llama.cpp NDK 构建
│       ├── cpp/tongyilite_jni.cpp    # JNI 桥接层
│       ├── java/com/dgxspark/tongyilite/
│       │   ├── MainActivity.kt       # Flutter + MethodChannel
│       │   ├── InferenceEngine.kt    # Kotlin 推理封装
│       │   └── service/InferenceService.kt  # 前台服务
│       └── AndroidManifest.xml
├── lib/                              # Flutter Dart 层
│   ├── main.dart                     # 入口
│   ├── models/                       # 数据模型
│   ├── services/                     # 推理/存储/模型管理
│   ├── widgets/                      # UI 组件
│   ├── screens/                      # 页面
│   └── providers/                    # Riverpod 状态管理
├── docs/                             # 设计文档
│   ├── mobile_llm_benchmark_report_v2.md
│   ├── architecture_design_v2.md
│   ├── plugin_architecture.md
│   ├── implementation_plan.md
│   └── archive/                      # v1 归档文档
├── pubspec.yaml                      # Flutter 依赖
├── .gitignore
└── README.md
```

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

## 构建步骤

### 1. 克隆 + 子模块

```bash
git clone git@github.com:liangjianzeng/TongYi-Lite.git
cd TongYi-Lite
git submodule update --init --recursive
```

### 2. 获取 Flutter 依赖

```bash
flutter pub get
```

### 3. 生成模型下载目录

```bash
mkdir -p android/app/src/main/assets/models
```

### 4. 构建调试 APK

```bash
flutter build apk --debug
```

输出: `build/app/outputs/flutter-apk/app-debug.apk`

### 5. 构建发布 APK (AAB)

```bash
flutter build appbundle --release
```

输出: `build/app/outputs/bundle/release/app-release.aab`

## 模型下载

首次启动时，应用会引导你从 ModelScope 下载模型 GGUF 文件：推荐 Qwen3-1.7B-Q4_K_M (~1.2 GB)。

也可手动下载到设备存储：

```bash
# 使用 wget/curl 下载
wget -O /sdcard/TongYi-Lite/models/qwen3-1.7b-q4_k_m.gguf \
  https://huggingface.co/Qwen/Qwen3-1.7B-Instruct-GGUF/resolve/main/qwen3-1.7b-instruct-q4_k_m.gguf
```

## 运行

```bash
# 连接 Android 设备后运行
flutter run -d <device_id>

# 查看推理日志
flutter logs | grep TongYiLite
```

## 远程任务 + Plugin（荒野求生模式）

见 `docs/plugin_architecture.md` 设计文档。

远程指令通过 WebSocket / HTTP 推送至设备，Plugin 引擎离线执行后回传结果。支持：
- 视觉任务（拍照分析）
- 语音任务（录音转写）
- 文本任务（LLM 处理）
- 文件任务（本地处理）

## 架构决策记录

### P0 修正（基于 llama.cpp b1017 官方示例验证）
1. **Android GPU 加速 → CPU-only MVP**：官方 Android 预编译包仅 CPU（KleidiAI + SME2），Vulkan 需自研 NDK
2. **HTTP Server → JNI 直调**：官方 `com.arm.aichat` 示例用 JNI 无 HTTP，更高效省内存
3. **VL 模型内存 3-3.5GB**（含 mmproj）：视觉模块需分层降级策略

### P1 计划
4. **视觉理解**：Qwen2.5-VL-3B + mmproj
5. **语音识别**：sherpa-onnx (WeNet) 流式 STT
6. **TTS 播报**：Android TextToSpeech 离线引擎
7. **Plugin 市场**：热插拔、签名验证、沙箱

## License

MIT
