import 'dart:io';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../models/model_info.dart';
import '../services/inference_service.dart';
import 'shared_providers.dart' show inferenceServiceProvider;

/// Lifecycle phase of the currently loaded model.
enum ModelLifecyclePhase { idle, loading, loaded, unloading, error }

/// Full state of the model manager — richer than a simple enum so the UI can
/// display meaningful information at every stage.
class ModelState {
  final ModelLifecyclePhase phase;
  final String? modelId;
  final String? modelName;
  final String? errorMessage;

  /// Real-time loading progress messages from native (C++/Kotlin).
  /// Each entry is a human-readable log line describing the current step.
  final List<String> loadingLogs;

  const ModelState({
    this.phase = ModelLifecyclePhase.idle,
    this.modelId,
    this.modelName,
    this.errorMessage,
    this.loadingLogs = const [],
  });

  // ---- convenience factories ----
  static const idle = ModelState(phase: ModelLifecyclePhase.idle);

  factory ModelState.loading({String? modelId, String? modelName}) =>
      ModelState(
        phase: ModelLifecyclePhase.loading,
        modelId: modelId,
        modelName: modelName,
      );

  factory ModelState.loaded({String? modelId, String? modelName}) =>
      ModelState(
        phase: ModelLifecyclePhase.loaded,
        modelId: modelId,
        modelName: modelName,
      );

  static const unloading =
      ModelState(phase: ModelLifecyclePhase.unloading);

  factory ModelState.error({
    required String message,
    String? modelId,
    String? modelName,
  }) =>
      ModelState(
        phase: ModelLifecyclePhase.error,
        modelId: modelId,
        modelName: modelName,
        errorMessage: message,
      );

  // ---- derived helpers ----
  bool get isLoading => phase == ModelLifecyclePhase.loading;
  bool get isLoaded => phase == ModelLifecyclePhase.loaded;
  bool get isError => phase == ModelLifecyclePhase.error;

  /// The most recent loading log message (null if none).
  String? get latestLog => loadingLogs.isNotEmpty ? loadingLogs.last : null;

  /// Human-readable label for the chip in UI.
  String get phaseLabel {
    switch (phase) {
      case ModelLifecyclePhase.idle:
        return '未加载';
      case ModelLifecyclePhase.loading:
        return '加载中...';
      case ModelLifecyclePhase.loaded:
        return '已加载';
      case ModelLifecyclePhase.unloading:
        return '卸载中...';
      case ModelLifecyclePhase.error:
        return '错误';
    }
  }

  /// Color name for the chip in UI.
  String get phaseColor {
    switch (phase) {
      case ModelLifecyclePhase.idle:
        return 'grey';
      case ModelLifecyclePhase.loading:
        return 'blue';
      case ModelLifecyclePhase.loaded:
        return 'green';
      case ModelLifecyclePhase.unloading:
        return 'orange';
      case ModelLifecyclePhase.error:
        return 'red';
    }
  }

  @override
  String toString() =>
      'ModelState(phase: $phase, modelId: $modelId, modelName: $modelName, logs: ${loadingLogs.length})';
}

class ModelManagerNotifier extends StateNotifier<ModelState> {
  final InferenceService _inference;
  bool _isBusy = false;

  ModelManagerNotifier(this._inference) : super(const ModelState()) {
    // Wire up loading log callback from native layer.
    _inference.onLoadingLog = (message) {
      if (state.isLoading && message != null) {
        final currentLogs = List<String>.from(state.loadingLogs);
        currentLogs.add(message);
        state = ModelState(
          phase: state.phase,
          modelId: state.modelId,
          modelName: state.modelName,
          errorMessage: state.errorMessage,
          loadingLogs: currentLogs,
        );
      }
    };
  }

  /// Whether a load/unload operation is in progress.
  bool get isBusy => _isBusy;

  // ---- Public getters exposing state fields (avoids direct `state.` access from UI). ----
  String? get modelId => state.modelId;
  String? get modelName => state.modelName;
  bool get isLoading => state.isLoading;
  bool get isLoadedState => state.isLoaded;
  bool get isErrorState => state.isError;

  /// Access the current lifecycle phase (exposed for UI code that needs it).
  ModelLifecyclePhase get phase => state.phase;

  /// ID of the currently loaded model, or null if idle/error. (alias for convenience)
  String? get currentModelId => modelId;

  Future<ModelConfig?> currentModel() async {
    final mid = modelId;
    if (mid == null) return null;
    try {
      final models = await loadModelCatalog();
      return models.firstWhere((m) => m.id == mid);
    } on Exception catch (_) {
      return null;
    }
  }

  String get currentModelName {
    if (modelName != null && modelName!.isNotEmpty) return modelName!;
    if (modelId == null) return '未加载';
    try {
      final syncCache = loadModelCatalogSync();
      return syncCache.firstWhere((m) => m.id == modelId!).name;
    } on Exception catch (_) {
      return '$modelId';
    }
  }

  static List<ModelConfig>? _syncCache;
  static Future<void> ensureSyncCache() async {
    if (_syncCache == null) _syncCache = await loadModelCatalog();
  }

