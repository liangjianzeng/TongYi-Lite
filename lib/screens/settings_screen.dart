// ============================================================
// Settings Screen — 设置页面（Tab 布局）
// 
// Tab 1: 📦 模型管理 - 下载、缓存模型列表
// Tab 2: 🧠 推理引擎 - 模型加载、日志查看
// Tab 3: ℹ️ 关于 - 应用信息
// ============================================================

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/model_info.dart';
import '../models/model_catalog.dart';
import '../providers/index.dart';
import '../providers/settings_provider.dart';
import '../services/model_manager.dart';
import 'inference_log_screen.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  late final Future<List<ModelConfig>> _catalogFuture;
  bool _autoScanned = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _catalogFuture = loadModelCatalog();
    _tabController.addListener(_onTabChanged);
    // 默认停在「模型管理」(index 0)，首帧后自动扫描一次本地已有的 .gguf。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_tabController.index == 0) _triggerAutoScan();
    });
  }

  void _onTabChanged() {
    if (_tabController.index == 0) _triggerAutoScan();
  }

  /// 首次进入「模型管理」时自动扫描本地模型一次，避免每次手工点。
  void _triggerAutoScan() {
    if (_autoScanned) return;
    _autoScanned = true;
    _scanModels(silent: true);
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
        title: const Text('设置'),
        centerTitle: true,
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(icon: Icon(Icons.storage), text: '模型管理'),
            Tab(icon: Icon(Icons.memory), text: '推理引擎'),
            Tab(icon: Icon(Icons.info), text: '关于'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildModelManagementTab(),
          const _InferenceEngineTab(),
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
      padding: const EdgeInsets.all(16),
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
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              ),
            ),
          ),
          const SizedBox(height: 8),
          const Center(
            child: Text(
              '首次进入自动扫描本地模型，也可手动重新扫描',
              style: TextStyle(fontSize: 11, color: Colors.grey),
              textAlign: TextAlign.center,
            ),
          ),

          const SizedBox(height: 16),

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
                  final order = <String, int>{};
                  for (var i = 0; i < catalog.length; i++) order[catalog[i].id] = i;
                  final models = List<ModelConfig>.from(catalog)
                    ..sort((a, b) {
                      final ca = tasks[a.id]?.state == DownloadState.completed;
                      final cb = tasks[b.id]?.state == DownloadState.completed;
                      if (ca != cb) return ca ? -1 : 1;
                      if (a.recommended != b.recommended) {
                        return a.recommended ? -1 : 1;
                      }
                      return (order[a.id] ?? 0).compareTo(order[b.id] ?? 0);
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
          const _StorageInfoWidget(),
        ],
      ),
    );
  }

  Widget _buildModelCard(ModelConfig model) {
    return Consumer(
      builder: (context, ref, _) {
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

        return Card(
          margin: const EdgeInsets.only(bottom: 12),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(modelTypeIcon(model.type)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        model.name,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ),
                    _buildStatusChip(displayState),
                  ],
                ),

                const SizedBox(height: 8),
                Row(
                  children: [
                    Text('${modelTypeIcon(model.type)} ${_formatSize(model.sizeBytes)}'),
                    if (isCached) ...[
                      const SizedBox(width: 12),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.green.shade100,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text('已缓存', style: TextStyle(fontSize: 12, color: Colors.green)),
                      ),
                    ],
                    if (model.recommended) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.blue.shade100,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text('推荐', style: TextStyle(fontSize: 12, color: Colors.blue)),
                      ),
                    ],
                  ],
                ),

                // Progress bar for downloading models
                if (task != null && task.state == DownloadState.downloading) ...[
                  const SizedBox(height: 8),
                  LinearProgressIndicator(value: task.progress, minHeight: 6),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('${task.downloadedDisplay} / ${task.totalDisplay}', style: const TextStyle(fontSize: 12)),
                      Text(task.progressPercent, style: const TextStyle(fontSize: 12)),
                    ],
                  ),
                ],

                // Error message
                if (task?.errorMessage != null && task!.state == DownloadState.failed) ...[
                  const SizedBox(height: 8),
                  Text('错误: ${task.errorMessage}', style: TextStyle(color: Colors.red.shade600, fontSize: 12)),
                ],

                const SizedBox(height: 12),
                _buildActionButtons(model, task, isCached),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildActionButtons(ModelConfig model, DownloadTask? task, bool isCached) {
    final activeState = task?.state ?? DownloadState.idle;
    final manager = ref.read(modelManagerProvider.notifier);

    switch (activeState) {
      case DownloadState.downloading:
        return OutlinedButton.icon(
          onPressed: () => ref.read(downloadNotifierProvider.notifier).pauseDownload(model.id),
          icon: const Icon(Icons.pause, size: 18),
          label: const Text('暂停'),
        );

      case DownloadState.paused:
        return OutlinedButton.icon(
          onPressed: () => ref.read(downloadNotifierProvider.notifier).resumeDownload(model.id),
          icon: const Icon(Icons.play_arrow, size: 18),
          label: const Text('继续'),
        );

      case DownloadState.failed:
        return OutlinedButton.icon(
          onPressed: () => ref.read(downloadNotifierProvider.notifier).startDownload(model),
          icon: const Icon(Icons.refresh, size: 18),
          label: const Text('重试'),
          style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
        );

      case DownloadState.completed:
      default:
        if (isCached) {
          final isLoading = manager.isLoading;
          final isLoadedHere = manager.modelId == model.id && manager.isLoadedState;

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
              ] else if (isLoading) ...[
                const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
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
                  onPressed: manager.isBusy ? null : () => _handleLoadModel(model),
                  icon: const Icon(Icons.memory, size: 18),
                  label: const Text('加载到内存'),
                ),
              ],

              const SizedBox(width: 8),

              // Unload button
              if (isLoadedHere) ...[
                OutlinedButton.icon(
                  onPressed: manager.isBusy ? null : () async {
                    await ref.read(modelManagerProvider.notifier).unloadModel();
                  },
                  icon: const Icon(Icons.close, size: 18),
                  label: const Text('卸载'),
                  style: OutlinedButton.styleFrom(foregroundColor: Colors.orange.shade700),
                ),
              ],

              // Delete button
              OutlinedButton.icon(
                onPressed: () {
                  ref.read(downloadNotifierProvider.notifier).deleteModel(model.id);
                },
                icon: const Icon(Icons.delete, size: 18),
                label: const Text('删除'),
                style: OutlinedButton.styleFrom(foregroundColor: Colors.red.shade700),
              ),
            ],
          );
        } else {
          return ElevatedButton.icon(
            onPressed: () => ref.read(downloadNotifierProvider.notifier).startDownload(model),
            icon: const Icon(Icons.download, size: 18),
            label: const Text('下载'),
          );
        }
    }
  }

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

  Future<void> _scanModels({bool silent = false}) async {
    final manager = ModelManager();
    final cachedIds = await manager.scanExistingModels();

    if (!mounted) return;

    if (cachedIds.isEmpty) {
      if (!silent) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('未找到已下载的模型文件'), backgroundColor: Colors.orange),
        );
      }
      return;
    }

    final allModels = await loadModelCatalog();
    final foundModels = allModels.where((m) => cachedIds.contains(m.id)).toList();

    if (foundModels.isNotEmpty) {
      await ref.read(downloadNotifierProvider.notifier).initCachedModels(foundModels);

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(silent
              ? '已自动恢复 ${foundModels.length} 个本地模型'
              : '已恢复 ${foundModels.length} 个模型状态'),
          backgroundColor: Colors.green,
          duration: const Duration(seconds: 2),
        ),
      );
    } else if (!silent) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('找到文件但未匹配到已知模型，请检查模型ID'), backgroundColor: Colors.orange),
      );
    }
  }

  Future<void> _handleLoadModel(ModelConfig model) async {
    final manager = ref.read(modelManagerProvider.notifier);

    if (manager.isLoadedState && manager.modelId != model.id) {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('切换模型'),
          content: Text('${model.name} 将替换当前运行的 ${manager.currentModelName}，是否继续？'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
            ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('切换')),
          ],
        ),
      );
      if (confirm != true) return;
    }

    // Mark generating so the UI reflects loading state across all screens.
    ref.read(isGeneratingProvider.notifier).state = true;

    final ok = await manager.loadModel(model.id);

    // Always reset generating flag when load finishes (success or failure).
    ref.read(isGeneratingProvider.notifier).state = false;

    if (!mounted) return;

    if (ok) {
      // Sync currentModelIdProvider so chat screen uses the correct model.
      ref.read(currentModelIdProvider.notifier).state = model.id;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('✅ ${model.name} 已加载到内存'), backgroundColor: Colors.green),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('❌ 模型加载失败，请查看"推理引擎"标签页的日志'), backgroundColor: Colors.red),
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

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ---- GPU 加速设置卡片 ----
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildSectionHeader('⚙️ GPU 加速（Vulkan）', context),
                  const SizedBox(height: 12),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('启用 GPU 加速'),
                    subtitle: const Text('关闭后使用纯 CPU 推理；设备无 Vulkan 驱动时自动回落 CPU'),
                    value: gpuSettings.enableGpu,
                    onChanged: (v) => gpuNotifier.setEnableGpu(v),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Expanded(
                        child: Slider(
                          value: gpuSettings.gpuLayers.toDouble(),
                          min: 0,
                          max: 100,
                          divisions: 100,
                          label: '${gpuSettings.gpuLayers}',
                          onChanged: gpuSettings.enableGpu
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
                            color: gpuSettings.enableGpu
                                ? null
                                : Colors.grey.shade500,
                          ),
                        ),
                      ),
                    ],
                  ),
                  // 关 GPU 时禁用层数设置并给出提示
                  if (!gpuSettings.enableGpu)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        'GPU 已关闭，层数设置不生效（纯 CPU）',
                        style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                      ),
                    ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // ---- 思考模式设置卡片 ----
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildSectionHeader('🧠 思考模式（Thinking）', context),
                  const SizedBox(height: 12),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('启用思考模式'),
                    subtitle: const Text(
                        '开启后模型先输出推理过程再给答案（更慢）；关闭则直接作答（更快），仅对 Qwen3 等思考模型生效'),
                    value: gpuSettings.enableThinking,
                    onChanged: (v) {
                      gpuNotifier.setEnableThinking(v);
                      // 立即同步到原生层，无需重新加载模型。
                      ref.read(inferenceServiceProvider).setEnableThinking(v);
                    },
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // ---- 上下文大小设置卡片 ----
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
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
                          onChanged: (v) => gpuNotifier.setContextSize(v.round()),
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

          const SizedBox(height: 16),

          // ---- 引擎状态卡片 ----
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildSectionHeader('🧠 推理引擎状态', context),
                  const SizedBox(height: 12),
                  
                  // Status row
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('当前状态:', style: TextStyle(fontSize: 14, color: Colors.grey.shade700)),
                      _buildLifecycleChipFromState(modelState),
                    ],
                  ),
                  
                  if (modelState.modelName != null && modelState.modelName!.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('当前模型:', style: TextStyle(fontSize: 14, color: Colors.grey.shade700)),
                        Text(modelState.modelName!, style: const TextStyle(fontWeight: FontWeight.w500)),
                      ],
                    ),
                  ],
                  
                  if (modelState.errorMessage != null && modelState.errorMessage!.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('错误:', style: TextStyle(fontSize: 14, color: Colors.red)),
                        Expanded(
                          child: Text(
                            modelState.errorMessage!,
                            style: const TextStyle(fontSize: 12, color: Colors.red),
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

          const SizedBox(height: 16),

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
                      MaterialPageRoute(builder: (_) => const InferenceLogScreen()),
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
                      ? () async {
                          await ref.read(modelManagerProvider.notifier).unloadModel();
                        }
                      : null,
                  icon: const Icon(Icons.close),
                  label: const Text('卸载模型'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.red.shade700,
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
                await ref.read(modelManagerProvider.notifier).loadModel(modelState.modelId!);
              },
              icon: const Icon(Icons.refresh),
              label: const Text('重试加载'),
            ),
          ],

          const SizedBox(height: 24),

          // ---- 最近日志摘要 ----
          _buildSectionHeader('📋 最近日志', context),
          const SizedBox(height: 8),
          
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

}

