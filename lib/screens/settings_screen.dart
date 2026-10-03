// ============================================================
// Settings Screen — 设置页面（Tab 布局）
//
// Tab 1: 📦 模型管理 - 下载、缓存模型列表
// Tab 2: 🧠 推理引擎 - 模型加载、日志查看
// Tab 3: ℹ️ 关于 - 应用信息
// ============================================================

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import '../agent/dev/dev.dart'
    show
        DevSessionController,
        DevStore,
        DevWorkspace,
        SshAuthType,
        SshConfig,
        SshEnvironmentService,
        SshKeyGen,
        SshStatus,
        WorkspaceBackend,
        sanitizeWorkspaceDirName;
import '../services/app_bridge.dart' show AppBridge;
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
import '../models/model_catalog.dart';
import '../models/api_model.dart';
import '../models/agent_persona.dart';
import '../providers/index.dart';
import '../providers/shared_providers.dart' show openAiServiceProvider;
import '../providers/settings_provider.dart';
import '../services/settings_service.dart';
import '../services/model_manager.dart';
import '../services/model_storage_service.dart' show modelStorageService;
import 'inference_log_screen.dart';

/// App-lifetime guard: the local .gguf scan runs **once per app launch**.
///
/// It used to live on `_SettingsScreenState`, but SettingsScreen is pushed as a
/// route, so every visit created a fresh State and re-triggered a full disk
/// scan — noisy and slow. Keeping the flag at library scope makes it survive
/// route disposal while still resetting on process restart.
bool _appLaunchScanDone = false;

/// Termux sshd 探测结论（`_probeSshd`）。
enum _SshdProbe { listening, refused, timeout }

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  late final Future<List<ModelConfig>> _catalogFuture;

  /// 存储占用信息的重建 tick：任一模型下载完成后自增，迫使 _StorageInfoWidget
  /// 重新拉取磁盘占用（它用 FutureBuilder 只拉一次）。
  int _storageTick = 0;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 5, vsync: this);
    _catalogFuture = loadModelCatalog();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // APP 启动后首次进入「模型管理」做一次全盘扫描；之后进出 tab 只做
      // 轻量校验（对已知 id 做 File.exists，无目录遍历、无提示），
      // 既不打扰用户，又能正确显示「已缓存」。
      if (_appLaunchScanDone) {
        _refreshCacheStatus();
      } else {
        _appLaunchScanDone = true;
        _scanModels(silent: true);
      }
    });
  }

  /// 轻量缓存状态校验：只对目录内已知 id 的 .gguf 做存在性判断，
  /// 用于纠正「文件已在磁盘但界面仍显示未下载」以及「文件被外部删除但
  /// 界面仍显示已缓存」两种不一致。开销极小，可每次进入页面执行。
  Future<void> _refreshCacheStatus() async {
    try {
      final catalog = await _catalogFuture;
      if (!mounted) return;
      await ref
          .read(downloadNotifierProvider.notifier)
          .refreshCacheStatus(catalog);
    } catch (_) {}
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 全局监听下载状态：任一模型下载完成 → 立即整体重扫模型列表 + 刷新存储
    // 占用，而不是只更新刚完成的那个模型卡片（否则列表排序/存储统计会滞后）。
    ref.listen<Map<String, DownloadTask>>(downloadNotifierProvider,
        (prev, next) {
      bool anyCompleted = false;
      for (final e in next.entries) {
        if (e.value.state == DownloadState.completed &&
            prev?[e.key]?.state != DownloadState.completed) {
          anyCompleted = true;
          break;
        }
      }
      if (anyCompleted) {
        _storageTick++;
        _scanModels(silent: true);
      }
    });

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
            Tab(icon: Icon(Icons.construction, size: 18), text: '开发者'),
            Tab(icon: Icon(Icons.info, size: 18), text: '关于'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildModelManagementTab(),
          const _ApiTab(),
          const _InferenceEngineTab(),
          const _AgentTab(),
          const _DevTab(),
          const _buildAboutTab(),
        ],
      ),
    );
  }

  // =========================================================================
  // Tab 1: 模型管理
  // =========================================================================

  Widget _buildModelManagementTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ---- 扫描已有模型（置顶，首次进入自动扫描）----
          Center(
            child: ElevatedButton.icon(
              onPressed: () => _scanModels(),
              icon: const Icon(Icons.search, size: 18),
              label: const Text('扫描已有模型'),
              style: ElevatedButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              ),
            ),
          ),
          const SizedBox(height: 8),
          const Center(
            child: Text(
              'APP 启动后自动扫描一次，下载完成自动更新；需要时可手动重新扫描',
              style: TextStyle(fontSize: 11, color: Colors.grey),
              textAlign: TextAlign.center,
            ),
          ),

          const SizedBox(height: 10),

          // ---- 模型列表（已缓存优先排序）----
          _buildSectionHeader('📦 可用模型', context),
          const SizedBox(height: 8),

          Consumer(
            builder: (context, ref, _) {
              final tasks = ref.watch(downloadNotifierProvider);
              return FutureBuilder<List<ModelConfig>>(
                future: _catalogFuture,
                builder: (context, snapshot) {
                  if (!snapshot.hasData || snapshot.data!.isEmpty) {
                    return const Center(
                      child: Padding(
                        padding: EdgeInsets.all(32),
                        child: CircularProgressIndicator(),
                      ),
                    );
                  }
                  final catalog = snapshot.data!;
                  // 排序规则：已缓存最优先在前；未下载的按名称首字母排序（A→Z）。
                  final models = List<ModelConfig>.from(catalog)
                    ..sort((a, b) {
                      final ca = tasks[a.id]?.state == DownloadState.completed;
                      final cb = tasks[b.id]?.state == DownloadState.completed;
                      if (ca != cb) return ca ? -1 : 1;
                      return cleanModelName(a.name)
                          .toLowerCase()
                          .compareTo(cleanModelName(b.name).toLowerCase());
                    });
                  return Column(
                    children: models.map((m) => _buildModelCard(m)).toList(),
                  );
                },
              );
            },
          ),

          const SizedBox(height: 24),

          // ---- 存储信息 ----
          _buildSectionHeader('💾 存储空间', context),
          // 用 tick 作为 key，下载完成时强制重建以重新读取磁盘占用。
          _StorageInfoWidget(key: ValueKey(_storageTick)),
        ],
      ),
    );
  }

  Widget _buildModelCard(ModelConfig model) {
    return Consumer(
      builder: (context, ref, _) {
        // 监听模型生命周期状态：加载/卸载后会触发卡片重建，刷新"已加载/卸载"按钮。
        ref.watch(modelManagerProvider);
        // 全局 MTP 开关状态：决定是否在模型卡片上显示各模型 MTP 开关。
        final settings = ref.watch(settingsProvider);
        final task = ref.watch(downloadTaskProvider(model.id));
        final isCached = task?.state == DownloadState.completed;

        DownloadState displayState;
        if (task != null && task.state == DownloadState.downloading) {
          displayState = DownloadState.downloading;
        } else if (task != null && task.state == DownloadState.paused) {
          displayState = DownloadState.paused;
        } else if (task != null && task.state == DownloadState.failed) {
          displayState = DownloadState.failed;
        } else if (isCached) {
          displayState = DownloadState.completed;
        } else {
          displayState = DownloadState.idle;
        }

        // 已缓存模型用蓝色描边 + 浅蓝底色，让「已下载」一眼可辨（区别于未下载的灰边卡片）。
        return Card(
          margin: const EdgeInsets.only(bottom: 8),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: isCached
                ? BorderSide(color: Colors.blue.shade300, width: 1.5)
                : BorderSide(color: Colors.grey.shade300, width: 1),
          ),
          color: isCached ? Colors.blue.shade50.withValues(alpha: 0.4) : null,
          elevation: isCached ? 1.5 : 0,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Stack(
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(modelTypeIcon(model.type)),
                        const SizedBox(width: 8),
                        // 模型名按系统规则显示：去掉括号内的精度/量化说明，缩短长度。
                        Flexible(
                          child: Text(
                            cleanModelName(model.name),
                            style: const TextStyle(
                                fontSize: 14, fontWeight: FontWeight.w600),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        // 总下载体积（主 gguf + mmproj 投影器），紧挨模型名。
                        Text(
                          _formatSize(model.totalBytes),
                          style:
                              const TextStyle(fontSize: 12, color: Colors.grey),
                        ),
                        // 右侧预留空间，避免右上角固定的默认勾选/状态 chip 遮挡。
                        const SizedBox(width: 88),
                      ],
                    ),

                    const SizedBox(height: 8),
                    // 特性标记统一为小 chip，Wrap 自动换行防溢出。
                    // （MTP 加速收益为负，已从 UI 屏蔽；已缓存/推荐为特性标记）
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        // 视觉能力标签：支持视觉理解 →「视觉」，否则 →「文本」。
                        // 依据目录里 type==vision（含单文件 VL 与 text+mmproj 两文件形态）。
                        _buildModelTag(
                          icon: model.type == ModelType.vision ? '🖼️' : '💬',
                          label: model.type == ModelType.vision ? '视觉' : '文本',
                          color: model.type == ModelType.vision
                              ? Colors.purple
                              : Colors.blueGrey,
                          bg: model.type == ModelType.vision
                              ? Colors.purple.shade100
                              : Colors.blueGrey.shade100,
                        ),
                        // 已缓存标记：已下载一眼可辨。
                        if (isCached)
                          _buildModelTag(
                            icon: '✅',
                            label: '已缓存',
                            color: Colors.green,
                            bg: Colors.green.shade100,
                          ),
                        // 特性标签（推荐 / 速度快 等），按目录里 tags 渲染。
                        for (final tag in model.tags)
                          _buildModelTag(
                            icon: _tagStyle(tag).$1,
                            label: tag,
                            color: _tagStyle(tag).$2,
                            bg: _tagStyle(tag).$3,
                          ),
                      ],
                    ),

                    // MTP 开关：仅当全局 MTP 开关开启且该模型支持 MTP 时显示，
                    // 用户可按模型逐个配置。端侧 MTP 默认不显示（收益为负）。
                    if (settings.enableMtpFeature && model.mtp) ...[
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            'MTP 加速',
                            style: TextStyle(fontSize: 13),
                          ),
                          Switch(
                            value: settings.mtpEnabled(model.id),
                            onChanged: (v) => ref
                                .read(settingsProvider.notifier)
                                .setEnableMtp(model.id, v),
                          ),
                        ],
                      ),
                    ],

                    // dspark 开关：仅当全局 dspark 开关开启且该模型声明了草稿头
                    // 时显示，用户可按模型逐个配置。
                    if (settings.enableDsparkFeature &&
                        model.dspark != null) ...[
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            'dspark 加速',
                            style: TextStyle(fontSize: 13),
                          ),
                          Switch(
                            value: settings.dsparkEnabled(model.id),
                            onChanged: (v) => ref
                                .read(settingsProvider.notifier)
                                .setEnableDspark(model.id, v),
                          ),
                        ],
                      ),
                    ],

                    // Progress bar for downloading models
                    if (task != null &&
                        task.state == DownloadState.downloading) ...[
                      const SizedBox(height: 8),
                      // 多文件模型（含 mmproj/dspark）显示当前下载阶段，
                      // 进度按总字节累计（阶段切换不再「重头」）。
                      if (task.stage != null)
                        Text('正在下载 ${task.stage}',
                            style: const TextStyle(fontSize: 12)),
                      LinearProgressIndicator(
                          value: task.progress, minHeight: 6),
                      const SizedBox(height: 4),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                              '${task.downloadedDisplay} / ${task.totalDisplay}',
                              style: const TextStyle(fontSize: 12)),
                          Text(task.progressPercent,
                              style: const TextStyle(fontSize: 12)),
                        ],
                      ),
                    ],

                    // Error message
                    if (task?.errorMessage != null &&
                        task!.state == DownloadState.failed) ...[
                      const SizedBox(height: 8),
                      Text('错误: ${task.errorMessage}',
                          style: TextStyle(
                              color: Colors.red.shade600, fontSize: 12)),
                    ],

                    const SizedBox(height: 12),
                    _buildActionButtons(model, task, isCached),
                  ],
                ),
                // 右上角固定：已缓存显示「设为默认加载」勾选，否则显示状态 chip。
                Positioned(
                  top: 0,
                  right: 0,
                  child: isCached
                      ? _buildDefaultToggle(model)
                      : _buildStatusChip(displayState),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildActionButtons(
      ModelConfig model, DownloadTask? task, bool isCached) {
    final activeState = task?.state ?? DownloadState.idle;
    final manager = ref.read(modelManagerProvider.notifier);
    final ms = ref.watch(modelManagerProvider);

    switch (activeState) {
      case DownloadState.downloading:
        // 下载中：暂停 + 删除（删除会取消当前下载并移除已下载的半成品文件，
        // 必须先弹确认框避免误删；确认后真正取消/清理）。
        return Row(
          children: [
            OutlinedButton.icon(
              onPressed: () => ref
                  .read(downloadNotifierProvider.notifier)
                  .pauseDownload(model.id),
              icon: const Icon(Icons.pause, size: 18),
              label: const Text('暂停'),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: () => _confirmDeleteDownloading(model, context),
              icon: const Icon(Icons.delete, size: 18),
              label: const Text('删除'),
              style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.red.shade700),
            ),
          ],
        );

      case DownloadState.paused:
        return OutlinedButton.icon(
          onPressed: () => _resumeDownloadAndRescan(model.id),
          icon: const Icon(Icons.play_arrow, size: 18),
          label: const Text('继续'),
        );

      case DownloadState.failed:
        return OutlinedButton.icon(
          onPressed: () => _startDownloadAndRescan(model),
          icon: const Icon(Icons.refresh, size: 18),
          label: const Text('重试'),
          style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
        );

      case DownloadState.completed:
      default:
        if (isCached) {
          // 只有「当前正在加载的那一个模型」才显示转圈，其余已缓存模型保持
          // 「加载到内存」按钮不变 —— 避免点一个模型、全部按钮一起转。
          final isLoadingHere = ms.isLoading && ms.modelId == model.id;
          final isLoadedHere = ms.modelId == model.id && ms.isLoaded;

          return Row(
            children: [
              // Load / Loading / Loaded button
              if (isLoadedHere) ...[
                ElevatedButton.icon(
                  onPressed: null,
                  icon: const Icon(Icons.check_circle, size: 18),
                  label: const Text('已加载'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green.shade50,
                    foregroundColor: Colors.green.shade700,
                  ),
                ),
              ] else if (isLoadingHere) ...[
                const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  onPressed: null,
                  icon: const SizedBox.shrink(),
                  label: const Text('加载中...'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue.shade50,
                    foregroundColor: Colors.blue.shade700,
                  ),
                ),
              ] else ...[
                ElevatedButton.icon(
                  onPressed:
                      manager.isBusy ? null : () => _handleLoadModel(model),
                  icon: const Icon(Icons.memory, size: 18),
                  label: const Text('加载到内存'),
                ),
              ],

              const SizedBox(width: 8),

              // Unload button
              if (isLoadedHere) ...[
                OutlinedButton.icon(
                  onPressed: manager.isBusy
                      ? null
                      : () => unloadModelAndNotify(ref, context, model.name),
                  icon: const Icon(Icons.close, size: 18),
                  label: const Text('卸载'),
                  style: OutlinedButton.styleFrom(
                      backgroundColor: Colors.red.shade700,
                      foregroundColor: Colors.white),
                ),
              ],

              // Delete button — 删除会移除已下载的模型文件（重新下载很费劲），
              // 必须先弹确认框，避免误删。确认后真正删除。
              OutlinedButton.icon(
                onPressed: () => _confirmDeleteModel(model, context),
                icon: const Icon(Icons.delete, size: 18),
                label: const Text('删除'),
                style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.red.shade700),
              ),
            ],
          );
        } else {
          return ElevatedButton.icon(
            onPressed: () => _startDownloadAndRescan(model),
            icon: const Icon(Icons.download, size: 18),
            // 视觉模型下载含 mmproj 投影器；若主 gguf 已完整则只补下投影器。
            label: Text(model.mmproj != null ? '下载(含投影器)' : '下载'),
          );
        }
    }
  }

  /// 删除已缓存模型前先弹确认框，避免误删（模型文件移除后需重新下载）。
  /// 确认后才真正调用 deleteModel。
  Future<void> _confirmDeleteModel(
      ModelConfig model, BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认删除模型？'),
        content: Text(
          '删除「${model.name}」会移除已下载的模型文件（${_formatSize(model.sizeBytes)}），'
          '之后需要重新下载才能再用。确定删除吗？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      ref.read(downloadNotifierProvider.notifier).deleteModel(model.id);
      // 若删除的是默认模型，同时清除默认设置，避免启动时指向已不存在的模型。
      if (ref.read(settingsProvider).defaultModelId == model.id) {
        await ref.read(settingsProvider.notifier).setDefaultModel(null);
      }
    }
  }

  /// 删除「下载中」的模型任务：先弹确认框（会丢失已下载的半成品，需重下），
  /// 确认后取消当前下载并清理主 gguf / mmproj 及其残留 .tmp 文件。
  Future<void> _confirmDeleteDownloading(
      ModelConfig model, BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除下载中的模型？'),
        content: Text(
          '删除「${model.name}」会取消当前下载，并移除已下载的半成品文件'
          '（${_formatSize(model.totalBytes)}，含 mmproj 投影器）。\n\n'
          '之后需要重新下载才能再用。确定删除吗？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      // cancelDownload 会取消进行中的传输并清理 gguf/mmproj 及其 .tmp。
      await ref
          .read(downloadNotifierProvider.notifier)
          .cancelDownload(model.id);
    }
  }

  /// 「设为默认加载」勾选框（仅已缓存模型显示在卡片右上角）。
  ///
  /// 勾选后该模型成为默认模型并持久化，启动进入首页时自动加载；
  /// 单选——勾选一个会自动取消其他（defaultModelId 为单一 id）。取消勾选即
  /// 清除默认设置（传 null）。
  Widget _buildDefaultToggle(ModelConfig model) {
    return Consumer(
      builder: (context, ref, _) {
        final settings = ref.watch(settingsProvider);
        final isDefault = settings.defaultModelId == model.id;
        final primary = Theme.of(context).colorScheme.primary;
        return InkWell(
          borderRadius: BorderRadius.circular(4),
          onTap: () {
            ref
                .read(settingsProvider.notifier)
                .setDefaultModel(isDefault ? null : model.id);
          },
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Checkbox(
                value: isDefault,
                onChanged: (v) {
                  ref
                      .read(settingsProvider.notifier)
                      .setDefaultModel(v == true ? model.id : null);
                },
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
                activeColor: Colors.green,
              ),
              Text(
                '默认',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: isDefault ? FontWeight.w600 : FontWeight.normal,
                  color: isDefault ? primary : Colors.grey,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 模型状态 chip —— AppBar 右侧紧凑指示。
  Widget _buildStatusChip(DownloadState state) {
    Color color;
    String label;
    switch (state) {
      case DownloadState.idle:
        color = Colors.grey;
        label = '待下载';
        break;
      case DownloadState.downloading:
        color = Colors.blue;
        label = '下载中';
        break;
      case DownloadState.paused:
        color = Colors.orange;
        label = '已暂停';
        break;
      case DownloadState.completed:
        color = Colors.green;
        label = '✅';
        break;
      case DownloadState.failed:
        color = Colors.red;
        label = '失败';
        break;
      case DownloadState.verifying:
        color = Colors.purple;
        label = '校验中';
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(label, style: TextStyle(color: color, fontSize: 12)),
    );
  }

  String _formatSize(int bytes) {
    final mb = bytes / (1024 * 1024);
    if (mb >= 1024) return '${(mb / 1024).toStringAsFixed(1)} GB';
    return '${mb.toStringAsFixed(0)} MB';
  }

  /// 统一的特性标记小 chip：图标 + 文字，胶囊圆角，语义配色。
  /// 用于「投影器 / 推荐 / MTP」等模型特性标记，保证视觉风格一致。
  Widget _buildModelTag({
    required String icon,
    required String label,
    required Color color,
    required Color bg,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        '$icon $label',
        style: TextStyle(fontSize: 12, color: color),
      ),
    );
  }

  /// 特性标签 → (icon, color, bg) 语义配色。未知标签给默认中性灰，防溢出/未知 tag 崩。
  (String, Color, Color) _tagStyle(String tag) {
    switch (tag) {
      case '推荐':
        return ('⭐', Colors.blue, Colors.blue.shade100);
      case '速度快':
        return ('⚡', Colors.orange, Colors.orange.shade100);
      // 不推荐：警示红，提示「体积大/门槛高，普通机型不推荐」。
      case '不推荐':
        return ('⚠️', Colors.red, Colors.red.shade100);
      // 限高端旗舰：金色，提示「需要旗舰级硬件（内存/算力）才带得动」。
      case '限高端旗舰':
        return ('👑', Colors.amber.shade800, Colors.amber.shade100);
      default:
        return ('🏷️', Colors.blueGrey, Colors.blueGrey.shade100);
    }
  }

  /// 启动下载。下载完成的「全局重扫 + 存储刷新」由 build 里的
  /// downloadNotifierProvider 监听统一处理（任何入口完成都会触发），
  /// 这里不再重复扫描。
  Future<void> _startDownloadAndRescan(ModelConfig model) async {
    await ref.read(downloadNotifierProvider.notifier).startDownload(model);
  }

  /// 断点续传。同上，完成后的全局重扫由监听统一处理。
  Future<void> _resumeDownloadAndRescan(String modelId) async {
    await ref.read(downloadNotifierProvider.notifier).resumeDownload(modelId);
  }

  Future<void> _scanModels({bool silent = false}) async {
    final manager = ModelManager();
    final cachedIds = await manager.scanExistingModels();

    if (!mounted) return;

    if (cachedIds.isEmpty) {
      if (!silent) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('未找到已下载的模型文件'), backgroundColor: Colors.orange),
        );
      }
      return;
    }

    final allModels = await loadModelCatalog();
    final foundModels =
        allModels.where((m) => cachedIds.contains(m.id)).toList();

    if (foundModels.isNotEmpty) {
      await ref
          .read(downloadNotifierProvider.notifier)
          .initCachedModels(foundModels);

      // 静默扫描（启动首次 / 下载完成）不弹 SnackBar，避免打扰。
      if (!silent && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('已恢复 ${foundModels.length} 个模型状态'),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } else if (!silent) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('找到文件但未匹配到已知模型，请检查模型ID'),
            backgroundColor: Colors.orange),
      );
    }
  }

  Future<void> _handleLoadModel(ModelConfig model) async {
    final manager = ref.read(modelManagerProvider.notifier);
    // 模型重载影响本地引擎：任何会话（含后台并发回合）在跑都算。
    final isGenerating = ref.read(runningTurnsProvider).isNotEmpty;

    // 1) 已有一个不同模型在内存中（可能正在推理）→ 友好提醒，确认后再切换。
    if (manager.isLoadedState && manager.modelId != model.id) {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.info_outline, color: Colors.orange),
              SizedBox(width: 8),
              Text('已有模型正在运行'),
            ],
          ),
          content: Text(
            '当前「${manager.currentModelName}」已在内存中'
            '${isGenerating ? '（正在推理）' : ''}。\n\n'
            '切换到「${model.name}」会先卸载当前模型，再加载新模型。确定继续吗？',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('切换模型'),
            ),
          ],
        ),
      );
      if (confirm != true) return;
    }

    // 2) 若正在推理，必须先停止全部回合，否则卸载模型会令原生引擎崩溃（红屏）。
    if (ref.read(runningTurnsProvider).isNotEmpty) {
      try {
        await ref.read(chatNotifierProvider.notifier).stopGeneration();
      } catch (_) {
        // 忽略停止异常，继续尝试卸载/加载。
      }
      // 给原生层一点时间完成停止流程。
      await Future.delayed(const Duration(milliseconds: 300));
    }

    if (!mounted) return;

    // 3) 弹出「加载中」对话框，实时展示进度（大模型耗时较长，避免用户不知所措）。
    final loadFuture = manager.loadModel(model.id);
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ModelLoadProgressDialog(modelName: model.name),
    );

    final ok = await loadFuture;

    // 加载结束，关闭进度弹窗。
    if (mounted && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
    if (!mounted) return;

    // 4) 走原有完成提示路径：成功 / 失败 SnackBar。
    if (ok) {
      ref.read(currentModelIdProvider.notifier).state = model.id;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text('✅ ${model.name} 已加载到内存'),
            backgroundColor: Colors.green),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('❌ 模型加载失败，请查看"推理引擎"标签页的日志'),
            backgroundColor: Colors.red),
      );
    }
  }
}

