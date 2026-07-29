import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/model_info.dart';
import '../providers/download_provider.dart';
import '../services/inference_service.dart';
import '../services/model_manager.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final ModelManager _modelManager = ModelManager();

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
          _buildSectionHeader('模型管理'),
          const SizedBox(height: 8),

          ..._modelManager.allModels.map((model) => _buildModelCard(model)),

          const SizedBox(height: 24),

          Consumer(
            builder: (context, ref, _) {
              final tasks = ref.watch(downloadNotifierProvider);
              final activeTasks = tasks.entries
                  .where((e) => e.value.state == DownloadState.downloading ||
                      e.value.state == DownloadState.paused)
                  .toList();

              if (activeTasks.isEmpty) return const SizedBox.shrink();

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildSectionHeader('下载中的任务'),
                  const SizedBox(height: 8),
                  ...activeTasks.map((entry) => _buildActiveDownloadCard(entry.value)),
                ],
              );
            },
          ),

          const SizedBox(height: 24),

          Consumer(
            builder: (context, ref, _) {
              return FutureBuilder<int>(
                future: ref.read(downloadNotifierProvider.notifier).getTotalCachedSize(),
                builder: (context, snapshot) {
                  final cachedBytes = snapshot.data ?? 0;
                  return _buildStorageInfo(cachedBytes);
                },
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
    return Consumer(
      builder: (context, ref, _) {
        final task = ref.watch(downloadTaskProvider(model.id));

        return Card(
          margin: const EdgeInsets.only(bottom: 12),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(_modelTypeIcon(model.type)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        model.name,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ),
                    _buildStatusChip(task?.state ?? DownloadState.idle),
                  ],
                ),

                const SizedBox(height: 8),
                Row(
                  children: [
                    Text('${modelTypeIcon(model.type)} ${_formatSize(model.sizeBytes)}'),
                    if (model.recommended) ...[
                      const SizedBox(width: 12),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.green.shade100,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text('推荐', style: TextStyle(fontSize: 12, color: Colors.green)),
                      ),
                    ],
                  ],
                ),

                if (task != null && task.state == DownloadState.downloading) ...[
                  const SizedBox(height: 12),
                  LinearProgressIndicator(
                    value: task.progress,
                    minHeight: 6,
                  ),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('${task.downloadedDisplay} / ${task.totalDisplay}',
                          style: const TextStyle(fontSize: 12)),
                      Text(task.progressPercent, style: const TextStyle(fontSize: 12)),
                    ],
                  ),
                ],

                if (task?.errorMessage != null && task!.state == DownloadState.failed) ...[
                  const SizedBox(height: 8),
                  Text(
                    '错误: ${task.errorMessage}',
                    style: TextStyle(color: Colors.red.shade600, fontSize: 12),
                  ),
                ],

                const SizedBox(height: 12),
                _buildActionButtons(model, task),
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
                  Text('正在下载: ${task.modelId}', style: const TextStyle(fontWeight: FontWeight.w500)),
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
                  final model = _modelManager.getModel(task.modelId);
                  if (model != null) {
                    ref.read(downloadNotifierProvider.notifier).resumeDownload(task.modelId);
                  }
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActionButtons(ModelConfig model, DownloadTask? task) {
    final state = task?.state ?? DownloadState.idle;

    switch (state) {
      case DownloadState.idle:
        return ElevatedButton.icon(
          onPressed: () => ref.read(downloadNotifierProvider.notifier).startDownload(model),
          icon: const Icon(Icons.download, size: 18),
          label: const Text('下载'),
        );

      case DownloadState.downloading:
        return OutlinedButton.icon(
          onPressed: () => ref.read(downloadNotifierProvider.notifier).pauseDownload(model.
