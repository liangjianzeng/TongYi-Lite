# TongYi-Lite Plugin & 荒野求生任务系统架构设计

> **版本**：v1.0  
> **日期**：2026-07-29  
> **核心理念**："你的端侧AI智能体，能远程接收任务、离线自主执行、像荒野求生一样成长"  

---

## 目录

1. [产品愿景](#1-产品愿景)
2. [Plugin 插件架构设计](#2-plugin-插件架构设计)
3. [远程任务推送协议 (Remote Task Protocol)](#3-远程任务推送协议-remote-task-protocol)
4. [荒野求生游戏化系统](#4-荒野求生游戏化系统)
5. [端到端任务执行流程](#5-端到端任务执行流程)
6. [Plugin 运行时安全沙箱](#6-plugin-运行时安全沙箱)
7. [项目目录结构（插件相关）](#7-项目目录结构插件相关)
8. [开发路线图](#8-开发路线图)

---

## 1. 产品愿景

### 核心概念：端侧AI Agent + 远程任务下发 + 游戏化成长

```
┌───────────────────────────────────────────────────────────────┐
│                     TongYi-Lite: AI Wilderness Agent            │
│                                                               │
│   ┌─────────────────────────────────────────────────────┐     │
│   │                🏕️ 荒野求生模式                        │     │
│   │                                                     │     │
│   │  你被困在了数字荒野中...                              │     │
│   │  你的AI智能体是你的唯一伙伴。                          │     │
│   │                                                     │     │
│   │  📡 远程指挥部通过 Plugin 下发任务：                   │     │
│   │    "识别这张图片中的可食用植物"                       │     │
│   │    "整理今天的日志，生成生存报告"                     │     │
│   │    "分析这个工具，告诉我怎么用"                       │     │
│   │                                                     │     │
│   │  🤖 AI Agent 离线自主执行 → 完成任务 → 获得经验值      │     │
│   │  ⭐ 解锁新 Plugin、新能力、新生存技能                   │     │
│   └─────────────────────────────────────────────────────┘     │
│                                                               │
│  ═══════ 三层架构 ═══════                                      │
│  [Plugin 插件] ← 能力扩展 → [任务系统] ← 远程推送 → [指挥部]    │
└───────────────────────────────────────────────────────────────┘
```

### 与元宝/豆包的本质差异

| 维度 | 元宝/豆包（云端AI助手） | TongYi-Lite（端侧荒野求生Agent） |
|------|---------------------|-------------------------------|
| **交互模式** | 用户主动提问 → AI回答 | 远程下发任务 → AI自主执行 → 结果汇报 |
| **联网依赖** | ❌ 必须联网 | ✅ 默认离线，仅Plugin下载/任务同步时联网 |
| **能力扩展** | 固定功能 | 🔌 Plugin 热插拔，无限扩展 |
| **成长机制** | 无 | ⭐ 完成任务获得经验、解锁新Plugin |
| **使用场景** | 日常问答工具 | 荒野求生挑战 / 远程任务管理 / 离线自主执行 |

### 典型使用场景

```
场景1：荒野求生挑战（游戏化）
┌──────────────────────────────────────┐
│ 📡 指挥部下发任务："找到水源"          │
│                                      │
│ 🤖 AI Agent 自主规划：               │
│   1. 拍照扫描周围地形                 │
│   2. 识别可能的积水/溪流迹象           │
│   3. 分析土壤湿度和植被分布            │
│   4. 生成最佳取水点建议                │
│                                      │
│ ✅ 任务完成！+150 XP                  │
│ 🔓 解锁新Plugin: "野外净水"            │
└──────────────────────────────────────┘

场景2：远程任务管理（实用化）
┌──────────────────────────────────────┐
│ 📡 远程下发："整理这份PDF，提取关键信息"│
│                                      │
│ 🤖 AI Agent 离线执行：               │
│   1. 读取本地文件                      │
│   2. LLM摘要+关键词提取                │
│   3. 生成结构化报告                    │
│   4. 回传结果                          │
│                                      │
│ ✅ 任务完成！经验值 +100               │
└──────────────────────────────────────┘

场景3：离线自主探索（趣味性）
┌──────────────────────────────────────┐
│ 📡 指挥部下发："学习这个新工具"         │
│                                      │
│ 🤖 AI Agent 自主执行：               │
│   1. 拍照识别工具类型                   │
│   2. 联网搜索使用指南（可选）           │
│   3. 生成操作教程                       │
│   4. 存入知识库                        │
│                                      │
│ ✅ 任务完成！解锁"工具大师"成就         │
└──────────────────────────────────────┘
```

---

## 2. Plugin 插件架构设计

### 2.1 核心设计理念

```
┌─────────────────────────────────────────────────────────────┐
│                    Plugin Architecture                        │
│                                                             │
│  ┌───────────────────────────────────────────────────────┐  │
│  │              Plugin Host (运行时)                       │  │
│  │                                                       │  │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐            │  │
│  │  │ Plugin A │  │ Plugin B │  │ Plugin C │   ...      │  │
│  │  │ (视觉)    │  │ (语音)    │  │ (文件)    │            │  │
│  │  └────┬─────┘  └────┬─────┘  └────┬─────┘            │  │
│  │       │              │              │                  │  │
│  │  ┌────▼──────────────▼──────────────▼─────┐           │  │
│  │  │         Plugin Runtime Engine          │           │  │
│  │  │                                        │           │  │
│  │  │  · 沙箱隔离 (每个Plugin独立内存空间)      │           │  │
│  │  │  · 能力注册表 (Capability Registry)     │           │  │
│  │  │  · 生命周期管理 (加载/卸载/热更新)       │           │  │
│  │  │  · 权限控制 (文件/网络/摄像头/麦克风)    │           │  │
│  │  └────────────────┬───────────────────────┘           │  │
│  └───────────────────┼───────────────────────────────────┘  │
│                      │                                     │
│  ┌───────────────────▼───────────────────────────────────┐  │
│  │              Plugin Registry (注册中心)                 │  │
│  │                                                       │  │
│  │  · manifest.json  (插件描述文件)                       │  │
│  │  · plugin.js / plugin.wasm / plugin.so               │  │
│  │  · capability_schema.json (能力定义)                   │  │
│  │  · signature.pem      (安全签名)                      │  │
│  └───────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 Plugin Manifest 规范（核心）

每个 Plugin 必须包含一个 `manifest.json`，定义其元数据、能力和权限：

```json
{
  "id": "wilderness-survival",
  "name": "荒野求生",
  "version": "1.0.0",
  "description": "荒野求生挑战任务系统 - 在数字荒野中生存并成长",
  "author": "DGXSpark",
  
  "icon": "🏕️",
  "category": "game",
  
  "minAppVersion": "1.0.0",
  "maxAppVersion": "2.0.0",
  
  "capabilities": [
    {
      "id": "photo_analysis",
      "name": "拍照分析",
      "description": "通过摄像头识别环境中的物体和危险源",
      "inputSchema": {
        "type": "object",
        "properties": {
          "image_uri": { "type": "string", "description": "图片本地路径或base64" },
          "analysis_type": { 
            "type": "string", 
            "enum": ["object_detection", "text_recognition", "scene_understanding"],
            "default": "scene_understanding"
          }
        },
        "required": ["image_uri"]
      },
      "outputSchema": {
        "type": "object",
        "properties": {
          "description": { "type": "string" },
          "objects": { "type": "array" },
          "danger_level": { "type": "number", "minimum": 0, "maximum": 10 }
        }
      }
    },
    {
      "id": "survival_task",
      "name": "生存任务生成",
      "description": "根据当前环境生成合适的生存挑战任务",
      "inputSchema": {
        "type": "object",
        "properties": {
          "environment": { "type": "string" },
          "resources": { "type": "array" }
        }
      },
      "outputSchema": {
        "type": "object",
        "properties": {
          "task_id": { "type": "string" },
          "title": { "type": "string" },
          "description": { "type": "string" },
          "difficulty": { "type": "number", "minimum": 1, "maximum": 5 },
          "xp_reward": { "type": "number" },
          "steps": { "type": "array" }
        }
      }
    },
    {
      "id": "inventory_management",
      "name": "物品管理",
      "description": "管理收集到的生存物资和工具",
      "inputSchema": {
        "type": "object",
        "properties": {
          "action": { 
            "type": "string", 
            "enum": ["add", "remove", "list", "search"] 
          },
          "item_name": { "type": "string" }
        },
        "required": ["action"]
      },
      "outputSchema": {
        "type": "object",
        "properties": {
          "inventory": { "type": "array" },
          "total_items": { "type": "number" }
        }
      }
    }
  ],

  "permissions": [
    "camera",
    "microphone",
    "file_read",
    "storage_write",
    "network_optional"
  ],

  "task_handlers": {
    "vision_task": "onVisionTask",
    "audio_task": "onAudioTask",
    "text_task": "onTextTask",
    "file_task": "onFileTask"
  },

  "gamification": {
    "xp_per_completion": 100,
    "level_up_thresholds": [0, 500, 1500, 3500, 7000],
    "achievements": [
      {"id": "first_survival", "name": "初次求生", "description": "完成第一个生存任务"},
      {"id": "explorer", "name": "探索者", "description": "识别10种不同物体"},
      {"id": "survivor_7days", "name": "七日幸存者", "description": "连续7天执行任务"}
    ]
  },

  "security": {
    "signature": "-----BEGIN PUBLIC KEY-----\n...\n-----END PUBLIC KEY-----",
    "hash_algorithm": "sha256"
  }
}
```

### 2.3 Plugin 接口定义（TypeScript/Flutter）

```dart
// lib/plugins/plugin_base.dart — Plugin 基类接口

/// Plugin 生命周期回调
abstract class PluginBase {
  /// Plugin ID (唯一标识)
  String get pluginId;
  
  /// Plugin 名称
  String get name;
  
  /// Plugin 版本
  String get version;
  
  /// Plugin 描述
  String get description;
  
  /// Plugin 图标 (emoji 或图片路径)
  String get icon;
  
  /// Plugin 类别
  PluginCategory get category;

  /// 初始化（Plugin 加载时调用）
  Future<void> onInit(PluginContext context);
  
  /// 销毁（Plugin 卸载时调用）
  Future<void> onDestroy();
  
  /// 暂停（应用进入后台时调用）
  Future<void> onPause();
  
  /// 恢复（应用回到前台时调用）
  Future<void> onResume();

  /// 执行任务（核心方法 - Plugin 处理远程下发的任务）
  Future<PluginTaskResult> execute(PluginTask task);

  /// 获取当前状态
  Map<String, dynamic> getStatus();
}

/// Plugin 运行上下文
class PluginContext {
  final InferenceService inference;    // LLM推理服务
  final VisionService vision;          // 视觉理解服务
  final SpeechService speech;          // STT服务
  final TTSService tts;                // TTS服务
  final StorageService storage;        // 存储服务
  final DeviceInfo deviceInfo;         // 设备信息
  final Logger logger;                 // 日志

  /// 临时文件目录（Plugin 可用）
  String get tempDir => '/data/data/com.dgxspark.tongyilite/files/plugins/${pluginId}/temp/';
  
  /// 持久化存储（Plugin 私有空间）
  Future<void> saveData(String key, dynamic value);
  Future<dynamic> loadData(String key);
}

/// Plugin 任务定义
class PluginTask {
  final String taskId;               // 任务唯一ID
  final String pluginId;             // 目标Plugin
  final String handlerName;          // 处理方法名 (如 "onVisionTask")
  final Map<String, dynamic> params; // 任务参数
  final DateTime deadline;           // 截止时间（可选）
  final bool isAsync;                // 是否异步执行

  /// 远程推送的任务示例：
  /// {
  ///   "taskId": "task_001",
  ///   "pluginId": "wilderness-survival",
  ///   "handlerName": "onVisionTask",
  ///   "params": {
  ///     "image_uri": "/data/.../photo.jpg",
  ///     "analysis_type": "object_detection"
  ///   },
  ///   "deadline": "2026-07-30T12:00:00Z",
  ///   "isAsync": true
  /// }
}

/// Plugin 任务执行结果
class PluginTaskResult {
  final String taskId;
  final bool success;                // 是否成功
  final dynamic data;                // 返回数据
  final String? error;               // 错误信息（失败时）
  final int xpEarned;                // 获得的经验值
  final DateTime completedAt;        // 完成时间

  /// 任务执行成功的示例：
  /// {
  ///   "taskId": "task_001",
  ///   "success": true,
  ///   "data": {
  ///     "description": "这是一张森林照片，可以看到溪流和岩石",
  ///     "objects": ["tree", "rock", "water"],
  ///     "danger_level": 2
  ///   },
  ///   "xpEarned": 150,
  ///   "completedAt": "2026-07-29T14:30:00Z"
  /// }
}

enum PluginCategory { game, tool, utility, knowledge, custom }
```

### 2.4 Plugin 运行时引擎

```dart
// lib/plugins/plugin_engine.dart — Plugin 管理核心

class PluginEngine {
  final Map<String, PluginBase> _loadedPlugins = {};
  final List<PluginTask> _pendingTasks = [];
  final PluginRegistry _registry;

  /// 加载所有已安装的 Plugin
  Future<void> loadAllPlugins() async {
    final pluginDir = Directory(_appDir + '/plugins');
    if (!await pluginDir.exists()) return;

    await for (final entity in pluginDir.list()) {
      if (entity is Directory) {
        try {
          await loadPlugin(entity.path);
        } catch (e) {
          _logger.error('Failed to load plugin ${entity.path}: $e');
        }
      }
    }
  }

  /// 加载单个 Plugin（含安全验证）
  Future<void> loadPlugin(String pluginPath) async {
    final manifest = await _loadManifest(pluginPath);
    
    // 1. 验证签名
    if (!_verifySignature(manifest)) {
      throw PluginSecurityException('Invalid signature for ${manifest.id}');
    }

    // 2. 检查版本兼容性
    if (!_isVersionCompatible(manifest)) {
      throw PluginVersionException('Incompatible version');
    }

    // 3. 加载 Plugin 实现
    final plugin = await _loadPluginImplementation(pluginPath);
    
    // 4. 注册到运行时
    _loadedPlugins[plugin.pluginId] = plugin;
    await plugin.onInit(_createContext(plugin));
    
    _logger.info('Plugin loaded: ${plugin.name} v${plugin.version}');
  }

  /// 卸载 Plugin
  Future<void> unloadPlugin(String pluginId) async {
    final plugin = _loadedPlugins[pluginId];
    if (plugin != null) {
      await plugin.onDestroy();
      _loadedPlugins.remove(pluginId);
      _logger.info('Plugin unloaded: $pluginId');
    }
  }

  /// 执行远程下发的任务
  Future<PluginTaskResult> executeTask(PluginTask task) async {
    final plugin = _loadedPlugins[task.pluginId];
    if (plugin == null) {
      return PluginTaskResult(
        taskId: task.taskId,
        success: false,
        error: 'Plugin not found: ${task.pluginId}',
        completedAt: DateTime.now(),
      );
    }

    try {
      // 检查权限
      if (!_hasPermission(plugin, task)) {
        return PluginTaskResult(
          taskId: task.taskId,
          success: false,
          error: 'Insufficient permissions',
          completedAt: DateTime.now(),
        );
      }

      final result = await plugin.execute(task);
      
      // 更新经验值
      if (result.xpEarned > 0) {
        await _updatePlayerXP(result.xpEarned);
      }

      return result;
    } catch (e) {
      return PluginTaskResult(
        taskId: task.taskId,
        success: false,
        error: e.toString(),
        completedAt: DateTime.now(),
      );
    }
  }

  /// 处理待执行的任务队列（离线时本地执行）
  Future<void> processPendingTasks() async {
    for (final task in List.from(_pendingTasks)) {
      final result = await executeTask(task);
      
      // 任务完成，从队列中移除
      _pendingTasks.remove(task);
      
      // 如果有回调URL，尝试回传结果（可选联网）
      if (task.callbackUrl != null) {
        await _sendResultBack(task, result);
      }
    }
  }

  /// 接收远程推送的新任务
  Future<void> receiveRemoteTask(Map<String, dynamic> payload) async {
    final task = PluginTask.fromMap(payload);
    
    // 验证任务来源（只接受可信的远程指挥部）
    if (!_verifyTaskSource(task)) {
      _logger.warning('Rejected untrusted task: ${task.taskId}');
      return;
    }

    if (_loadedPlugins.containsKey(task.pluginId)) {
      // Plugin已安装 → 立即执行
      await executeTask(task);
    } else {
      // Plugin未安装 → 加入待执行队列（离线时可稍后处理）
      _pendingTasks.add(task);
      _logger.info('Task queued for later: ${task.taskId}');
    }
  }
}
```

### 2.5 内置 Plugin 示例：荒野求生

```dart
// lib/plugins/wilderness_survival_plugin.dart — 荒野求生 Plugin 实现

class WildernessSurvivalPlugin extends PluginBase {
  @override
  String get pluginId => 'wilderness-survival';
  
  @override
  String get name => '🏕️ 荒野求生';
  
  @override
  String get version => '1.0.0';

  @override
  String get description => '在数字荒野中生存并成长，通过远程任务挑战提升AI能力';

  @override
  PluginCategory get category => PluginCategory.game;

  // === 玩家状态 ===
  int _xp = 0;
  int _level = 1;
  final List<String> _achievements = [];
  final Map<String, dynamic> _inventory = {};

  @override
  Future<void> onInit(PluginContext context) async {
    // 加载玩家存档
    _xp = await context.loadData('xp') ?? 0;
    _level = await context.loadData('level') ?? 1;
    final savedInventory = await context.loadData('inventory');
    if (savedInventory != null) {
      _inventory.addAll(savedInventory as Map);
    }
    
    // 解锁初始能力
    _checkAchievements();
  }

  @override
  Future<PluginTaskResult> execute(PluginTask task) async {
    switch (task.handlerName) {
      case 'onVisionTask':
        return await _handleVisionTask(task);
      case 'onAudioTask':
        return await _handleAudioTask(task);
      case 'onTextTask':
        return await _handleTextTask(task);
      case 'generateSurvivalChallenge':
        return await _generateSurvivalChallenge(task);
      case 'checkInventory':
        return await _checkInventory(task);
      default:
        throw UnimplementedError('Handler not found: ${task.handlerName}');
    }
  }

  /// 处理视觉任务（拍照分析）
  Future<PluginTaskResult> _handleVisionTask(PluginTask task) async {
    final params = task.params;
    
    // 调用本地 VLM 进行图片分析
    final description = await _context.vision.describeImage(
      params['image_uri'] as String,
    );

    // AI Agent 自主判断危险等级和可用资源
    final analysis = await _analyzeEnvironment(description);

    final resultData = {
      'description': description,
      'objects': analysis['objects'],
      'danger_level': analysis['dangerLevel'],
      'resources_found': analysis['resources'],
      'suggestions': analysis['suggestions'],
    };

    // 根据发现给予经验值
    final xpReward = _calculateVisionXP(analysis);
    
    return PluginTaskResult(
      taskId: task.taskId,
      success: true,
      data: resultData,
      xpEarned: xpReward,
      completedAt: DateTime.now(),
    );
  }

  /// 生成生存挑战任务（远程下发时使用）
  Future<PluginTaskResult> _generateSurvivalChallenge(PluginTask task) async {
    // AI Agent 根据当前等级和环境生成合适的挑战
    final challenge = await _context.inference.chat(
      messages: [
        ChatMessage(role: 'system', content: '''
你是荒野求生教练。根据玩家当前等级（$_level级）和已收集的资源，
生成一个有趣的生存挑战任务。要求：
1. 难度适中（与等级匹配）
2. 利用现有能力（视觉/语音/文字）
3. 有明确的完成标准和经验值奖励

返回JSON格式：
{
  "title": "任务标题",
  "description": "详细描述",
  "difficulty": 1-5,
  "xp_reward": 经验值,
  "steps": ["步骤1", "步骤2"],
  "required_capabilities": ["vision", "audio"]
}
        '''),
      ],
    );

    return PluginTaskResult(
      taskId: task.taskId,
      success: true,
      data: _parseJSON(challenge),
      xpEarned: 0, // 挑战生成本身不奖励XP，完成任务才奖励
      completedAt: DateTime.now(),
    );
  }

  /// 计算视觉分析的经验值
  int _calculateVisionXP(Map<String, dynamic> analysis) {
    var xp = 50; // 基础分
    
    // 发现稀有物品加分
    if (analysis['resources'] != null && (analysis['resources'] as List).isNotEmpty) {
      xp += (analysis['resources'] as List).length * 30;
    }
    
    // 识别出危险源加分（安全相关）
    if (analysis['dangerLevel'] > 5) {
      xp += 50;
    }
    
    return xp;
  }

  /// AI Agent 自主分析环境
  Future<Map<String, dynamic>> _analyzeEnvironment(String description) async {
    final analysis = await _context.inference.chat(
      messages: [
        ChatMessage(role: 'system', content: '''
你是一个荒野求生AI助手。根据以下图片描述，分析：
1. 环境中有哪些物体（objects）
2. 危险等级（0-10，0为安全，10为极度危险）
3. 可用的生存资源（resources）
4. 建议行动（suggestions）

用中文回答，返回JSON格式。
        '''),
        ChatMessage(role: 'user', content: description),
      ],
    );

    return _parseJSON(analysis);
  }

  /// 检查玩家成就
  void _checkAchievements() {
    if (_xp >= 500 && !_achievements.contains('first_milestone')) {
      _achievements.add('first_milestone');
      _notifyAchievementUnlocked('初次里程碑', '累计获得500经验值');
    }
    
    // ... 更多成就检查逻辑
  }

  /// 更新玩家经验值和等级
  Future<void> _updatePlayerXP(int xp) async {
    _xp += xp;
    
    // 检查是否升级
    final thresholds = [0, 500, 1500, 3500, 7000, 12000];
    for (int i = thresholds.length - 1; i >= 0; i--) {
      if (_xp >= thresholds[i]) {
        if (_level < i + 1) {
          _level = i + 1;
          await _context.tts.speak('恭喜！你升级到了 $_level 级！');
        }
        break;
      }
    }

    // 保存存档
    await _context.saveData('xp', _xp);
    await _context.saveData('level', _level);
    await _context.saveData('inventory', _inventory);
  }

  /// 通知成就解锁
  void _notifyAchievementUnlocked(String name, String description) {
    // TODO: 触发UI动画和TTS播报
    print('🏆 Achievement Unlocked: $name - $description');
  }

  @override
  Map<String, dynamic> getStatus() => {
    'xp': _xp,
    'level': _level,
    'achievements': _achievements.length,
    'inventory_count': _inventory.length,
  };
}
```

---

## 3. 远程任务推送协议 (Remote Task Protocol)

### 3.1 协议设计原则

```
┌─────────────────────────────────────────────────────────────┐
│              Remote Task Push Protocol                        │
│                                                             │
│  【离线优先】任务可以完全离线执行，联网仅用于：                │
│    1. 接收新任务和Plugin更新                                  │
│    2. 回传执行结果                                            │
│    3. 请求额外资源（可选）                                    │
│                                                             │
│  【安全认证】所有远程推送必须经过签名验证                      │
│  【幂等性】相同taskId的任务不会重复执行                        │
│  【超时控制】任务有截止时间，超时可取消                         │
└─────────────────────────────────────────────────────────────┘
```

### 3.2 协议消息格式（JSON）

#### 📥 服务端 → 客户端：下发任务

```json
{
  "type": "TASK_PUSH",
  "messageId": "msg_001",
  "timestamp": "2026-07-29T10:00:00Z",
  "source": {
    "commander_id": "cmd_001",
    "commander_name": "AI指挥部",
    "signature": "base64_encoded_signature"
  },
  "task": {
    "taskId": "task_wilderness_001",
    "pluginId": "wilderness-survival",
    "handlerName": "onVisionTask",
    "params": {
      "image_uri": "/data/.../photo.jpg",
      "analysis_type": "scene_understanding"
    },
    "deadline": "2026-07-29T14:00:00Z",
    "isAsync": true,
    "priority": "normal",
    "callbackUrl": "https://command.dgxspark.com/api/results",
    "metadata": {
      "challengeId": "challenge_forest_day3",
      "xpMultiplier": 1.5
    }
  },
  "ackRequired": true
}
```

#### 📤 客户端 → 服务端：回传结果

```json
{
  "type": "TASK_RESULT",
  "messageId": "msg_ack_001",
  "timestamp": "2026-07-29T14:30:00Z",
  "taskId": "task_wilderness_001",
  "result": {
    "success": true,
    "data": {
      "description": "这是一张森林照片...",
      "objects": ["tree", "rock", "water"],
      "danger_level": 2,
      "resources_found": ["fresh_water", "berries"]
    },
    "xpEarned": 195,
    "executionTimeMs": 4500,
    "completedAt": "2026-07-29T14:30:00Z"
  }
}
```

#### 📥 服务端 → 客户端：Plugin 更新推送

```json
{
  "type": "PLUGIN_UPDATE",
  "messageId": "msg_plugin_001",
  "timestamp": "2026-07-29T10:00:00Z",
  "plugin": {
    "id": "wilderness-survival",
    "version": "1.1.0",
    "manifest": { ... },
    "downloadUrl": "https://cdn.dgxspark.com/plugins/wilderness-survival-1.1.0.zip",
    "changelog": "新增：夜间模式识别、水源检测增强"
  }
}
```

### 3.3 协议状态机

```
                    ┌─────────────┐
                    │   IDLE      │ ← 空闲等待任务
                    └──────┬──────┘
                           │
              ┌────────────▼────────────┐
              │    TASK_RECEIVED        │ ← 收到远程任务推送
              │    (离线模式)            │
              └────────────┬────────────┘
                           │
              ┌────────────▼────────────┐
              │   EXECUTING             │ ← AI Agent 执行中
              │   (本地推理)              │
              └────────────┬────────────┘
                           │
              ┌────────────▼────────────┐
              │    COMPLETED            │ ← 任务完成
              │                         │
              │  ┌─ 有 callbackUrl ───┐ │
              │  │   联网回传结果      │ │
              │  └─────────┬──────────┘ │
              │             │           │
              │  ┌─ 无callbackUrl ───┐  │
              │  │ 本地缓存结果       │  │
              │  │ 下次联网时回传     │  │
              │  └─────────┬──────────┘  │
              └────────────┬────────────┘
                           │
                    ┌──────▼──────┐
                    │   IDLE      │ ← 回到空闲状态
```

### 3.4 通信通道设计（离线优先）

```
┌─────────────────────────────────────────────────┐
│           Communication Channels                  │
│                                                  │
│  Channel 1: [WebSocket] ← 实时任务推送            │
│    · 长连接，服务端主动推送到客户端                 │
│    · 心跳保活（30秒）                             │
│    · 断线自动重连                                 │
│    · 离线时不依赖                                │
│                                                  │
│  Channel 2: [HTTP Polling] ← 备用通道             │
│    · WebSocket不可用时降级为轮询                   │
│    · 每60秒检查一次新任务                         │
│    · 适合低配设备或网络不稳定场景                  │
│                                                  │
│  Channel 3: [Local Queue] ← 离线队列              │
│    · 所有接收到的任务先存入本地SQLite               │
│    · 有网时按序执行+回传                           │
│    · 无网时继续执行，结果缓存待回传                 │
│                                                  │
│  Channel 4: [Push Notification] ← 系统通知        │
│    · 任务到达时推送系统通知                        │
│    · 任务完成时推送结果摘要                        │
│    · Android FCM / iOS APNs                      │
└─────────────────────────────────────────────────┘
```

---

## 4. 荒野求生游戏化系统

### 4.1 核心游戏循环

```
┌──────────────────────────────────────────────────────┐
│                  Game Loop (游戏循环)                   │
│                                                      │
│   📡 远程下发任务                                      │
│        ↓                                              │
│   🤖 AI Agent 离线执行                                 │
│        ↓                                              │
│   ✅ 任务完成 → +XP → ⭐ 升级                          │
│        ↓                                              │
│   🔓 解锁新Plugin / 新能力 / 新成就                     │
│        ↓                                              │
│   📡 接收更高级的挑战任务                               │
│        ↓                                              │
│   (循环)                                               │
└──────────────────────────────────────────────────────┘
```

### 4.2 等级与经验系统

```dart
// lib/game/level_system.dart

class LevelSystem {
  static const List<LevelConfig> levels = [
    LevelConfig(level: 1, name: '新手幸存者', xpRequired: 0),
    LevelConfig(level: 2, name: '初级探索者', xpRequired: 500),
    LevelConfig(level: 3, name: '中级求生者', xpRequired: 1500),
    LevelConfig(level: 4, name: '高级荒野猎人', xpRequired: 3500),
    LevelConfig(level: 5, name: '荒野大师', xpRequired: 7000),
    LevelConfig(level: 6, name: '求生传奇', xpRequired: 12000),
    LevelConfig(level: 7, name: 'AI生存之神', xpRequired: 20000),
  ];

  /// 升级时解锁的能力
  static const Map<int, List<UnlockableCapability>> unlocks = {
    1: [
      UnlockableCapability(id: 'text_chat', name: '文字对话'),
      UnlockableCapability(id: 'basic_vision', name: '基础图片识别'),
    ],
    2: [
      UnlockableCapability(id: 'voice_input', name: '语音输入'),
      UnlockableCapability(id: 'plugin_marketplace', name: 'Plugin市场'),
    ],
    3: [
      UnlockableCapability(id: 'advanced_vision', name: '高级视觉分析'),
      UnlockableCapability(id: 'tts_output', name: 'TTS语音播报'),
    ],
    4: [
      UnlockableCapability(id: 'plugin_creator', name: '自定义Plugin开发'),
      UnlockableCapability(id: 'multi_model_switch', name: '多模型切换'),
    ],
    5: [
      UnlockableCapability(id: 'wilderness_master', name: '荒野大师Plugin'),
      UnlockableCapability(id: 'remote_commander', name: '远程指挥部'),
    ],
  };

  /// 检查是否可以解锁新能力
  List<UnlockableCapability> getUnlocksAtLevel(int level) {
    return unlocks[level] ?? [];
  }
}

class LevelConfig {
  final int level;
  final String name;
  final int xpRequired;
}

class UnlockableCapability {
  final String id;
  final String name;
}
```

### 4.3 成就系统

```dart
// lib/game/achievement_system.dart

class AchievementSystem {
  static const List<Achievement> allAchievements = [
    // === 基础成就 ===
    Achievement(
      id: 'first_task',
      name: '初次任务',
      description: '完成第一个远程下发的任务',
      icon: '🎯',
      xpReward: 50,
      condition: (state) => state.totalTasksCompleted >= 1,
    ),
    Achievement(
      id: 'vision_master',
      name: '视觉大师',
      description: '通过视觉任务识别超过50种不同物体',
      icon: '👁️',
      xpReward: 200,
      condition: (state) => state.totalObjectsIdentified >= 50,
    ),
    Achievement(
      id: 'voice_pioneer',
      name: '语音先锋',
      description: '使用语音输入完成10个任务',
      icon: '🎤',
      xpReward: 100,
      condition: (state) => state.voiceTasksCompleted >= 10,
    ),

    // === 荒野求生成就 ===
    Achievement(
      id: 'survivor_day1',
      name: '第一天生存',
      description: '在荒野求生模式下存活第一天',
      icon: '🏕️',
      xpReward: 100,
      condition: (state) => state.survivalDays >= 1,
    ),
    Achievement(
      id: 'survivor_week',
      name: '七日幸存者',
      description: '连续7天执行荒野求生任务',
      icon: '⭐',
      xpReward: 500,
      condition: (state) => state.consecutiveSurvivalDays >= 7,
    ),
    Achievement(
      id: 'treasure_hunter',
      name: '宝藏猎人',
      description: '在视觉任务中发现稀有资源10次',
      icon: '💎',
      xpReward: 300,
      condition: (state) => state.rareResourcesFound >= 10,
    ),

    // === Plugin 成就 ===
    Achievement(
      id: 'plugin_collector',
      name: '插件收藏家',
      description: '安装并启用5个不同的Plugin',
      icon: '🧩',
      xpReward: 200,
      condition: (state) => state.installedPlugins.length >= 5,
    ),
    Achievement(
      id: 'plugin_creator_pro',
      name: '插件大师',
      description: '创建并发布1个自定义Plugin',
      icon: '🛠️',
      xpReward: 500,
      condition: (state) => state.createdPlugins >= 1,
    ),

    // === 隐藏成就（彩蛋）===
    Achievement(
      id: 'night_owl',
      name: '夜猫子',
      description: '在凌晨2-4点完成一个任务',
      icon: '🦉',
      xpReward: 100,
      condition: (state) => _isLateNight(state.lastTaskTime),
    ),
    Achievement(
      id: 'speed_demon',
      name: '闪电侠',
      description: '在3秒内完成一个视觉任务（极限操作）',
      icon: '⚡',
      xpReward: 200,
      condition: (state) => state.fastestTaskTime <= 3.0,
    ),
  ];

  /// 检查所有成就状态
  List<Achievement> checkAllAchievements(PlayerState state) {
    return allAchievements.where((a) => 
      !state.unlockedAchievements.contains(a.id) && a.condition(state)
    ).toList();
  }
}

class Achievement {
  final String id;
  final String name;
  final String description;
  final String icon;
  final int xpReward;
  final bool Function(PlayerState state) condition;
  
  bool isUnlocked(PlayerState state) => condition(state);
}

class PlayerState {
  int totalTasksCompleted = 0;
  int totalObjectsIdentified = 0;
  int voiceTasksCompleted = 0;
  int survivalDays = 0;
  int consecutiveSurvivalDays = 0;
  int rareResourcesFound = 0;
  List<String> installedPlugins = [];
  int createdPlugins = 0;
  DateTime? lastTaskTime;
  double fastestTaskTime = double.infinity;
  List<String> unlockedAchievements = [];
}
```

### 4.4 荒野求生挑战系统

```dart
// lib/game/survival_challenge.dart

class SurvivalChallenge {
  final String challengeId;
  final String title;
  final String description;
  final int difficulty;       // 1-5
  final List<ChallengeStep> steps;
  final Map<String, dynamic> reward;
  final DateTime createdAt;
  final DateTime deadline;
  ChallengeStatus status;

  /// 挑战状态
  enum ChallengeStatus { pending, in_progress, completed, failed, expired }
}

class ChallengeStep {
  final String stepId;
  final String description;
  final String requiredCapability; // 'vision', 'audio', 'text'
  final Map<String, dynamic> params;
  bool isCompleted = false;
}

/// 挑战难度与任务类型的对应关系
class ChallengeDifficultyMatrix {
  static const Map<int, List<ChallengeTemplate>> templates = {
    1: [  // 简单 - 基础识别
      ChallengeTemplate(
        title: '这是什么？',
        capability: 'vision',
        description: '拍摄一张照片，让AI识别其中的物体',
        xpReward: 50,
      ),
      ChallengeTemplate(
        title: '文字提取',
        capability: 'vision',
        description: '拍一张有文字的图片（菜单、路牌等），让AI提取文字',
        xpReward: 60,
      ),
    ],
    2: [  // 中等 - 场景理解
      ChallengeTemplate(
        title: '环境分析',
        capability: 'vision',
        description: '拍摄周围环境，让AI分析场景并给出建议',
        xpReward: 100,
      ),
      ChallengeTemplate(
        title: '语音日记',
        capability: 'audio',
        description: '用语音记录今天的经历，让AI整理成文字日志',
        xpReward: 80,
      ),
    ],
    3: [  // 困难 - 综合分析
      ChallengeTemplate(
        title: '多模态侦探',
        capability: 'vision+audio',
        description: '拍摄一张照片并用语音描述你的疑问，AI综合回答',
        xpReward: 150,
      ),
    ],
    4: [  // 专家 - 创造性任务
      ChallengeTemplate(
        title: '创意写作助手',
        capability: 'text+vision',
        description: '拍一张照片，让AI基于它创作一个短篇故事',
        xpReward: 200,
      ),
    ],
    5: [  // 大师 - 复杂项目
      ChallengeTemplate(
        title: '全能助手挑战',
        capability: 'all',
        description: '完成一个多步骤的综合任务（拍照+语音+文字+文件处理）',
        xpReward: 300,
      ),
    ],
  };

  /// 根据玩家等级推荐挑战
  static List<ChallengeTemplate> recommendChallenges(int playerLevel) {
    final level = playerLevel.clamp(1, 5);
    return templates[level] ?? templates[1]!;
  }
}
```

### 4.5 游戏化 UI 设计

```dart
// lib/screens/wilderness_dashboard.dart — 荒野求生仪表盘

class WildernessDashboard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('🏕️ 荒野求生')),
      body: SingleChildScrollView(
        child: Column(
          children: [
            // === 玩家状态卡片 ===
            _PlayerStatusCard(),
            
            // === 当前挑战进度 ===
            _CurrentChallengeCard(),
            
            // === 最近成就 ===
            _RecentAchievementsCard(),
            
            // === 可接取的挑战列表 ===
            _AvailableChallengesList(),
            
            // === Plugin 市场入口 ===
            _PluginMarketplaceEntry(),
          ],
        ),
      ),
    );
  }

  Widget _PlayerStatusCard() {
    return Card(
      margin: EdgeInsets.all(16),
      child: Padding(
        padding: EdgeInsets.all(20),
        child: Column(
          children: [
            // 等级头像 + 名称
            Row(
              children: [
                CircleAvatar(
                  radius: 30,
                  backgroundColor: Colors.orange.shade100,
                  child: Text('🧑‍🌾', style: TextStyle(fontSize: 30)),
                ),
                SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Lv.${_player.level} ${_player.levelName}', 
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                      // XP 进度条
                      LinearProgressIndicator(
                        value: _player.xpProgress,
                        backgroundColor: Colors.grey.shade200,
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.orange),
                      ),
                      SizedBox(height: 4),
                      Text('${_player.xp}/${_player.nextLevelXp} XP'),
                    ],
                  ),
                ),
              ],
            ),

            SizedBox(height: 16),

            // 统计面板
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _StatItem(icon: '📋', value: '${_player.totalTasks}', label: '完成任务'),
                _StatItem(icon: '⭐', value: '${_player.achievements.length}', label: '成就'),
                _StatItem(icon: '🧩', value: '${_player.installedPlugins.length}', label: 'Plugin'),
                _StatItem(icon: '🔥', value: '${_player.streakDays}', label: '连续天数'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _CurrentChallengeCard() {
    return Card(
      margin: EdgeInsets.symmetric(horizontal: 16),
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('🎯 当前挑战', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                Chip(label: Text('难度 ${_challenge.difficulty}⭐')),
              ],
            ),
            SizedBox(height: 8),
            Text(_challenge.title, style: TextStyle(fontSize: 14)),
            SizedBox(height: 8),
            
            // 步骤进度
            ...List.generate(_challenge.steps.length, (i) {
              return Padding(
                padding: EdgeInsets.only(left: 8, top: 4),
                child: Row(
                  children: [
                    Icon(
                      _challenge.steps[i].isCompleted 
                          ? Icons.check_circle : Icons.radio_button_unchecked,
                      color: _challenge.steps[i].isCompleted ? Colors.green : Colors.grey,
                      size: 18,
                    ),
                    SizedBox(width: 8),
                    Text(_challenge.steps[i].description, style: TextStyle(fontSize: 12)),
                  ],
                ),
              );
            }),

            SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('奖励：+${_challenge.reward['xp']} XP'),
                ElevatedButton(
                  onPressed: _startChallenge,
                  child: Text('开始挑战'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _RecentAchievementsCard() {
    return Card(
      margin: EdgeInsets.symmetric(horizontal: 16),
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('🏆 最近成就', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            SizedBox(height: 8),
            
            // 成就网格（2列）
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _recentAchievements.map((a) {
                return Chip(
                  avatar: Text(a.icon),
                  label: Text(a.name, style: TextStyle(fontSize: 12)),
                );
              }).toList(),
            ),

            if (_pendingUnlocks.isNotEmpty) ...[
              SizedBox(height: 8),
              Text('🔓 即将解锁:', style: TextStyle(fontSize: 12, color: Colors.orange)),
              Wrap(
                spacing: 8,
                children: _pendingUnlocks.map((a) {
                  return Chip(
                    avatar: Icon(Icons.lock_outline, size: 14),
                    label: Text(a.name, style: TextStyle(fontSize: 12)),
                  );
                }).toList(),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _AvailableChallengesList() {
    return Card(
      margin: EdgeInsets.symmetric(horizontal: 16),
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('📋 可接取挑战', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            SizedBox(height: 8),
            
            ...ChallengeDifficultyMatrix.recommendChallenges(_player.level).map((template) {
              return ListTile(
                leading: Icon(_getCapabilityIcon(template.capability)),
                title: Text(template.title),
                subtitle: Text('${template.description}\n奖励：+${template.xpReward} XP'),
                trailing: ElevatedButton(
                  onPressed: () => _acceptChallenge(template),
                  child: Text('接取'),
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  Widget _PluginMarketplaceEntry() {
    return Card(
      margin: EdgeInsets.all(16),
      child: InkWell(
        onTap: () => Navigator.push(context, 
          MaterialPageRoute(builder: (_) => PluginMarketplaceScreen())),
        child: Padding(
          padding: EdgeInsets.all(20),
          child: Row(
            children: [
              Icon(Icons.extension, size: 40, color: Colors.purple),
              SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('🧩 Plugin 市场', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    SizedBox(height: 4),
                    Text('浏览、下载和安装新Plugin扩展你的AI能力'),
                  ],
                ),
              ),
              Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }

  IconData _getCapabilityIcon(String capability) {
    if (capability.contains('vision')) return Icons.image;
    if (capability.contains('audio')) return Icons.mic;
    if (capability.contains('text')) return Icons.text_fields;
    return Icons.extension;
  }
}
```

### 4.6 Plugin 市场 UI

```dart
// lib/screens/plugin_marketplace.dart — Plugin 商店

class PluginMarketplaceScreen extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('🧩 Plugin 市场')),
      body: Column(
        children: [
          // 分类标签
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: ['全部', '游戏', '工具', '实用', '知识', '自定义'].map((cat) {
                return Padding(
                  padding: EdgeInsets.all(8),
                  child: ChoiceChip(
                    label: Text(cat),
                    selected: cat == _selectedCategory,
                    onSelected: (selected) => setState(() => _selectedCategory = cat),
                  ),
                );
              }).toList(),
            ),
          ),

          // Plugin 列表
          Expanded(
            child: StreamBuilder<List<PluginInfo>>(
              stream: _pluginRegistry.watchMarketplacePlugins(_selectedCategory),
              builder: (context, snapshot) {
                return ListView.builder(
                  itemCount: snapshot.data?.length ?? 0,
                  itemBuilder: (context, index) {
                    final plugin = snapshot.data![index];
                    final isInstalled = _isPluginInstalled(plugin.id);

                    return Card(
                      margin: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: _getCategoryColor(plugin.category),
                          child: Text(plugin.icon),
                        ),
                        title: Text(plugin.name),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(plugin.description),
                            SizedBox(height: 4),
                            Row(
                              children: [
                                Icon(Icons.star, size: 14, color: Colors.amber),
                                SizedBox(width: 4),
                                Text('${plugin.rating}'),
                                SizedBox(width: 16),
                                Text('${plugin.downloads} 次安装'),
                              ],
                            ),
                          ],
                        ),
                        trailing: isInstalled
                            ? ElevatedButton(
                                onPressed: () => _managePlugin(plugin.id),
                                child: Text('已安装'),
                              )
                            : ElevatedButton(
                                onPressed: () => _downloadPlugin(plugin),
                                child: Text('下载 ${plugin.sizeMB}MB'),
                              ),
                      ),
                    );
                  },
                );
              },
            ),
          ),

          // 底部：自定义 Plugin 开发入口
          Padding(
            padding: EdgeInsets.all(16),
            child: OutlinedButton.icon(
              onPressed: () => Navigator.push(context, 
                MaterialPageRoute(builder: (_) => PluginCreatorScreen())),
              icon: Icon(Icons.code),
              label: Text('创建自己的 Plugin'),
            ),
          ),
        ],
      ),
    );
  }
}
```

---

## 5. 端到端任务执行流程

### 完整流程图

```
┌──────────────────────────────────────────────────────────────┐
│                    远程指挥部 (Server)                         │
│                                                               │
│  📋 创建挑战任务 → 签名打包 → WebSocket推送                     │
│                           │                                   │
│                           ▼                                   │
│  ┌─────────────────────────────────────────────────────┐     │
│  │              TongYi-Lite APK (Android)               │     │
│  │                                                     │     │
│  │  1. WebSocket收到任务推送                              │     │
│  │     ↓                                                │     │
│  │  2. Plugin Engine 验证签名 + 检查Plugin是否已安装       │     │
│  │     ├─ 已安装 → 立即执行                               │     │
│  │     └─ 未安装 → 加入离线队列，推送"需要下载"通知         │     │
│  │     ↓                                                │     │
│  │  3. Plugin 执行任务                                    │     │
│  │     ├─ 视觉任务：调用 VLM (Qwen2.5-VL) → 分析图片       │     │
│  │     ├─ 语音任务：调用 STT (sherpa-onnx) → 转写文字      │     │
│  │     └─ 文本/文件任务：调用 LLM (Qwen3-1.7B) → 处理      │     │
│  │     ↓                                                │     │
│  │  4. Plugin 返回结果 + XP                               │     │
│  │     ↓                                                │     │
│  │  5. 更新玩家状态 (XP/等级/成就)                          │     │
│  │     ↓                                                │     │
│  │  6. 回传结果到远程指挥部                                 │     │
│  │        ├─ 有网 → 即时回传                               │     │
│  │        └─ 无网 → 缓存到本地，下次联网时回传               │     │
│  └─────────────────────────────────────────────────────┘     │
│                           │                                   │
│                           ▼                                   │
│  📊 服务器接收结果 → 更新挑战进度 → 推送下一个任务               │
└──────────────────────────────────────────────────────────────┘
```

### 离线执行场景详解

```
场景：用户在飞机上（无网络），收到之前缓存的任务

时间线:
14:00  📡 有网时，接收3个远程任务 → 全部存入本地队列
       ┌─ task_001: 视觉分析 (wilderness plugin)
       ├─ task_002: 语音日记转写 (speech plugin)
       └─ task_003: 文件整理 (document plugin)

14:30  ✈️ 进入飞行模式（无网络）
       → Plugin Engine 自动开始执行离线队列中的任务
       
14:31  ✅ task_001 完成：AI识别了图片中的物体，+80 XP
       → 结果缓存到本地 SQLite

14:35  ✅ task_002 完成：语音转文字成功，+60 XP  
       → 结果缓存到本地 SQLite

14:40  ✅ task_003 完成：文件摘要生成完毕，+100 XP
       → 结果缓存到本地 SQLite

       → 玩家等级从 Lv.2 → Lv.3！解锁"Plugin市场"能力 🔓
       → TTS播报："恭喜升级！现在你可以访问Plugin市场了！"

16:00  📶 恢复网络（落地后）
       → Plugin Engine 自动回传所有缓存结果到远程指挥部
       → 服务器更新挑战进度，推送下一个任务
```

---

## 6. Plugin 运行时安全沙箱

### 6.1 安全架构

```
┌─────────────────────────────────────────────────────────────┐
│                    Security Sandbox                            │
│                                                               │
│  ┌───────────────────────────────────────────────────────┐   │
│  │              Plugin Runtime (受限环境)                   │   │
│  │                                                       │   │
│  │  ┌─────────────────────────────────────────────────┐  │   │
│  │  │  Plugin A: wilderness-survival                   │  │   │
│  │  │  · 独立内存空间 (隔离)                            │  │   │
│  │  │  · 仅可访问 /plugins/wilderness-survival/        │  │   │
│  │  │  · 权限: camera, file_read                       │  │   │
│  │  │  · CPU时间配额: 30s/任务                         │  │   │
│  │  │  · 内存限制: 256MB                               │  │   │
│  │  └─────────────────────────────────────────────────┘  │   │
│  │                                                       │   │
│  │  ┌─────────────────────────────────────────────────┐  │   │
│  │  │  Plugin B: custom-tool                           │  │   │
│  │  │  · 独立内存空间 (隔离)                            │  │   │
│  │  │  · 仅可访问 /plugins/custom-tool/                │  │   │
│  │  │  · 权限: file_read, network_optional             │  │   │
│  │  │  · CPU时间配额: 60s/任务                         │  │   │
│  │  │  · 内存限制: 512MB                               │  │   │
│  │  └─────────────────────────────────────────────────┘  │   │
│  └───────────────────────────────────────────────────────┘   │
│                           │                                   │
│              ┌────────────▼────────────┐                      │
│              │    Security Monitor      │                      │
│              │                         │                      │
│              │  · 文件访问拦截           │                      │
│              │  · 网络请求过滤           │                      │
│              │  · CPU/内存监控           │                      │
│              │  · 异常行为检测           │                      │
│              │  · 签名验证 (每次加载)    │                      │
│              └─────────────────────────┘                      │
└─────────────────────────────────────────────────────────────┘
```

### 6.2 安全策略

| 维度 | 策略 | 实现方式 |
|------|------|---------|
| **代码签名** | 所有Plugin必须经过数字签名验证 | SHA-256 + RSA签名，加载时校验 |
| **权限最小化** | Plugin只能声明和使用所需权限 | manifest.json 中显式声明 |
| **文件隔离** | 每个Plugin有独立的存储目录 | `/plugins/{pluginId}/` |
| **内存限制** | 单个Plugin最大256MB（可配置） | Android Process.memoryLimit |
| **CPU配额** | 单任务最长30秒（超时自动终止） | Handler.postDelayed 超时检测 |
| **网络隔离** | Plugin默认无网络权限，需显式声明 | manifest.json permissions字段 |
| **行为监控** | 异常行为触发安全告警并卸载Plugin | Security Monitor 后台服务 |

---

## 7. 项目目录结构（插件相关）

```
TongYi-Lite/
├── lib/
│   ├── plugins/                      # Plugin 系统核心
│   │   ├── plugin_base.dart          # Plugin 基类接口
│   │   ├── plugin_engine.dart        # Plugin 运行时引擎
│   │   ├── plugin_registry.dart      # Plugin 注册中心
│   │   ├── plugin_security.dart      # 安全沙箱 + 签名验证
│   │   └── task_protocol.dart        # 远程任务协议解析
│   │
│   │   └── built_in/                 # 内置 Plugin
│   │       ├── wilderness_survival_plugin.dart  # 🏕️ 荒野求生
│   │       ├── document_tool_plugin.dart         # 📄 文档处理工具
│   │       ├── knowledge_base_plugin.dart        # 📚 知识库管理
│   │       └── custom_task_plugin.dart           # 🔧 自定义任务模板
│   │
│   │   └── marketplace/              # Plugin 市场
│   │       ├── marketplace_client.dart     # 从服务器获取Plugin列表
│   │       ├── plugin_installer.dart      # 下载+安装Plugin
│   │       └── plugin_creator_template.dart # 自定义Plugin开发模板
│   │
│   ├── game/                         # 游戏化系统
│   │   ├── level_system.dart          # 等级与经验系统
│   │   ├── achievement_system.dart     # 成就系统
│   │   ├── survival_challenge.dart     # 荒野求生挑战
│   │   └── player_state.dart           # 玩家状态管理
│   │
│   └── screens/                      # UI 页面（新增）
│       ├── wilderness_dashboard.dart   # 🏕️ 荒野求生仪表盘
│       ├── plugin_marketplace.dart     # 🧩 Plugin 市场
│       └── plugin_creator.dart         # 🔧 Plugin 创建器
│
├── backend/                          # 远程指挥部服务端（可选）
│   ├── server.py                     # FastAPI 任务推送服务
│   ├── task_manager.py               # 任务创建+调度
│   ├── plugin_registry_server.py     # Plugin 注册中心(服务端)
│   └── results_collector.py          # 结果收集+分析
│
├── plugins/                          # 社区Plugin仓库（示例）
│   ├── wilderness-survival-v1.0.zip
│   ├── document-tool-v1.0.zip
│   └── ...
│
└── docs/
    ├── architecture_design_v2.md     # v2: 智能体架构
    ├── plugin_architecture.md        # ← 本文档：Plugin + 荒野求生
    └── remote_task_protocol.md       # 远程任务协议详细规范
```

---

## 8. 开发路线图

### Phase 1：Plugin 基础框架（2周）

| 任务 | 技术点 | 预计工时 |
|------|--------|---------|
| Plugin 基类接口定义 + 生命周期管理 | Dart Interface | 4h |
| Plugin Engine 运行时（加载/卸载/执行） | Dart + File I/O | 8h |
| manifest.json 解析 + 签名验证 | JSON + RSA | 4h |
| 安全沙箱基础（文件隔离 + 权限检查） | Android Storage API | 6h |

### Phase 2：荒野求生 Plugin（2周）

| 任务 | 技术点 | 预计工时 |
|------|--------|---------|
| 荒野求生 Plugin 核心逻辑实现 | Dart (PluginBase) | 12h |
| 等级系统 + XP计算 + 升级检测 | Riverpod Provider | 4h |
| 成就系统（检查条件 + UI展示） | StreamBuilder | 6h |
| 荒野求生仪表盘UI | Flutter Widget | 8h |

### Phase 3：远程任务推送（2周）

| 任务 | 技术点 | 预计工时 |
|------|--------|---------|
| WebSocket 长连接 + 心跳保活 | Dart WebSocket | 6h |
| 离线任务队列 (SQLite) | sqflite | 4h |
| 结果回传机制（有网即时/无网缓存） | Dio + SQLite | 6h |
| 远程指挥部服务端 MVP | FastAPI | 8h |

### Phase 4：Plugin 市场 + 游戏化完善（2周）

| 任务 | 技术点 | 预计工时 |
|------|--------|---------|
| Plugin 市场 UI (浏览/下载/安装) | Flutter ListView | 6h |
| 自定义 Plugin 创建器 | Dart Code Generator | 8h |
| 挑战难度推荐算法 | 等级匹配逻辑 | 4h |
| TTS播报成就解锁 + 升级通知 | flutter_tts | 2h |

---

## 总结

```
┌─────────────────────────────────────────────┐
│   TongYi-Lite: Plugin + 荒野求生系统           │
├─────────────────────────────────────────────┤
│                                             │
│  🔌 Plugin 架构：                            │
│    · manifest.json 声明能力+权限              │
│    · Plugin Engine 运行时（加载/卸载/执行）     │
│    · 安全沙箱（签名验证 + 文件隔离 + 资源限制） │
│    · 热插拔，无需重启APP                       │
│                                             │
│  📡 远程任务协议：                            │
│    · WebSocket 实时推送（离线时降级轮询）       │
│    · JSON 格式任务定义 + 签名认证              │
│    · 离线队列（无网时本地执行，有网时回传结果）   │
│    · 幂等性 + 超时控制                        │
│                                             │
│  🏕️ 荒野求生游戏化：                          │
│    · 7级等级体系（新手→AI生存之神）             │
│    · 完成任务获得XP，升级解锁新能力              │
│    · 成就系统（基础/求生/Plugin/隐藏彩蛋）       │
│    · 挑战难度矩阵（1-5星，匹配玩家等级）         │
│    · Plugin市场浏览+下载+安装                  │
│                                             │
│  ═══════ 核心价值 ═══════                    │
│  "你的AI智能体不只是工具，而是陪你成长的伙伴"     │
│  "离线也能玩，联网更强大"                       │
│                                             │
└─────────────────────────────────────────────┘
```

---

*Plugin + 荒野求生架构设计完毕。这将 TongYi-Lite 从一个聊天工具升级为一个有成长体系的端侧AI Agent平台。*