// =========================================================================
// Tab 2: 推理引擎
// =========================================================================

class _InferenceEngineTab extends ConsumerWidget {
  const _InferenceEngineTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final modelState = ref.watch(modelManagerProvider);
    final gpuSettings = ref.watch(settingsProvider);
    final gpuNotifier = ref.read(settingsProvider.notifier);
    // 设备 SoC 信息：天玑（MediaTek）芯片不支持 OpenCL，禁用该后端并提示。
    final deviceInfo = ref.watch(deviceInfoProvider).valueOrNull ?? const {};
    final isDimensity = _isDimensitySoC(deviceInfo);
    // 天玑不支持 OpenCL：若此前选了 opencl 后端，自动切到 Vulkan。
    if (isDimensity && gpuSettings.gpuBackend == 'opencl') {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (gpuSettings.gpuBackend == 'opencl') {
          gpuNotifier.setGpuBackend('vulkan');
        }
      });
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ---- GPU 加速设置卡片 ----
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildToggleTitle(
                    '⚙️ GPU 加速',
                    gpuSettings.enableGpu,
                    gpuNotifier.setEnableGpu,
                  ),
                  const SizedBox(height: 10),
                  SegmentedButton<String>(
                    segments: [
                      const ButtonSegment(
                        value: 'auto',
                        label: Text('自动'),
                        icon: Icon(Icons.auto_awesome, size: 16),
                      ),
                      ButtonSegment(
                        value: 'opencl',
                        label: Text('OpenCL'),
                        icon: Icon(Icons.speed, size: 16),
                        enabled: !isDimensity,
                      ),
                      const ButtonSegment(
                        value: 'vulkan',
                        label: Text('Vulkan'),
                        icon: Icon(Icons.view_in_ar, size: 16),
                      ),
                    ],
                    selected: {gpuSettings.gpuBackend},
                    onSelectionChanged: gpuSettings.enableGpu
                        ? (sel) {
                            final v = sel.first;
                            if (v != gpuSettings.gpuBackend) {
                              gpuNotifier.setGpuBackend(v);
                            }
                          }
                        : null,
                    showSelectedIcon: false,
                    style: ButtonStyle(
                      visualDensity: VisualDensity.compact,
                      textStyle: WidgetStatePropertyAll(
                        TextStyle(fontSize: 12, color: Colors.grey.shade800),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    isDimensity
                        ? '当前设备为天玑（MediaTek）芯片：不支持 OpenCL，GPU 加速请优先使用 Vulkan'
                        : (gpuSettings.enableGpu
                            ? _gpuBackendHint(gpuSettings.gpuBackend)
                            : 'GPU 已关闭（纯 CPU）'),
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: Slider(
                          value: gpuSettings.gpuLayers.toDouble(),
                          min: 0,
                          max: 100,
                          divisions: 100,
                          label: '${gpuSettings.gpuLayers}',
                          onChanged: _gpuLayersEditable(gpuSettings)
                              ? (v) => gpuNotifier.setGpuLayers(v.round())
                              : null,
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 56,
                        child: Text(
                          '${gpuSettings.gpuLayers} 层',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontWeight: FontWeight.w500,
                            color: Colors.grey.shade500,
                          ),
                        ),
                      ),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      _gpuLayersHint(gpuSettings),
                      style:
                          TextStyle(fontSize: 12, color: Colors.grey.shade600),
                    ),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 10),

          // ---- 思考模式设置卡片 ----
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildToggleTitle(
                    '🧠 思考模式',
                    gpuSettings.enableThinking,
                    (v) {
                      gpuNotifier.setEnableThinking(v);
                      // 立即同步到原生层，无需重新加载模型。
                      ref.read(inferenceServiceProvider).setEnableThinking(v);
                    },
                    subtitle: '先输出推理过程再给结论；直接作答更快（仅思考型模型生效）',
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 10),

          // ---- MTP 加速全局开关卡片 ----
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildToggleTitle(
                    '🚀 MTP 加速（端侧推测解码）',
                    gpuSettings.enableMtpFeature,
                    gpuNotifier.setEnableMtpFeature,
                    subtitle: '默认关闭；开启后在模型卡片配置各模型 MTP（仅高端机按需开启）',
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 10),

          // ---- dspark 加速全局开关卡片 ----
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildToggleTitle(
                    '⚡ dspark 加速（整块投机解码）',
                    gpuSettings.enableDsparkFeature,
                    gpuNotifier.setEnableDsparkFeature,
                    subtitle: '默认关闭；开启后在模型卡片配置各模型 dspark（Q1_0 低比特模型收益有限）',
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 10),

          // ---- 上下文大小设置卡片 ----
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildSectionHeader('🧩 上下文大小（Context Size）', context),
                  const SizedBox(height: 4),
                  const Text(
                    '模型可记忆的对话长度上限，越大占用内存越多',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: Slider(
                          value: gpuSettings.contextSize.toDouble(),
                          min: 1024,
                          max: 65536,
                          divisions: 63,
                          label: '${gpuSettings.contextSize}',
                          onChanged: (v) =>
                              gpuNotifier.setContextSize(v.round()),
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 78,
                        child: Text(
                          '${gpuSettings.contextSize} 字',
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontWeight: FontWeight.w500),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 10),

          // ---- 推理引擎扩展设置卡片（视觉投影器 / 资源监控）----
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildSectionHeader('🧠 推理引擎扩展', context),
                  const SizedBox(height: 12),
                  _buildToggleTitle(
                    '🖼️ 默认加载视觉投影器',
                    gpuSettings.autoLoadMmproj,
                    gpuNotifier.setAutoLoadMmproj,
                    subtitle: '针对有投影器（mmproj）的视觉模型；关闭后仅文本推理',
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 10),

          // ---- OOM 内存守卫设置卡片 ----
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildToggleTitle(
                    '🛡️ OOM 内存守卫',
                    gpuSettings.oomGuardEnabled,
                    gpuNotifier.setOomGuardEnabled,
                    subtitle: gpuSettings.oomGuardEnabled
                        ? '加载前预检内存余量，超出则拒绝加载，防止整机硬死机'
                        : '⚠️ 已关闭：超大模型可强行加载，内存不足时可能整机死机重启',
                  ),
                  // 余量滑条仅守卫开启时可调；关闭时置灰直观反映「不生效」。
                  Opacity(
                    opacity: gpuSettings.oomGuardEnabled ? 1.0 : 0.45,
                    child: IgnorePointer(
                      ignoring: !gpuSettings.oomGuardEnabled,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Divider(height: 24),
                          _buildHeadroomSlider(
                            label: '预检余量',
                            value: gpuSettings.oomPreHeadroomMb,
                            onChanged: gpuNotifier.setOomPreHeadroomMb,
                            hint: '加载前可用内存需超出模型体积至少该余量，否则拒绝加载；'
                                '调小更容易放过极限大模型，调大更保守',
                          ),
                          _buildHeadroomSlider(
                            label: '加载后余量',
                            value: gpuSettings.oomPostHeadroomMb,
                            onChanged: gpuNotifier.setOomPostHeadroomMb,
                            hint: '加载完成后 KV 缓存/图计算缓冲的内存预算 = '
                                '可用内存 − 该余量；调小给上下文更大空间，调大更保守',
                          ),
                        ],
                      ),
                    ),
                  ),
                  Text(
                    '默认 768 / 1536 MB（与原生层一致）。修改后下次加载模型生效',
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 10),

          // ---- 引擎状态卡片 ----
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildSectionHeader('🧠 推理引擎状态', context),
                  const SizedBox(height: 12),

                  // Status row
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('当前状态:',
                          style: TextStyle(
                              fontSize: 14, color: Colors.grey.shade700)),
                      _buildLifecycleChipFromState(modelState),
                    ],
                  ),

                  if (modelState.modelName != null &&
                      modelState.modelName!.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('当前模型:',
                            style: TextStyle(
                                fontSize: 14, color: Colors.grey.shade700)),
                        Text(modelState.modelName!,
                            style:
                                const TextStyle(fontWeight: FontWeight.w500)),
                      ],
                    ),
                  ],

                  if (modelState.errorMessage != null &&
                      modelState.errorMessage!.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('错误:',
                            style: TextStyle(fontSize: 14, color: Colors.red)),
                        Expanded(
                          child: Text(
                            modelState.errorMessage!,
                            style: const TextStyle(
                                fontSize: 12, color: Colors.red),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),

          const SizedBox(height: 10),

          // ---- 操作按钮 ----
          _buildSectionHeader('⚡ 快捷操作', context),
          const SizedBox(height: 8),

          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const InferenceLogScreen()),
                    );
                  },
                  icon: const Icon(Icons.terminal),
                  label: const Text('查看推理日志'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: modelState.isLoaded
                      ? () => unloadModelAndNotify(
                          ref, context, modelState.modelName ?? '当前模型')
                      : null,
                  icon: const Icon(Icons.close),
                  label: const Text('卸载模型'),
                  style: OutlinedButton.styleFrom(
                    backgroundColor: Colors.red.shade700,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                ),
              ),
            ],
          ),

          if (modelState.isError && modelState.modelId != null) ...[
            const SizedBox(height: 8),
            ElevatedButton.icon(
              onPressed: () async {
                await ref
                    .read(modelManagerProvider.notifier)
                    .loadModel(modelState.modelId!);
              },
              icon: const Icon(Icons.refresh),
              label: const Text('重试加载'),
            ),
          ],

          const SizedBox(height: 24),

          // ---- 最近日志摘要 ----
          Row(
            children: [
              Expanded(child: _buildSectionHeader('📋 最近日志', context)),
              IconButton(
                icon: const Icon(Icons.copy, size: 18),
                tooltip: '复制全部日志',
                onPressed: () => _copyInferenceLogs(context, ref),
              ),
            ],
          ),
          const SizedBox(height: 4),

          _RecentLogsWidget(),
        ],
      ),
    );
  }

  Widget _buildLifecycleChipFromState(ModelState modelState) {
    Color color;
    String label;
    switch (modelState.phase) {
      case ModelLifecyclePhase.idle:
        color = Colors.grey;
        label = '未加载';
        break;
      case ModelLifecyclePhase.loading:
        color = Colors.blue;
        label = '加载中...';
        break;
      case ModelLifecyclePhase.loaded:
        color = Colors.green;
        label = '已加载';
        break;
      case ModelLifecyclePhase.unloading:
        color = Colors.orange;
        label = '卸载中...';
        break;
      case ModelLifecyclePhase.error:
        color = Colors.red;
        label = '错误';
        break;
      default:
        color = Colors.grey;
        label = '未知';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(label, style: TextStyle(color: color, fontSize: 13)),
    );
  }

  // ---- GPU 后端辅助 ----

  /// OOM 余量滑条行：标签 + 当前值（MB）+ 滑条（0~4096，步进 64）+ 说明。
  Widget _buildHeadroomSlider({
    required String label,
    required int value,
    required ValueChanged<int> onChanged,
    required String hint,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                  child: Text(label, style: const TextStyle(fontSize: 12))),
              SizedBox(
                width: 88,
                child: Text(
                  '$value MB',
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w500),
                ),
              ),
            ],
          ),
          SizedBox(
            height: 34,
            child: Slider(
              value: value.clamp(0, 4096).toDouble(),
              min: 0,
              max: 4096,
              divisions: 64,
              label: '$value MB',
              onChanged: (v) => onChanged((v / 64).round() * 64),
            ),
          ),
          Text(hint,
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
        ],
      ),
    );
  }

  /// 判断是否为 MediaTek 天玑（Dimensity）SoC。
  /// 依据：Build.SOC_MANUFACTURER == "MediaTek"（API 31+），
  /// 或硬件/主板名含 MTK 平台代号（mtxxxx / MTxxxx）。
  static bool _isDimensitySoC(Map<String, String> info) {
    final socMfg = (info['socManufacturer'] ?? '').toLowerCase();
    if (socMfg.contains('mediatek')) return true;
    final hardware = (info['hardware'] ?? '').toLowerCase();
    final board = (info['board'] ?? '').toLowerCase();
    final socModel = (info['socModel'] ?? '').toLowerCase();
    if (hardware.startsWith('mt') || board.startsWith('mt')) return true;
    if (socModel.startsWith('mt')) return true;
    // 平台代号回退：常见天玑平台代号（部分机型 hardware 为 "mt6877" 等）
    if (RegExp(r'^mt\d{4,5}$').hasMatch(hardware)) return true;
    if (RegExp(r'^mt\d{4,5}$').hasMatch(board)) return true;
    return false;
  }

  String _gpuBackendHint(String backend) {
    switch (backend) {
      case 'opencl':
        return 'OpenCL：推荐后端';
      case 'vulkan':
        return 'Vulkan';
      case 'cpu':
        return 'CPU：纯 CPU 后端';
      default:
        return '自动：优先 OpenCL，无 GPU 时回落 CPU';
    }
  }

  /// 一键复制全部推理日志（最近日志摘要与日志页共用语义：全量拼接换行）。
  void _copyInferenceLogs(BuildContext context, WidgetRef ref) {
    final logs = ref.read(modelManagerProvider.notifier).loadingLogs;
    if (logs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('暂无日志可复制')),
      );
      return;
    }
    Clipboard.setData(ClipboardData(text: logs.join('\n')));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已复制 ${logs.length} 条日志')),
    );
  }

  bool _gpuLayersEditable(InferenceSettings s) {
    if (!s.enableGpu) return false;
    // CPU 无意义；其余后端（opencl/auto）允许调层数，Vulkan 暂不可调。
    return s.gpuBackend == 'opencl' || s.gpuBackend == 'auto';
  }

  String _gpuLayersHint(InferenceSettings s) {
    if (!s.enableGpu) return 'GPU 已关闭（纯 CPU）';
    if (_gpuLayersEditable(s)) {
      return '0 = 纯 CPU，越大卸载越多（全量 = 999）';
    }
    if (s.gpuBackend == 'vulkan') {
      return 'Vulkan 暂不可调层数';
    }
    return '当前后端固定，层数不可调';
  }
}

