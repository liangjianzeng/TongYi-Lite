// ============================================================
// Settings Screen — 设置页面（Tab 布局）
//
// Tab 1: 📦 模型管理 - 下载、缓存模型列表
// Tab 2: 🧠 推理引擎 - 模型加载、日志查看
// Tab 3: ℹ️ 关于 - 应用信息
// ============================================================
library;


import 'dart:io';
import '../plugins/panel/plugins_screen.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import '../tts/edge_tts_service.dart'
    show EdgeTtsService, TtsVoiceInfo, groupTtsVoices, kFallbackVoices;

import '../agent/dev/dev.dart'
    show
        DevNativeEnv,
        DevSessionController,
        DevStore,
        DevTask,
        DevTaskStatus,
        DevWorkspace,
        SshAuthType,
        SshConfig,
        SshEnvironmentService,
        SshKeyGen,
        SshStatus,
        SshTargetKind,
        TermuxIntentService,
        WorkspaceBackend,
        classifySshFailure,
        createWorkspaceOnActiveConnection,
        ensureRemoteProjectDir,
        listRemoteDirs,
        newDevTaskId,
        resolveSshSecrets,
        sshTargetKindOf,
        sshUsesPasswordAuth,
        taskBelongsToWorkspace;
import '../services/app_bridge.dart' show AppBridge;
import '../agent/adb/adb_client.dart';
import '../agent/adb/adb_targets.dart';
import '../agent/mcp/mcp_client.dart' show McpServerConfig;
import '../agent/metrics/turn_metrics.dart' show TurnMetricsStore;
import '../asr/asr_model_manager.dart' show AsrModelManager;
import '../asr/hold_to_talk.dart' show AsrModelGate;
import '../asr/default_hotwords.dart'
    show
        HotwordCategory,
        hotwordCategories,
        effectiveCategoryWords,
        diffCategoryWords,
        defaultCategoryWords;

import '../agent/skills/provider.dart'
    show
        loadUserSkills,
        writeUserSkill,
        deleteUserSkill,
        buildSkillMarkdown,
        sanitizeSkillDirName;
import '../agent/skills/skill.dart' show Skill, loadBuiltinSkills;
import '../agent/builtin_tools/memory_tool.dart'
    show readGlobalMemorySnapshot, deleteGlobalMemoryEntry, clearGlobalMemory;
import '../agent/web_search/web_search_provider.dart';
import '../models/model_info.dart';
import '../models/model_family.dart';
import '../models/model_catalog.dart';
import '../models/api_model.dart';
import '../agent/llm/thinking_effort.dart';
import '../providers/index.dart';
import '../providers/shared_providers.dart' show openAiServiceProvider;
import '../providers/settings_provider.dart';
import '../services/settings_service.dart';
import '../services/model_manager.dart';
import '../services/model_storage_service.dart'
    show ModelStorageService, modelStorageService;
import 'inference_log_screen.dart';

part 'settings/about.dart';
part 'settings/agent.dart';
part 'settings/api.dart';
part 'settings/capability.dart';
part 'settings/common.dart';
part 'settings/dev.dart';
part 'settings/inference_engine.dart';
part 'settings/model_management.dart';
part 'settings/skills.dart';
part 'settings/storage.dart';
part 'settings/voice.dart';
part 'settings/web_search.dart';


/// App-lifetime guard: the local .gguf scan runs **once per app launch**.
///
/// It used to live on `_SettingsScreenState`, but SettingsScreen is pushed as a
/// route, so every visit created a fresh State and re-triggered a full disk
/// scan — noisy and slow. Keeping the flag at library scope makes it survive
/// route disposal while still resetting on process restart.
bool _appLaunchScanDone = false;

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    // 6 个 Tab（模型管理/API 接入/推理引擎/智能体/开发者/关于）——
    // length 必须与 TabBar/TabBarView 数量一致。
    _tabController = TabController(length: 7, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        // 标题字号收敛（默认 20 偏大），标题栏整体压扁，给正文留更多空间。
        title: const Text('设置', style: TextStyle(fontSize: 18)),
        centerTitle: true,
        toolbarHeight: 46,
        bottom: TabBar(
          controller: _tabController,
          // 窄屏可横向滑动，避免「TAB 字未能露出」被裁切。
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          // 小图标 + 小字号，减少标题栏占用的纵向空间。
          indicatorWeight: 2,
          labelStyle:
              const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          unselectedLabelStyle: const TextStyle(fontSize: 12),
          tabs: const [
            Tab(icon: Icon(Icons.storage, size: 18), text: '模型管理'),
            Tab(icon: Icon(Icons.cloud, size: 18), text: 'API 接入'),
            Tab(icon: Icon(Icons.memory, size: 18), text: '推理引擎'),
            Tab(icon: Icon(Icons.smart_toy, size: 18), text: '智能体'),
            // 「能力」独立成 Tab（2026-10-24 用户定案）：插件与技能是**智能体的能力扩展面**，
            // 不该并进「开发者」（那是 Dev Agent/SSH 的地盘）。这里按梯队管三层：
            // 原生能力（默认开）→ 插件 → 技能。
            Tab(icon: Icon(Icons.bolt_outlined, size: 18), text: '能力'),
            Tab(icon: Icon(Icons.construction, size: 18), text: '开发者'),
            Tab(icon: Icon(Icons.info, size: 18), text: '关于'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          const ApiSettingsBody(),
          const InferenceEngineSettingsBody(),
          const AgentSettingsBody(),
          CapabilitySettingsBody(controller: _tabController),
          const DevSettingsBody(),
          const _buildAboutTab(),
        ],
      ),
    );
  }
}

// =========================================================================
// Tab 2: 推理引擎
// =========================================================================

