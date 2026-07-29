# TongYi-Lite 产品架构设计方案

> **版本**：v1.0  
> **日期**：2026-07-29  
> **目标**：端侧离线 AI 聊天应用，Android APK 形态，类似元宝/豆包的交互体验  

---

## 目录

1. [产品定位与核心理念](#1-产品定位与核心理念)
2. [技术架构总览](#2-技术架构总览)
3. [三种方案对比分析](#3-三种方案对比分析)
4. [推荐方案：Flutter + llama.cpp JNI](#4-推荐方案flutter--llamacpp-jni)
5. [项目目录结构](#5-项目目录结构)
6. [核心交互流程](#6-核心交互流程)
7. [UI 设计与元宝/豆包对比](#7-ui-设计与元宝豆包对比)
8. [离线优先架构设计](#8-离线优先架构设计)
9. [联网能力模块（可选插件）](#9-联网能力模块可选插件)
10. [开发路线图](#10-开发路线图)

---

## 1. 产品定位与核心理念

### 核心卖点

```
┌─────────────────────────────────────────────┐
│           TongYi-Lite：你的私人 AI            │
│                                             │
│  📴 绝对离线 — 数据不出设备                  │
│  ⚡ 快速响应 — C++ 原生推理，25+ tok/s       │
│  💬 自然对话 — 类似元宝/豆包的交互体验        │
│  🔌 可选联网 — 按需调用三方 API               │
│                                             │
│  "你的对话，只属于你"                         │
└─────────────────────────────────────────────┘
```

### 与元宝/豆包的核心差异

| 维度 | 元宝/豆包（云端） | TongYi-Lite（端侧） |
|------|-----------------|-------------------|
| 数据隐私 | ❌ 对话上传到服务器 | ✅ **完全本地，不出设备** |
| 网络依赖 | ❌ 必须联网 | ✅ **默认离线可用** |
| 响应速度 | ⚠️ 受网络影响 | ✅ 25+ tok/s，稳定流畅 |
| 模型选择 | 🔒 固定云端模型 | ✅ **用户自选模型、量化精度** |
| 成本 | 💰 按量计费/会员 | ✅ **完全免费，无API费用** |

---

## 2. 技术架构总览

### 整体架构图

```
┌──────────────────────────────────────────────────────────────┐
│                    TongYi-Lite APK (Android)                  │
│                                                              │
│  ┌──────────────────────────┐    HTTP API      ┌────────────┐│
│  │   Flutter Chat UI        │ ◄─────────────►  │ llama.cpp  ││
│  │   (Flutter 3.x / Dart)   │   localhost:8080 │  Android   ││
│  │                          │                  │ Native .so ││
│  │  • Material3 聊天界面     │    ▲             │ Library    ││
│  │  • Streaming 流式输出     │    │             │            ││
│  │  • Markdown 渲染          │    │ GGUF model │            ││
│  │  • 多轮对话管理           │    ▼             └────────────┘│
│  │  • 暗/亮主题切换         │   Internal Storage              │
│  └──────────┬───────────────┘   /data/data/.../files/models/  │
│             │                                                  │
│             ▼                                                  │
│  ┌──────────────────┐                                          │
│  │ Local HTTP Server │                                          │
│  │ (embedded in      │                                          │
│  │  Flutter/Dart)    │                                          │
│  │                   │                                          │
│  │  :8080/api/chat   │                                          │
│  └──────────────────┘                                          │
│                                                              │
│  ┌─────────────────────────────────────────────┐              │
│  │ Offline-First Architecture                   │              │
│  │                                              │              │
│  │  [首次启动] → 联网下载模型 GGUF (~1.2GB)      │              │
│  │  [日常使用] → 完全离线，本地推理              │              │
│  │  [可选功能] → 联网调用第三方 API               │              │
│  └─────────────────────────────────────────────┘              │
└──────────────────────────────────────────────────────────────┘
```

### 技术选型决策矩阵

| 层次 | 候选方案 | 最终选择 | 核心理由 |
|------|---------|---------|---------|
| **前端 UI** | Flutter / React Native / Kotlin Compose | **Flutter 3.x** | Material3 开箱即有聊天模板；跨平台一套代码覆盖 APK + IPA |
| **推理引擎** | llama.cpp (C++) / MLC-LLM / ONNX Runtime | **llama.cpp Android (.so)** | GGUF 事实标准、社区最大、JNI 封装最简单 |
| **通信协议** | HTTP REST / gRPC / WebSocket | **HTTP REST + SSE** | Flutter Dio 原生支持；SSE streaming 实现打字机效果 |
| **状态管理** | Provider / Riverpod / Bloc | **Riverpod** | 类型安全、测试友好、Flutter 官方推荐 |
| **本地存储** | SQLite / SharedPreferences | **SQLite (sqflite)** | 对话历史结构化存储，支持多轮上下文检索 |
| **联网下载** | Dio / http | **Dio** | Flutter 生态最佳 HTTP 客户端，支持断点续传 |

---

## 3. 三种方案对比分析

### 🔴 方案 A：纯 Python 框架（Kivy / BeeWare）— ❌ 不推荐

| 维度 | 评估 |
|------|------|
| 思路 | Kivy 直接做 UI，Python 同时跑推理 + 前端逻辑 |
| APK 大小 | ~150MB+（含 Python 运行时） |
| 启动速度 | 慢（3-5秒） |
| UI 流畅度 | ❌ 卡顿明显，不适合聊天类应用 |
| 内存占用 | 高（Python VM + 模型各占 ~500MB+） |
| **结论** | Kivy/BeeWare 的渲染引擎太弱，聊天场景体验差 |

### 🟡 方案 B：React Native / Flutter + Python HTTP Server — ⚠️ 可行但工程复杂

```
┌─────────────────────────────────────────────┐
│              APK (Flutter/RN)                │
│                                             │
│  ┌──────────┐    localhost:8080    ┌────────┴──┐
│  │ Flutter   │ ◄────────────────► │  Python    │
│  │ Chat UI   │                    │  Backend   │
│  │ (Native)  │                    │  (Chaquopy/ │
│  │           │                    │  buildozer) │
│  └──────────┘                      └────────────┘
```

| 维度 | 评估 |
|------|------|
| UI 质量 | ✅ 好（Flutter/RN 原生渲染） |
| Python 集成 | ⚠️ Chaquopy 有兼容性问题，buildozer 打包 APK 复杂 |
| 推理性能 | ⚠️ Python 进程额外内存开销 ~200-300MB |
| 打包复杂度 | ❌ 高（需要交叉编译 Python + C++ 库到 Android） |
| **结论** | 理论可行，实际工程量大且不稳定 |

### 🟢 方案 C：Flutter UI + llama.cpp (C++) JNI — ✅ 强烈推荐

```
┌─────────────────────────────────────────────┐
│              APK (Kotlin/Flutter)            │
│                                             │
│  ┌──────────┐    HTTP/gRPC     ┌────────────┐│
│  │ Flutter   │ ◄─────────────► │ llama.cpp  ││
│  │ Chat UI   │   localhost:8080│ Native .so ││
│  │           │                 │ Library    ││
│  └──────────┘                 └────────────┘│
└─────────────────────────────────────────────┘
```

| 维度 | 评估 |
|------|------|
| UI 质量 | ✅ 原生流畅（Flutter Material3） |
| 推理性能 | ✅ 最优（C++ 零开销，直接调用 GPU/CPU） |
| APK 大小 | ~50-80MB（不含模型文件，模型按需下载） |
| 启动速度 | 快（<1秒） |
| 内存占用 | 低（仅 C++ 进程 + 模型 ~1.2GB for Q4_K_M） |
| **结论** | ✅ **最佳方案：前端和后端分离但共存于同一 APK** |

---

## 4. 推荐方案：Flutter + llama.cpp JNI

### 为什么选 Flutter？

```dart
// Flutter Chat UI 核心优势
class ChatScreen extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('TongYi-Lite')),
      body: Column(
        children: [
          Expanded(child: ChatMessageList()),   // 消息列表（流式渲染）
          ChatInputBar(),                        // 输入栏（文本+语音按钮）
        ],
      ),
    );
  }
}

// Material3 开箱即有：
// ✅ 气泡聊天气泡（User / Assistant）
// ✅ 暗/亮主题切换
// ✅ 流式文字打字机效果
// ✅ Markdown 渲染（flutter_markdown）
// ✅ 动画过渡、手势操作
```

### Flutter ↔ llama.cpp 通信机制

```
┌─────────────┐    HTTP POST     ┌──────────────────┐
│  Flutter    │ ◄──────────────► │  llama-server    │
│  Dart Code  │                  │  (C++ Native)    │
│             │   SSE Stream     │                  │
│  POST /v1/  │  ← token by      │  runs in         │
│  chat/compl  │  token           │  background      │
└─────────────┘                  └──────────────────┘

// Flutter 端调用示例：
final response = await http.post(
  Uri.parse('http://localhost:8080/v1/chat/completions'),
  headers: {'Content-Type': 'application/json'},
  body: jsonEncode({
    'model': 'qwen3-1.7b',
    'messages': [
      {'role': 'user', 'content': message},
    ],
    'stream': true,
  }),
);

// SSE stream → 逐 token 渲染（打字机效果）
response.stream.transform(utf8.decoder).listen((chunk) {
  // parse SSE event → append to chat bubble
});
```

---

## 5. 项目目录结构

```
TongYi-Lite/
├── android/                      # Android 原生层（Kotlin + C++ JNI）
│   ├── app/src/main/java/com/dgxspark/tongyilite/
│   │   ├── MainActivity.kt           # Flutter Activity 入口
│   │   └── LlamaEngineService.kt     # llama.cpp JNI 封装，后台推理服务
│   ├── cpp/                          # C++ 原生代码
│   │   ├── CMakeLists.txt
│   │   └── llama_jni.cpp             # JNI 桥接层（加载模型 → HTTP Server）
│   └── libs/arm64-v8a/libllama.so    # 预编译的 llama.cpp Android 库
│
├── ios/                      # iOS 原生层（可选，后续支持）
│   └── ...
│
├── lib/                      # Flutter Dart 代码（核心业务逻辑）
│   ├── main.dart               # 应用入口 + Theme 配置
│   │
│   ├── models/                 # 数据模型
│   │   ├── chat_message.dart       # {role, content, timestamp, isStreaming}
│   │   ├── conversation.dart       # {id, title, messages[], createdAt}
│   │   └── model_config.dart       # {name, path, quantization, contextSize}
│   │
│   ├── screens/                # UI 页面（类似元宝布局）
│   │   ├── home_screen.dart        # 主聊天界面（气泡+底部输入栏）
│   │   ├── settings_screen.dart    # 设置页（选择模型、量化精度、上下文长度）
│   │   ├── download_screen.dart    # 模型下载页（进度条+来源选择）
│   │   └── chat_bubble.dart        # 消息气泡组件（User/Assistant/Markeown）
│   │
│   ├── services/               # 服务层
│   │   ├── inference_service.dart  # HTTP 调用本地推理后端 + SSE stream
│   │   ├── model_manager.dart      # 模型下载/管理/版本检查
│   │   └── storage_service.dart    # SQLite 对话历史 CRUD
│   │
│   ├── widgets/                # UI 组件库
│   │   ├── streaming_text.dart     # 流式文字渲染（打字机效果 + 光标闪烁）
│   │   ├── markdown_renderer.dart  # Markdown → Widget 转换
│   │   └── chat_input_bar.dart     # 输入栏（文本+语音按钮+发送）
│   │
│   └── providers/              # Riverpod 状态管理
│       └── chat_provider.dart      # 当前对话、消息列表、加载状态
│
├── backend/                    # Python 参考后端（开发调试用，非 APK 内嵌）
│   ├── server.py               # FastAPI HTTP Server (本地调试)
│   └── engine.py               # llama-cpp-python 引擎封装
│
├── models/                     # 模型文件（git-lfs 管理）
│   └── qwen3-1.7b-q4_k_m.gguf  # ~1.2 GB
│
├── docs/                       # 文档
│   ├── mobile_llm_benchmark_report_v2.md
│   └── architecture_design.md    # ← 本文档
│
├── pubspec.yaml                # Flutter 依赖配置
├── build.gradle                # Android Gradle 构建脚本
└── README.md                   # 项目说明
```

---

## 6. 核心交互流程

### 首次启动流程

```
用户打开 APP
    │
    ├─ 检查本地是否有模型文件？
    │     ├─ YES → 直接进入聊天界面 ✅
    │     └─ NO  → 进入下载页
    │           │
    │           ▼
    │      [联网] 从 HuggingFace / ModelScope 下载 GGUF (~1.2GB)
    │           │          ↑ 断点续传，支持暂停/恢复
    │           ▼
    │      下载完成 → 模型加载到内存 → 进入聊天界面
    │
用户输入文字 "你好"
    │
    ▼
Flutter Chat UI 显示用户气泡："你好"
    │
    ▼
Flutter HTTP POST localhost:8080/v1/chat/completions
    │
    ├─ [离线模式 - 默认] → llama.cpp 本地推理 → SSE stream 返回 token
    │     └─ Flutter 逐字渲染（打字机效果 + Markdown 高亮）
    │
    └─ [联网模式 - 可选插件] → HTTP POST 到第三方 API
          └─ 如：联网搜索增强、知识问答等

对话历史 → SQLite 本地存储，支持多轮上下文
```

### 日常使用流程（离线）

```
用户打开 APP → 直接进入聊天界面 (<1秒启动)
    │
    ├─ 输入文字 → 实时流式回复 (25+ tok/s)
    ├─ 切换会话 → SQLite 加载历史消息
    ├─ 长文本对话 → 自动截断到上下文窗口 (4K tokens)
    └─ 设置页 → 可切换不同量化精度的模型
```

---

## 7. UI 设计与元宝/豆包对比

### 聊天界面设计（Flutter Material3）

```
┌─────────────────────────────────────┐
│ ← TongYi-Lite          ⚙️ 设置     │  ← AppBar
├─────────────────────────────────────┤
│                                     │
│  [系统] 你好，有什么可以帮你？        │  ← 欢迎消息（居中灰色）
│                                     │
│                         ┌─────────┐ │
│                         │ 今天天气  │ │  ← User 气泡（右侧，蓝色）
│                         │   怎么样？│ │
│                         └─────────┘ │
│                                     │
│  ┌───────────────────────────────┐  │
│  │ 今天北京天气晴朗，气温约25°C。  │  │ ← Assistant 气泡（左侧，白色）
│  │                               │  │     Markdown渲染（加粗、列表等）
│  │  建议穿轻薄衣物，注意防晒 ☀️    │  │
│  └───────────────────────────────┘  │
│                                     │
│  [Assistant] 正在输入... █          │  ← 流式输出中的光标闪烁
│                                     │
├─────────────────────────────────────┤
│  [🎤] 输入消息...           [➤]    │  ← Input Bar（语音按钮 + 文本框 + 发送）
└─────────────────────────────────────┘
```

### 与元宝/豆包的 UI 功能对比

| 功能 | 元宝/豆包 | TongYi-Lite 离线版 | 实现方式 |
|------|----------|-------------------|---------|
| 聊天界面 | ✅ 气泡+底部输入 | ✅ Flutter Material3 | `ChatBubble` Widget |
| 流式输出 | ✅ 打字机效果 | ✅ SSE streaming + StreamBuilder | Dart async stream |
| Markdown渲染 | ✅ | ✅ flutter_markdown | markdown → Widget |
| 多轮对话 | ✅ 会话列表 | ✅ SQLite + Riverpod | sqflite + Provider |
| 主题切换 | ✅ 暗/亮模式 | ✅ Flutter Theme 系统 | ThemeData |
| 语音输入 | ✅ | ⚠️ Android SpeechRecognizer API | google_speech (离线 STT) |
| TTS朗读 | ✅ | ⚠️ Android TextToSpeech | flutter_tts |
| **核心差异** | 云端推理 | **纯本地推理，绝对隐私** | — |

---

## 8. Offline-First 架构设计

### 三层网络策略

```
┌───────────────────────────────────────────────┐
│           Network Strategy (Offline-First)      │
│                                               │
│  Layer 1: [完全离线] ← 默认路径                 │
│    └─ 所有对话、推理、存储均在本地完成            │
│    └─ 零网络请求，零数据上传                      │
│                                               │
│  Layer 2: [按需联网] ← 用户主动触发              │
│    ├─ 首次启动：下载模型 GGUF (~1.2GB)          │
│    ├─ 更新模型：检查新版本并下载                  │
│    └─ 切换量化精度：下载不同精度的模型文件         │
│                                               │
│  Layer 3: [可选联网插件] ← 用户开关控制           │
│    ├─ 🔌 联网搜索增强（调用 Bing/Google API）     │
│    ├─ 🔌 知识问答扩展（调用第三方知识库）          │
│    └─ 🔌 模型推荐（从 HuggingFace 获取新模型列表） │
│                                               │
└───────────────────────────────────────────────┘
```

### 数据流向图

```
                    ┌──────────────┐
                    │   User Input  │
                    └──────┬───────┘
                           │
                           ▼
              ┌────────────────────────┐
              │    Flutter Chat UI     │
              │  (本地渲染，无网络依赖)  │
              └────────────┬───────────┘
                           │ HTTP POST localhost:8080
                           ▼
              ┌────────────────────────┐
              │   llama.cpp Server     │
              │  (C++ Native, 纯本地)   │
              └────────────┬───────────┘
                           │ SSE Stream (token by token)
                           ▼
              ┌────────────────────────┐
              │    Streaming Render    │
              │  (打字机效果 + Markdown)│
              └────────────┬───────────┘
                           │
                           ├─ [离线] → SQLite 存储对话历史
                           │
                           └─ [联网插件] → HTTP to 第三方 API
```

---

## 9. 联网能力模块（可选插件）

### 插件架构设计

```dart
// lib/plugins/
├── plugin_base.dart           // 插件基类接口
│   abstract class NetworkPlugin {
│     String get name;          // 插件名称
│     bool get isEnabled;       // 是否启用
│     Future<String> call(String query);  // 执行联网请求
│   }
│
├── web_search_plugin.dart      // 联网搜索增强
│   class WebSearchPlugin implements NetworkPlugin {
│     @override String get name => '联网搜索';
│     @override Future<String> call(query) async {
│       final results = await Dio().get('https://api.search.com/...');
│       return formatResults(results);
│     }
│   }
│
├── knowledge_base_plugin.dart  // 知识库扩展
│   class KnowledgeBasePlugin implements NetworkPlugin { ... }
│
└── model_update_plugin.dart    // 模型更新检查
    class ModelUpdatePlugin implements NetworkPlugin { ... }
```

### 插件开关 UI

```
设置页 → "联网增强功能"
├─ [ ] 联网搜索（需要网络时自动调用）
├─ [ ] 知识库问答（需要网络时调用外部知识库）
└─ [x] 模型更新检查（启动时检查新版本）
```

---

## 10. 开发路线图

### Phase 1：MVP — 基础聊天功能（2-3周）

| 任务 | 技术点 | 预计工时 |
|------|--------|---------|
| Flutter 项目初始化 + Material3 Theme | Flutter SDK | 2h |
| llama.cpp Android .so 预编译 | CMake + NDK | 4h |
| JNI 桥接层（模型加载 → HTTP Server） | Kotlin + C++ JNI | 6h |
| 聊天界面 UI（气泡 + 输入栏） | Flutter Widget | 4h |
| SSE Streaming 流式输出 | Dart http + StreamBuilder | 3h |
| SQLite 对话历史存储 | sqflite | 2h |
| 模型下载功能（断点续传） | Dio | 3h |
| **MVP 测试验证** | iPhone/Samsung 真机 | 2h |

### Phase 2：体验优化（1-2周）

| 任务 | 技术点 | 预计工时 |
|------|--------|---------|
| Markdown 渲染 + 代码块高亮 | flutter_markdown | 3h |
| 多会话管理（列表 + 切换） | Riverpod State Management | 3h |
| 暗/亮主题切换 | Flutter Theme System | 2h |
| 语音输入集成 | Android SpeechRecognizer API | 4h |

### Phase 3：联网插件（1周）

| 任务 | 技术点 | 预计工时 |
|------|--------|---------|
| 插件架构设计 + 基类 | Dart Interface | 2h |
| 联网搜索增强插件 | Dio HTTP Client | 4h |
| 模型更新检查插件 | HuggingFace API | 2h |

### Phase 4：iOS 适配（可选，后续）

| 任务 | 技术点 | 预计工时 |
|------|--------|---------|
| Flutter iOS 项目配置 | Xcode + Podfile | 3h |
| llama.cpp iOS XCFramework 集成 | Metal GPU Acceleration | 4h |
| iOS UI 适配（不同屏幕尺寸） | Flutter MediaQuery | 3h |

---

## 总结

```
┌─────────────────────────────────────────────┐
│         TongYi-Lite 技术选型总结              │
├─────────────────────────────────────────────┤
│                                             │
│  前端 UI：Flutter 3.x (Dart)                │
│    → Material3 开箱即有聊天模板               │
│    → 跨平台一套代码，覆盖 Android APK + iOS   │
│                                             │
│  推理引擎：llama.cpp Android (.so)           │
│    → C++ 原生零开销，GPU/CPU 加速             │
│    → Qwen3-1.7B-Q4_K_M ~1.2GB，25+ tok/s   │
│                                             │
│  通信：HTTP REST + SSE (localhost:8080)      │
│    → Flutter 内嵌 HTTP Server               │
│    → 流式输出实现打字机效果                   │
│                                             │
│  离线架构：Offline-First                     │
│    → Layer 1: 完全离线（默认路径）            │
│    → Layer 2: 按需联网（模型下载/更新）        │
│    → Layer 3: 可选插件（联网搜索等）           │
│                                             │
│  数据存储：SQLite (sqflite)                  │
│    → 对话历史本地持久化                       │
│                                             │
└─────────────────────────────────────────────┘
```

---

*架构设计文档完毕。下一步可根据此方案开始 Phase 1 MVP 开发。*