  static List<ModelConfig> loadModelCatalogSync() => _syncCache ?? [];

  /// Load a model into memory. If another model is currently loaded it will
  /// be unloaded first automatically (single-model constraint).
  Future<bool> loadModel(String modelId) async {
    if (_isBusy) return false;

    // Check if the same model is already loaded → no-op success.
    final cur = state.modelId;
    if (cur == modelId && state.isLoaded) return true;

    _isBusy = true;
    try {
      // 1. If a different model is currently loaded, unload it first.
      if (_currentModelId != null && _currentModelId != modelId) {
        debugPrint('[ModelManager] Unloading previous model before switching to $modelId');
        await unloadModel();
      }

      // 2. Look up the display name from catalog (best-effort).
      String? displayName = _lookupModelName(modelId);

      // 3. Set state to loading with empty logs — native will push updates.
      state = ModelState(
        phase: ModelLifecyclePhase.loading,
        modelId: modelId,
        modelName: displayName,
        loadingLogs: const [],
      );

      final path = await getModelPath(modelId);
      if (path == null) {
        debugPrint('[ModelManager] File not found: $modelId.gguf');
        state = ModelState.error(
          message: '模型文件不存在，请重新下载',
          modelId: modelId,
          modelName: displayName,
        );
        return false;
      }

      // 4. Call native inference engine to load the model.
      debugPrint('[ModelManager] Calling loadModel(path=$path)');
      final ok = await _inference.loadModel(path);

      if (ok) {
        state = ModelState.loaded(modelId: modelId, modelName: displayName);
        debugPrint('[ModelManager] Loaded: $modelId ($displayName)');
        return true;
      } else {
        state = ModelState.error(
          message: '模型加载失败（原生层返回 false）',
          modelId: modelId,
          modelName: displayName,
        );
        debugPrint('[ModelManager] Load returned false for $modelId');
        return false;
      }
    } on Exception catch (e, st) {
      String? displayName = _lookupModelName(modelId);

      state = ModelState.error(
        message: '加载异常: $e',
        modelId: modelId,
        modelName: displayName,
      );
      debugPrint('[ModelManager] Load failed: $e\n$st');
      return false;
    } finally {
      _isBusy = false;
    }
  }

  /// Unload the currently loaded model from memory.
  Future<bool> unloadModel() async {
    final curId = state.modelId;
    if (_isBusy || curId == null) return true;
    final id = curId;
    String? name = state.modelName;
    _isBusy = true;
    try {
      state = ModelState(phase: ModelLifecyclePhase.unloading);

      debugPrint('[ModelManager] Calling unloadModel() for $id');
      await _inference.unloadModel();

      debugPrint('[ModelManager] Unloaded: $id ($name)');
      state = const ModelState(); // reset to idle (default phase=idle)
      return true;
    } on Exception catch (e, st) {
      debugPrint('[ModelManager] Unload failed: $e\n$st');
      // Stay in idle — we don't want to get stuck.
      state = const ModelState();
      return false;
    } finally {
      _isBusy = false;
    }
  }

  /// Keep a reference for the old unloadModel() path compatibility.
  String? get _currentModelId => state.modelId;

  Future<bool> isModelCached(String modelId) async => await getModelPath(modelId) != null;

  Future<String?> getModelPath(String modelId) async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final file = File('${appDir.path}/models/$modelId.gguf');
      return file.existsSync() ? file.path : null;
    } on Exception catch (_) {
      return null;
    }
  }

  Future<int> getCachedSize(String modelId) async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final file = File('${appDir.path}/models/$modelId.gguf');
      return file.existsSync() ? await file.length() : 0;
    } on Exception catch (_) {
      return 0;
    }
  }

  Future<int> getTotalCachedSize() async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final dir = Directory('${appDir.path}/models');
      if (!await dir.exists()) return 0;
      int total = 0;
      for (final entity in await dir.list().toList()) {
        if (entity is File && entity.path.endsWith('.gguf')) {
          total += await entity.length();
        }
      }
      return total;
    } on Exception catch (_) {
      return 0;
    }
  }

  /// Look up a model's display name from the cached catalog (best-effort).
  static String? _lookupModelName(String modelId) {
    final syncCache = loadModelCatalogSync();
    for (final m in syncCache) {
      if (m.id == modelId) return m.name;
    }
    return null;
  }
}

/// Extension to read model-manager state from the provider without needing
/// `.notifier` — avoids `AlwaysAliveRefreshable<T>` type issues in UI code.
extension ModelStateExtension on StateNotifierProvider<ModelManagerNotifier, ModelState> {
  /// Read the current [ModelState] directly (no notifier access).
  ModelState get state => throw UnimplementedError('Use ref.watch(provider) instead.');
}

/// Provider — declared after the notifier class so the reference resolves.
final modelManagerProvider = StateNotifierProvider<ModelManagerNotifier, ModelState>((ref) {
  final inference = ref.read(inferenceServiceProvider);
  return ModelManagerNotifier(inference);
});