Widget _buildSectionHeader(String title, BuildContext context) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(
      title,
      style: Theme.of(context)
          .textTheme
          .titleSmall
          ?.copyWith(fontWeight: FontWeight.bold),
    ),
  );
}

/// 标题行内嵌开关：标题 + 右侧 Switch，可选副标题。用于节省卡片纵向空间。
/// 字号紧凑（14/11），开关用 shrinkWrap 减小触点占位。
Widget _buildToggleTitle(
  String title,
  bool value,
  ValueChanged<bool> onChanged, {
  String? subtitle,
}) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Text(
              title,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            height: 32,
            child: Switch(
              value: value,
              onChanged: onChanged,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ],
      ),
      if (subtitle != null) ...[
        const SizedBox(height: 2),
        Text(subtitle,
            style: const TextStyle(fontSize: 11, color: Colors.grey)),
      ],
    ],
  );
}

// =========================================================================
// Tab 4: 智能体（Agent）
// =========================================================================

/// 智能体设置 Tab（v0.2.1 全新引擎对齐）。
///
/// 设计原则：
/// 1. **能力驱动展示**：特性块查询驱动模型的能力快照，不支持则置灰说明；
/// 2. **只保留新引擎真实消费的旋钮**：每项设置都映射到引擎消费点；
/// 3. 旧键不动，新键安全默认，旧配置无损迁移。
class _AgentTab extends ConsumerStatefulWidget {
  const _AgentTab();

  @override
  ConsumerState<_AgentTab> createState() => _AgentTabState();
}

class _AgentTabState extends ConsumerState<_AgentTab> {
  /// 用户自定义 skills（null = 扫描中）。
  List<Skill>? _userSkills;

  /// 内置技能清单（常量，取一次避免每次 build 重建 17 个对象）。
  final List<Skill> _builtinSkills = loadBuiltinSkills();

  /// 技能列表展开态：技能会越来越多，默认收起成一行汇总，
  /// 展开后也只在限高滚动区里浏览——技能卡不再把设置页拉成 2 米长。
  bool _skillsExpanded = false;

  /// 全局记忆条目（null = 加载中；记忆管理卡用）。
  List<MapEntry<String, String>>? _memoryEntries;

  /// 全局 AGENTS.md 路径与字节数（-1 = 不存在）。
  String? _agentsMdPath;
  int _agentsMdLen = -1;

  /// 开发模式状态监听：SSH 连接/工作区激活是异步后台变化，
  /// 必须监听 ChangeNotifier 才能实时刷新（否则"测试连接成功但页面显示未连接"）。
  VoidCallback? _devStateListener;

  @override
  void initState() {
    super.initState();
    _rescanSkills();
    _loadAgentsMdInfo();
    _loadMemoryEntries();
    final listener = () {
      if (mounted) setState(() {});
    };
    _devStateListener = listener;
    SshEnvironmentService.instance.addListener(listener);
    DevSessionController.instance.addListener(listener);
  }

  @override
  void dispose() {
    final listener = _devStateListener;
    if (listener != null) {
      SshEnvironmentService.instance.removeListener(listener);
      DevSessionController.instance.removeListener(listener);
    }
    super.dispose();
  }

  Future<void> _rescanSkills() async {
    final skills = await loadUserSkills();
    if (!mounted) return;
    setState(() => _userSkills = skills);
  }

  // ================= 记忆管理（查看/删除，与 memory.json 同存储） =================

  Future<void> _loadMemoryEntries() async {
    final entries = await readGlobalMemorySnapshot(
        maxEntries: 100, maxValueChars: 200);
    if (!mounted) return;
    setState(() => _memoryEntries = entries);
  }

  Future<void> _confirmDeleteMemoryEntry(String key) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除记忆：$key'),
        content: const Text('删除后智能体将不再记得该条内容，无法恢复。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (ok != true) return;
    await deleteGlobalMemoryEntry(key);
    await _loadMemoryEntries();
  }

