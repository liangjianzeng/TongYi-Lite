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

import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import '../models/model_info.dart';
import '../models/model_catalog.dart';
import '../models/api_model.dart';
import '../providers/index.dart';
import '../providers/shared_providers.dart' show openAiServiceProvider;
import '../providers/settings_provider.dart';
import '../services/settings_service.dart';
import '../services/model_manager.dart';
import 'inference_log_screen.dart';

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
  late final Future<List<ModelConfig>> _catalogFuture;

  /// 存储占用信息的重建 tick：任一模型下载完成后自增，迫使 _StorageInfoWidget
  /// 重新拉取磁盘占用（它用 FutureBuilder 只拉一次）。
  int _storageTick = 0;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
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
        title: const Text('设置'),
        centerTitle: true,
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(icon: Icon(Icons.storage), text: '模型管理'),
            Tab(icon: Icon(Icons.cloud), text: 'API 接入'),
            Tab(icon: Icon(Icons.memory), text: '推理引擎'),
            Tab(icon: Icon(Icons.info), text: '关于'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildModelManagementTab(),
          const _ApiTab(),
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
                padding:
                    const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
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
          margin: const EdgeInsets.only(bottom: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: isCached
                ? BorderSide(color: Colors.blue.shade300, width: 1.5)
                : BorderSide(color: Colors.grey.shade300, width: 1),
          ),
          color: isCached ? Colors.blue.shade50.withValues(alpha: 0.4) : null,
          elevation: isCached ? 1.5 : 0,
          child: Padding(
            padding: const EdgeInsets.all(16),
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
                                fontSize: 15, fontWeight: FontWeight.w600),
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

                    // Progress bar for downloading models
                    if (task != null &&
                        task.state == DownloadState.downloading) ...[
                      const SizedBox(height: 8),
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
                      foregroundColor: Colors.orange.shade700),
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
                  ),
                  const SizedBox(height: 16),
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
                      style:
                          TextStyle(fontSize: 12, color: Colors.grey.shade600),
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

          // ---- MTP 加速全局开关卡片 ----
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildToggleTitle(
                    'MTP 加速（端侧推测解码）',
                    gpuSettings.enableMtpFeature,
                    gpuNotifier.setEnableMtpFeature,
                    subtitle: '默认关闭；开启后在模型卡片配置各模型 MTP（仅高端机按需开启）',
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
      style: Theme.of(context)
          .textTheme
          .titleMedium
          ?.copyWith(fontWeight: FontWeight.bold),
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
        Text(subtitle,
            style: const TextStyle(fontSize: 12, color: Colors.grey)),
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

// About 页版本号：集中式常量，与 android/app/build.gradle.kts 的
// versionName（0.1.6）保持同步。离线沙箱无法下载 package_info_plus 的
// AGP 依赖，故不引插件动态读取，直接用此常量。
const _appVersion = '0.1.6';

/// GitHub 项目主页地址（README 介绍与使用说明）。
const _githubUrl = 'https://github.com/liangjianzeng/TongYi-Lite';

/// 通过系统外部浏览器打开 GitHub README 页面。
Future<void> _openGithub(BuildContext context) async {
  final uri = Uri.parse(_githubUrl);
  final launched =
      await launchUrl(uri, mode: LaunchMode.externalApplication);
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
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('开源许可', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const Text('MIT License'),
            const SizedBox(height: 8),
            const Text('Copyright (c) 2026 TongYi-Lite Contributors'),
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
  const _StorageInfoWidget({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FutureBuilder<Map<String, dynamic>>(
      future: _loadStorageInfo(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Center(
              child: Padding(
                  padding: EdgeInsets.all(16),
                  child: CircularProgressIndicator()));
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

            cachedModels.add(
                {'name': displayName, 'id': fileName, 'sizeBytes': sizeBytes});
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
              const SizedBox(height: 16),
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

class _ApiTab extends ConsumerWidget {
  const _ApiTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final apiModels = settings.apiModels;
    final activeId = settings.activeApiModelId;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
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
          const SizedBox(height: 16),
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
              padding: const EdgeInsets.all(16),
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
        ],
      ),
    );
  }

  Widget _buildApiModelCard(
      BuildContext context, WidgetRef ref, ApiModelConfig cfg, bool isActive) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
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
              'max_tokens=${cfg.effectiveMaxTokens}',
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
