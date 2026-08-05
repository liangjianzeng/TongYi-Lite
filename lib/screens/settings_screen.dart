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
import '../services/settings_service.dart';
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
        // 监听模型生命周期状态：加载/卸载后会触发卡片重建，刷新"已加载/卸载"按钮。
        ref.watch(modelManagerProvider);
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
                      child: _ModelNameField(
                        // 按 modelId 绑定独立 State：列表按下载/推荐动态排序重排时，
                        // 名称输入框跟随其所属模型移动，不会因位置复用而串到别的模型。
                        key: ValueKey(model.id),
                        modelId: model.id,
                        defaultName: model.name,
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
    final ms = ref.watch(modelManagerProvider);

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
          final isLoading = ms.isLoading;
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
                  onPressed: manager.isBusy ? null : () => unloadModelAndNotify(ref, context, model.name),
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
    final isGenerating = ref.read(isGeneratingProvider);

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

    // 2) 若正在推理，必须先停止生成，否则卸载模型会令原生引擎崩溃（红屏）。
    if (ref.read(isGeneratingProvider)) {
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
                  _buildToggleTitle(
                    'GPU 加速',
                    gpuSettings.enableGpu,
                    gpuNotifier.setEnableGpu,
                    subtitle: '按所选后端卸载计算到 GPU',
                  ),
                  const SizedBox(height: 16),
                  // GPU 后端选择：auto / opencl / vulkan。
                  // CPU 不单列——关闭 GPU 即纯 CPU，自动模式无 GPU 时也会回落 CPU。
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text('后端', style: TextStyle(fontSize: 13, color: Colors.grey.shade700)),
                  ),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(
                        value: 'auto',
                        label: Text('自动'),
                        icon: Icon(Icons.auto_awesome, size: 16),
                      ),
                      ButtonSegment(
                        value: 'opencl',
                        label: Text('OpenCL'),
                        icon: Icon(Icons.speed, size: 16),
                      ),
                      ButtonSegment(
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
                    gpuSettings.enableGpu
                        ? _gpuBackendHint(gpuSettings.gpuBackend)
                        : 'GPU 已关闭（纯 CPU）',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                  ),
                  const SizedBox(height: 16),
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
                  _buildToggleTitle(
                    '思考模式',
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
                      ? () => unloadModelAndNotify(ref, context, modelState.modelName ?? '当前模型')
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

  // ---- GPU 后端辅助 ----

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
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(
      title,
      style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
    ),
  );
}

/// 标题行内嵌开关：标题 + 右侧 Switch，可选副标题。用于节省卡片纵向空间。
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
          Text(
            title,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
      if (subtitle != null) ...[
        const SizedBox(height: 4),
        Text(subtitle, style: const TextStyle(fontSize: 12, color: Colors.grey)),
      ],
    ],
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
            _AboutRow(label: '版本', value: '0.1.3'),
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

// =========================================================================
// 自定义模型显示名称输入框（可选）
// =========================================================================

/// 自定义模型显示名称输入框（可选）。
/// 用 StatefulWidget 持有独立的 TextEditingController，
/// 使下载进度频繁重建时不会丢失输入焦点/光标。
/// 模型名内联编辑框（替换原独立「自定义名称」行）。
/// 直接显示在模型卡片标题位置：有自定义名则显示自定义名，否则显示模型配置名
/// （不持久化，等同于「未改名」）；点击即可编辑，清空则回落到配置名。
class _ModelNameField extends ConsumerStatefulWidget {
  final String modelId;
  final String defaultName;
  const _ModelNameField({super.key, required this.modelId, required this.defaultName});
  @override
  ConsumerState<_ModelNameField> createState() => _ModelNameFieldState();
}

class _ModelNameFieldState extends ConsumerState<_ModelNameField> {
  late final TextEditingController _controller;
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final custom = ref.watch(modelDisplayNameProvider)[widget.modelId];
    final name = custom ?? '';
    // 首次构建时把已存自定义名（或回落到配置名）回填；后续不覆盖用户输入。
    if (!_initialized) {
      _initialized = true;
      _controller.text = name.isEmpty ? widget.defaultName : name;
    }
    final isCustom = name.isNotEmpty;
    return TextField(
      controller: _controller,
      decoration: InputDecoration(
        isDense: true,
        border: InputBorder.none,
        hintText: widget.defaultName,
        hintStyle: TextStyle(color: Colors.grey.shade500, fontWeight: FontWeight.w500),
        suffixIcon: isCustom
            ? IconButton(
                icon: const Icon(Icons.clear, size: 16),
                tooltip: '清除自定义名称，恢复配置名',
                onPressed: () {
                  _controller.text = widget.defaultName;
                  ref.read(modelDisplayNameProvider.notifier).setName(widget.modelId, '');
                },
              )
            : null,
      ),
      style: Theme.of(context).textTheme.titleSmall,
      maxLines: 1,
      onChanged: (v) {
        final trimmed = v.trim();
        if (trimmed.isEmpty) {
          // 清空 → 回落配置名，且不持久化覆盖。
          _controller.text = widget.defaultName;
          ref.read(modelDisplayNameProvider.notifier).setName(widget.modelId, '');
        } else if (trimmed == widget.defaultName) {
          // 与配置名相同 → 视为未改名，不存储覆盖。
          ref.read(modelDisplayNameProvider.notifier).setName(widget.modelId, '');
        } else if (trimmed != name) {
          ref.read(modelDisplayNameProvider.notifier).setName(widget.modelId, trimmed);
        }
      },
    );
  }
}

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
              const SizedBox(height: 16),
              Text('正在加载模型…', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(modelName, style: const TextStyle(fontSize: 12, color: Colors.grey)),
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
                      style: TextStyle(fontSize: 12, color: Colors.blue.shade800),
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
      content: Text(ok
          ? '✅ 已卸载 $modelName，已释放内存'
          : '❌ 卸载失败，请重试'),
      backgroundColor: ok ? Colors.green : Colors.red,
      duration: const Duration(seconds: 2),
    ),
  );
}