  Future<void> _confirmClearMemory() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空全部记忆'),
        content: const Text('将删除全部长期记忆条目，无法恢复。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('清空')),
        ],
      ),
    );
    if (ok != true) return;
    await clearGlobalMemory();
    await _loadMemoryEntries();
  }

  /// 记忆管理列表（嵌在长期记忆开关下方；随开关关闭置灰）。
  Widget _buildMemoryManager(bool enabled) {
    final entries = _memoryEntries;
    if (!enabled) {
      return const Padding(
        padding: EdgeInsets.only(left: 16, right: 16, bottom: 8),
        child: Text('已关闭；开启后自动注入每回合系统提示',
            style: TextStyle(fontSize: 12, color: Colors.grey)),
      );
    }
    if (entries == null) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: SizedBox(
            height: 20,
            width: 20,
            child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    if (entries.isEmpty) {
      return const Padding(
        padding: EdgeInsets.only(left: 16, right: 16, bottom: 8),
        child: Text('暂无记忆。对话里说"记住……"即可写入',
            style: TextStyle(fontSize: 12, color: Colors.grey)),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(left: 16, right: 16, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final e in entries)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text('${e.key}: ${e.value}',
                        style: const TextStyle(fontSize: 12)),
                  ),
                  InkWell(
                    onTap: () => _confirmDeleteMemoryEntry(e.key),
                    child: const Icon(Icons.close,
                        size: 16, color: Colors.grey),
                  ),
                ],
              ),
            ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: _confirmClearMemory,
              child: const Text('清空全部', style: TextStyle(fontSize: 12)),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _loadAgentsMdInfo() async {
    final base = await getApplicationSupportDirectory();
    final file = File(p.join(base.path, 'AGENTS.md'));
    if (!mounted) return;
    setState(() {
      _agentsMdPath = file.path;
      _agentsMdLen = file.existsSync() ? file.lengthSync() : -1;
    });
  }

  // ================= ①b 人格（Persona） =================

  Widget _buildPersonaCard(BuildContext context, InferenceSettings settings,
      SettingsNotifier notifier) {
    final activeId = settings.activePersonaId;
    final active = settings.activePersona();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSectionHeader('🎭 人格（Persona）', context),
            const Text(
              '为不同场景切换不同人格：标准人格保持默认行为；自定义人格的人设'
              '提示词会注入智能体系统提示词（语气/专长/行为边界）',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ChoiceChip(
                  label: const Text('标准'),
                  selected: activeId == kStandardPersonaId,
                  onSelected: (_) =>
                      notifier.setActivePersona(kStandardPersonaId),
                ),
                for (final persona in settings.agentPersonas)
                  ChoiceChip(
                    label: Text(persona.name),
                    selected: activeId == persona.id,
                    onSelected: (_) => notifier.setActivePersona(persona.id),
                  ),
              ],
            ),
            if (active != null && active.prompt.trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  active.prompt,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
              ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 4,
              children: [
                TextButton.icon(
                  onPressed: () => _showPersonaDialog(context, notifier),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('新增人格'),
                ),
                if (active != null) ...[
                  TextButton.icon(
                    onPressed: () =>
                        _showPersonaDialog(context, notifier, existing: active),
                    icon: const Icon(Icons.edit, size: 18),
                    label: const Text('编辑'),
                  ),
                  TextButton.icon(
                    onPressed: () =>
                        _confirmDeletePersona(context, notifier, active.id),
                    icon: const Icon(Icons.delete_outline, size: 18),
                    label: const Text('删除'),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 新增/编辑人格对话框。保存走 [SettingsNotifier.upsertPersona]（trim + 校验）。
  Future<void> _showPersonaDialog(
      BuildContext context, SettingsNotifier notifier,
      {AgentPersona? existing}) async {
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final promptCtrl = TextEditingController(text: existing?.prompt ?? '');
    final formKey = GlobalKey<FormState>();
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(existing == null ? '新增人格' : '编辑人格'),
        content: Form(
          key: formKey,
          child: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: nameCtrl,
                  autofocus: existing == null,
                  decoration: const InputDecoration(
                    labelText: '人格名称',
                    hintText: '如：写作助手 / 严谨学者 / 翻译官',
                    border: OutlineInputBorder(),
                  ),
                  validator: (v) =>
                      (v == null || v.trim().isEmpty) ? '请填写名称' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: promptCtrl,
                  minLines: 4,
                  maxLines: 8,
                  decoration: const InputDecoration(
                    labelText: '人设提示词',
                    hintText: '描述该人格的语气、专长与行为边界，例如：'
                        '你是一名资深中文编辑，回答精炼、语气克制，'
                        '擅长润色与改写，改写时保留原意……',
                    border: OutlineInputBorder(),
                    alignLabelWithHint: true,
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (formKey.currentState!.validate()) {
                Navigator.pop(ctx, true);
              }
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (saved != true) return;
    await notifier.upsertPersona(AgentPersona(
      id: existing?.id ?? const Uuid().v4(),
      name: nameCtrl.text,
      prompt: promptCtrl.text,
    ));
  }

  Future<void> _confirmDeletePersona(
      BuildContext context, SettingsNotifier notifier, String personaId) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除人格'),
        content: const Text('删除后无法恢复；若为当前激活人格，将回落到标准人格。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await notifier.deletePersona(personaId);
    }
  }

  // ================= ⑤ 用户技能管理（直接落盘 SKILL.md） =================

  /// 查看内置技能内容（只读），可「另存为我的技能」 customized 后覆盖内置。
  Future<void> _showBuiltinSkillView(Skill s) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('内置技能：${s.name}'),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('触发：${s.whenToUse}',
                    style: const TextStyle(fontSize: 12, color: Colors.grey)),
                const SizedBox(height: 10),
                SelectableText(s.body,
                    style: const TextStyle(fontSize: 13, height: 1.4)),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
          TextButton.icon(
            onPressed: () {
              Navigator.pop(ctx);
              _showUserSkillDialog(prefillText: buildSkillMarkdown(
                description: s.description,
                whenToUse: s.whenToUse,
                invocation: s.invocation,
                body: s.body,
              ));
            },
            icon: const Icon(Icons.save_as_outlined, size: 16),
            label: const Text('另存为我的技能'),
          ),
        ],
      ),
    );
  }

  /// 新增技能 = **整段粘贴一站式**：一个文本框贴完整 SKILL.md（meta 行 +
  /// `---` + 正文），技能名自动取 `name:` 行、缺省从描述派生——不再逐字段
  /// 手填。[prefillText] 用于"从内置技能另存"。编辑已有技能走字段表单。
  Future<void> _showUserSkillDialog({Skill? existing, String? prefillText}) async {
    if (existing != null) {
      return _showEditSkillDialog(existing);
    }
    final rawCtrl = TextEditingController(text: prefillText ?? '');
    final formKey = GlobalKey<FormState>();
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新增技能（整段粘贴）'),
        content: Form(
          key: formKey,
          child: SizedBox(
            width: 420,
            child: TextFormField(
              controller: rawCtrl,
              autofocus: true,
              minLines: 8,
              maxLines: 16,
              decoration: const InputDecoration(
                labelText: '粘贴完整技能文本',
                hintText: 'name: 可选（技能名，缺省从描述取）\n'
                    'description: 一句话描述\n'
                    'whenToUse: 何时触发\n'
                    '---\n'
                    '正文执行指引（步骤/格式/注意）',
                border: OutlineInputBorder(),
                alignLabelWithHint: true,
              ),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? '请粘贴技能文本' : null,
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
            onPressed: () {
              if (formKey.currentState!.validate()) {
                Navigator.pop(ctx, true);
              }
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (saved != true) return;
    final raw = rawCtrl.text;
    // 技能名：`name:` 行优先；缺省从描述派生（去尾标点取前 12 字再 sanitize）。
    final nameMatch =
        RegExp(r'^\s*name\s*:\s*(.+)$', multiLine: true).firstMatch(raw);
    String? name = nameMatch?.group(1)?.trim();
    final Skill parsed;
    try {
      parsed = Skill.parse(raw, name: name ?? '');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('解析失败（格式见输入框提示）：$e')));
      return;
    }
    if (parsed.description.trim().isEmpty || parsed.whenToUse.trim().isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('缺少 description / whenToUse 行——'
              '格式：meta 行在前，`---` 分隔正文')));
      return;
    }
    if (name == null || name.isEmpty) {
      final base = parsed.description.trim().replaceAll(
          RegExp(r'[。！？!?.、，,；;：:]'), '');
      final sanitized = sanitizeSkillDirName(base);
      name = (sanitized == null || sanitized.isEmpty)
          ? null
          : (sanitized.length > 12 ? sanitized.substring(0, 12) : sanitized);
    }
    if (name == null || name.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('无法确定技能名：请在文本首行加 `name: 技能名`')));
      return;
    }
    try {
      await writeUserSkill(
        name: name,
        description: parsed.description,
        whenToUse: parsed.whenToUse,
        invocation: parsed.invocation,
        body: parsed.body,
      );
    } on ArgumentError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('保存失败：${e.message}')));
      return;
    } on Exception catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('保存失败：$e')));
      return;
    }
    await _rescanSkills();
  }

  /// 编辑已有技能（字段表单；技能名锁定）。
  Future<void> _showEditSkillDialog(Skill existing) async {
    final descCtrl = TextEditingController(text: existing.description);
    final whenCtrl = TextEditingController(text: existing.whenToUse);
    final bodyCtrl = TextEditingController(text: existing.body);
    final formKey = GlobalKey<FormState>();
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('编辑技能：${existing.name}'),
        content: Form(
          key: formKey,
          child: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    controller: descCtrl,
                    decoration: const InputDecoration(
                      labelText: '一句话描述',
                      border: OutlineInputBorder(),
                    ),
                    validator: (v) =>
                        (v == null || v.trim().isEmpty) ? '请填写描述' : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: whenCtrl,
                    decoration: const InputDecoration(
                      labelText: '何时触发（whenToUse）',
                      border: OutlineInputBorder(),
                    ),
                    validator: (v) =>
                        (v == null || v.trim().isEmpty) ? '请填写触发条件' : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: bodyCtrl,
                    minLines: 5,
                    maxLines: 12,
                    decoration: const InputDecoration(
                      labelText: '技能正文（执行指引）',
                      border: OutlineInputBorder(),
                      alignLabelWithHint: true,
                    ),
                    validator: (v) =>
                        (v == null || v.trim().isEmpty) ? '请填写正文' : null,
                  ),
                ],
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
            onPressed: () {
              if (formKey.currentState!.validate()) {
                Navigator.pop(ctx, true);
              }
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (saved != true) return;
    try {
      await writeUserSkill(
        name: existing.name,
        previousName: existing.name,
        description: descCtrl.text,
        whenToUse: whenCtrl.text,
        body: bodyCtrl.text,
      );
    } on ArgumentError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('保存失败：${e.message}')));
      return;
    } on Exception catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('保存失败：$e')));
      return;
    }
    await _rescanSkills();
  }

  Future<void> _confirmDeleteUserSkill(Skill skill) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除技能：${skill.name}'),
        content: const Text('将从技能目录删除该技能（含其目录下的全部文件），'
            '删除后无法恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await deleteUserSkill(skill.name);
    await _rescanSkills();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);

    // ---- 能力快照（与 chat_provider._engineCapabilitiesFor 同源规则）----
    // api → 原生工具调用 + 并行 5；local/跟随默认 → Prompt-JSON + 并行 2。
    final isApi = settings.agentModelSource == 'api';
    final capsMaxParallel = isApi ? 5 : 2;
    // ---- 双场景档：API 档读写 agentApi* 专键，local 档读写原平铺键 ----
    final profMaxRounds =
        isApi ? settings.agentApiMaxRounds : settings.agentMaxRounds;
    final profTokensPerRound =
        isApi ? settings.agentApiTokensPerRound : settings.agentTokensPerRound;
    final profToolTimeoutMs =
        isApi ? settings.agentApiToolTimeoutMs : settings.agentToolTimeoutMs;
    final profTemperature =
        isApi ? settings.agentApiTemperature : settings.agentTemperature;
    final profAllowParallel = isApi
        ? settings.agentApiAllowParallelTools
        : settings.agentAllowParallelTools;
    final profMaxParallel =
        isApi ? settings.agentApiMaxParallel : settings.agentMaxParallel;
    final profTokensMax = isApi ? 32768 : 16384;
    final effectiveParallel = profAllowParallel ? profMaxParallel : 1;
    final parallelNote = isApi
        ? 'API 路线能力上限 5 路；实际并发 = min(设置值, 能力上限)'
        : '本地路线能力上限 2 路（prompt-JSON 协议）；实际并发 = min(设置值, 2)';

    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ============ ⓪ 智能体模式总开关（首排） ============
          // 关闭 = 普通聊天：不注入系统提示词/工具定义/AGENTS.md/Skills，
          // prefill 最小，本地小模型友好；打开才走工具循环。
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: _buildToggleTitle(
                '🤖 智能体模式',
                settings.agentEnabled,
                notifier.setAgentEnabled,
                subtitle: settings.agentEnabled
                    ? '开：走智能体循环（注入系统提示词 + 工具定义，可多步调用工具）'
                    : '关：简单聊天直连模型，不注入系统提示词/工具说明，'
                        'prefill 最小；下方所有智能体设置暂不生效',
              ),
            ),
          ),

          const SizedBox(height: 10),

          // ================= ⓪b 对话区文字大小（不受智能体开关门控）=================
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: _buildSliderRow(
                label: '对话文字大小',
                value: (settings.chatTextScale * 100).round(),
                min: 70,
                max: 130,
                divisions: 12,
                display: '${(settings.chatTextScale * 100).round()}%',
                onChanged: (v) => notifier.setChatTextScale(v / 100),
                hint: '对话区文字整体缩放（气泡/思考/工具卡/时间戳），'
                    '默认 100% = 当前字号，可放大缩小前后 30%',
              ),
            ),
          ),

          const SizedBox(height: 10),

          // 关闭总开关时置灰全部子项（不可交互，直观反映"暂不生效"）。
          Opacity(
            opacity: settings.agentEnabled ? 1.0 : 0.45,
            child: IgnorePointer(
              ignoring: !settings.agentEnabled,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ================= ① 引擎状态（能力总览）=================
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SizedBox(height: 8),
                          _buildSectionHeader('🤖 驱动模型', context),
                          const Text(
                            '指定智能体由哪个模型驱动；能力徽标随选择实时变化',
                            style: TextStyle(fontSize: 12, color: Colors.grey),
                          ),
                          const SizedBox(height: 8),
                          _buildAgentModelSelector(context, ref, settings),
                          const SizedBox(height: 10),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              _capChip(isApi ? '场景档：API 档' : '场景档：本地档',
                                  ok: true),
                              _capChip(isApi ? '协议：原生工具调用' : '协议：Prompt-JSON',
                                  ok: true),
                              _capChip('工具调用：支持', ok: true),
                              _capChip('并行上限：$capsMaxParallel 路',
                                  ok: capsMaxParallel > 1),
                              _capChip(
                                  isApi
                                      ? '上下文：由服务端决定'
                                      : '上下文：${settings.agentNctx} tok',
                                  ok: true),
                              _capChip('上下文压缩',
                                  ok: settings.agentCompactEnabled),
                              _capChip('输出溢写', ok: settings.agentSpillEnabled),
                              _capChip('子代理',
                                  ok: settings.agentSubagentEnabled),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 10),

                  // ================= ①b 人格（Persona） =================
                  _buildPersonaCard(context, settings, notifier),

                  const SizedBox(height: 10),

                  // ================= ② 核心执行参数 =================
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildSectionHeader('🔁 执行参数', context),
                          _buildSliderRow(
                            label: '单轮最大步数',
                            value: profMaxRounds,
                            min: 1,
                            max: 100,
                            divisions: 99,
                            display: '$profMaxRounds 步',
                            onChanged: (v) => isApi
                                ? notifier.setAgentApiMaxRounds(v)
                                : notifier.setAgentMaxRounds(v),
                            hint: '一次提问内最多几次模型请求（含工具往返）；'
                                '${isApi ? 'API 档默认 16' : '端侧建议 3–12（默认 12）'}，'
                                '复杂任务可调到 100',
                          ),
                          _buildSliderRow(
                            label: '并发会话槽位',
                            value: settings.agentMaxConcurrentTurns,
                            min: 1,
                            max: 4,
                            divisions: 3,
                            display: '${settings.agentMaxConcurrentTurns} 个',
                            onChanged: (v) =>
                                notifier.setAgentMaxConcurrentTurns(v),
                            hint: '同时允许执行回合的会话数量（默认 1）。'
                                'API 驱动可真正并行；本地模型受引擎限制，'
                                '同一时刻仍只能跑一个会话，其余会提示槽位已满',
                          ),
                          _buildSliderRow(
                            label: '每回合搜索上限',
                            value: settings.agentMaxSearchesPerTurn,
                            min: 1,
                            max: 10,
                            divisions: 9,
                            display: '${settings.agentMaxSearchesPerTurn} 次',
                            onChanged: (v) =>
                                notifier.setAgentMaxSearchesPerTurn(v),
                            hint: 'web_search 每回合最多调用次数（DSH max_uses 语义，默认 5）；'
                                '达到上限拒绝联网、强制基于已有结果回答，杜绝反复搜索',
                          ),
                          _buildSliderRow(
                            label: 'API 上下文压缩预算',
                            value: settings.agentApiContextBudget,
                            min: 4096,
                            max: 131072,
                            divisions: 31,
                            display:
                                '${settings.agentApiContextBudget ~/ 1024}k token',
                            onChanged: (v) =>
                                notifier.setAgentApiContextBudget(v),
                            hint: '投影历史超此值即自动压缩（默认 32k）；'
                                '配置了端点窗口时取较小值',
                          ),
                          _buildSliderRow(
                            label: '每步生成预算',
                            value: profTokensPerRound,
                            min: 128,
                            max: profTokensMax,
                            divisions: (profTokensMax - 128) ~/ 256,
                            display: profTokensPerRound >= 1024
                                ? '${(profTokensPerRound / 1024).toStringAsFixed(0)}k token'
                                : '$profTokensPerRound token',
                            onChanged: (v) => isApi
                                ? notifier.setAgentApiTokensPerRound(v)
                                : notifier.setAgentTokensPerRound(v),
                            hint: isApi
                                ? 'API 档每步生成 token 上限（默认 8192，云端模型吃满思考）'
                                : '本地档每步生成 token 上限（默认 1024）',
                          ),
                          _buildSliderRow(
                            label: '工具执行超时',
                            value: profToolTimeoutMs,
                            min: 1000,
                            max: 120000,
                            divisions: 119,
                            display: _formatTimeout(profToolTimeoutMs),
                            onChanged: (v) => isApi
                                ? notifier.setAgentApiToolTimeoutMs(v)
                                : notifier.setAgentToolTimeoutMs(v),
                            hint: '单工具超时，防止卡死循环；工具自声明超时优先'
                                '（${isApi ? 'API 档默认 30 秒' : '本地档默认 15 秒'}）',
                          ),
                          _buildDoubleSliderRow(
                            label: '生成温度',
                            value: profTemperature,
                            min: 0.0,
                            max: 2.0,
                            divisions: 20,
                            display: profTemperature.toStringAsFixed(1),
                            onChanged: (v) => isApi
                                ? notifier.setAgentApiTemperature(v)
                                : notifier.setAgentTemperature(v),
                            hint: '工具决策建议 0.3–0.7；创意直答可到 1.0+（默认 0.7）',
                          ),
                          _buildSliderRow(
                            label: '思考失控守卫阈值',
                            value: settings.agentThinkingMaxChars,
                            min: 1000,
                            max: 65536,
                            divisions: 129,
                            display: settings.agentThinkingMaxChars >= 1000
                                ? '${(settings.agentThinkingMaxChars / 1000).toStringAsFixed(1)}k 字'
                                : '${settings.agentThinkingMaxChars} 字',
                            onChanged: (v) =>
                                notifier.setAgentThinkingMaxChars(v),
                            hint: '思考块超长未闭合到该字数即主动止损（默认 6000）；'
                                '常提示"思考超长未闭合导致任务失败"时调大，'
                                '或在模型设置里关闭思考模式',
                          ),
                          Opacity(
                            opacity: isApi ? 0.4 : 1.0,
                            child: IgnorePointer(
                              ignoring: isApi,
                              child: _buildSliderRow(
                                label: '智能体上下文长度',
                                value: settings.agentNctx,
                                min: 1024,
                                max: 65536,
                                divisions: 63,
                                display: '${settings.agentNctx} token',
                                onChanged: (v) => notifier.setAgentNctx(v),
                                hint: isApi
                                    ? 'API 驱动的上下文长度由服务端决定，此设置仅本地引擎生效'
                                    : '本地引擎 n_ctx，独立于普通聊天；工具历史越多所需越大（默认 8192）。修改后需重载模型生效',
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 10),

                  // ================= ③ 上下文管理 =================
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildSectionHeader('🗜️ 上下文管理', context),
                          _buildToggleTitle(
                            '超限自动压缩',
                            settings.agentCompactEnabled,
                            notifier.setAgentCompactEnabled,
                            subtitle: '上下文超限时自动裁剪旧轮工具结果（追加摘要 + 影子遮蔽，'
                                '日志永不删原文）。关闭 = 超限直接报错终止',
                          ),
                          const Divider(height: 24),
                          _buildToggleTitle(
                            '超长工具输出溢写',
                            settings.agentSpillEnabled,
                            notifier.setAgentSpillEnabled,
                            subtitle: '单条工具结果超过约 4k token 时落盘，模型侧只留摘要与文件定位，'
                                '可按需读回；省上下文显著',
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 10),

                  // ================= ④ 能力与并行 =================
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildSectionHeader('🧩 能力与并行', context),
                          _buildToggleTitle(
                            '🛠️ 并行工具调用',
                            profAllowParallel,
                            isApi
                                ? notifier.setAgentApiAllowParallelTools
                                : notifier.setAgentAllowParallelTools,
                            subtitle: '模型一次要多个工具时并发执行（$parallelNote）；'
                                '当前生效并发：$effectiveParallel',
                          ),
                          if (profAllowParallel && capsMaxParallel > 2)
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: _buildSliderRow(
                                label: '并发上限',
                                value: profMaxParallel
                                    .clamp(2, capsMaxParallel)
                                    .toInt(),
                                min: 2,
                                max: capsMaxParallel,
                                divisions: capsMaxParallel - 1,
                                display:
                                    '${profMaxParallel.clamp(2, capsMaxParallel)} 路',
                                onChanged: (v) => isApi
                                    ? notifier.setAgentApiMaxParallel(v)
                                    : notifier.setAgentMaxParallel(v),
                                hint: '同时执行的工具数上限（按驱动模型能力封顶 $capsMaxParallel）',
                              ),
                            )
                          else if (settings.agentAllowParallelTools)
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                '本地路线并发固定 2 路（能力上限）；换 API 驱动可调更高',
                                style: TextStyle(
                                    fontSize: 12, color: Colors.grey.shade600),
                              ),
                            ),
                          const Divider(height: 24),
                          _buildToggleTitle(
                            '🤝 子代理（subagent）',
                            settings.agentSubagentEnabled,
                            notifier.setAgentSubagentEnabled,
                            subtitle: '模型可派生独立子代理执行大任务的子任务（spawn/fork）。'
                                '固定约束：嵌套 ≤ 2 层、子代理内不可申请沙箱升级、每层独立预算',
                          ),
                          // 子代理专用模型（P3-2）：重活/子任务可走更便宜的
                          // API 配置，主回答仍走主模型（仅 API 档生效）。
                          if (settings.agentSubagentEnabled &&
                              settings.apiModels.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(
                                  left: 4, right: 4, top: 8),
                              child: DropdownButtonFormField<String>(
                                value: settings.agentSubagentApiModelId,
                                isDense: true,
                                decoration: const InputDecoration(
                                  labelText: '子代理专用模型（API 档）',
                                  hintText: '跟随主模型',
                                  isDense: true,
                                  border: OutlineInputBorder(),
                                ),
                                items: [
                                  const DropdownMenuItem(
                                      value: '', child: Text('跟随主模型')),
                                  for (final cfg in settings.apiModels)
                                    DropdownMenuItem(
                                        value: cfg.id, child: Text(cfg.name)),
                                ],
                                onChanged: (v) => notifier
                                    .setAgentSubagentApiModelId(v ?? ''),
                              ),
                            ),
                          const Divider(height: 24),
                          _buildToggleTitle(
                            '🌐 联网搜索',
                            settings.webSearchEnabled,
                            notifier.setWebSearchEnabled,
                            subtitle:
                                '允许调用 web_search/get_weather（实例地址在「API 接入」页配置）',
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 10),

                  // ================= ⑤ Skills 与指令文件 =================
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildSectionHeader('📚 Skills 与指令文件', context),
                          // 汇总行：默认收起，点开展开限高滚动列表。
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            leading: const Icon(Icons.extension, size: 20),
                            title: Text(
                              '技能库（内置 ${_builtinSkills.length}'
                              ' · 我的 ${_userSkills?.length ?? '?'}）',
                              style: const TextStyle(fontSize: 14),
                            ),
                            subtitle: const Text(
                              '点开浏览/管理；整段粘贴 SKILL.md 即可新增',
                              style: TextStyle(fontSize: 12),
                            ),
                            trailing: Icon(
                              _skillsExpanded
                                  ? Icons.expand_less
                                  : Icons.expand_more,
                              size: 20,
                              color: Colors.grey,
                            ),
                            onTap: () =>
                                setState(() => _skillsExpanded = !_skillsExpanded),
                          ),
                          if (_skillsExpanded)
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxHeight: 320),
                              child: SingleChildScrollView(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    for (final s in _builtinSkills)
                                      ListTile(
                                        contentPadding: EdgeInsets.zero,
                                        dense: true,
                                        visualDensity: VisualDensity.compact,
                                        leading: const Icon(Icons.extension,
                                            size: 20),
                                        title: Text('内置 · ${s.name}',
                                            style: const TextStyle(fontSize: 14)),
                                        subtitle: Text(s.description,
                                            style: const TextStyle(fontSize: 12)),
                                        trailing: const Icon(Icons.chevron_right,
                                            size: 18, color: Colors.grey),
                                        onTap: () => _showBuiltinSkillView(s),
                                      ),
                                    const SizedBox(height: 6),
                                    if (_userSkills == null)
                                      const Text('正在扫描用户技能…',
                                          style: TextStyle(
                                              fontSize: 12, color: Colors.grey))
                                  else if (_userSkills!.isEmpty)
                                      const Text('暂无用户技能',
                                          style: TextStyle(
                                              fontSize: 12, color: Colors.grey))
                                    else
                                      for (final s in _userSkills!)
                                        ListTile(
                                          contentPadding: EdgeInsets.zero,
                                          dense: true,
                                          visualDensity: VisualDensity.compact,
                                          leading: const Icon(
                                              Icons.extension_outlined,
                                              size: 20),
                                          title: Text('用户 · ${s.name}',
                                              style:
                                                  const TextStyle(fontSize: 14)),
                                          subtitle: Text(s.description,
                                              style:
                                                  const TextStyle(fontSize: 12)),
                                          trailing: IconButton(
                                            icon: const Icon(Icons.delete_outline,
                                                size: 18),
                                            tooltip: '删除技能',
                                            onPressed: () =>
                                                _confirmDeleteUserSkill(s),
                                          ),
                                          onTap: () => _showUserSkillDialog(
                                              existing: s),
                                        ),
                                  ],
                                ),
                              ),
                            ),
                          Row(
                            children: [
                              TextButton.icon(
                                onPressed: _rescanSkills,
                                icon: const Icon(Icons.refresh, size: 16),
                                label: const Text('重新扫描'),
                              ),
                              const SizedBox(width: 4),
                              TextButton.icon(
                                onPressed: () => _showUserSkillDialog(),
                                icon: const Icon(Icons.add, size: 16),
                                label: const Text('新增技能'),
                              ),
                            ],
                          ),
                          Text(
                            '整段粘贴 SKILL.md 即可新增；同名覆盖内置。',
                            style: TextStyle(
                                fontSize: 11, color: Colors.grey.shade500),
                          ),
                          const Divider(height: 20),
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            leading: const Icon(Icons.description_outlined),
                            title: Text(
                              _agentsMdLen < 0
                                  ? 'AGENTS.md 指令文件（未创建）'
                                  : 'AGENTS.md 指令文件（${_agentsMdLen} 字节）',
                              style: const TextStyle(fontSize: 14),
                            ),
                            subtitle: const Text('注入系统提示的全局指令（角色、偏好、约束），点按编辑',
                                style: TextStyle(fontSize: 12)),
                            trailing: const Icon(Icons.edit_outlined, size: 18),
                            onTap: _editAgentsMd,
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 10),

                  // ================= ⑥ 工具 =================
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildSectionHeader('🧰 工具', context),
                          Text(
                            '核心工具恒可用：时间 / 计算 / 待办 / 便签 / 单位换算 / 文件读写检索。'
                            '以下高级工具按需开启：',
                            style: TextStyle(
                                fontSize: 12, color: Colors.grey.shade600),
                          ),
                          const SizedBox(height: 4),
                          SwitchListTile(
                            title: const Text('🖥️ Shell 执行（shell_exec）',
                                style: TextStyle(fontSize: 14)),
                            subtitle: const Text(
                                '设备 shell 命令执行（app 权限内），逐次弹窗审批',
                                style: TextStyle(fontSize: 12)),
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            value: settings.agentShellEnabled,
                            onChanged: notifier.setAgentShellEnabled,
                          ),
                          SwitchListTile(
                            title: const Text('🐍 Python 执行（python_exec）',
                                style: TextStyle(fontSize: 14)),
                            subtitle: const Text(
                                '嵌入式 CPython 跑脚本（计算/数据处理/文件/网络）',
                                style: TextStyle(fontSize: 12)),
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            value: settings.agentPythonEnabled,
                            onChanged: notifier.setAgentPythonEnabled,
                          ),
                          SwitchListTile(
                            title: const Text(
                                '🧠 长期记忆（memory_set / memory_get）',
                                style: TextStyle(fontSize: 14)),
                            subtitle: const Text(
                                '跨会话持久记忆（默认开）：模型可记住偏好/事实，'
                                '并自动注入每回合系统提示',
                                style: TextStyle(fontSize: 12)),
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            value: settings.agentMemoryEnabled,
                            onChanged: (v) {
                              notifier.setAgentMemoryEnabled(v);
                              _loadMemoryEntries();
                            },
                          ),
                          _buildMemoryManager(settings.agentMemoryEnabled),
                          SwitchListTile(
                            title: const Text('📂 完整文件访问授权',
                                style: TextStyle(fontSize: 14)),
                            subtitle: const Text(
                                '允许经逐次批准访问公共目录/完整文件系统'
                                '（All-Files-Access，默认关）',
                                style: TextStyle(fontSize: 12)),
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            value: settings.agentFullFileAccess,
                            onChanged: notifier.setAgentFullFileAccess,
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 10),

                  // ================= ⑦ 高级 / 开发者 =================
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildSectionHeader('🧪 高级 / 开发者', context),
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            leading: const Icon(Icons.folder_outlined),
                            title: const Text('智能体数据目录',
                                style: TextStyle(fontSize: 14)),
                            subtitle: const Text(
                                '会话事件日志(JSONL) / 溢写文件 / 技能 / AGENTS.md',
                                style: TextStyle(fontSize: 12)),
                            trailing: const Icon(Icons.chevron_right, size: 18),
                            onTap: _showDataDirs,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '扩展接缝（代码级）：agent/pre-step 可否决单步；tools/result 只读审计；'
                            '流水线 pre/post-execute 可拦截改写。',
                            style: TextStyle(
                                fontSize: 11, color: Colors.grey.shade500),
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------- 小部件 ----------------

  /// 能力徽标：绿=支持/开，灰=关或不可用。
  Widget _capChip(String label, {required bool ok}) {
    final color = ok ? Colors.teal : Colors.grey;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 11, color: color),
      ),
    );
  }

  /// 浮点滑块行（温度）。紧凑排版同 [_buildSliderRow]。
  Widget _buildDoubleSliderRow({
    required String label,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String display,
    required ValueChanged<double> onChanged,
    String? hint,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                  child: Text(label, style: const TextStyle(fontSize: 12))),
              Text(display,
                  style: const TextStyle(
                      fontWeight: FontWeight.w500, fontSize: 12)),
            ],
          ),
          SizedBox(
            height: 34,
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              divisions: divisions,
              label: display,
              onChanged: onChanged,
            ),
          ),
          if (hint != null)
            Text(hint,
                style: const TextStyle(fontSize: 11, color: Colors.grey)),
        ],
      ),
    );
  }

  // ---------------- 对话框 ----------------

  /// AGENTS.md 编辑对话框（全局文件）。
  Future<void> _editAgentsMd() async {
    final base = await getApplicationSupportDirectory();
    final file = File(p.join(base.path, 'AGENTS.md'));
    final initial = file.existsSync() ? file.readAsStringSync() : '';
    if (!mounted) return;
    final controller = TextEditingController(text: initial);
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('AGENTS.md 指令文件'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '作为低权威 workspace guidance 注入系统提示。\n${file.path}',
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: controller,
              maxLines: 12,
              minLines: 6,
              autofocus: true,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: '例如：回答一律用中文；先列计划再执行…',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('保存')),
        ],
      ),
    );
    if (saved != true) return;
    try {
      if (controller.text.trim().isEmpty) {
        if (file.existsSync()) file.deleteSync();
      } else {
        file.writeAsStringSync(controller.text);
      }
    } catch (_) {/* 只读分区等情况：忽略，状态刷新会如实反映 */}
    _loadAgentsMdInfo();
  }

  /// 智能体数据目录对话框（可复制路径）。
  Future<void> _showDataDirs() async {
    final base = await getApplicationSupportDirectory();
    if (!mounted) return;
    final dirs = <String, String>{
      '会话事件日志': p.join(base.path, 'sessions'),
      '工具输出溢写': p.join(base.path, 'agent_spill'),
      '用户技能': p.join(base.path, 'skills'),
      'AGENTS.md': _agentsMdPath ?? p.join(base.path, 'AGENTS.md'),
    };
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('智能体数据目录'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final e in dirs.entries)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(e.key,
                        style: const TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w600)),
                    subtitle: Text(e.value,
                        style: const TextStyle(fontSize: 11),
                        overflow: TextOverflow.ellipsis),
                    trailing: IconButton(
                      icon: const Icon(Icons.copy, size: 16),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: e.value));
                        ScaffoldMessenger.of(dialogContext).showSnackBar(
                          SnackBar(content: Text('已复制 ${e.key} 路径')),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('关闭')),
        ],
      ),
    );
  }

  /// 驱动模型选择器：显示当前选择，点击弹出选择对话框。
  /// API 模型显示**配置名**（无名称回退模型名）而非内部 id——此前直接显示
  /// agentModelId（ApiModelConfig 的 uuid），用户看到的是一串 key。
  Widget _buildAgentModelSelector(
      BuildContext context, WidgetRef ref, InferenceSettings settings) {
    final String currentLabel;
    if (settings.agentModelSource == null) {
      currentLabel = '跟随默认（本地优先，API 兜底）';
    } else if (settings.agentModelSource == 'local') {
      currentLabel = '本地：${settings.agentModelId}';
    } else {
      String displayName = settings.agentModelId ?? '';
      for (final cfg in settings.apiModels) {
        if (cfg.id == settings.agentModelId) {
          displayName = cfg.name.isEmpty ? cfg.model : cfg.name;
          break;
        }
      }
      currentLabel = 'API：$displayName';
    }

    return InkWell(
      onTap: () => _pickAgentModel(context, ref, settings),
      borderRadius: BorderRadius.circular(8),
      child: InputDecorator(
        decoration: const InputDecoration(
          border: OutlineInputBorder(),
          suffixIcon: Icon(Icons.arrow_drop_down),
        ),
        child: Text(currentLabel, style: const TextStyle(fontSize: 13)),
      ),
    );
  }

  /// 弹出「选择智能体驱动模型」对话框：跟随默认 / 本地模型 / API 模型。
  Future<void> _pickAgentModel(
      BuildContext context, WidgetRef ref, InferenceSettings settings) async {
    final catalog = await loadModelCatalog();
    if (!context.mounted) return;
    final notifier = ref.read(settingsProvider.notifier);
    final apiModels = settings.apiModels;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('选择智能体驱动模型'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(
            shrinkWrap: true,
            children: [
              ListTile(
                leading: const Icon(Icons.auto_awesome),
                title: const Text('跟随默认'),
                subtitle: const Text('本地优先，API 兜底'),
                selected: settings.agentModelSource == null,
                onTap: () {
                  Navigator.pop(dialogContext);
                  notifier.setAgentModel(null, null);
                },
              ),
              const Divider(height: 24),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 4),
                child:
                    Text('本地模型', style: TextStyle(fontWeight: FontWeight.w600)),
              ),
              for (final m in catalog)
                ListTile(
                  leading: const Icon(Icons.storage),
                  title: Text(cleanModelName(m.name),
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle:
                      Text(m.id, maxLines: 1, overflow: TextOverflow.ellipsis),
                  selected: settings.agentModelSource == 'local' &&
                      settings.agentModelId == m.id,
                  onTap: () {
                    Navigator.pop(dialogContext);
                    notifier.setAgentModel('local', m.id);
                  },
                ),
              if (apiModels.isNotEmpty) ...[
                const Divider(height: 24),
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 4),
                  child: Text('API 接入模型',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                ),
                for (final cfg in apiModels)
                  ListTile(
                    leading: const Icon(Icons.cloud),
                    title: Text(cfg.name.isEmpty ? cfg.model : cfg.name,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(cfg.id,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    selected: settings.agentModelSource == 'api' &&
                        settings.agentModelId == cfg.id,
                    onTap: () {
                      Navigator.pop(dialogContext);
                      notifier.setAgentModel('api', cfg.id);
                    },
                  ),
              ] else
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Text('暂无 API 模型，请先在「API 接入」配置',
                      style: TextStyle(color: Colors.grey)),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消')),
        ],
      ),
    );
  }
}

