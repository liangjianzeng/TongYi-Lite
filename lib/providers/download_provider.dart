import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/model_info.dart';
import '../services/download_service.dart';

class DownloadNotifier extends StateNotifier<Map<String, DownloadTask>> {
  final DownloadService _downloadService;

  DownloadNotifier(this._downloadService) : super({});

  Future<void> startDownload(ModelConfig model) async {
    final existing = state[model.id];
    if (existing != null && existing.state == DownloadState.completed) return;

    await _downloadService.download(
      model,
      onProgress: (task) {
        state = {...state, task.modelId: task};
      },
    );
  }

  Future<void> pauseDownload(String modelId) async {
    final task = state[modelId];
    if (task == null || task.state != DownloadState.downloading) return;

    await _downloadService.pause(modelId);
    state = {...state, modelId: task.copyWith(state: DownloadState.paused)};
  }

  Future<void> resumeDownload(String modelId) async {
    final existing = state[modelId];
    if (existing == null || existing.state != DownloadState.paused) return;

    // Save the paused progress so we can restore it after download() creates a fresh task.
    final savedProgress = existing.downloadedBytes;

    await _downloadService.resume(modelId, onProgress: (task) {
      // If this is a resume and the new task's progress is less than what we had,
      // restore from disk — the .tmp file already contains saved data.
      if (savedProgress > 0 && task.downloadedBytes < savedProgress) {
        task = task.copyWith(downloadedBytes: savedProgress);
      }
      state = {...state, task.modelId: task};
    });
  }

  Future<void> cancelDownload(String modelId) async {
    await _downloadService.cancel(modelId);
    state = {...state, modelId: DownloadTask(modelId: modelId)};
  }

  Future<bool> deleteModel(String modelId) async {
    try {
      final task = state[modelId];
      if (task != null && task.state == DownloadState.downloading) {
        await _downloadService.cancel(modelId);
      }
      await _downloadService.deleteModel(modelId);
      state = {...state, modelId: DownloadTask(modelId: modelId)};
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> isModelCached(String modelId) async {
    final dir = await _getModelsDir();
    final file = File('${dir.path}/$modelId.gguf');
    return await file.exists();
  }

  Future<int> getTotalCachedSize() async {
    final dir = await _getModelsDir();
    if (!await dir.exists()) return 0;
    int total = 0;
    for (final entity in await dir.list().toList()) {
      if (entity is File && entity.path.endsWith('.gguf')) {
        total += await entity.length();
      }
    }
    return total;
  }

  Future<int> getAvailableSpace() async {
    try {
      return 64 * 1024 * 1024 * 1024;
    } catch (_) {
      return 0;
    }
  }

  Future<Directory> _getModelsDir() async {
    final appDir = await getApplicationDocumentsDirectory();
    return Directory('${appDir.path}/models');
  }
}

final downloadServiceProvider = Provider<DownloadService>((ref) => DownloadService());

final downloadNotifierProvider = StateNotifierProvider<DownloadNotifier, Map<String, DownloadTask>>((ref) {
  return DownloadNotifier(ref.watch(downloadServiceProvider));
});

final downloadTaskProvider = Provider.family<DownloadTask?, String>((ref, modelId) {
  final tasks = ref.watch(downloadNotifierProvider);
  return tasks[modelId];
});
