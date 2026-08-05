import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/model_info.dart';
import '../models/model_catalog.dart';
import '../services/inference_service.dart';
import '../services/model_storage_service.dart';
import 'settings_provider.dart';
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
  final Ref _ref;
  bool _isBusy = false;

  ModelManagerNotifier(this._inference, this._ref) : super(const ModelState()) {
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
  
  /// Loading logs from native layer (for display in log screen)
  List<String> get loadingLogs => state.loadingLogs;

  /// Access the current lifecycle phase (exposed for UI code that needs it).
  ModelLifecyclePhase get phase => state.phase;

  /// Append a line to the inference log panel. Unlike native loading logs,
  /// this is emitted from Dart-side during model interactions and is allowed
  /// in any phase (especially [loaded]).
  void appendInferenceLog(String message) {
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

      // 2. Ensure the catalog sync cache is populated (it's loaded lazily and
      //    was previously never triggered, so modelName was always null → the
      //    status sheet showed "未知模型"). Then look up the display name.
      await ModelManagerNotifier.ensureSyncCache();
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

      // 4. Warn if this is a vision model (mmproj not yet supported).
      final config = _lookupModelConfig(modelId);
      if (config != null && config.type == ModelType.vision) {
        debugPrint('[ModelManager] WARNING: Vision model $modelId loaded without mmproj — '
            'image understanding is NOT available. Text-only inference will work.');
        state = ModelState(
          phase: ModelLifecyclePhase.loading,
          modelId: modelId,
          modelName: displayName,
          loadingLogs: ['⚠️ 视觉模型：当前仅支持文本推理，图像理解功能暂不可用'],
        );
      }

      // 5. Call native inference engine to load the model.
      //    直接从持久化文件读取设置，避免 settingsProvider 异步 _load 完成前
      //    读到默认 enableGpu=false，导致启动后直接加载模型时 GPU 未生效。
      final gpu = await _ref.read(settingsServiceProvider).load();
      final mtp = gpu.mtpEnabled(modelId);
      debugPrint('[ModelManager] Calling loadModel(path=$path, '
          'enableGpu=${gpu.enableGpu}, gpuLayers=${gpu.gpuLayers}, '
          'gpuBackend=${gpu.gpuBackend}, contextSize=${gpu.contextSize}, '
          'enableMtp($modelId)=$mtp)');
      final ok = await _inference.loadModel(
        path,
        enableGpu: gpu.enableGpu,
        gpuLayers: gpu.gpuLayers,
        gpuBackend: gpu.gpuBackend,
        nCtx: gpu.contextSize,
        enableMtp: mtp,
      );

      if (ok) {
        // Preserve loading logs so the log screen can still show them after load completes.
        state = ModelState(
          phase: ModelLifecyclePhase.loaded,
          modelId: modelId,
          modelName: displayName,
          loadingLogs: List<String>.from(state.loadingLogs),
        );
        // 把思考模式开关同步到原生层（原生侧引擎重启后会复位为默认 false）。
        await _inference.setEnableThinking(gpu.enableThinking);
        debugPrint('[ModelManager] Loaded: $modelId ($displayName), '
            'enableThinking=${gpu.enableThinking}');
        return true;
      } else {
        String errorMsg = '模型加载失败（原生层返回 false）';
        // Provide a more helpful error for common failure modes.
        if (state.latestLog != null && state.latestLog!.contains('内存')) {
          errorMsg = '内存不足，无法加载此模型。请关闭其他应用后重试，或选择更小的模型（如 Qwen3-0.6B）。';
        } else if (config != null && config.type == ModelType.vision) {
          errorMsg = '视觉模型加载失败。当前版本不支持 mmproj 投影器，建议使用文本模型。';
        }
        state = ModelState.error(
          message: errorMsg,
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
    final storage = ModelStorageService();
    return await storage.getModelPath(modelId);
  }

  Future<int> getCachedSize(String modelId) async {
    final storage = ModelStorageService();
    return await storage.getCachedSize(modelId);
  }

  Future<int> getTotalCachedSize() async {
    final storage = ModelStorageService();
    return await storage.getTotalCachedSize();
  }

  /// Look up a model's display name from the cached catalog (best-effort).
  static String? _lookupModelName(String modelId) {
    final syncCache = loadModelCatalogSync();
    for (final m in syncCache) {
      if (m.id == modelId) return m.name;
    }
    return null;
  }

  /// Look up full ModelConfig from the cached catalog.
  static ModelConfig? _lookupModelConfig(String modelId) {
    final syncCache = loadModelCatalogSync();
    for (final m in syncCache) {
      if (m.id == modelId) return m;
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
  return ModelManagerNotifier(inference, ref);
});