/// 通用「标签 + 滑块 + 当前值 + 提示」行，用于设置页数值型配置。
/// 紧凑排版：文字 12/11，滑块区压到 34px 高，整体比默认省 ~40% 纵向空间。
Widget _buildSliderRow({
  required String label,
  required int value,
  required int min,
  required int max,
  required int divisions,
  required String display,
  required ValueChanged<int> onChanged,
  String? hint,
}) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(label, style: const TextStyle(fontSize: 12)),
            ),
            Text(display,
                style:
                    const TextStyle(fontWeight: FontWeight.w500, fontSize: 12)),
          ],
        ),
        SizedBox(
          height: 34,
          child: Slider(
            value: value.toDouble(),
            min: min.toDouble(),
            max: max.toDouble(),
            divisions: divisions,
            label: '$value',
            onChanged: (v) => onChanged(v.round()),
          ),
        ),
        if (hint != null)
          Text(hint, style: const TextStyle(fontSize: 11, color: Colors.grey)),
      ],
    ),
  );
}

/// 毫秒 → 可读时长（如 15000 → "15 秒"）。
String _formatTimeout(int ms) {
  if (ms < 1000) return '$ms 毫秒';
  if (ms % 1000 == 0) return '${ms ~/ 1000} 秒';
  return '${(ms / 1000).toStringAsFixed(1)} 秒';
}

// =========================================================================
// Tab 5: 关于
// =========================================================================

class _buildAboutTab extends StatelessWidget {
  const _buildAboutTab();

  @override
  Widget build(BuildContext context) {
    return const SingleChildScrollView(
      padding: EdgeInsets.all(12),
      child: Column(
        children: [
          _AboutCard(),
          SizedBox(height: 10),
          _LicenseCard(),
        ],
      ),
    );
  }
}

// About 页版本号：集中式常量，与 android/app/build.gradle.kts 的
// versionName（0.2.1）保持同步。离线沙箱无法下载 package_info_plus 的
// AGP 依赖，故不引插件动态读取，直接用此常量。
const _appVersion = '0.2.8';

/// GitHub 项目主页地址（README 介绍与使用说明）。
const _githubUrl = 'https://github.com/liangjianzeng/TongYi-Lite';

/// 通过系统外部浏览器打开 GitHub README 页面。
Future<void> _openGithub(BuildContext context) async {
  final uri = Uri.parse(_githubUrl);
  final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
  if (!launched && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('无法打开浏览器，请手动访问：$_githubUrl')),
    );
  }
}

