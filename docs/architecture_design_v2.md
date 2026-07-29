# TongYi-Lite 智能体架构设计方案 v2

> **版本**：v2.0  
> **日期**：2026-07-29  
> **定位**：端侧离线 AI 智能体（视觉 + 语音 + 对话），Android APK 形态  
> **核心理念**："你的私人AI，数据不出设备"  

---

## 目录

1. [产品全景图](#1-产品全景图)
2. [核心能力模块总览](#2-核心能力模块总览)
3. [视觉理解模块（Vision）](#3-视觉理解模块vision)
4. [语音通信模块（Speech）](#4-语音通信模块speech)
5. [对话引擎模块（Chat）](#5-对话引擎模块chat)
6. [会话管理模块（Session）](#6-会话管理模块session)
7. [模型管理中心（Model Hub）](#7-模型管理中心model-hub)
8. [系统架构设计](#8-系统架构设计)
9. [项目目录结构](#9-项目目录结构)
10. [UI 交互设计](#10-ui-交互设计)
11. [开发路线图](#11-开发路线图)

---

## 1. 产品全景图

```
┌───────────────────────────────────────────────────────────────┐
│                    TongYi-Lite 智能体                          │
│                                                               │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐     │
│  │ 👁️ 视觉   │  │ 🎤 语音输入│  │ 💬 文字对话│  │ 🔊 TTS播报│     │
│  │ 拍照/上传 │  │ STT离线   │  │ LLM推理   │  │ 朗读回复  │     │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘  └────┬─────┘     │
│       │             │            │             │              │
│       ▼             ▼            ▼             ▼              │
│  ┌──────────────────────────────────────────────────────┐    │
│  │           统一输入处理层 (Unified Input Pipeline)      │    │
│  │  Image → VLM → Text   |   Audio → STT → Text        │    │
│  └─────────────────────────┬────────────────────────────┘    │
│                            │                                  │
│                            ▼                                  │
│  ┌──────────────────────────────────────────────────────┐    │
│  │              LLM 推理引擎 (llama.cpp)                  │    │
│  │         Qwen3-1.7B / Qwen2.5-VL-3B / ...             │    │
│  └─────────────────────────┬────────────────────────────┘    │
│                            │                                  │
│              ┌─────────────┼─────────────┐                    │
│              ▼             ▼             ▼                    │
│       ┌──────────┐  ┌──────────┐  ┌──────────┐               │
│       │ 📝 会话   │  │ 🗂️ 模型   │  │ ⚙️ 设置   │               │
│       │ 管理     │  │ 管理中心  │  │ 配置     │               │
│       └──────────┘  └──────────┘  └──────────┘               │
│                                                               │
│  ═══════ Offline-First ═══════                                │
│  [完全离线] ← 默认 | [按需联网] ← 模型下载/更新 | [可选插件]    │
└───────────────────────────────────────────────────────────────┘
```

### 核心能力清单

| 模块 | 功能 | 离线可用性 | 端侧实现方案 |
|------|------|-----------|-------------|
| **视觉理解** | 拍照/上传图片 → AI 解读 | ✅ 完全离线 | Qwen2.5-VL-3B / InternVL2.5-2B + llama.cpp |
| **语音输入** | 说话 → 文字 → 送入对话 | ✅ 完全离线 | sherpa-onnx (WeNet) / Android SpeechRecognizer |
| **TTS播报** | AI回复 → 朗读输出 | ✅ 部分离线 | Android TTS引擎 + Piper (可选本地模型) |
| **文字对话** | 文本输入 → LLM 流式回复 | ✅ 完全离线 | Qwen3-1.7B + llama.cpp |
| **会话管理** | 多轮对话、历史检索、会话切换 | ✅ 完全离线 | SQLite 本地存储 |
| **模型管理** | 下载/缓存/切换/删除模型 | ⚠️ 联网下载 | HuggingFace / ModelScope API |

---

## 2. 核心能力模块总览

### 统一输入 → 处理 → 输出流水线

```
┌─────────────────────────────────────────────────────────────┐
│                    Input Modality Selector                   │
│                                                             │
│   📷 Camera / Gallery       🎤 Voice Recording             │
│        │                       │                             │
│        ▼                       ▼                             │
│  ┌──────────┐            ┌──────────┐                        │
│  │ Image    │            │ Audio    │                        │
│  │ Pipeline │            │ Pipeline │                        │
│  └────┬─────┘            └────┬─────┘                        │
│       │                       │                              │
│       ▼ (VLM)                ▼ (STT)                          │
│  ┌──────────┐            ┌──────────┐                        │
│  │ Qwen2.5- │            │ sherpa-  │                        │
│  │ VL-3B    │            │ onnx     │                        │
│  └────┬─────┘            └────┬─────┘                        │
│       │                       │                              │
│       ▼ (text output)        ▼ (text output)                  │
│  ┌──────────────────────────────────────┐                    │
│  │         Unified Text Input           │                    │
│  │    "Describe this image: ..."        │                    │
│  │    "What is in the photo?"            │                    │
│  └─────────────────┬────────────────────┘                    │
│                    ▼                                          │
│  ┌──────────────────────────────────────┐                    │
│  │         LLM Inference (llama.cpp)    │                    │
│  │    Qwen3-1.7B-Instruct / Qwen2.5-VL │                    │
│  └─────────────────┬────────────────────┘                    │
│                    ▼                                          │
│  ┌──────────┐        ┌──────────┐                            │
│  │ 💬 Chat   │        │ 🔊 TTS    │                            │
│  │ UI Display│        │ Playback  │                            │
│  └──────────┘        └──────────┘                            │
└─────────────────────────────────────────────────────────────┘
```

---

## 3. 视觉理解模块（Vision）

### 3.1 端侧多模态模型选型

| 模型 | 参数量 | Q4_K_M 体积 | 中文能力 | 手机端可行性 | 推荐度 |
|------|--------|------------|---------|-------------|--------|
| **Qwen2.5-VL-3B-Instruct** | 3.2B | ~2.0 GB | ⭐⭐⭐⭐⭐ | ✅ 中端以上手机可运行 | ⭐⭐⭐⭐⭐ (首选) |
| InternVL2.5-2B | 2.1B | ~1.4 GB | ⭐⭐⭐⭐ | ✅ 流畅 | ⭐⭐⭐⭐ |
| MiniCPM-V 2.6 (8B) | 8B | ~5.0 GB | ⭐⭐⭐⭐⭐ | ❌ 仅高端旗舰 | B+ |
| Qwen2.5-VL-7B-Instruct | 7.4B | ~4.5 GB | ⭐⭐⭐⭐⭐ | ❌ 体积过大 | C |

### 3.2 Qwen2.5-VL-3B 详解（视觉理解首选）

**核心能力**：
- **图片描述**："Describe this image in detail" → 生成自然语言描述
- **视觉问答 (VQA)**："What object is in the center of this photo?" → 精准回答
- **OCR 文字识别**：识别图片中的文字并提取
- **场景理解**：理解照片中的物体、人物关系、空间布局
- **中文优化**：对中文 prompt 的理解和生成能力显著优于同尺寸国际模型

**输入处理流程**：
```
用户拍照/选择图片
    │
    ▼
Flutter Image Picker → 本地压缩 (max-width: 1024, quality: 85)
    │
    ▼
Base64 / 文件路径 → llama.cpp multimodal API
    │
    ▼
POST http://localhost:8080/v1/chat/completions
{
  "model": "qwen2.5-vl-3b",
  "messages": [
    {
      "role": "user",
      "content": [
        {"type": "text", "text": "请描述这张图片的内容"},
        {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64,..."}}
      ]
    }
  ],
  "stream": true
}
    │
    ▼
SSE Stream → Flutter 流式渲染回复
```

**llama.cpp 多模态支持现状（2025-2026）**：
- llama.cpp v0.3.x+ 已原生支持 Qwen2.5-VL 架构的视觉编码器和语言模型联合推理
- 图片经过 Vision Encoder → Visual Tokens → 注入 LLM Context
- 手机端建议图片最大分辨率 768×768（平衡质量和内存）

### 3.3 视觉模块 UI 设计

```
┌─────────────────────────────────────┐
│ ← 拍照识别              [📷] [🖼️]   │  ← AppBar
├─────────────────────────────────────┤
│                                     │
│  ┌───────────────────────────────┐  │
│  │                               │  │
│  │    [用户拍摄的照片预览]         │  │  ← Image Preview Card
│  │                               │  │     (圆角+阴影)
│  │    ┌─────────────────────┐    │  │
│  │    │                     │    │  │
│  │    │   📷 Camera Photo   │    │  │
│  │    │                     │    │  │
│  │    └─────────────────────┘    │  │
│  │                               │  │
│  └───────────────────────────────┘  │
│                                     │
│  [快速提问按钮组]                      │
│  ┌─────┐ ┌─────┐ ┌─────┐           │
│  │描述  │ │识别  │ │OCR   │           │
│  │图片  │ │文字  │ │提取  │           │
│  └─────┘ └─────┘ └─────┘           │
│                                     │
│  [AI回复 - Markdown渲染]               │
│  ┌───────────────────────────────┐  │
│  │ 这是一张户外风景照片，拍摄于   │  │
│  │ **晴朗的下午**。画面中可以看到：│  │
│  │                                │  │
│  │ - 🏔️ 远处的雪山               │  │
│  │ - 🌿 近处的绿色草地            │  │
│  │ - ☀️ 蓝天白云                   │  │
│  └───────────────────────────────┘  │
│                                     │
│  [🎤语音播报] [📋复制] [🔄重新识别]    │
├─────────────────────────────────────┤
│  [📷拍照]         [选择相册]          │
└─────────────────────────────────────┘
```

### 3.4 视觉模块技术实现

```dart
// lib/services/vision_service.dart
class VisionService {
  final InferenceService _inference;

  Future<String> describeImage(String imagePath) async {
    final imageBytes = await File(imagePath).readAsBytes();
    final base64Data = base64Encode(imageBytes);

    return await _inference.chatWithImage(
      model: 'qwen2.5-vl-3b',
      prompt: '请详细描述这张图片的内容，包括场景、物体、颜色等细节。用中文回答。',
      imageData: base64Data,
      onToken: (token) => /* update streaming UI */,
    );
  }

  Future<String> extractText(String imagePath) async {
    final imageBytes = await File(imagePath).readAsBytes();
    final base64Data = base64Encode(imageBytes);

    return await _inference.chatWithImage(
      model: 'qwen2.5-vl-3b',
      prompt: '请提取图片中的所有文字内容，保持原始格式。如果有英文也一并提取。',
      imageData: base64Data,
    );
  }

  Future<String> answerQuestion(String imagePath, String question) async {
    final imageBytes = await File(imagePath).readAsBytes();
    final base64Data = base64Encode(imageBytes);

    return await _inference.chatWithImage(
      model: 'qwen2.5-vl-3b',
      prompt: question,
      imageData: base64Data,
    );
  }
}
```

---

## 4. 语音通信模块（Speech）

### 4.1 离线 STT（语音转文字）选型

| 方案 | 语言支持 | 离线能力 | 准确率 | 内存占用 | APK增量 | 推荐度 |
|------|---------|---------|--------|---------|---------|--------|
| **sherpa-onnx (WeNet)** | 中/英多语种 | ✅ 完全离线 | ⭐⭐⭐⭐ | ~80MB | +40MB | ⭐⭐⭐⭐⭐ (首选) |
| Android SpeechRecognizer | 中/英 | ⚠️ 部分离线（需预装Google服务） | ⭐⭐⭐⭐ | 系统级 | +0MB | ⭐⭐⭐ |
| Vosk | 多语种 | ✅ 完全离线 | ⭐⭐⭐ | ~50MB | +25MB | ⭐⭐⭐ |

### 4.2 sherpa-onnx 详解（STT首选）

**为什么选 sherpa-onnx**：
- **中文识别准确率最高**的端侧方案（基于 WeNet 模型，阿里达摩院出品）
- **完全离线**，不依赖任何网络或 Google 服务
- **跨平台**：Android / iOS / Linux / Windows 统一 API
- **轻量级**：基础模型仅 ~40MB，支持流式识别

```
用户按住语音按钮说话
    │
    ▼
Flutter → sherpa-onnx JNI (实时音频采集)
    │
    ▼
WeNet 流式识别引擎 (端侧推理)
    │
    ▼
文字输出: "今天天气怎么样"
    │
    ▼
自动送入 LLM 对话上下文
```

**sherpa-onnx 中文模型包（约40MB）**：
```
models/sherpa-onnx/
├── wenetspeech_ctc_large.onnx          # CTC 模型 (~35MB)
├── tokens.txt                            # 词表
└── README.md
```

### 4.3 离线 TTS（文字转语音）选型

| 方案 | 音质 | 中文支持 | 离线能力 | 内存占用 | APK增量 | 推荐度 |
|------|------|---------|---------|---------|---------|--------|
| **Android TextToSpeech + 离线引擎** | ⭐⭐⭐⭐ | ✅ 优秀 | ✅ 完全离线 | ~30MB (语音包) | +15MB | ⭐⭐⭐⭐⭐ (首选) |
| Piper TTS | ⭐⭐⭐⭐ | ⚠️ 基础 | ✅ 完全离线 | ~200MB | +100MB | ⭐⭐⭐ |
| Fish-Speech (本地模型) | ⭐⭐⭐⭐⭐ | ✅ 优秀 | ✅ 完全离线 | ~500MB | +250MB | ⭐⭐⭐ (高端机可选) |

### 4.4 TTS 实现方案（Android原生）

**推荐方案：Android TextToSpeech + 中文语音包**

这是最稳定、体验最好的方案。Android 系统自带 TTS 引擎，配合离线中文语音包即可完全离线使用。

```dart
// lib/services/tts_service.dart
import 'package:flutter_tts/flutter_tts.dart';

class TTSService {
  final FlutterTts _tts = FlutterTts();

  Future<void> init() async {
    await _tts.setLanguage('zh-CN');
    await _tts.setSpeechRate(0.5);        // 语速 (0.0 ~ 2.0)
    await _tts.setVolume(1.0);            // 音量
    await _tts.setPitch(1.0);             // 音调

    // 检查并安装离线中文语音包
    final languages = await _tts.getLanguages;
    if (languages.contains('zh-CN')) {
      await _tts.setLanguage('zh-CN');
    } else {
      // 提示用户下载离线语音包（一次性联网操作）
      // Android: Settings → Language & Input → Text-to-Speech → Download Chinese voice
    }
  }

  Future<void> speak(String text) async {
    await _tts.stop();  // 停止当前播放
    await _tts.speak(text);
  }

  Future<void> stop() async {
    await _tts.stop();
  }

  Future<bool> isSpeaking() async => await _tts.isSpeaking;
}
```

### 4.5 语音模块 UI 设计

```
┌─────────────────────────────────────┐
│ ← TongYi-Lite          ⚙️ 设置     │
├─────────────────────────────────────┤
│                                     │
│  [User] 今天北京天气怎么样？         │  ← 语音输入的文字气泡
│                                     │
│  [AI]  今天北京晴转多云，气温18-26°C。│  ← AI回复
│        紫外线中等，建议外出时做好    │  ← Markdown渲染
│        防晒措施。                    │
│                                     │
├─────────────────────────────────────┤
│                                     │
│  ┌───────────────────────────────┐  │
│  │                               │  │
│  │      🎙️                      │  │  ← 长按录音按钮（语音输入）
│  │    "按住说话"                  │  │     按住 → 实时波形 + STT转写
│  │                               │  │     松开 → 自动发送
│  └───────────────────────────────┘  │
│                                     │
│  [📷拍照]  [输入文字...]        [➤] │
│                                     │
│  [🔊 TTS: 开/关]   [⚡快/慢]         │
├─────────────────────────────────────┤
```

**语音交互增强设计**：
- **按住说话**：长按录音按钮，实时显示波形 + STT转写文字，松开发送
- **自动识别语言**：sherpa-onnx 支持中英混合识别
- **TTS 开关控制**：设置页可开启/关闭 AI回复的语音播报
- **语速调节**：快 / 正常 / 慢 三档

---

## 5. 对话引擎模块（Chat）

### 5.1 LLM 推理引擎

```dart
// lib/services/inference_service.dart
class InferenceService {
  static const String _baseUrl = 'http://localhost:8080';

  /// 文字对话 (纯文本)
  Future<String> chat({
    required String model,
    required List<ChatMessage> messages,
    void Function(String token)? onToken,
  }) async {
    final response = await http.post(
      Uri.parse('$_baseUrl/v1/chat/completions'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'model': model,
        'messages': messages.map((m) => m.toMap()).toList(),
        'stream': true,
        'temperature': 0.7,
        'max_tokens': 2048,
      }),
    );

    // SSE stream → 逐 token 回调
    final body = await response.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .join('\n');

    return _parseSSE(body);
  }

  /// 多模态对话 (图片 + 文本)
  Future<String> chatWithImage({
    required String model,
    required String prompt,
    required String imageData,  // base64
    void Function(String token)? onToken,
  }) async {
    final response = await http.post(
      Uri.parse('$_baseUrl/v1/chat/completions'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'model': model,
        'messages': [
          {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': prompt},
              {
                'type': 'image_url',
                'image_url': {'url': 'data:image/jpeg;base64,$imageData'},
              },
            ],
          }
        ],
        'stream': true,
      }),
    );

    return _parseSSE(await response.stream.transform(utf8.decoder).join());
  }

  /// SSE 流式解析（打字机效果）
  String _parseSSE(String body) {
    final buffer = StringBuffer();
    for (final line in body.split('\n')) {
      if (line.startsWith('data: ')) {
        final data = line.substring(6).trim();
        if (data == '[DONE]') break;
        try {
          final json = jsonDecode(data);
          final content = json['choices']?[0]?['delta']?['content'];
          if (content != null) buffer.write(content);
        } catch (_) {}
      }
    }
    return buffer.toString();
  }
}
```

### 5.2 模型切换策略

不同任务使用不同模型，通过统一接口自动路由：

| 任务类型 | 推荐模型 | Q4_K_M 体积 | 说明 |
|---------|---------|------------|------|
| **纯文本对话** | Qwen3-1.7B-Instruct | ~1.2 GB | 速度快，中文能力强 |
| **图片理解/描述** | Qwen2.5-VL-3B-Instruct | ~2.0 GB | 视觉编码器 + LLM |
| **复杂推理** | Qwen3-4B-Instruct | ~2.8 GB | 更大上下文，更强推理 |

```dart
// lib/services/model_router.dart
class ModelRouter {
  /// 根据任务类型自动选择最优模型
  String selectModel(String taskType) {
    switch (taskType) {
      case 'chat':
        return _config.textModel ?? 'qwen3-1.7b';
      case 'vision':
        return _config.visionModel ?? 'qwen2.5-vl-3b';
      case 'reasoning':
        return _config.reasoningModel ?? 'qwen3-4b';
      default:
        return _config.textModel ?? 'qwen3-1.7b';
    }
  }

  /// 动态切换模型（用户设置页触发）
  Future<void> switchModel(String taskType, String modelPath) async {
    // 停止当前推理服务
    await _llamaServer.stop();
    // 加载新模型
    await _llamaServer.load(modelPath);
    // 更新路由配置
    _config.update(taskType, modelPath);
    await _storage.saveConfig(_config);
  }
}
```

---

## 6. 会话管理模块（Session）

### 6.1 数据模型设计

```dart
// lib/models/conversation.dart
class Conversation {
  final String id;              // UUID
  final String title;           // 自动生成的会话标题
  final DateTime createdAt;     // 创建时间
  final DateTime updatedAt;     // 最后更新时间
  final String modelId;         // 当前使用的模型ID
  final int messageCount;       // 消息数量

  List<ChatMessage> messages;   // 消息列表（内存中）
}

// lib/models/chat_message.dart
class ChatMessage {
  final String id;              // UUID
  final String conversationId;  // 所属会话ID
  final String role;            // 'user' | 'assistant' | 'system' | 'vision_input'
  final String content;         // 文本内容
  final String? imageUrl;       // 图片路径（视觉输入时）
  final DateTime timestamp;     // 时间戳
  final bool isStreaming;       // 是否正在流式输出中
}
```

### 6.2 SQLite 存储方案

```dart
// lib/services/storage_service.dart
class StorageService {
  static const String _dbPath = 'tongyilite.db';

  Future<void> init() async {
    final db = await databaseFactory.openDatabase(_dbPath);

    // 会话表
    await db.execute('''
      CREATE TABLE IF NOT EXISTS conversations (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        model_id TEXT DEFAULT 'qwen3-1.7b',
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        message_count INTEGER DEFAULT 0
      )
    ''');

    // 消息表
    await db.execute('''
      CREATE TABLE IF NOT EXISTS messages (
        id TEXT PRIMARY KEY,
        conversation_id TEXT NOT NULL,
        role TEXT NOT NULL,
        content TEXT NOT NULL,
        image_path TEXT,
        created_at INTEGER NOT NULL,
        is_streaming INTEGER DEFAULT 0,
        FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON DELETE CASCADE
      )
    ''');

    // 索引：加速会话列表查询
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_messages_conv
      ON messages(conversation_id, created_at)
    ''');
  }

  /// 创建新会话
  Future<Conversation> createConversation({String title = '新对话'}) async {
    final db = await _getDb();
    final id = uuid.v4();
    final now = DateTime.now().millisecondsSinceEpoch;

    await db.insert('conversations', {
      'id': id,
      'title': title,
      'model_id': 'qwen3-1.7b',
      'created_at': now,
      'updated_at': now,
      'message_count': 0,
    });

    return Conversation(id: id, title: title, createdAt: DateTime.now());
  }

  /// 获取所有会话列表（按更新时间倒序）
  Future<List<Conversation>> getAllConversations() async {
    final db = await _getDb();
    final rows = await db.query(
      'conversations',
      orderBy: 'updated_at DESC',
    );
    return rows.map((r) => Conversation.fromMap(r)).toList();
  }

  /// 获取会话的消息列表
  Future<List<ChatMessage>> getMessages(String conversationId, {int limit = 100}) async {
    final db = await _getDb();
    final rows = await db.query(
      'messages',
      where: 'conversation_id = ?',
      whereArgs: [conversationId],
      orderBy: 'created_at ASC',
      limit: limit,
    );
    return rows.map((r) => ChatMessage.fromMap(r)).toList();
  }

  /// 保存单条消息
  Future<void> saveMessage(ChatMessage message) async {
    final db = await _getDb();
    await db.insert('messages', message.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// 删除会话（级联删除所有消息）
  Future<void> deleteConversation(String id) async {
    final db = await _getDb();
    await db.delete('conversations', where: 'id = ?', whereArgs: [id]);
  }

  /// 清空当前会话的消息
  Future<void> clearMessages(String conversationId) async {
    final db = await _getDb();
    await db.delete('messages', where: 'conversation_id = ?', whereArgs: [conversationId]);
  }

  /// 统计总存储占用（对话历史 + 模型文件）
  Future<Map<String, int>> getStorageStats() async {
    // 计算对话历史大小
    final db = await _getDb();
    final result = await db.rawQuery('SELECT SUM(LENGTH(content)) as total FROM messages');
    final historySize = (result.first['total'] as int?) ?? 0;

    // 计算模型文件总大小
    final modelDir = Directory('/data/data/com.dgxspark.tongyilite/files/models');
    int modelSize = 0;
    if (await modelDir.exists()) {
      await for (final entity in modelDir.list()) {
        if (entity is File) modelSize += await entity.length();
      }
    }

    return {
      'history': historySize,
      'models': modelSize,
      'total': historySize + modelSize,
    };
  }
}
```

### 6.3 会话管理 UI

```dart
// lib/screens/sessions_screen.dart — 会话列表页（侧边抽屉）

class SessionsScreen extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Drawer(
      child: Column(
        children: [
          // 顶部：新建对话按钮
          Padding(
            padding: EdgeInsets.all(16),
            child: ElevatedButton.icon(
              onPressed: () => _createNewSession(),
              icon: Icon(Icons.add),
              label: Text('新对话'),
            ),
          ),

          // 会话列表（可滑动删除）
          Expanded(
            child: StreamBuilder<List<Conversation>>(
              stream: _storage.watchConversations(),
              builder: (context, snapshot) {
                return ListView.builder(
                  itemCount: snapshot.data?.length ?? 0,
                  itemBuilder: (context, index) {
                    final conv = snapshot.data![index];
                    return Dismissible(
                      key: ValueKey(conv.id),
                      background: Container(color: Colors.red),
                      onDismissed: (_) => _deleteSession(conv.id),
                      child: ListTile(
                        leading: Icon(Icons.chat_bubble_outline),
                        title: Text(conv.title),
                        subtitle: Text(
                          '${conv.messageCount} 条消息 · ${_formatTime(conv.updatedAt)}',
                          style: TextStyle(fontSize: 12, color: Colors.grey),
                        ),
                        trailing: conv.id == _currentSessionId
                            ? Icon(Icons.check_circle, color: Colors.blue)
                            : null,
                        onTap: () => _selectSession(conv.id),
                      ),
                    );
                  },
                );
              },
            ),
          ),

          // 底部：存储统计
          Container(
            padding: EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceVariant,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('💾 已用存储'),
                StreamBuilder<Map<String, int>>(
                  stream: _storage.watchStorageStats(),
                  builder: (context, snapshot) {
                    final stats = snapshot.data ?? {'total': 0};
                    return Text(FormatUtils.formatBytes(stats['total']!));
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
```

---

## 7. 模型管理中心（Model Hub）

### 7.1 模型管理功能全景

| 功能 | 说明 | 联网需求 |
|------|------|---------|
| **模型列表** | 展示可用模型及详情 | ⚠️ 首次加载（可选缓存） |
| **模型下载** | 从 HuggingFace / ModelScope 下载 GGUF 文件 | ✅ 必须联网 |
| **断点续传** | 支持暂停/恢复，网络中断后自动恢复 | — |
| **模型缓存管理** | 查看已下载模型、大小、占用空间 | ❌ 纯本地 |
| **模型切换** | 在设置页选择不同模型（对话/Vision） | ❌ 纯本地 |
| **模型删除** | 释放磁盘空间 | ❌ 纯本地 |
| **版本检查** | 检查是否有新版本模型可用 | ⚠️ 可选联网 |

### 7.2 支持的模型类型

```dart
// lib/models/model_registry.dart
class ModelRegistry {
  static const List<ModelInfo> availableModels = [
    // === 文本对话模型 ===
    ModelInfo(
      id: 'qwen3-0.6b',
      name: 'Qwen3-0.6B-Instruct',
      type: ModelType.text,
      params: '610M',
      contextLength: 32000,
      quantization: 'Q4_K_M',
      sizeMB: 420,
      description: '轻量级，适合低端设备',
      sourceUrl: 'https://huggingface.co/Qwen/Qwen3-0.6B-Instruct-GGUF',
    ),
    ModelInfo(
      id: 'qwen3-1.7b',
      name: 'Qwen3-1.7B-Instruct',
      type: ModelType.text,
      params: '1.75B',
      contextLength: 32000,
      quantization: 'Q4_K_M',
      sizeMB: 1200,
      description: '推荐！中文能力最强，性能体积平衡最佳',
      sourceUrl: 'https://huggingface.co/Qwen/Qwen3-1.7B-Instruct-GGUF',
    ),
    ModelInfo(
      id: 'qwen3-4b',
      name: 'Qwen3-4B-Instruct',
      type: ModelType.text,
      params: '4.0B',
      contextLength: 32000,
      quantization: 'Q4_K_M',
      sizeMB: 2800,
      description: '高质量，适合中端以上设备',
      sourceUrl: 'https://huggingface.co/Qwen/Qwen3-4B-Instruct-GGUF',
    ),

    // === 视觉理解模型 ===
    ModelInfo(
      id: 'qwen2.5-vl-3b',
      name: 'Qwen2.5-VL-3B-Instruct',
      type: ModelType.vision,
      params: '3.2B',
      contextLength: 32000,
      quantization: 'Q4_K_M',
      sizeMB: 2000,
      description: '视觉理解，图片描述/VQA/OCR',
      sourceUrl: 'https://huggingface.co/Qwen/Qwen2.5-VL-3B-Instruct-GGUF',
    ),

    // === STT 语音识别模型 ===
    ModelInfo(
      id: 'sherpa-wenet-ctc-large',
      name: 'WeNet CTC Large (中文)',
      type: ModelType.stt,
      params: '~400M',
      contextLength: null,
      quantization: 'ONNX INT8',
      sizeMB: 40,
      description: '离线语音识别，支持中英混合',
      sourceUrl: 'https://github.com/k2-fsa/sherpa-onnx/releases',
    ),

    // === TTS 语音合成模型（可选）===
    ModelInfo(
      id: 'piper-zh-CN',
      name: 'Piper 中文 (zh-CN)',
      type: ModelType.tts,
      params: '~200M',
      contextLength: null,
      quantization: 'ONNX FP32',
      sizeMB: 200,
      description: '离线文字转语音（可选增强）',
      sourceUrl: 'https://huggingface.co/rhasspy/piper-voices',
    ),
  ];
}

enum ModelType { text, vision, stt, tts }
```

### 7.3 模型下载管理器

```dart
// lib/services/model_downloader.dart
class ModelDownloader {
  final Dio _dio = Dio(BaseOptions(
    connectTimeout: Duration(minutes: 2),
    receiveTimeout: Duration(hours: 1),
  ));

  /// 下载模型文件（支持断点续传）
  Future<ModelDownloadResult> download({
    required ModelInfo model,
    String? customSourceUrl,   // 可选：使用自定义镜像源
  }) async {
    final savePath = _getModelSavePath(model);
    final url = customSourceUrl ?? model.sourceUrl;

    // 检查本地是否已有部分文件（断点续传）
    final file = File(savePath);
    final existingSize = await file.exists() ? await file.length() : 0;

    return _dio.download(
      '$url/$model.id-$model.quantization.gguf',
      savePath,
      onReceiveProgress: (received, total) {
        if (total != -1) {
          final percent = received / total * 100;
          // 更新 UI 进度条
          _downloadController.add(DownloadProgress(
            modelId: model.id,
            percent: percent,
            receivedBytes: received + existingSize,
            totalBytes: total,
          ));
        }
      },
    );

    return ModelDownloadResult(
      success: true,
      model: model,
      path: savePath,
      sizeMB: (await file.length()) / 1024 / 1024,
    );
  }

  /// 获取模型保存路径
  String _getModelSavePath(ModelInfo model) {
    return '${_appDir}/models/${model.id}-${model.quantization}.gguf';
  }

  /// 删除已下载的模型文件
  Future<void> deleteModel(String modelId) async {
    final path = _getModelSavePath(
      ModelRegistry.availableModels.firstWhere((m) => m.id == modelId),
    );
    await File(path).delete();
  }

  /// 获取所有已下载模型的信息
  Future<List<ModelInfo>> getDownloadedModels() async {
    final modelDir = Directory(_appDir);
    final models = <ModelInfo>[];

    for (final entry in await modelDir.list().toList()) {
      if (entry is File && entry.path.endsWith('.gguf')) {
        final fileName = basename(entry.path).replaceAll('-q4_k_m.gguf', '');
        final modelInfo = ModelRegistry.availableModels.firstWhere(
          (m) => m.id == fileName,
          orElse: () => throw Exception('Unknown model'),
        );
        models.add(ModelInfo(
          ...modelInfo,  // copy fields
          isDownloaded: true,
          downloadSizeMB: await entry.length() / 1024 / 1024,
          downloadedAt: (await entry.lastModified()).toIso8601String(),
        ));
      }
    }

    return models;
  }
}
```

### 7.4 模型管理 UI

```dart
// lib/screens/model_manager_screen.dart — 模型管理中心

class ModelManagerScreen extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('🗂️ 模型管理')),
      body: StreamBuilder<List<ModelInfo>>(
        stream: _modelHub.watchModels(),
        builder: (context, snapshot) {
          final models = snapshot.data ?? [];

          return ListView.builder(
            itemCount: models.length,
            itemBuilder: (context, index) {
              final model = models[index];

              return Card(
                margin: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: _getModelTypeColor(model.type),
                    child: Icon(_getModelTypeIcon(model.type)),
                  ),
                  title: Text(model.name),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${model.params} · ${model.quantization}'),
                      if (model.isDownloaded) ...[
                        Text('✅ 已下载 · ${FormatUtils.formatBytes(model.downloadSizeMB * 1024 * 1024)}',
                            style: TextStyle(color: Colors.green)),
                      ] else ...[
                        Text('📦 待下载 · ${FormatUtils.formatBytes(model.sizeMB * 1024 * 1024)}'),
                      ],
                    ],
                  ),
                  trailing: model.isDownloaded
                      ? Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: Icon(Icons.swap_horiz),
                              tooltip: '切换模型',
                              onPressed: () => _switchModel(model),
                            ),
                            IconButton(
                              icon: Icon(Icons.delete_outline, color: Colors.red),
                              tooltip: '删除模型',
                              onPressed: () => _deleteModel(model.id),
                            ),
                          ],
                        )
                      : ElevatedButton(
                          onPressed: () => _downloadModel(model),
                          child: Text('下载'),
                        ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

// 模型类型图标和颜色映射
Color _getModelTypeColor(ModelType type) {
  switch (type) {
    case ModelType.text: return Colors.blue;
    case ModelType.vision: return Colors.purple;
    case ModelType.stt: return Colors.orange;
    case ModelType.tts: return Colors.green;
  }
}

IconData _getModelTypeIcon(ModelType type) {
  switch (type) {
    case ModelType.text: return Icons.text_fields;
    case ModelType.vision: return Icons.image;
    case ModelType.stt: return Icons.mic;
    case ModelType.tts: return Icons.volume_up;
  }
}
```

---

## 8. 系统架构设计

### 8.1 完整架构图

```
┌─────────────────────────────────────────────────────────────────┐
│                     TongYi-Lite Android APK                      │
│                                                                  │
│  ╔═══════════════════════════════════════════════════════════╗   │
│  ║              Flutter Layer (Dart)                         ║   │
│  ║                                                           ║   │
│  ║  ┌─────────────┐  ┌─────────────┐  ┌──────────────┐     ║   │
│  ║  │ ChatScreen   │  │ VisionScreen│  │ SessionsList  │     ║   │
│  ║  │ (文字对话)    │  │ (视觉理解)   │  │ (会话列表)    │     ║   │
│  ║  └──────┬───────┘  └──────┬──────┘  └──────┬───────┘     ║   │
│  ║         │                 │                │              ║   │
│  ║  ┌──────▼─────────────────▼────────────────▼───────┐     ║   │
│  ║  │           Service Layer (Riverpod)               ║   │
│  ║  │                                                   ║   │
│  ║  │  InferenceService  VisionService  TTSService      ║   │
│  ║  │       │              │            │              ║   │
│  ║  │  StorageService   ModelHub    SpeechService      ║   │
│  ║  └──────────────┬─────────────────────────────────┘     ║   │
│  ╚═════════════════╪═══════════════════════════════════════╝   │
│                    │                                          │
│  ╔═════════════════╪═══════════════════════════════════════╗   │
│  ║    Android Native Layer (Kotlin + C++)                  ║   │
│  ║                                                           ║   │
│  ║  ┌──────────────┐  ┌─────────────┐  ┌──────────────┐   ║   │
│  ║  │ llama-server │  │ sherpa-onnx │  │ Android TTS  │   ║   │
│  ║  │ (C++ JNI)    │  │ (STT JNI)   │  │ Engine       │   ║   │
│  ║  │              │  │             │  │              │   ║   │
│  ║  │ ·加载 GGUF   │  │ ·语音采集   │  │ ·离线中文    │   ║   │
│  ║  │ ·HTTP Server │  │ ·流式识别   │  │ ·语速控制    │   ║   │
│  ║  │ ·SSE Stream  │  │ ·中英混合   │  │ ·TTS播报    │   ║   │
│  ║  └──────────────┘  └─────────────┘  └──────────────┘   ║   │
│  ╚═════════════════╪═══════════════════════════════════════╝   │
│                    │                                          │
│  ╔═════════════════╪═══════════════════════════════════════╗   │
│  ║              Local Storage Layer                         ║   │
│  ║                                                           ║   │
│  ║  ┌──────────────┐  ┌─────────────┐  ┌──────────────┐   ║   │
│  ║  │ SQLite       │  │ GGUF Models │  │ Audio Files  │   ║   │
│  ║  │ (对话历史)    │  │ (/models/)  │  │ (/audio/)    │   ║   │
│  ║  └──────────────┘  └─────────────┘  └──────────────┘   ║   │
│  ╚═════════════════╪═══════════════════════════════════════╝   │
│                    │                                          │
│  ╔═════════════════╪═══════════════════════════════════════╗   │
│  ║              Network Layer (Offline-First)               ║   │
│  ║                                                           ║   │
│  ║  [完全离线] ← 默认路径 | [按需联网] ← 模型下载 | [可选]    ║   │
│  ╚═════════════════╪═══════════════════════════════════════╝   │
└─────────────────────────────────────────────────────────────┘
```

### 8.2 模块依赖关系

```
                    ┌──────────────┐
                    │  Flutter UI   │
                    │ (Chat/Vision/ │
                    │ Sessions/... )│
                    └──────┬───────┘
                           │
              ┌────────────┼────────────┐
              ▼            ▼            ▼
     ┌────────────┐ ┌────────────┐ ┌────────────┐
     │Inference   │ │Vision      │ │Speech      │
     │Service     │ │Service     │ │Service     │
     └─────┬──────┘ └─────┬──────┘ └─────┬──────┘
           │              │              │
    ┌──────▼──────────────▼──────────────▼──────┐
    │         Native Layer (Android .so)        │
    │                                           │
    │  llama-server (.so) ←→ sherpa-onnx (.so) │
    │       ↕                                    │
    │  Android TTS Engine (系统级)               │
    └──────────────────────┬────────────────────┘
                           │
              ┌────────────┼────────────┐
              ▼            ▼            ▼
     ┌────────────┐ ┌────────────┐ ┌────────────┐
     │ SQLite     │ │ GGUF Files │ │ Audio Files│
     │ (对话历史)  │ │ (/models/)  │ │ (/audio/)  │
     └────────────┘ └────────────┘ └────────────┘
```

### 8.3 进程模型

```
┌─────────────────────────────────────────────┐
│           Android Process: tongyilite       │
│                                             │
│  ┌───────────────────────────────────────┐  │
│  │ Flutter Engine (UI Thread)            │  │
│  │  · Dart VM                            │  │
│  │  · Render Tree                        │  │
│  │  · HTTP Client (Dio)                  │  │
│  └───────────────┬───────────────────────┘  │
│                  │ JNI                       │
│  ┌───────────────▼───────────────────────┐  │
│  │ Native Thread Pool                    │  │
│  │                                       │  │
│  │  · llama-server (推理线程，后台)        │  │
│  │    → 独立进程或同进程 native thread   │  │
│  │  · sherpa-onnx (STT 音频采集线程)      │  │
│  │  · Android TTS (系统服务回调)          │  │
│  └───────────────────────────────────────┘  │
│                                             │
│  Memory Budget:                             │
│  · Flutter UI: ~100MB                       │
│  · llama.cpp Q4_K_M: ~1.2-2.0GB            │
│  · sherpa-onnx: ~80MB                       │
│  · TTS Engine: ~30MB (系统级)               │
│  ──────────────────────────────             │
│  Total: ~1.5-2.4GB (中端手机可接受)          │
└─────────────────────────────────────────────┘
```

---

## 9. 项目目录结构（完整版）

```
TongYi-Lite/
├── android/                          # Android 原生层
│   ├── app/src/main/java/com/dgxspark/tongyilite/
│   │   ├── MainActivity.kt           # Flutter Activity 入口
│   │   ├── LlamaEngineService.kt     # llama.cpp JNI 封装，后台推理服务
│   │   └── SpeechEngineService.kt    # sherpa-onnx STT JNI 封装
│   ├── cpp/                          # C++ 原生代码
│   │   ├── CMakeLists.txt
│   │   ├── llama_jni.cpp             # JNI: 模型加载 + HTTP Server 启动
│   │   └── speech_jni.cpp            # JNI: 音频采集 + STT 推理
│   └── libs/arm64-v8a/
│       ├── libllama.so               # llama.cpp Android 库
│       └── libsherpa-onnx.so         # sherpa-onnx Android 库
│
├── ios/                              # iOS 原生层（后续支持）
│   └── ...
│
├── lib/                              # Flutter Dart 代码
│   ├── main.dart                     # 应用入口 + Theme
│   │
│   ├── models/                       # 数据模型
│   │   ├── chat_message.dart         # {role, content, imageUrl, timestamp}
│   │   ├── conversation.dart         # {id, title, modelId, messages[]}
│   │   ├── model_info.dart           # {id, name, type, params, sizeMB, ...}
│   │   └── download_progress.dart    # 下载进度状态
│   │
│   ├── screens/                      # UI 页面（元宝风格）
│   │   ├── home_screen.dart          # 主聊天界面（气泡+输入栏）
│   │   ├── vision_screen.dart        # 视觉理解界面（拍照+图片分析）
│   │   ├── sessions_screen.dart      # 会话列表页（侧边抽屉）
│   │   ├── model_manager_screen.dart # 模型管理中心（下载/切换/删除）
│   │   ├── settings_screen.dart      # 设置页（TTS开关、语速、主题）
│   │   └── chat_bubble.dart          # 消息气泡组件
│   │
│   ├── widgets/                      # UI 组件库
│   │   ├── streaming_text.dart       # 流式文字渲染 + Markdown
│   │   ├── image_preview_card.dart   # 图片预览卡片（圆角+阴影）
│   │   ├── chat_input_bar.dart       # 输入栏（文本+语音按钮+拍照）
│   │   ├── voice_waveform.dart       # 录音波形动画
│   │   └── download_progress_bar.dart# 下载进度条组件
│   │
│   ├── services/                     # 服务层
│   │   ├── inference_service.dart    # LLM 推理 (HTTP → llama-server)
│   │   ├── vision_service.dart       # 视觉理解 (图片 → VLM → Text)
│   │   ├── speech_service.dart       # STT (音频 → sherpa-onnx → Text)
│   │   ├── tts_service.dart          # TTS (Text → Android TTS Engine)
│   │   ├── storage_service.dart      # SQLite 对话历史 CRUD
│   │   └── model_downloader.dart     # 模型下载 (断点续传)
│   │
│   ├── providers/                    # Riverpod 状态管理
│   │   ├── chat_provider.dart        # 当前对话 + 消息列表
│   │   ├── session_provider.dart     # 会话列表 + 切换
│   │   └── model_provider.dart       # 模型下载进度 + 已下载列表
│   │
│   └── utils/                        # 工具类
│       ├── format_utils.dart         # 文件大小格式化、时间格式化
│       ├── image_utils.dart          # 图片压缩、Base64 编码
│       └── audio_utils.dart          # 音频格式转换
│
├── backend/                          # Python 参考后端（开发调试用）
│   ├── server.py                     # FastAPI HTTP Server
│   ├── engine.py                     # llama-cpp-python 引擎封装
│   └── vision_engine.py              # Qwen2.5-VL 多模态推理
│
├── models/                           # 模型文件（git-lfs）
│   ├── qwen3-1.7b-q4_k_m.gguf       # ~1.2 GB (文本对话)
│   ├── qwen2.5-vl-3b-q4_k_m.gguf    # ~2.0 GB (视觉理解)
│   └── sherpa-wenet-ctc-large.onnx  # ~40 MB (语音识别)
│
├── docs/                             # 文档
│   ├── mobile_llm_benchmark_report_v2.md
│   ├── architecture_design.md        # v1: 基础聊天架构
│   └── architecture_design_v2.md     # ← 本文档: 智能体完整架构
│
├── pubspec.yaml                      # Flutter 依赖配置
│       flutter_tts                   # TTS
│       sqflite                       # SQLite
│       dio                           # HTTP + 断点续传
│       riverpod                      # 状态管理
│       flutter_markdown              # Markdown 渲染
│       image_picker                  # 拍照/相册选择
│       permission_handler            # 权限管理（相机/麦克风/存储）
│
└── README.md                         # 项目说明
```

---

## 10. UI 交互设计

### 10.1 主界面布局（类似元宝）

```
┌─────────────────────────────────────┐
│ ← TongYi-Lite          ⚙️ 设置     │  ← AppBar (侧滑抽屉入口)
├─────────────────────────────────────┤
│                                     │
│  [User]                           ──→│  ← 用户消息气泡（右侧蓝色）
│       "帮我看看这张图里有什么"        │
│                                     │
│  ┌───────────────────────────────┐  │
│  │ 📷 [图片缩略图预览]            │  │  ← 图片附件气泡
│  └───────────────────────────────┘  │
│                                     │
│  ← [AI]                           ──→│  ← AI回复气泡（左侧白色）
│       这张照片里有一只橘色的猫咪，    │
│       它正趴在窗台上晒太阳 ☀️。背景   │
│       可以看到远处的**高楼大厦**。    │
│                                     │
│  [🔊播放] [📋复制]                  │  ← AI回复操作按钮
│                                     │
├─────────────────────────────────────┤
│                                     │
│  ┌───[🎤]──┐   [输入消息...]    [➤]│  ← Input Bar
│  └─────────┘                        │
│                                     │
│  [📷拍照] [🖼️相册]                   │  ← 快捷操作栏（可选显示）
├─────────────────────────────────────┤
```

### 10.2 视觉理解界面

```
┌─────────────────────────────────────┐
│ ← 拍照识别              [📷] [🖼️]   │
├─────────────────────────────────────┤
│                                     │
│  ┌───────────────────────────────┐  │
│  │                               │  │
│  │    📷 Camera Photo Preview    │  │  ← 图片预览区
│  │                               │  │     (点击可放大)
│  │    ┌─────────────────────┐    │  │
│  │    │                     │    │  │
│  │    │   📷 Camera Photo   │    │  │
│  │    │                     │    │  │
│  │    └─────────────────────┘    │  │
│  │                               │  │
│  └───────────────────────────────┘  │
│                                     │
│  [快速提问]                          │
│  ┌─────┐ ┌─────┐ ┌─────┐ ┌─────┐   │
│  │描述  │ │识别  │ │OCR   │ │分析  │   │
│  │图片  │ │文字  │ │提取  │ │场景  │   │
│  └─────┘ └─────┘ └─────┘ └─────┘   │
│                                     │
│  [自定义输入]                         │
│  ┌───────────────────────────────┐  │
│  │ 这张图片中有什么物体？请详细    │  │  ← 文本输入框（可编辑）
│  │ 描述。                          │  │
│  └───────────────────────────────┘  │
│                                     │
│  [AI回复 - Markdown渲染]               │
│  ┌───────────────────────────────┐  │
│  │ 这是一张户外风景照片，拍摄于   │  │
│  │ **晴朗的下午**。画面中可以看到：│  │
│  │                                │  │
│  │ - 🏔️ 远处的雪山               │  │
│  │ - 🌿 近处的绿色草地            │  │
│  └───────────────────────────────┘  │
│                                     │
│  [🔊语音播报] [📋复制] [🔄重新识别]    │
│                                     │
│  [📷重新拍照]         [选择相册图片]   │
├─────────────────────────────────────┤
```

### 10.3 会话管理（侧边抽屉）

```
┌─────────────────────────────────────┐
│          TongYi-Lite                │
│                                     │
│  [+ 新对话]                          │
│  ─────────────────                  │
│                                     │
│  🟢 今天天气怎么样                    │  ← 当前会话（蓝色高亮）
│     3条消息 · 刚刚                   │
│                                     │
│  💬 猫咪识别                         │
│     5条消息 · 1小时前               │
│                                     │
│  📝 代码问题                         │
│     12条消息 · 昨天                 │
│                                     │
│  🗂️ 旅行攻略                        │
│     8条消息 · 3天前                 │
│                                     │
│  ─────────────────                  │
│  💾 已用存储: 3.4 GB                │
│  [🗂️ 模型管理]                       │
└─────────────────────────────────────┘
```

### 10.4 模型管理中心

```
┌─────────────────────────────────────┐
│ ← 🗂️ 模型管理                        │
├─────────────────────────────────────┤
│                                     │
│  💬 文本对话模型                      │
│  ─────────────────                  │
│  ┌───────────────────────────────┐  │
│  │ 🟦 Qwen3-0.6B-Instruct        │  │
│  │    610M · Q4_K_M · 420 MB     │  │
│  │    ✅ 已下载 · 轻量级           │  │
│  │              [切换] [删除]      │  │
│  └───────────────────────────────┘  │
│  ┌───────────────────────────────┐  │
│  │ 🟦 Qwen3-1.7B-Instruct        │  │
│  │    1.75B · Q4_K_M · 1.2 GB    │  │
│  │    ✅ 已下载 · ⭐推荐            │  │
│  │              [切换] [删除]      │  │
│  └───────────────────────────────┘  │
│  ┌───────────────────────────────┐  │
│  │ 🟦 Qwen3-4B-Instruct          │  │
│  │    4.0B · Q4_K_M · 2.8 GB     │  │
│  │    ❓ 待下载                   │  │
│  │              [下载]             │  │
│  └───────────────────────────────┘  │
│                                     │
│  👁️ 视觉理解模型                      │
│  ─────────────────                  │
│  ┌───────────────────────────────┐  │
│  │ 🟪 Qwen2.5-VL-3B-Instruct     │  │
│  │    3.2B · Q4_K_M · 2.0 GB     │  │
│  │    ✅ 已下载                   │  │
│  │              [切换] [删除]      │  │
│  └───────────────────────────────┘  │
│                                     │
│  🎤 语音识别模型                      │
│  ─────────────────                  │
│  ┌───────────────────────────────┐  │
│  │ 🟧 WeNet CTC Large (中文)     │  │
│  │    ~400M · ONNX INT8 · 40 MB  │  │
│  │    ✅ 已下载                   │  │
│  │              [删除]             │  │
│  └───────────────────────────────┘  │
│                                     │
│  🔊 语音合成模型（可选）                │
│  ─────────────────                  │
│  ┌───────────────────────────────┐  │
│  │ 🟩 Piper 中文 (zh-CN)         │  │
│  │    ~200M · ONNX FP32 · 200 MB │  │
│  │    ❓ 待下载                   │  │
│  │              [下载]             │  │
│  └───────────────────────────────┘  │
│                                     │
│  📊 存储统计                         │
│  ─────────────────                  │
│  · 对话历史: 12 MB                   │
│  · 模型文件: 3.4 GB                  │
│  · 总计: 3.41 GB / 可用 50 GB        │
├─────────────────────────────────────┤
```

---

## 11. 开发路线图

### Phase 1：MVP — 基础对话 + 视觉（2-3周）

| 任务 | 技术点 | 预计工时 |
|------|--------|---------|
| Flutter 项目初始化 + Material3 Theme | Flutter SDK | 2h |
| llama.cpp Android .so 预编译 + JNI | CMake + NDK | 6h |
| HTTP Server + SSE Streaming | Dart Dio | 4h |
| 聊天界面 UI（气泡+输入栏） | Flutter Widget | 4h |
| Markdown 渲染 + 流式输出 | flutter_markdown | 2h |
| SQLite 对话历史存储 | sqflite | 3h |
| 视觉理解集成（图片上传 → VLM） | image_picker + multimodal API | 6h |
| 模型下载功能（断点续传） | Dio | 3h |

### Phase 2：语音能力（1-2周）

| 任务 | 技术点 | 预计工时 |
|------|--------|---------|
| sherpa-onnx Android .so + JNI | CMake + NDK | 6h |
| 录音 UI（波形动画+STT转写） | Flutter Audio Recorder | 4h |
| TTS 集成（Android TextToSpeech） | flutter_tts | 2h |
| 语音输入 → LLM 自动送入对话 | Service Layer 整合 | 3h |

### Phase 3：会话管理 + 模型管理（1周）

| 任务 | 技术点 | 预计工时 |
|------|--------|---------|
| 多会话列表 + 切换 | Riverpod + SQLite | 4h |
| 侧边抽屉 UI | Flutter Drawer | 2h |
| 模型管理中心 UI（下载/切换/删除） | ListView + Card | 4h |
| 存储统计展示 | File API | 1h |

### Phase 4：体验优化（1周）

| 任务 | 技术点 | 预计工时 |
|------|--------|---------|
| 暗/亮主题切换 | Flutter Theme System | 2h |
| 图片预览 + 放大查看 | photo_view 插件 | 2h |
| AI回复操作按钮（播放/复制/重新生成）| Custom Widget | 2h |
| 真机测试 + 性能优化 | iPhone/Samsung 调试 | 4h |

---

## 总结

```
┌─────────────────────────────────────────────┐
│       TongYi-Lite v2: 端侧 AI 智能体          │
├─────────────────────────────────────────────┤
│                                             │
│  👁️ 视觉理解：Qwen2.5-VL-3B + llama.cpp     │
│    → 拍照/上传图片 → AI描述/VQA/OCR          │
│                                             │
│  🎤 语音输入：sherpa-onnx (WeNet)            │
│    → 按住说话 → 实时STT转写 → 送入对话        │
│                                             │
│  🔊 TTS播报：Android TextToSpeech            │
│    → AI回复 → 离线朗读（中文语音包）           │
│                                             │
│  💬 文字对话：Qwen3-1.7B + llama.cpp         │
│    → 25+ tok/s 流式输出，打字机效果            │
│                                             │
│  📝 会话管理：SQLite + Riverpod              │
│    → 多轮对话、历史检索、会话切换               │
│                                             │
│  🗂️ 模型管理：Model Hub                      │
│    → 下载/缓存/切换/删除（视觉+语音+文本）      │
│                                             │
│  ═══════ Offline-First ═══════              │
│  [完全离线] ← 默认 | [按需联网] ← 模型下载     │
│                                             │
└─────────────────────────────────────────────┘
```

---

*智能体架构设计方案 v2.0 完毕。下一步可根据此方案开始 Phase 1 MVP 开发。*
