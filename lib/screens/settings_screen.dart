import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/model_info.dart';
import '../providers/index.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  Future<Map<String, dynamic>> _loadStorageInfo() async {
    final allModels = await loadModelCatalog();
    final cachedModels = <Map<String, dynamic>>[];
    int totalBytes = 0;

    for (final model in allModels) {
      final isCached = await ref.read(downloadNotifierProvider.notifier).isModelCached(model.id);
      if (isCached) {
        final sizeBytes = await ref.read(modelManagerProvider.notifier).getCachedSize(model.id);
        cachedModels.add({
          'name': model.name,
          'id': model.id,
          'sizeBytes': sizeBytes,
        });
        totalBytes += sizeBytes;
      }
    }

    return {
      'cachedModels': cachedModels,
      'totalBytes': totalBytes,
    };
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('设置'),
        centerTitle: true,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildSectionHeader('📦 模型管理'),
          const SizedBox(height: 8),

          FutureBuilder<List<ModelConfig>>(
            future: loadModelCatalog(),
            builder: (context, snapshot) {
              if (!snapshot.hasData || snapshot.data!.isEmpty) {
                return const Center(child: CircularProgressIndicator());
              }
              final models = snapshot.data!;
              return Column(
                children: [
                  ...models.map((model) => _buildModelCard(model)),
                ],
              );
            },
          ),

          const SizedBox(height: 24),

          _buildSectionHeader('⬇️ 下载中的任务'),
          Consumer(
            builder: (context, ref, _) {
              final tasks = ref.watch(downloadNotifierProvider);
              final activeTasks = tasks.entries
                  .where((e) =>
                      e.value.state == DownloadState.downloading ||
                      e.value.state == DownloadState.paused)
                  .toList();

              if (activeTasks.isEmpty) return const SizedBox.shrink();

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ...activeTasks
                      .map((entry) => _buildActiveDownloadCard(entry.value)),
                ],
              );
            },
          ),

          const SizedBox(height: 24),

          FutureBuilder<Map<String, dynamic>>(
            future: _loadStorageInfo(),
            builder: (context, snapshot) {
              if (!snapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final info = snapshot.data!;
              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildSectionHeader('💾 存储信息'),
                      const SizedBox(height: 8),

                      if (info['cachedModels'] != null &&
                          (info['cachedModels'] as List).isNotEmpty) ...[
                        Text(
                          '已缓存模型 (${_formatSize(info['totalBytes'])}):',
                          style: const TextStyle(fontWeight: FontWeight.w500),
                        ),
                        const SizedBox(height: 8),
                        ...(info['cachedModels'] as List<Map<String, dynamic>>)
                            .map((m) => Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 4),
                                  child: Row(
                                    children: [
                                      Icon(Icons.check_circle, size: 16, color: Colors.green),
                                      const SizedBox(width: 8),
                                      Expanded(child: Text(m['name'] as String)),
                                      Text(_formatSize(m['sizeBytes']), style: TextStyle(fontSize: 12, color: Colors.grey)),
                                    ],
                                  ),
                                ))
                            .toList(),
                        const Divider(height: 24),

                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text('总占用:', style: TextStyle(fontWeight: FontWeight.w600)),
                            Text(_formatSize(info['totalBytes']),
                                style: const TextStyle(fontWeight: FontWeight.bold)),
                          ],
                        ),
                      ] else ...[
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.folder_off_outlined, color: Colors.grey.shade400),
                            const SizedBox(width: 8),
                            Text('暂无已缓存模型', style: TextStyle(color: Colors.grey)),
                          ],
                        ),
                      ],

                      const SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('可用空间:', style: TextStyle(fontSize: 14)),
                          Text('-- GB',
                              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                        ],
                      ),

                      const SizedBox(height: 24),
                      _buildSectionHeader('🧠 推理引擎'),
                      Consumer(
                        builder: (context, ref, _) {
                          final lifecycle = ref.watch(modelManagerProvider);
                          return Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text('状态:', style: TextStyle(fontSize: 14)),
                              _buildLifecycleChip(lifecycle),
                            ],
                          );
                        },
                      ),
                    ],
                  ),
                ),
              );
            },
          ),

          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
      ),
    );
  }

  Widget _buildModelCard(ModelConfig model) {
    return FutureBuilder<bool>(
      future: ref.read(downloadNotifierProvider.notifier).isModelCached(model.id),
      builder: (context, snapshot) {
        final isCached = snapshot.data ?? false;
        final task = ref.watch(downloadTaskProvider(model.id));

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

  Widget _buildActiveDownloadCard(DownloadTask task) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('正在下载: ${task.modelId}',
                      style: const TextStyle(fontWeight: FontWeight.w500)),
                  const SizedBox(height: 4),
                  LinearProgressIndicator(value: task.progress, minHeight: 4),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('${task.downloadedDisplay} / ${task.totalDisplay}', style: const TextStyle(fontSize: 12)),
                      Text(task.progressPercent, style: const TextStyle(fontSize: 12)),
                    ],
                  ),
                ],
              ),
            ),
            IconButton(
              icon: Icon(task.state == DownloadState.downloading ? Icons.pause : Icons.play_arrow),
              onPressed: () {
                if (task.state == DownloadState.downloading) {
                  ref.read(downloadNotifierProvider.notifier).pauseDownload(task.modelId);
                } else {
                  ref.read(downloadNotifierProvider.notifier).resumeDownload(task.modelId);
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActionButtons(ModelConfig model, DownloadTask? task, bool isCached) {
    final activeState = task?.state ?? DownloadState.idle;

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
          return Row(
            children: [
              ElevatedButton.icon(
                onPressed: () async {
                  final ok = await ref.read(modelManagerProvider.notifier).loadModel(model.id);
                  if (!mounted) return;
                  if (ok) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('✅ ${model.name} 已加载到内存')),
                    );
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('❌ 模型加载失败'), backgroundColor: Colors.red),
                    );
                  }
                },
                icon: const Icon(Icons.memory, size: 18),
                label: const Text('加载到内存'),
              ),
              const SizedBox(width: 8),
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

  Widget _buildLifecycleChip(ModelLifecycleState lifecycle) {
    Color color;
    String label;
    switch (lifecycle) {
      case ModelLifecycleState.idle:
        color = Colors.grey;
        label = '未加载';
        break;
      case ModelLifecycleState.loading:
        color = Colors.blue;
        label = '加载中...';
        break;
      case ModelLifecycleState.loaded:
        color = Colors.green;
        label = '已加载';
        break;
      case ModelLifecycleState.unloading:
        color = Colors.orange;
        label = '卸载中...';
        break;
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

  String _formatSize(int bytes) {
    final mb = bytes / (1024 * 1024);
    if (mb >= 1024) return '${(mb / 1024).toStringAsFixed(1)} GB';
    return '${mb.toStringAsFixed(0)} MB';
  }
}