class _AboutCard extends StatelessWidget {
  const _AboutCard();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            const Icon(Icons.auto_awesome, size: 64, color: Colors.indigo),
            const SizedBox(height: 10),
            const Text(
              'TongYi-Lite',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            const Text(
              '端侧离线 AI 智能体',
              style: TextStyle(color: Colors.grey, fontSize: 14),
            ),
            const SizedBox(height: 10),
            _AboutRow(label: '版本', value: _appVersion),
            _AboutRow(label: '推理引擎', value: 'llama.cpp b10173'),
            _AboutRow(label: '框架', value: 'Flutter 3.x'),
            _AboutRow(label: '平台', value: 'Android API 33+'),
            const SizedBox(height: 8),
            const Divider(),
            const SizedBox(height: 8),
            InkWell(
              onTap: () => _openGithub(context),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.open_in_new, size: 18, color: Colors.indigo),
                  SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      'GitHub 项目主页 · README 介绍与使用说明',
                      style: TextStyle(
                        color: Colors.indigo,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LicenseCard extends StatelessWidget {
  const _LicenseCard();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('开源许可', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const Text('MIT License'),
            const SizedBox(height: 8),
            const Text('Copyright (c) 2026 TongYi-Lite Contributors'),
            const SizedBox(height: 10),
            const Text(
              '本项目使用 llama.cpp 作为推理引擎，遵循其开源许可协议。',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }
}

class _AboutRow extends StatelessWidget {
  final String label;
  final String value;

  const _AboutRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(color: Colors.grey.shade700)),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }
}

// =========================================================================
// 存储信息组件
// =========================================================================

class _StorageInfoWidget extends ConsumerWidget {
  const _StorageInfoWidget({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FutureBuilder<Map<String, dynamic>>(
      future: _loadStorageInfo(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Center(
              child: Padding(
                  padding: EdgeInsets.all(12),
                  child: CircularProgressIndicator()));
        }

        final info = snapshot.data!;
        final cachedModels = info['cachedModels'] as List? ?? [];
        final totalBytes = info['totalBytes'] as int? ?? 0;

        return Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (cachedModels.isNotEmpty) ...[
                  Text('已缓存模型 (${_formatSize(totalBytes)}):',
                      style: const TextStyle(fontWeight: FontWeight.w500)),
                  const SizedBox(height: 8),
                  ...(cachedModels as List<Map<String, dynamic>>)
                      .map((m) => Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Row(
                              children: [
                                const Icon(Icons.check_circle,
                                    size: 16, color: Colors.green),
                                const SizedBox(width: 8),
                                Expanded(child: Text(m['name'] as String)),
                                Text(_formatSize(m['sizeBytes'] as int),
                                    style: TextStyle(
                                        fontSize: 12, color: Colors.grey)),
                              ],
                            ),
                          ))
                      .toList(),
                  const Divider(height: 24),
                ],
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('总占用:',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                    Text(_formatSize(totalBytes),
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  String _formatSize(int bytes) {
    if (bytes >= 1024 * 1024 * 1024)
      return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(1)} GB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(0)} MB';
  }

  Future<Map<String, dynamic>> _loadStorageInfo() async {
    final cachedModels = <Map<String, dynamic>>[];
    int totalBytes = 0;

    try {
      // 模型实际存储位置与 ModelStorageService 的候选目录一致：
      // 外部主目录（/storage/emulated/0/TongYiLite/models 等）+ 内部
      // app_flutter/models + app docs 回退。此前只扫 app docs → 恒 0MB。
      final dirs = <Directory>[];
      try {
        dirs.add(await modelStorageService.getModelsRootDir());
      } catch (_) {}
      dirs.add(
          Directory('/data/data/com.dgxspark.tongyilite/app_flutter/models'));
      try {
        final appDir = await getApplicationDocumentsDirectory();
        dirs.add(Directory(p.join(appDir.path, 'models')));
      } catch (_) {}

      final seenPaths = <String>{};
      for (final dir in dirs) {
        if (!seenPaths.add(dir.path)) continue;
        if (!await dir.exists()) continue;
        await for (final entity in dir.list(recursive: true)) {
          if (entity is! File) continue;
          final isGguf = entity.path.endsWith('.gguf');
          final isMmproj = entity.path.endsWith('.mmproj');
          if (!isGguf && !isMmproj) continue;
          final sizeBytes = await entity.length();
          totalBytes += sizeBytes;
          if (!isGguf) continue; // 投影器/草稿头只计入总量，不单列模型行
          final fileName = p.basenameWithoutExtension(entity.path);

          String displayName = fileName;
          try {
            final allModels = await loadModelCatalog();
            final match = allModels.where((m) => m.id == fileName).toList();
            if (match.isNotEmpty) displayName = match.first.name;
          } catch (_) {}

          cachedModels.add(
              {'name': displayName, 'id': fileName, 'sizeBytes': sizeBytes});
        }
      }
    } catch (e) {
      debugPrint('[Settings] Failed to scan storage: $e');
    }

    return {'cachedModels': cachedModels, 'totalBytes': totalBytes};
  }
}

// =========================================================================
// 最近日志组件（在推理引擎 Tab 显示）
// =========================================================================

class _RecentLogsWidget extends ConsumerWidget {
  const _RecentLogsWidget();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final manager = ref.watch(modelManagerProvider.notifier);
    final logs = manager.loadingLogs;

    if (logs.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
            color: Colors.grey.shade100,
            borderRadius: BorderRadius.circular(8)),
        child: const Center(
          child: Column(
            children: [
              Icon(Icons.help_outline, size: 48, color: Colors.grey),
              SizedBox(height: 8),
              Text('暂无日志', style: TextStyle(color: Colors.grey)),
              SizedBox(height: 4),
              Text('点击"加载到内存"后开始记录',
                  style: TextStyle(fontSize: 12, color: Colors.grey)),
            ],
          ),
        ),
      );
    }

    return Container(
      constraints: const BoxConstraints(maxHeight: 200),
      child: ListView.builder(
        shrinkWrap: true,
        itemCount: logs.length,
        itemBuilder: (context, index) {
          final log = logs[index];
          IconData icon;
          Color color;

          if (log.contains('✓') || log.contains('成功')) {
            icon = Icons.check_circle;
            color = Colors.green;
          } else if (log.contains('失败') ||
              log.contains('错误') ||
              log.contains('ERROR')) {
            icon = Icons.error;
            color = Colors.red;
          } else {
            icon = Icons.terminal;
            color = Colors.blueGrey;
          }

          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, size: 14, color: color),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    log,
                    style: TextStyle(
                        fontSize: 12,
                        color: color.withValues(alpha: 0.9),
                        fontFamily: 'monospace'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

// =========================================================================
// 自定义模型显示名称输入框（可选）
// =========================================================================

/// 自定义模型显示名称输入框（可选）。
/// 用 StatefulWidget 持有独立的 TextEditingController，
/// 使下载进度频繁重建时不会丢失输入焦点/光标。
/// 模型名内联编辑框（替换原独立「自定义名称」行）。
/// 直接显示在模型卡片标题位置：有自定义名则显示自定义名，否则显示模型配置名
/// 加载模型时的「加载中」对话框。
/// 监听 [modelManagerProvider]，实时展示原生层推送的最新加载日志，
/// 让用户清楚大模型（数 GB）加载的进展，避免误以为卡死。
class _ModelLoadProgressDialog extends ConsumerWidget {
  final String modelName;
  const _ModelLoadProgressDialog({required this.modelName});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ms = ref.watch(modelManagerProvider);
    final log = ms.latestLog;
    return PopScope(
      canPop: false,
      child: AlertDialog(
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 10),
              Text('正在加载模型…', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(modelName,
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
              const SizedBox(height: 12),
              if (log != null)
                Container(
                  width: double.infinity,
                  constraints: const BoxConstraints(maxHeight: 120),
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.blue.shade50,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SingleChildScrollView(
                    child: Text(
                      log,
                      style:
                          TextStyle(fontSize: 12, color: Colors.blue.shade800),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 卸载当前已加载模型，并弹出结果提示（成功/失败）。
/// 顶层函数：设置页（模型卡片 / 推理引擎页）均可调用。
/// 卸载完成后由 modelManagerProvider 状态变化驱动 UI 刷新（模型卡片、引擎状态卡）。
Future<void> unloadModelAndNotify(
  WidgetRef ref,
  BuildContext context,
  String modelName,
) async {
  final manager = ref.read(modelManagerProvider.notifier);
  if (manager.isBusy) return;

  final ok = await manager.unloadModel();
  if (!context.mounted) return;

  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(ok ? '✅ 已卸载 $modelName，已释放内存' : '❌ 卸载失败，请重试'),
      backgroundColor: ok ? Colors.green : Colors.red,
      duration: const Duration(seconds: 2),
    ),
  );
}

// =========================================================================
// Tab 2: API 接入（OpenAI 兼容远程模型）
// =========================================================================

// =========================================================================
// 开发者 Tab：开发模式 + SSH 自动连接向导 + 工作区管理 + 危险命令策略。
// 设计目标（用户反馈）：能自动的绝不手填——密钥自动生成、命令一键复制、
// 连接自动建立、Termux 项目目录自动创建。用户只做"复制粘贴一条命令"。
// =========================================================================
class _DevTab extends ConsumerStatefulWidget {
  const _DevTab();

  @override
  ConsumerState<_DevTab> createState() => _DevTabState();
}

class _DevTabState extends ConsumerState<_DevTab> {
  /// SSH 连接/工作区激活是异步后台变化，监听 ChangeNotifier 实时刷新。
  VoidCallback? _devStateListener;

  @override
  void initState() {
    super.initState();
    final listener = () {
      if (mounted) setState(() {});
    };
    _devStateListener = listener;
    SshEnvironmentService.instance.addListener(listener);
    DevSessionController.instance.addListener(listener);
  }

  @override
  void dispose() {
    final listener = _devStateListener;
    if (listener != null) {
      SshEnvironmentService.instance.removeListener(listener);
      DevSessionController.instance.removeListener(listener);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildModeCard(settings, notifier),
          const SizedBox(height: 10),
          _buildConnectionsCard(settings, notifier),
          const SizedBox(height: 10),
          _buildWorkspacesCard(settings, notifier),
          const SizedBox(height: 10),
          _buildSafetyCard(settings, notifier),
        ],
      ),
    );
  }

  // ---------------- 总开关 ----------------

  Widget _buildModeCard(InferenceSettings settings, SettingsNotifier notifier) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildToggleTitle(
              '🛠️ 开发模式（Dev Agent）',
              settings.devModeEnabled,
              (v) async {
                await notifier.setDevModeEnabled(v);
                if (mounted) setState(() {});
              },
              subtitle: settings.devModeEnabled
                  ? '开：注册 git/规划/SSH/测试工具，可连 Termux/远程电脑做 AI 编程'
                  : '关：现有智能体行为完全不变（默认）',
            ),
            const SizedBox(height: 4),
            Text(
              '开启后：对话里的智能体可直接读写手机 Termux / 远程电脑上的项目，'
              '执行 git 提交、跑测试。连接与密钥由下方向导自动完成。',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------- 连接配置（多目标：Termux / 远程电脑） ----------------

  Widget _buildConnectionsCard(
      InferenceSettings settings, SettingsNotifier notifier) {
    final ssh = SshEnvironmentService.instance;
    final sshStatusLabel = switch (ssh.status) {
      SshStatus.idle => '未连接',
      SshStatus.connecting => '连接中…',
      SshStatus.connected => '已连接',
      SshStatus.failed => '失败',
    };
    final sshStatusColor = switch (ssh.status) {
      SshStatus.connected => Colors.green,
      SshStatus.connecting => Colors.orange,
      SshStatus.failed => Colors.red,
      _ => Colors.grey,
    };
    final configs = settings.sshConfigs;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSectionHeader('🔌 SSH 连接（自动配置向导）', context),
            Row(
              children: [
                Icon(Icons.circle, size: 10, color: sshStatusColor),
                const SizedBox(width: 6),
                Text(sshStatusLabel, style: const TextStyle(fontSize: 12)),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    ssh.isConnected
                        ? '${ssh.activeConfig?.name ?? ''} '
                            '${ssh.activeConfig?.username ?? ''}@'
                            '${ssh.activeConfig?.host ?? ''}:'
                            '${ssh.activeConfig?.port ?? ''}'
                        : (ssh.status == SshStatus.failed &&
                                (ssh.lastError?.isNotEmpty ?? false))
                            ? ssh.lastError!
                            : '未连接（向导自动完成，无需手填密钥）',
                    style: TextStyle(
                        fontSize: 12,
                        color: ssh.status == SshStatus.failed
                            ? Colors.red.shade700
                            : Colors.grey.shade600),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // 自动向导入口：Termux / 远程电脑 各一个。
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: () => _showTermuxSetupDialog(context, notifier),
                  icon: const Icon(Icons.smartphone, size: 16),
                  label: const Text('📱 连接 Termux'),
                ),
                FilledButton.icon(
                  onPressed: () => _showRemotePcSetupDialog(context, notifier),
                  icon: const Icon(Icons.desktop_windows, size: 16),
                  label: const Text('💻 连接远程电脑'),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '自动生成密钥，一条命令完成，无需 root；'
              '连接失败会给诊断和修复动作。',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
            ),
            // 配置列表（已保存的连接目标）。
            if (configs.isNotEmpty) ...[
              const SizedBox(height: 8),
              for (final cfg in configs)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${cfg.name.isEmpty ? '配置' : cfg.name} · '
                          '${cfg.username.isEmpty ? '?' : cfg.username}@'
                          '${cfg.host}:${cfg.port}',
                          style: const TextStyle(fontSize: 12),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      TextButton(
                        onPressed: () => _showSshConfigDialog(context, notifier,
                            existing: cfg),
                        child: const Text('编辑'),
                      ),
                      TextButton(
                        onPressed: () async {
                          await notifier.removeSshConfig(cfg.id);
                          if (ssh.activeConfig?.id == cfg.id) {
                            await ssh.disconnect();
                          }
                          if (mounted) setState(() {});
                        },
                        child: const Text('删除'),
                      ),
                      TextButton(
                        onPressed: () async {
                          await _connectTo(cfg);
                          if (mounted) setState(() {});
                        },
                        child: const Text('连接'),
                      ),
                    ],
                  ),
                ),
            ],
            if (ssh.isConnected) ...[
              const SizedBox(height: 6),
              Wrap(
                spacing: 4,
                children: [
                  TextButton.icon(
                    onPressed: () async {
                      await ssh.disconnect();
                      if (mounted) setState(() {});
                    },
                    icon: const Icon(Icons.link_off, size: 18),
                    label: const Text('断开'),
                  ),
                  TextButton.icon(
                    onPressed: () async {
                      await ssh.clearHostKeyFingerprints();
                      if (mounted) setState(() {});
                    },
                    icon: const Icon(Icons.fingerprint, size: 18),
                    label: const Text('清除指纹'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 连接（保持连接；配置相同幂等复用，不同自动切换）。
  ///
  /// 注意：`SshEnvironmentService.connect` 失败只置内部状态不抛异常，
  /// 必须用 `isConnected` 判定结果，不能依赖 try/catch（否则永远弹"已连接"）。
  Future<void> _connectTo(SshConfig cfg) async {
    if (!cfg.isComplete) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('配置不完整：请先编辑补全用户名/密钥或密码')));
      }
      return;
    }
    final ssh = SshEnvironmentService.instance;
    await ssh.connect(cfg);
    if (!mounted) return;
    final ok = ssh.isConnected;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(ok
            ? '✅ 已连接 ${cfg.name}'
            : '❌ ${_classifySshError(ssh.lastError)}')));
  }

  // ---------------- Termux 自动向导 ----------------

  /// Termux 向导（诊断驱动）：
  /// 打开时探测一次 sshd → 按结果给诊断（未运行 / 被拉黑 / 正常）→
  /// 万能命令（自带 pkill+sshd 重启，顺带清 PerSourcePenalties 惩罚）→
  /// 可一键拉起 Termux → 用户名 → 真实连接。
  Future<void> _showTermuxSetupDialog(
      BuildContext context, SettingsNotifier notifier) async {
    var step = 0; // 0: 探测  1: 命令执行  2: 用户名+连接
    var probing = true;
    var probeResult = _SshdProbe.timeout;
    var generated = false;
    String? publicKey;
    String? privateKeyPem;
    var command = '';
    var userName = '';
    var connecting = false;
    var probeStarted = false;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) {
          Future<void> probeAndGen() async {
            setState(() => probing = true);
            probeResult = await _probeSshd('127.0.0.1', 8022);
            if (!generated) {
              final keys = SshKeyGen.generate();
              if (keys != null) {
                generated = true;
                publicKey = keys.publicKey;
                privateKeyPem = keys.privateKeyPem;
                command = _buildTermuxInstallCommand(keys.publicKey);
              }
            }
            probing = false;
            step = 1;
            setState(() {});
          }

          Future<void> finishConnect() async {
            setState(() => connecting = true);
            userName = userName.trim();
            final cfg = SshConfig.termuxTemplate.copyWith(
              username: userName,
              privateKeyPem: privateKeyPem,
              authType: SshAuthType.key,
            );
            await notifier.upsertSshConfig(cfg);
            final ssh = SshEnvironmentService.instance;
            await ssh.connect(cfg);
            connecting = false;
            if (!ctx.mounted) return;
            if (ssh.isConnected) {
              Navigator.pop(ctx);
              return;
            }
            Navigator.pop(ctx);
            ScaffoldMessenger.of(this.context).showSnackBar(SnackBar(
                backgroundColor: Colors.red.shade700,
                content: Text('❌ ${_classifySshError(ssh.lastError)}',
                    style: const TextStyle(fontSize: 12))));
          }

          if (!probeStarted) {
            probeStarted = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (ctx.mounted) probeAndGen();
            });
          }

          final diagnosis = switch (probeResult) {
            _SshdProbe.listening => 'sshd 运行中——还差最后一步：安装公钥',
            _SshdProbe.refused => 'sshd 没在运行（最常见的失败原因）',
            _SshdProbe.timeout =>
              '端口无响应——大概率是之前多次连接失败后被 Termux 的 OpenSSH '
                  '临时拉黑（PerSourcePenalties），越重试越连不上',
          };

          final dialog = AlertDialog(
            title: const Text('📱 Termux 自动连接向导'),
            content: SizedBox(
              width: 480,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (step == 0)
                      const Row(children: [
                        SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2)),
                        SizedBox(width: 12),
                        Text('正在检测 Termux sshd（127.0.0.1:8022）…'),
                      ])
                    else ...[
                      Text('诊断：$diagnosis',
                          style: const TextStyle(fontSize: 13)),
                      const SizedBox(height: 10),
                      // 万能命令：pkill 重启 sshd（清拉黑）+ 装公钥 + 写用户名，
                      // 三种诊断状态都靠它修复，一条到底。
                      Text('在 Termux 里粘贴执行这条命令（自动重启 sshd + 安装公钥）：',
                          style: const TextStyle(fontSize: 12)),
                      const SizedBox(height: 6),
                      _copyableCommand(ctx, command),
                      const SizedBox(height: 10),
                      Row(children: [
                        FilledButton.tonalIcon(
                          onPressed: () async {
                            final ok = await AppBridge.launchApp(
                                AppBridge.termuxPackage);
                            if ((!ok) && ctx.mounted) {
                              ScaffoldMessenger.of(this.context).showSnackBar(
                                  const SnackBar(
                                      content: Text('未找到 Termux，请先安装 Termux')));
                            }
                          },
                          icon: const Icon(Icons.open_in_new, size: 16),
                          label: const Text('拉起 Termux'),
                        ),
                        const SizedBox(width: 8),
                        TextButton.icon(
                          onPressed:
                              probing ? null : () => probeAndGen(),
                          icon: const Icon(Icons.refresh, size: 16),
                          label: Text(probing ? '检测中…' : '重新检测'),
                        ),
                      ]),
                      if (step == 2) ...[
                        const SizedBox(height: 12),
                        TextField(
                          controller:
                              TextEditingController(text: userName),
                          onChanged: (v) => userName = v,
                          decoration: const InputDecoration(
                            labelText: 'Termux 用户名',
                            hintText: '通常 u0_aXXX，已自动填好',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ] else ...[
                        const SizedBox(height: 6),
                        const Text('执行完命令后点「下一步」。',
                            style: TextStyle(fontSize: 11, color: Colors.grey)),
                      ],
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              if (step == 1)
                TextButton(
                  onPressed: () {
                    userName = _readSharedUserName() ?? '';
                    setState(() => step = 2);
                  },
                  child: const Text('下一步'),
                ),
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('取消'),
              ),
              if (step == 2)
                FilledButton(
                  onPressed: connecting ? null : finishConnect,
                  child: Text(connecting ? '连接中…' : '✅ 连接'),
                ),
            ],
          );
          return dialog;
        },
      ),
    );
    if (mounted) setState(() {});
  }

  /// 远程电脑向导：host/port（唯一必填）+ 自动密钥 + 公钥命令 + 连接。
  Future<void> _showRemotePcSetupDialog(
      BuildContext context, SettingsNotifier notifier) async {
    final hostCtrl = TextEditingController(text: '192.168.1.100');
    final portCtrl = TextEditingController(text: '22');
    final userCtrl = TextEditingController();
    var generated = false;
    String? publicKey;
    String? privateKeyPem;
    var command = '';

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('💻 远程电脑自动配置'),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    controller: hostCtrl,
                    decoration: const InputDecoration(
                      labelText: '电脑地址（唯一必填）',
                      hintText: '局域网 IP 或主机名，如 192.168.1.100',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextFormField(
                    controller: portCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '端口（默认 22）',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextFormField(
                    controller: userCtrl,
                    decoration: const InputDecoration(
                      labelText: '电脑用户名',
                      hintText: '如：yourname（登录电脑的用户名）',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (!generated)
                    FilledButton.icon(
                      onPressed: () {
                        final keys = SshKeyGen.generate();
                        if (keys != null) {
                          generated = true;
                          publicKey = keys.publicKey;
                          privateKeyPem = keys.privateKeyPem;
                          command = _buildRemoteInstallCommand(keys.publicKey);
                          setState(() {});
                        }
                      },
                      icon: const Icon(Icons.key, size: 16),
                      label: const Text('🔑 自动生成密钥'),
                    )
                  else ...[
                    Text('在电脑上执行这条命令（添加公钥到 authorized_keys）：',
                        style: const TextStyle(fontSize: 12)),
                    const SizedBox(height: 6),
                    _copyableCommand(ctx, command),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: generated
                  ? () async {
                      final host = hostCtrl.text.trim();
                      final user = userCtrl.text.trim();
                      if (host.isEmpty || user.isEmpty) {
                        ScaffoldMessenger.of(ctx).showSnackBar(
                            const SnackBar(content: Text('请填写电脑地址与用户名')));
                        return;
                      }
                      final cfg = SshConfig.remotePcTemplate.copyWith(
                        host: host,
                        port: int.tryParse(portCtrl.text.trim()) ?? 22,
                        username: user,
                        privateKeyPem: privateKeyPem,
                        authType: SshAuthType.key,
                      );
                      await notifier.upsertSshConfig(cfg);
                      Navigator.pop(ctx);
                      await _connectTo(cfg);
                    }
                  : null,
              child: const Text('保存并连接'),
            ),
          ],
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  /// 可复制的命令块（选中即复制）。
  Widget _copyableCommand(BuildContext ctx, String command) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.grey.shade900,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          Expanded(
            child: SelectableText(
              command,
              style: const TextStyle(fontSize: 12, color: Colors.white),
            ),
          ),
          IconButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: command));
              if (ctx.mounted) {
                ScaffoldMessenger.of(ctx)
                    .showSnackBar(const SnackBar(content: Text('已复制，去粘贴执行即可')));
              }
            },
            icon: const Icon(Icons.copy, size: 16, color: Colors.white),
          ),
        ],
      ),
    );
  }

  /// Termux sshd 诊断探测（只在向导打开时做一次）。
  ///
  /// ⚠️ 对 Termux 的 OpenSSH 10.x **不能频繁裸探测**：TCP 连上后未认证即断开
  /// 会被 PerSourcePenalties 记惩罚（源 127.0.0.1 被拉黑后 sshd 接受连接但
  /// 不发 banner → 表现为 timeout），越探越死。refused = 没监听（不记惩罚）。
  Future<_SshdProbe> _probeSshd(String host, int port) async {
    try {
      final socket =
          await Socket.connect(host, port, timeout: const Duration(seconds: 3));
      socket.destroy();
      return _SshdProbe.listening;
    } on SocketException catch (e) {
      final msg = e.message.toLowerCase();
      if (msg.contains('refused') || e.osError?.errorCode == 111) {
        return _SshdProbe.refused; // sshd 没在监听
      }
      return _SshdProbe.timeout; // 被拉黑 / sshd 卡死
    } catch (_) {
      return _SshdProbe.timeout;
    }
  }

  /// SSH 连接失败 → 人话 + 下一步动作（不甩原始异常）。
  String _classifySshError(String? raw) {
    final msg = raw ?? '';
    final lower = msg.toLowerCase();
    if (lower.contains('refused')) {
      return '连接失败：Termux 的 sshd 没在运行。'
          '打开 Termux 重新执行安装命令（会自动重启 sshd），再点连接';
    }
    if (lower.contains('timed out') || lower.contains('timeout')) {
      return '连接失败：端口无响应——多半是多次失败后被 Termux OpenSSH '
          '临时拉黑。在 Termux 重新执行安装命令（自带重启 sshd 清拉黑），再点连接';
    }
    if (lower.contains('auth') ||
        lower.contains('denied') ||
        lower.contains('permission')) {
      return '连接失败：认证不通过——公钥没装上或用户名不对。'
          '重新执行安装命令，用户名以命令输出 USER= 为准';
    }
    return '连接失败：$msg';
  }

  /// 读取 Termux 写入共享文件的用户名（/sdcard/tongyilite_ssh_user.txt）。
  String? _readSharedUserName() {
    try {
      final f = File('/storage/emulated/0/tongyilite_ssh_user.txt');
      if (!f.existsSync()) return null;
      final v = f.readAsStringSync().trim();
      return v.isEmpty ? null : v;
    } catch (_) {
      return null;
    }
  }

  /// Termux 安装公钥 + 写用户名（一条复制即用；无存储权限不影响公钥安装）。
  String _buildTermuxInstallCommand(String publicKey) {
    // v2（2026-10-01）：装 procps 提供 pkill，先杀再启 sshd——
    // 每次执行命令顺带清掉 OpenSSH PerSourcePenalties 的源拉黑。
    return 'pkg install -y openssh procps 2>/dev/null; '
        'pkill sshd 2>/dev/null; sleep 1; sshd 2>/dev/null; '
        'mkdir -p ~/.ssh && echo "$publicKey" > ~/.ssh/authorized_keys && '
        'chmod 600 ~/.ssh/authorized_keys; '
        'echo "USER=\$(whoami)" > /sdcard/tongyilite_ssh_user.txt 2>/dev/null || true; '
        'echo ALL_DONE';
  }

  /// 远程电脑添加公钥命令（追加，不覆盖已有公钥）。
  String _buildRemoteInstallCommand(String publicKey) {
    return 'mkdir -p ~/.ssh && echo "$publicKey" >> ~/.ssh/authorized_keys && '
        'chmod 600 ~/.ssh/authorized_keys && echo ALL_DONE';
  }

  // ---------------- SSH 配置编辑 ----------------

  /// 编辑指定配置（existing 为空则新建）。
  Future<void> _showSshConfigDialog(
      BuildContext context, SettingsNotifier notifier,
      {SshConfig? existing}) async {
    final cfg = existing;
    final nameCtrl = TextEditingController(text: cfg?.name ?? '');
    final hostCtrl = TextEditingController(text: cfg?.host ?? '127.0.0.1');
    final portCtrl =
        TextEditingController(text: (cfg?.port ?? 8022).toString());
    final userCtrl = TextEditingController(text: cfg?.username ?? '');
    final passCtrl = TextEditingController(text: cfg?.password ?? '');
    final keyCtrl = TextEditingController(text: cfg?.privateKeyPem ?? '');
    final formKey = GlobalKey<FormState>();
    var authType = cfg?.authType ?? SshAuthType.key;
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: Text(existing == null ? '新增连接配置' : '编辑连接配置'),
          content: Form(
            key: formKey,
            child: SizedBox(
              width: 460,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextFormField(
                      controller: nameCtrl,
                      decoration: const InputDecoration(
                        labelText: '配置名称',
                        hintText: '如：Termux / 家里电脑',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: hostCtrl,
                      decoration: const InputDecoration(
                        labelText: '主机',
                        border: OutlineInputBorder(),
                      ),
                      validator: (v) =>
                          (v == null || v.trim().isEmpty) ? '请填写主机' : null,
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: portCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: '端口',
                        border: OutlineInputBorder(),
                      ),
                      validator: (v) =>
                          (int.tryParse(v ?? '') ?? 0) <= 0 ? '端口非法' : null,
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: userCtrl,
                      decoration: const InputDecoration(
                        labelText: '用户名',
                        border: OutlineInputBorder(),
                      ),
                      validator: (v) =>
                          (v == null || v.trim().isEmpty) ? '请填写用户名' : null,
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        ChoiceChip(
                          label: const Text('密钥'),
                          selected: authType == SshAuthType.key,
                          onSelected: (_) =>
                              setState(() => authType = SshAuthType.key),
                        ),
                        const SizedBox(width: 8),
                        ChoiceChip(
                          label: const Text('密码'),
                          selected: authType == SshAuthType.password,
                          onSelected: (_) =>
                              setState(() => authType = SshAuthType.password),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    if (authType == SshAuthType.key)
                      TextFormField(
                        controller: keyCtrl,
                        minLines: 4,
                        maxLines: 8,
                        decoration: const InputDecoration(
                          labelText: '私钥（PEM / OpenSSH）',
                          border: OutlineInputBorder(),
                          alignLabelWithHint: true,
                        ),
                        validator: (v) =>
                            (v == null || v.trim().isEmpty) ? '请填写私钥' : null,
                      )
                    else
                      TextFormField(
                        controller: passCtrl,
                        decoration: const InputDecoration(
                          labelText: '密码',
                          border: OutlineInputBorder(),
                        ),
                        validator: (v) =>
                            (v == null || v.trim().isEmpty) ? '请填写密码' : null,
                      ),
                    const SizedBox(height: 8),
                    Text(
                      '提示：密钥认证更安全。也可点「自动生成」让 app 生成 ed25519 密钥，'
                      '再用向导里的命令把公钥装到对端。',
                      style:
                          TextStyle(fontSize: 11, color: Colors.grey.shade600),
                    ),
                  ],
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () async {
                if (!formKey.currentState!.validate()) return;
                Navigator.pop(ctx, true);
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (saved != true) return;
    // 兜底：existing 无稳定 id（旧配置迁移遗漏）→ 分配新 id，避免 upsert 追加。
    final stableId = (existing?.id.trim().isNotEmpty ?? false)
        ? existing!.id.trim()
        : 'ssh_${DateTime.now().millisecondsSinceEpoch}';
    await notifier.upsertSshConfig(SshConfig(
      id: stableId,
      name: nameCtrl.text.trim(),
      host: hostCtrl.text.trim(),
      port: int.tryParse(portCtrl.text.trim()) ?? 8022,
      username: userCtrl.text.trim(),
      authType: authType,
      privateKeyPem: authType == SshAuthType.key ? keyCtrl.text.trim() : null,
      password: authType == SshAuthType.password ? passCtrl.text.trim() : null,
    ));
    if (mounted) setState(() {});
  }

  // ---------------- 工作区 ----------------

  Widget _buildWorkspacesCard(
      InferenceSettings settings, SettingsNotifier notifier) {
    final dev = DevSessionController.instance;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSectionHeader('📁 工作区', context),
            Text(
              '文件/记忆工具跟随激活工作区；远端工作区（Termux/电脑）'
              '用 ssh_exec / ssh_read_file / ssh_write_file 操作。'
              '新增 Termux 工作区时可自动建目录。',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final ws in dev.workspaces)
                  ChoiceChip(
                    label: Text(ws.isDefault ? ws.name : ws.name),
                    selected: dev.activeWorkspaceId == ws.id,
                    onSelected: (_) async {
                      await dev.switchWorkspace(ws.id);
                      await notifier.setDevWorkspaceId(ws.id);
                      if (mounted) setState(() {});
                    },
                  ),
                TextButton.icon(
                  onPressed: () => _showWorkspaceDialog(context, notifier),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('新增'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 新增/编辑工作区对话框。
  Future<void> _showWorkspaceDialog(
      BuildContext context, SettingsNotifier notifier,
      {DevWorkspace? existing}) async {
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final pathCtrl = TextEditingController(text: existing?.remotePath ?? '');
    final formKey = GlobalKey<FormState>();
    var backend = existing?.backend ?? WorkspaceBackend.localApp;
    var sshConfigId = existing?.sshConfigId;
    var creatingDir = false;
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: Text(existing == null ? '新增工作区' : '编辑工作区'),
          content: Form(
            key: formKey,
            child: SizedBox(
              width: 460,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    controller: nameCtrl,
                    autofocus: existing == null,
                    decoration: const InputDecoration(
                      labelText: '工作区名称',
                      hintText: '如：TongYi-Lite / 我的博客项目',
                      border: OutlineInputBorder(),
                    ),
                    validator: (v) =>
                        (v == null || v.trim().isEmpty) ? '请填写名称' : null,
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<WorkspaceBackend>(
                    value: backend,
                    decoration: const InputDecoration(
                      labelText: '后端',
                      border: OutlineInputBorder(),
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: WorkspaceBackend.localApp,
                        child: Text('本地沙盒（app 内目录）'),
                      ),
                      DropdownMenuItem(
                        value: WorkspaceBackend.termux,
                        child: Text('Termux（手机 Linux）'),
                      ),
                      DropdownMenuItem(
                        value: WorkspaceBackend.remotePc,
                        child: Text('远程电脑'),
                      ),
                    ],
                    onChanged: (v) => setState(
                        () => backend = v ?? WorkspaceBackend.localApp),
                  ),
                  if (backend != WorkspaceBackend.localApp) ...[
                    const SizedBox(height: 12),
                    // 绑定连接配置。
                    DropdownButtonFormField<String?>(
                      value: sshConfigId,
                      decoration: const InputDecoration(
                        labelText: '绑定连接配置',
                        border: OutlineInputBorder(),
                      ),
                      items: [
                        const DropdownMenuItem<String?>(
                          value: null,
                          child: Text('自动（第一份可用配置）'),
                        ),
                        for (final cfg in ref.read(settingsProvider).sshConfigs)
                          DropdownMenuItem<String?>(
                            value: cfg.id,
                            child: Text('${cfg.name}（${cfg.host}:${cfg.port}）'),
                          ),
                      ],
                      onChanged: (v) => setState(() => sshConfigId = v),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: pathCtrl,
                      decoration: const InputDecoration(
                        labelText: '远端路径（绝对路径）',
                        hintText: '可手填，或点下方「自动创建目录」',
                        border: OutlineInputBorder(),
                      ),
                      validator: (v) =>
                          (v == null || v.trim().isEmpty) ? '远端路径必填' : null,
                    ),
                    const SizedBox(height: 8),
                    // 自动创建：连接后建 ~/projects/<名称> 并把路径填上。
                    FilledButton.icon(
                      onPressed: creatingDir
                          ? null
                          : () async {
                              setState(() => creatingDir = true);
                              try {
                                final dir =
                                    await _autoCreateRemoteDir(nameCtrl.text);
                                if (dir != null && ctx.mounted) {
                                  pathCtrl.text = dir;
                                } else if (ctx.mounted) {
                                  ScaffoldMessenger.of(ctx)
                                      .showSnackBar(const SnackBar(
                                          content: Text('自动创建失败：请先连接开发环境，'
                                              '或检查用户名/密钥')));
                                }
                              } finally {
                                setState(() => creatingDir = false);
                              }
                            },
                      icon: const Icon(Icons.folder_open, size: 16),
                      label: Text(creatingDir ? '创建中…' : '🔍 自动创建目录'),
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () async {
                if (!formKey.currentState!.validate()) return;
                Navigator.pop(ctx, true);
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (saved != true) return;
    final name = nameCtrl.text.trim();
    if (name.isEmpty) return;
    final id = existing?.id ?? 'ws_${DateTime.now().millisecondsSinceEpoch}';
    await DevSessionController.instance.upsertWorkspace(DevWorkspace(
      id: id,
      name: name,
      backend: backend,
      remotePath:
          backend == WorkspaceBackend.localApp ? null : pathCtrl.text.trim(),
      sshConfigId: backend == WorkspaceBackend.localApp ? null : sshConfigId,
    ));
    if (mounted) setState(() {});
  }

  /// 自动创建远端目录：连接后 `echo $HOME` + `mkdir -p ~/projects/<safe>`。
  Future<String?> _autoCreateRemoteDir(String name) async {
    final settings = ref.read(settingsProvider);
    final ssh = SshEnvironmentService.instance;
    // 找一份可用配置（已连接优先）。
    SshConfig? cfg;
    if (ssh.isConnected) {
      cfg = ssh.activeConfig;
    } else {
      for (final c in settings.sshConfigs) {
        if (c.isComplete) {
          cfg = c;
          break;
        }
      }
    }
    if (cfg == null) return null;
    if (!await ssh.ensureConnected(cfg)) return null;
    final safe = sanitizeWorkspaceDirName(name);
    final home =
        (await ssh.run('echo \$HOME', timeout: const Duration(seconds: 30)))
                ?.trim() ??
            '';
    if (home.isEmpty) return null;
    final dir = '$home/projects/$safe';
    final out = await ssh.run('mkdir -p "$dir" && echo OK',
        timeout: const Duration(seconds: 30));
    if ((out?.trim() ?? '') != 'OK') return null;
    return dir;
  }

  // ---------------- 安全策略 ----------------

  Widget _buildSafetyCard(
      InferenceSettings settings, SettingsNotifier notifier) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSectionHeader('🛡️ 危险命令策略', context),
            Row(
              children: [
                ChoiceChip(
                  label: const Text('拒绝'),
                  selected: settings.dangerousCommandPolicy == 'deny',
                  onSelected: (_) => notifier.setDangerousCommandPolicy('deny'),
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: const Text('每次审批'),
                  selected: settings.dangerousCommandPolicy == 'ask',
                  onSelected: (_) => notifier.setDangerousCommandPolicy('ask'),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '拒绝 = 黑名单命令直接拦截（rm -rf /、reboot、git push --force 等）；'
              '每次审批 = 转用户确认。',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
            ),
          ],
        ),
      ),
    );
  }
}

class _ApiTab extends ConsumerWidget {
  const _ApiTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final apiModels = settings.apiModels;
    final activeId = settings.activeApiModelId;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Icon(Icons.cloud_queue,
                      color: Theme.of(context).colorScheme.primary),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      '本地模型优先：仅当本地模型不可用时，才自动使用下方激活的 API 模型。',
                      style: TextStyle(fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(child: _buildSectionHeader('已配置的 API 模型', context)),
              FilledButton.icon(
                onPressed: () => _showApiModelDialog(context, ref),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('添加'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (apiModels.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(
                child:
                    Text('尚未配置任何 API 模型', style: TextStyle(color: Colors.grey)),
              ),
            )
          else
            for (final cfg in apiModels)
              _buildApiModelCard(context, ref, cfg, activeId == cfg.id),
          const SizedBox(height: 20),
          _buildSectionHeader('当前激活', context),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildToggleTitle(
                    '启用 API 接入',
                    activeId != null,
                    (v) {
                      // 打开时激活当前列表首个可用模型；关闭时停用。
                      ref.read(settingsProvider.notifier).setActiveApiModel(v
                          ? (activeId ??
                              (apiModels.isNotEmpty
                                  ? apiModels.first.id
                                  : null))
                          : null);
                    },
                    subtitle: activeId != null
                        ? '当前激活：${_activeApiName(apiModels, activeId)}'
                        : '未启用 API，聊天仅使用本地模型',
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          // 联网搜索（SearXNG 实例地址等）：与 API 接入同属"外部服务"配置。
          const _WebSearchCard(),
        ],
      ),
    );
  }

  Widget _buildApiModelCard(
      BuildContext context, WidgetRef ref, ApiModelConfig cfg, bool isActive) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.cloud,
                    size: 20, color: isActive ? Colors.green : Colors.grey),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(cfg.name,
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold)),
                ),
                if (isActive)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.green,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Text('已激活',
                        style: TextStyle(fontSize: 11, color: Colors.white)),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(cfg.baseUrl,
                style: const TextStyle(fontSize: 12, color: Colors.grey)),
            Text('模型：${cfg.model}', style: const TextStyle(fontSize: 12)),
            Text(
              'temp=${cfg.effectiveTemperature.toStringAsFixed(2)} · '
              'max_tokens=${cfg.effectiveMaxTokens}'
              '${cfg.contextWindow != null ? ' · 上下文=${cfg.contextWindow}' : ''}',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: isActive
                      ? OutlinedButton.icon(
                          onPressed: () => ref
                              .read(settingsProvider.notifier)
                              .setActiveApiModel(null),
                          icon: const Icon(Icons.power_off, size: 16),
                          label: const Text('停用'),
                        )
                      : FilledButton.icon(
                          onPressed: () => ref
                              .read(settingsProvider.notifier)
                              .setActiveApiModel(cfg.id),
                          icon: const Icon(Icons.play_arrow, size: 16),
                          label: const Text('激活'),
                        ),
                ),
                IconButton(
                  icon: const Icon(Icons.edit, size: 20),
                  tooltip: '编辑',
                  onPressed: () =>
                      _showApiModelDialog(context, ref, existing: cfg),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 20),
                  tooltip: '删除',
                  onPressed: () => _confirmDeleteApiModel(context, ref, cfg),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDeleteApiModel(
      BuildContext context, WidgetRef ref, ApiModelConfig cfg) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('删除 API 模型'),
        content: Text('确定删除「${cfg.name}」吗？删除后其密钥一并移除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true) {
      ref.read(settingsProvider.notifier).deleteApiModel(cfg.id);
    }
  }

  String? _activeApiName(List<ApiModelConfig> list, String? id) {
    if (id == null) return null;
    for (final cfg in list) {
      if (cfg.id == id) return cfg.name;
    }
    return null;
  }

  void _showApiModelDialog(BuildContext context, WidgetRef ref,
      {ApiModelConfig? existing}) {
    showDialog(
      context: context,
      builder: (_) =>
          _ApiModelDialog(existing: existing, isEditing: existing != null),
    );
  }
}

class _ApiModelDialog extends ConsumerStatefulWidget {
  const _ApiModelDialog({this.existing, required this.isEditing});

  final ApiModelConfig? existing;
  final bool isEditing;

  @override
  ConsumerState<_ApiModelDialog> createState() => _ApiModelDialogState();
}

class _ApiModelDialogState extends ConsumerState<_ApiModelDialog> {
  late final TextEditingController _name;
  late final TextEditingController _baseUrl;
  late final TextEditingController _apiKey;
  late final TextEditingController _model;
  late final TextEditingController _temp;
  late final TextEditingController _maxTokens;
  late final TextEditingController _contextWindow;

  String? _testResult;
  bool _testing = false;
  bool _visionCapable = false;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name = TextEditingController(text: e?.name ?? '');
    _baseUrl = TextEditingController(text: e?.baseUrl ?? '');
    _apiKey = TextEditingController(text: e?.apiKey ?? '');
    _model = TextEditingController(text: e?.model ?? '');
    _temp =
        TextEditingController(text: e?.temperature?.toStringAsFixed(2) ?? '');
    _maxTokens = TextEditingController(text: e?.maxTokens?.toString() ?? '');
    _contextWindow =
        TextEditingController(text: e?.contextWindow?.toString() ?? '');
    _visionCapable = e?.visionCapable ?? false;
  }

  @override
  void dispose() {
    _name.dispose();
    _baseUrl.dispose();
    _apiKey.dispose();
    _model.dispose();
    _temp.dispose();
    _maxTokens.dispose();
    _contextWindow.dispose();
    super.dispose();
  }

  ApiModelConfig? _buildConfig() {
    final name = _name.text.trim();
    final baseUrl = _baseUrl.text.trim();
    final model = _model.text.trim();
    if (name.isEmpty || baseUrl.isEmpty || model.isEmpty) return null;
    return ApiModelConfig(
      id: widget.existing?.id ?? Uuid().v4(),
      name: name,
      baseUrl: baseUrl,
      apiKey: _apiKey.text.trim(),
      model: model,
      temperature: double.tryParse(_temp.text.trim()),
      maxTokens: int.tryParse(_maxTokens.text.trim()),
      visionCapable: _visionCapable,
      contextWindow: int.tryParse(_contextWindow.text.trim()),
    );
  }

  Future<void> _test() async {
    final cfg = _buildConfig();
    if (cfg == null) {
      setState(() => _testResult = '请先填写 名称/baseUrl/模型名');
      return;
    }
    setState(() => _testing = true);
    final err = await ref.read(openAiServiceProvider).testConnection(cfg);
    if (!mounted) return;
    setState(() {
      _testing = false;
      _testResult = err == null ? '✅ 连接成功' : '❌ $err';
    });
  }

  Future<void> _save() async {
    final cfg = _buildConfig();
    if (cfg == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('名称 / baseUrl / 模型名 为必填')),
      );
      return;
    }
    final notifier = ref.read(settingsProvider.notifier);
    if (widget.isEditing) {
      await notifier.updateApiModel(cfg);
    } else {
      await notifier.addApiModel(cfg);
    }
    if (!mounted) return;
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.isEditing ? '编辑 API 模型' : '添加 API 模型'),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: '显示名称 *')),
          TextField(
            controller: _baseUrl,
            decoration: const InputDecoration(
              labelText: 'Base URL *',
              hintText: 'https://api.openai.com/v1 或 http://127.0.0.1:8080/v1',
            ),
          ),
          TextField(
            controller: _apiKey,
            decoration: const InputDecoration(
              labelText: 'API Key',
              hintText: '可留空（本地服务）',
            ),
            obscureText: true,
          ),
          TextField(
            controller: _model,
            decoration: const InputDecoration(
              labelText: '模型名 *',
              hintText: 'gpt-4o / qwen2.5-7b-instruct',
            ),
          ),
          TextField(
            controller: _temp,
            keyboardType: TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'temperature（留空=0.7）'),
          ),
          TextField(
            controller: _maxTokens,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'max_tokens（留空=1024）'),
          ),
          TextField(
            controller: _contextWindow,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: '上下文窗口（留空=自动探测）',
              hintText: '顶部上下文占用百分比的分母；自动从 /v1/models 读取 n_ctx',
            ),
          ),
          SwitchListTile(
            title: const Text('支持视觉（图片理解）'),
            subtitle: const Text('开启后，带图消息会以 base64 图片发送给该 API'),
            value: _visionCapable,
            onChanged: (v) => setState(() => _visionCapable = v),
          ),
          const SizedBox(height: 12),
          if (_testResult != null)
            Text(
              _testResult!,
              style: TextStyle(
                color: _testResult!.startsWith('✅') ? Colors.green : Colors.red,
              ),
            ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _testing ? null : _test,
                  icon: const Icon(Icons.wifi_tethering, size: 16),
                  label: Text(_testing ? '测试中…' : '测试连接'),
                ),
              ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _save, child: const Text('保存')),
      ],
    );
  }
}

