import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/model_info.dart';
import '../services/download_service.dart';
import '../services/model_storage_service.dart';

class DownloadNotifier extends StateNotifier<Map<String, DownloadTask>> {
  final DownloadService _downloadService;

  DownloadNotifier(this._downloadService) : super({});

  /// Initialize download state for already cached models (e.g., after scan or restart)
  Future<void> initCachedModels(List<ModelConfig> models) async {
    final storage = ModelStorageService();
    final updatedState = Map<String, DownloadTask>.from(state);
    
    for (final model in models) {
      // Skip if already tracked
      if (updatedState.containsKey(model.id)) continue;
      
      // Check if file exists on disk
      final isCached = await storage.isModelCached(model.id);
      if (isCached) {
        updatedState[model.id] = DownloadTask(
          modelId: model.id,
          state: DownloadState.completed,
          totalBytes: model.sizeBytes,
          downloadedBytes: model.sizeBytes,
        );
      }
    }
    
    state = updatedState;
  }

  Future<void> startDownload(ModelConfig model) async {
    final existing = state[model.id];
    if (existing != null && existing.state == DownloadState.completed) return;

    // Create initial task for tracking — pass it to the service so Dio mutates THIS same object.
    final initialTask = DownloadTask(
      modelId: model.id,
      state: DownloadState.downloading,
      totalBytes: model.sizeBytes,
    );
    state = {...state, model.id: initialTask};

    await _downloadService.download(
      model,
      existingTask: initialTask, // <-- reuse the same task object
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

  /// Check if model is cached (using persistent storage)
  Future<bool> isModelCached(String modelId) async {
    final storage = ModelStorageService();
    return await storage.isModelCached(modelId);
  }

  /// Get total size of cached models
  Future<int> getTotalCachedSize() async {
    final storage = ModelStorageService();
    return await storage.getTotalCachedSize();
  }

  /// Get available space (stub - returns fixed value)
  Future<int> getAvailableSpace() async {
    try {
      return 64 * 1024 * 1024 * 1024;
    } catch (_) {
      return 0;
    }
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
