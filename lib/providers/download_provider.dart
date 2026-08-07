import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/model_info.dart';
import '../services/download_service.dart';
import '../services/model_storage_service.dart' show ModelStorageService;

class DownloadNotifier extends StateNotifier<Map<String, DownloadTask>> {
  final DownloadService _downloadService;

  DownloadNotifier(this._downloadService) : super({});

  /// Mark the given models as cached.
  ///
  /// [models] are the entries a disk scan already proved to exist, so we trust
  /// that result instead of re-checking `isModelCached` (which only looks at
  /// the *primary* models dir and would drop files found in Download/DCIM).
  ///
  /// IMPORTANT: this used to `continue` whenever `state` already contained the
  /// id, which meant a stale `failed`/`idle`/cancelled entry could never be
  /// corrected — the model stayed on the "下载" button forever even though the
  /// .gguf was sitting on disk. Now only *in-flight* tasks are preserved.
  Future<void> initCachedModels(List<ModelConfig> models) async {
    final storage = ModelStorageService();
    final updated = Map<String, DownloadTask>.from(state);

    for (final model in models) {
      final existing = updated[model.id];
      // Never clobber a running/paused transfer.
      if (existing != null &&
          (existing.state == DownloadState.downloading ||
           existing.state == DownloadState.paused)) {
        continue;
      }
      if (existing != null && existing.state == DownloadState.completed) continue;

      // 视觉模型（text+mmproj 两文件形态）：磁盘扫描只证明了主 .gguf 存在，
      // 投影器 mmproj 必须也在主存储目录完整存在才能算「已缓存」，否则模型
      // 加载会因缺投影器失败。这里对 mmproj 模型改用 isFullyCached 复核。
      if (model.mmproj != null) {
        final onDisk = await storage.isFullyCached(model);
        if (!onDisk) {
          // 主 gguf 已下但缺 mmproj：不标记 completed，界面仍显示下载按钮，
          // 点击可只补下投影器（download() 会跳过已完整的 gguf）。
          updated[model.id] = DownloadTask(modelId: model.id);
          continue;
        }
      }

      updated[model.id] = DownloadTask(
        modelId: model.id,
        state: DownloadState.completed,
        totalBytes: model.sizeBytes,
        downloadedBytes: model.sizeBytes,
      );
    }

    state = updated;
  }

  /// Cheap consistency check: for every model already marked `completed`,
  /// verify the file is still on disk; drop the mark if the user deleted it
  /// externally. Only does `File.exists()` on known ids — no directory walk —
  /// so it is safe to call on every screen entry.
  Future<void> refreshCacheStatus(List<ModelConfig> models) async {
    final storage = ModelStorageService();
    final updated = Map<String, DownloadTask>.from(state);
    var changed = false;

    for (final model in models) {
      final existing = updated[model.id];
      if (existing == null) continue;
      if (existing.state == DownloadState.downloading ||
          existing.state == DownloadState.paused) {
        continue;
      }
      // Use the full-cache check (file exists AND size matches AND no stray
      // .tmp) so a truncated/partial `.gguf` is never reported as cached.
      final onDisk = await storage.isFullyCached(model);
      if (existing.state == DownloadState.completed && !onDisk) {
        updated[model.id] = DownloadTask(modelId: model.id);
        changed = true;
      } else if (existing.state != DownloadState.completed && onDisk) {
        updated[model.id] = DownloadTask(
          modelId: model.id,
          state: DownloadState.completed,
          totalBytes: model.sizeBytes,
          downloadedBytes: model.sizeBytes,
        );
        changed = true;
      }
    }

    if (changed) state = updated;
  }

  Future<void> startDownload(ModelConfig model) async {
    final existing = state[model.id];
    if (existing != null && existing.state == DownloadState.completed) return;
    // Don't restart a download that is already active (downloading/paused) here.
    if (existing != null &&
        (existing.state == DownloadState.downloading ||
         existing.state == DownloadState.paused)) {
      return;
    }
    // Only one model may download at a time globally — block a second start so
    // the service's capacity guard never throws an unhandled exception.
    final anyActive = state.values.any((t) => t.state == DownloadState.downloading);
    if (anyActive) return;

    // Create initial task for tracking — pass it to the service so Dio mutates THIS same object.
    final initialTask = DownloadTask(
      modelId: model.id,
      state: DownloadState.downloading,
      totalBytes: model.sizeBytes,
    );
    state = {...state, model.id: initialTask};

    try {
      await _downloadService.download(
        model,
        existingTask: initialTask, // <-- reuse the same task object
        onProgress: (task) {
          state = {...state, task.modelId: task};
        },
      );
    } catch (e) {
      // Previously the caller never awaited this future, so an exception (e.g.
      // the capacity guard's "Only one download at a time") vanished into an
      // unhandled async error and the button just did nothing. Surface it.
      initialTask.state = DownloadState.failed;
      initialTask.errorMessage = e is DownloadException ? e.message : '$e';
      state = {...state, model.id: initialTask};
    }
    // Reflect the terminal state one final time (the mutable task object is
    // shared with the service, so identity-based Map updates need a fresh Map).
    state = {...state, model.id: initialTask};
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

    // The service resumes from the on-disk `.tmp` partial and reports real
    // progress directly, so no in-memory progress restoration is needed.
    await _downloadService.resume(modelId, onProgress: (task) {
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