// =========================================================================
// 联网搜索（SearXNG）配置卡 —— 放在「API 接入」页：与远程 API 同属外部服务配置。
//
// 设计要点：
// - 地址由用户自己的部署决定，App **不预置任何实例**；未填时 web_search 会
//   明确回"未配置地址"的诊断，而不是拿 127.0.0.1 去连手机自己。
// - 「测试连接」用输入框里的**草稿值**直接发一次真实搜索（无需先保存），并把
//   provider 的分类诊断原样显示（HTTP 状态 / 超时 / 实例未开 format=json 等），
//   避免"红条指错方向"。
// =========================================================================

class _WebSearchCard extends ConsumerStatefulWidget {
  const _WebSearchCard();

  @override
  ConsumerState<_WebSearchCard> createState() => _WebSearchCardState();
}

class _WebSearchCardState extends ConsumerState<_WebSearchCard> {
  final _url = TextEditingController();
  final _apiKey = TextEditingController();
  final _engines = TextEditingController();
  final _language = TextEditingController();
  final _maxResults = TextEditingController();
  final _timeoutSec = TextEditingController();

  /// 各文本框的 FocusNode：用于「离焦即自动保存」，
  /// 解决"填完值没按回车就丢了"的问题。
  final _urlFocus = FocusNode();
  final _apiKeyFocus = FocusNode();
  final _enginesFocus = FocusNode();
  final _languageFocus = FocusNode();
  final _maxResultsFocus = FocusNode();
  final _timeoutSecFocus = FocusNode();