Widget _buildSectionHeader(String title, BuildContext context) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(
      title,
      style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
    ),
  );
}

// =========================================================================
// Tab 3: 关于
// =========================================================================

class _buildAboutTab extends StatelessWidget {
  const _buildAboutTab();

  @override
  Widget build(BuildContext context) {
    return const SingleChildScrollView(
      padding: EdgeInsets.all(16),
      child: Column(
        children: [
          _AboutCard(),
          SizedBox(height: 16),
          _LicenseCard(),
        ],
      ),
    );
  }
}

class _AboutCard extends StatelessWidget {
  const _AboutCard();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            const Icon(Icons.auto_awesome, size: 64, color: Colors.indigo),
            const SizedBox(height: 16),
            const Text(
              'TongYi-Lite',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            const Text(
              '端侧离线 AI 智能体',
              style: TextStyle(color: Colors.grey, fontSize: 14),
            ),
            const SizedBox(height: 16),
            _AboutRow(label: '版本', value: '0.1.0'),
            _AboutRow(label: '推理引擎', value: 'llama.cpp b1017+'),
            _AboutRow(label: '框架', value: 'Flutter 3.x'),
            _AboutRow(label: '平台', value: 'Android API 33+'),
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
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('开源许可', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const Text('MIT License'),
            const SizedBox(height: 8),
            const Text('Copyright (c) 2024 TongYi-Lite Contributors'),
            const SizedBox(height: 16),
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
  const _StorageInfoWidget();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FutureBuilder<Map<String, dynamic>>(
      future: _loadStorageInfo(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Center(child: Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator()));
        }

        final info = snapshot.data!;
        final cachedModels = info['cachedModels'] as List? ?? [];
        final totalBytes = info['totalBytes'] as int? ?? 0;

        return Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (cachedModels.isNotEmpty) ...[
                  Text('已缓存模型 (${_formatSize(totalBytes)}):', style: const TextStyle(fontWeight: FontWeight.w500)),
                  const SizedBox(height: 8),
                  ...(cachedModels as List<Map<String, dynamic>>)
                      .map((m) => Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Row(
                              children: [
                                const Icon(Icons.check_circle, size: 16, color: Colors.green),
                                const SizedBox(width: 8),
                                Expanded(child: Text(m['name'] as String)),
                                Text(_formatSize(m['sizeBytes'] as int), style: TextStyle(fontSize: 12, color: Colors.grey)),
                              ],
                            ),
                          ))
                      .toList(),
                  const Divider(height: 24),
                ],
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('总占用:', style: TextStyle(fontWeight: FontWeight.w600)),
                    Text(_formatSize(totalBytes), style: const TextStyle(fontWeight: FontWeight.bold)),
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
    if (bytes >= 1024 * 1024 * 1024) return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(1)} GB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(0)} MB';
  }

  Future<Map<String, dynamic>> _loadStorageInfo() async {
    final cachedModels = <Map<String, dynamic>>[];
    int totalBytes = 0;

    try {
      final appDir = await getApplicationDocumentsDirectory();
      final modelsDir = Directory('${appDir.path}/models');
      if (await modelsDir.exists()) {
        for (final entity in await modelsDir.list().toList()) {
          if (entity is File && entity.path.endsWith('.gguf')) {
            final fileName = p.basenameWithoutExtension(entity.path);
            final sizeBytes = await entity.length();

            String displayName = fileName;
            try {
              final allModels = await loadModelCatalog();
              final match = allModels.where((m) => m.id == fileName).toList();
              if (match.isNotEmpty) displayName = match.first.name;
            } catch (_) {}

            cachedModels.add({'name': displayName, 'id': fileName, 'sizeBytes': sizeBytes});
            totalBytes += sizeBytes;
          }
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
        decoration: BoxDecoration(color: Colors.grey.shade100, borderRadius: BorderRadius.circular(8)),
        child: const Center(
          child: Column(
            children: [
              Icon(Icons.help_outline, size: 48, color: Colors.grey),
              SizedBox(height: 8),
              Text('暂无日志', style: TextStyle(color: Colors.grey)),
              SizedBox(height: 4),
              Text('点击"加载到内存"后开始记录', style: TextStyle(fontSize: 12, color: Colors.grey)),
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
          } else if (log.contains('失败') || log.contains('错误') || log.contains('ERROR')) {
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
                    style: TextStyle(fontSize: 12, color: color.withValues(alpha: 0.9), fontFamily: 'monospace'),
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