  bool _revealKey = false;
  bool _testing = false;
  String? _testResult;
  bool _testOk = false;

  /// 提前捕获 notifier（provider 与应用同生命周期）：dispose（离开页面）时
  /// 还要落盘草稿，而那时不能再触碰 ref。
  SettingsNotifier? _liveNotifier;

  @override
  void initState() {
    super.initState();
    _liveNotifier = ref.read(settingsProvider.notifier);
    // 离焦即保存（SDK 3.27 的 TextField 既无 onBlur 也无 onFocusChange，
    // 用 FocusNode 监听实现；仅"由有焦点→失去焦点"时触发一次）。
    final n = _liveNotifier!;
    _saveOnBlur(_urlFocus, () => n.setWebSearchSearXngBaseUrl(_url.text));
    _saveOnBlur(_apiKeyFocus, () => n.setWebSearchSearXngApiKey(_apiKey.text));
    _saveOnBlur(
        _enginesFocus, () => n.setWebSearchSearXngEngines(_engines.text));
    _saveOnBlur(
        _languageFocus, () => n.setWebSearchSearXngLanguage(_language.text));
    _saveOnBlur(_maxResultsFocus, () => _saveMaxResults(_maxResults.text));
    _saveOnBlur(_timeoutSecFocus, () => _saveTimeoutSec(_timeoutSec.text));
  }

  /// 焦点离开 [node] 时执行一次 [save]（不依赖 ref，页面销毁路径也安全）。
  void _saveOnBlur(FocusNode node, void Function() save) {
    var hadFocus = false;
    node.addListener(() {
      if (hadFocus && !node.hasFocus && _liveNotifier != null) save();
      hadFocus = node.hasFocus;
    });
  }

  @override
  void dispose() {
    // 离页兜底保存：离焦保存只覆盖"焦点切换"场景；填完直接返回/切页时
    // 焦点从未离开过输入框，若不在此落盘，值就丢了（"配置不自动保存"的
    // 最后一个口子）。setter 幂等，与离焦保存重复触发无副作用。
    final n = _liveNotifier;
    if (n != null) {
      n.setWebSearchSearXngBaseUrl(_url.text);
      n.setWebSearchSearXngApiKey(_apiKey.text);
      n.setWebSearchSearXngEngines(_engines.text);
      n.setWebSearchSearXngLanguage(_language.text);
      final maxResults = int.tryParse(_maxResults.text.trim());
      if (maxResults != null) n.setWebSearchSearXngMaxResults(maxResults);
      final timeoutSec = int.tryParse(_timeoutSec.text.trim());
      if (timeoutSec != null) {
        n.setWebSearchSearXngTimeoutMs(timeoutSec * 1000);
      }
    }
    _url.dispose();
    _apiKey.dispose();
    _engines.dispose();
    _language.dispose();
    _maxResults.dispose();
    _timeoutSec.dispose();
    _urlFocus.dispose();
    _apiKeyFocus.dispose();
    _enginesFocus.dispose();
    _languageFocus.dispose();
    _maxResultsFocus.dispose();
    _timeoutSecFocus.dispose();
    super.dispose();
  }

  /// 设置是异步加载的：首帧输入框还是空的，等值到位后灌进去一次。
  /// 只灌空字段——绝不覆盖用户正在输入的内容。
  void _seed(TextEditingController c, String value) {
    if (c.text.isEmpty && value.isNotEmpty) c.text = value;
  }

  SettingsNotifier get _notifier => ref.read(settingsProvider.notifier);

  String? get _draftKeyOrNull =>
      _apiKey.text.trim().isEmpty ? null : _apiKey.text.trim();

  /// 用输入框里的当前内容构造一个 provider 并搜索一次"测试"。
  /// 测试前先**保存草稿**（点测试通常代表"我配完了"），避免只点了测试、
  /// 没按回车/没离焦导致值丢失——这正是"配置后不自动保存"的常见场景。
  Future<void> _test() async {
    await _saveAllDrafts();
    setState(() {
      _testing = true;
      _testResult = null;
    });
    final provider = SearXNGSearchProvider(
      baseURL: _url.text.trim(),
      apiKey: _draftKeyOrNull,
      engines: _engines.text.trim().isEmpty ? null : _engines.text.trim(),
      language: _language.text.trim().isEmpty ? null : _language.text.trim(),
      maxResults: int.tryParse(_maxResults.text.trim()) ?? 8,
      timeout: Duration(
          seconds: int.tryParse(_timeoutSec.text.trim()) ??
              (InferenceSettings.kDefaultSearXngTimeoutMs ~/ 1000)),
    );
    final sw = Stopwatch()..start();
    String message;
    bool ok;
    try {
      final result = await provider.search('测试');
      ok = true;
      message = '连接成功：${result.sources.length} 条结果'
          '，用时 ${sw.elapsedMilliseconds} ms'
          '${result.truncated ? '（结果超过上限，已截断）' : ''}';
      if (result.sources.isEmpty) {
        message = '连接成功但 0 条结果（用时 ${sw.elapsedMilliseconds} ms）：'
            '多半是指定的引擎都没结果，清空引擎白名单试试';
      }
    } on WebSearchProviderError catch (e) {
      ok = false;
      message = e.kind == 'WEB_ABORTED'
          ? '${e.message}（已等 ${sw.elapsedMilliseconds} ms）'
          : e.message;
    } catch (e) {
      ok = false;
      message = '搜索失败：$e';
    } finally {
      provider.dispose();
    }
    if (!mounted) return;
    setState(() {
      _testing = false;
      _testOk = ok;
      _testResult = message;
    });
  }

  /// 数字项保存：notifier 会把值夹紧到合法区间，保存后把**真正生效的值**回写输入框，
  /// 避免"填了 300、实际生效 120"这种自己看不出来的偏差。
  Future<void> _saveMaxResults(String v) async {
    final n = _liveNotifier;
    if (n == null) return;
    await n.setWebSearchSearXngMaxResults(
        int.tryParse(v.trim()) ?? n.state.webSearchSearXngMaxResults);
    if (!mounted) return;
    _maxResults.text = '${n.state.webSearchSearXngMaxResults}';
  }

  Future<void> _saveTimeoutSec(String v) async {
    final n = _liveNotifier;
    if (n == null) return;
    final currentSec = n.state.webSearchSearXngTimeoutMs ~/ 1000;
    await n.setWebSearchSearXngTimeoutMs(
        (int.tryParse(v.trim()) ?? currentSec) * 1000);
    if (!mounted) return;
    _timeoutSec.text = '${(n.state.webSearchSearXngTimeoutMs / 1000).round()}';
  }

  /// 顺序保存所有文本框的当前草稿值（测试连接前调用）。
  /// 逐个 await（setter 内部读 state 再写 controller），避免并发竞态。
  /// 每个 setter 都会 _persist（原子写 + 热更新 provider），重复调用幂等。
  Future<void> _saveAllDrafts() async {
    await _notifier.setWebSearchSearXngBaseUrl(_url.text);
    await _notifier.setWebSearchSearXngApiKey(_apiKey.text);
    await _notifier.setWebSearchSearXngEngines(_engines.text);
    await _notifier.setWebSearchSearXngLanguage(_language.text);
    await _saveMaxResults(_maxResults.text);
    await _saveTimeoutSec(_timeoutSec.text);
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    _seed(_url, settings.webSearchSearXngBaseUrl);
    _seed(_apiKey, settings.webSearchSearXngApiKey ?? '');
    _seed(_engines, settings.webSearchSearXngEngines ?? '');
    _seed(_language, settings.webSearchSearXngLanguage ?? '');
    _seed(_maxResults, '${settings.webSearchSearXngMaxResults}');
    _seed(
        _timeoutSec, '${(settings.webSearchSearXngTimeoutMs / 1000).round()}');

    final url = _url.text.trim();
    final notConfigured = url.isEmpty;
    // http 明文 + 填了密钥 = Bearer key 明文过网（回环地址除外）。
    final isHttp = url.toLowerCase().startsWith('http://');
    final host = url.isEmpty ? '' : (Uri.tryParse(url)?.host ?? '');
    final isLoopbackHost =
        host == '127.0.0.1' || host == 'localhost' || host == '::1';
    final insecureKey = !notConfigured &&
        isHttp &&
        !isLoopbackHost &&
        _apiKey.text.trim().isNotEmpty;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSectionHeader('🌐 联网搜索', context),
            const SizedBox(height: 4),
            Text(
              '为智能体提供 web_search 联网搜索。「端侧直连引擎」开关打开时'
              '优先级最高（忽略下方 SearXNG 地址）；关闭后用你的 SearXNG 实例'
              '（需手机能直接访问，局域网 IP 或 Tailscale 地址均可）。',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('启用联网搜索', style: TextStyle(fontSize: 14)),
              subtitle: const Text(
                  '开启后模型可用 web_search / get_weather；关闭则这两个工具不可见',
                  style: TextStyle(fontSize: 12)),
              value: settings.webSearchEnabled,
              onChanged: (v) => _notifier.setWebSearchEnabled(v),
            ),
            // ---- SearXNG 实例配置（直连引擎开关打开时优先级更高）----
            const SizedBox(height: 8),
            TextField(
                controller: _url,
                keyboardType: TextInputType.url,
                focusNode: _urlFocus,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'SearXNG 地址',
                  hintText: 'http://192.168.1.20:8080',
                  helperText: '离焦或按回车自动保存；路径会自动补 /search，只填主机和端口即可',
                  helperMaxLines: 2,
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onSubmitted: (v) => _notifier.setWebSearchSearXngBaseUrl(v),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _apiKey,
                focusNode: _apiKeyFocus,
                obscureText: !_revealKey,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: 'API Key（可选）',
                  helperText: '仅私有实例需要；以 Bearer 发送',
                  border: const OutlineInputBorder(),
                  isDense: true,
                  suffixIcon: IconButton(
                    icon: Icon(
                        _revealKey ? Icons.visibility_off : Icons.visibility,
                        size: 18),
                    onPressed: () => setState(() => _revealKey = !_revealKey),
                  ),
                ),
                onSubmitted: (v) => _notifier.setWebSearchSearXngApiKey(v),
              ),
              if (insecureKey) ...[
                const SizedBox(height: 6),
                Text(
                  '⚠️ 当前用 http 明文传输，API Key 会明文过网；建议改用 https 或走 Tailscale。',
                  style: TextStyle(fontSize: 12, color: Colors.orange.shade800),
                ),
              ],
              const SizedBox(height: 12),
              TextField(
                controller: _engines,
                focusNode: _enginesFocus,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: '引擎白名单（可选）',
                  hintText: '如 bing,sogou',
                  helperText: '留空 = 用实例的全部引擎。实例上若有连不通的引擎，'
                      '搜索会一直等到超时（实测可从 20 秒级降到 2~3 秒）',
                  helperMaxLines: 3,
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onSubmitted: (v) => _notifier.setWebSearchSearXngEngines(v),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _language,
                focusNode: _languageFocus,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: '搜索语言（可选）',
                  hintText: '如 zh-CN，留空 = 不指定',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onSubmitted: (v) => _notifier.setWebSearchSearXngLanguage(v),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _testing ? null : _test,
                      icon: const Icon(Icons.wifi_tethering, size: 16),
                      label: Text(_testing ? '测试中…' : '测试连接'),
                    ),
                  ),
                ],
              ),
            // ---- 条数 / 超时设置 ----
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _maxResults,
                    focusNode: _maxResultsFocus,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '最多条数',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onSubmitted: _saveMaxResults,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _timeoutSec,
                    focusNode: _timeoutSecFocus,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '超时（秒）',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onSubmitted: _saveTimeoutSec,
                  ),
                ),
              ],
            ),
            if (notConfigured) ...[
              const SizedBox(height: 6),
              Text(
                '尚未填写地址：联网搜索将使用端侧直连引擎（下方可开关选择）。'
                '填好地址点「测试连接」可改用 SearXNG 实例。',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
              ),
            ],
            if (_testResult != null) ...[
              const SizedBox(height: 8),
              Text(
                '${_testOk ? '✅' : '❌'} $_testResult',
                style: TextStyle(
                  fontSize: 12,
                  color: _testOk ? Colors.green : Colors.red,
                ),
              ),
            ],
            // ---- 端侧直连引擎（SearXNG 地址为空时生效）----
            _buildDirectEngineSection(context, notConfigured, settings),
          ],
        ),
      ),
    );
  }

  /// 端侧直连引擎配置：引擎开关（按风险分档）+ 每 10 分钟窗口请求预算。
  /// 「细水长流」管控：高风险引擎（搜狗/百度/夸克，风控激进）默认每窗口
  /// 发 4 次；预算耗尽自动跳过，窗口到期恢复；引擎被反爬拦截时熔断冷却
  /// 并自动换 Cookie/UA 身份重试（2026-10-02 放宽：次数 2→4、冷却缩短）。
  Widget _buildDirectEngineSection(
      BuildContext context, bool notConfigured, InferenceSettings settings) {
    const engineLabels = {
      'bing_cn': '必应 CN',
      'so360': '360 搜索',
      'chinaso': '中国搜索',
      'sogou': '搜狗（高风险）',
      'baidu': '百度（高风险）',
      'quark': '夸克（高风险）',
    };
    final enabled = settings.webSearchDirectEngines;
    Widget budgetSlider({
      required String label,
      required String hint,
      required int value,
      required int min,
      required int max,
      required ValueChanged<int> onChanged,
    }) =>
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: const TextStyle(fontSize: 12)),
            SizedBox(
              height: 34,
              child: Slider(
                value: value.toDouble(),
                min: min.toDouble(),
                max: max.toDouble(),
                divisions: max - min,
                label: '$value 次',
                onChanged: (v) => onChanged(v.round()),
              ),
            ),
            Text(hint, style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
          ],
        );
    final directOn = settings.webSearchDirectEnabled;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 14),
        _buildSectionHeader('⚡ 端侧直连引擎', context),
        const SizedBox(height: 2),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text('端侧直连引擎（优先级最高）',
              style: TextStyle(fontSize: 14)),
          subtitle: Text(
            directOn
                ? '已启用：优先用端侧直连，忽略上方 SearXNG 地址'
                : '已关闭：使用上方配置的 SearXNG 实例',
            style: const TextStyle(fontSize: 12),
          ),
          value: directOn,
          onChanged: (v) => _notifier.setWebSearchDirectEnabled(v),
        ),
        // 总开关关闭时子设置整体置灰不可点（对齐 agentEnabled 的置灰模式）。
        Opacity(
          opacity: directOn ? 1.0 : 0.45,
          child: IgnorePointer(
            ignoring: !directOn,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  notConfigured
                      ? '高风险引擎每窗口请求数少、被拦自动冷却换身份，'
                          '保证长期可用。'
                      : '当前被 SearXNG 地址覆盖（直连开关打开才生效）。',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
                const SizedBox(height: 4),
                for (final entry in engineLabels.entries)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            visualDensity: VisualDensity.compact,
            title: Text(entry.value, style: const TextStyle(fontSize: 14)),
            value: enabled.contains(entry.key),
            onChanged: (v) => _notifier
                .setWebSearchDirectEngineEnabled(entry.key, v),
          ),
        const SizedBox(height: 4),
        budgetSlider(
          label: '低风险引擎每 10 分钟搜索上限'
              '（必应/360/中国搜索，当前 ${settings.webSearchDirectLowRiskPerWindow} 次）',
          hint: '容忍度高，可适当放宽；预算用于控制连续任务的请求节奏',
          value: settings.webSearchDirectLowRiskPerWindow,
          min: 1,
          max: 20,
          onChanged: (v) => _notifier.setWebSearchDirectLowRiskPerWindow(v),
        ),
        const SizedBox(height: 4),
        budgetSlider(
          label: '高风险引擎每 10 分钟搜索上限'
              '（搜狗/百度/夸克，当前 ${settings.webSearchDirectHighRiskPerWindow} 次）',
          hint: '风控激进，默认 4 次"细水长流"——偶尔贡献高质量结果，'
              '避免连续请求被判定机器行为而封禁',
          value: settings.webSearchDirectHighRiskPerWindow,
          min: 1,
          max: 6,
          onChanged: (v) => _notifier.setWebSearchDirectHighRiskPerWindow(v),
        ),
                if (enabled.isEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    '⚠️ 所有直连引擎均已关闭：端侧直连不可用。',
                    style: TextStyle(
                        fontSize: 12, color: Colors.orange.shade800),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}
