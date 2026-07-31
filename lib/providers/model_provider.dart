import 'dart:io';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../models/model_info.dart';
import '../services/inference_service.dart';
import 'chat_provider.dart' show inferenceServiceProvider;

/// Lifecycle state of the currently loaded model.
enum ModelLifecycleState { idle, loading, loaded, unloading }

/// Manages the single-model lifecycle: load / unload / switch.
/// Only ONE model can be in memory at any time (single-instance lock).
class ModelManagerNotifier extends StateNotifier<ModelLifecycleState> {
  final InferenceService _inference;

  String? _currentModelId; // ID of the currently loaded model, or null
  bool _isBusy = false;    // Prevents concurrent load/unload operations

  ModelManagerNotifier(this._inference) : super(ModelLifecycleState.idle);

  /// Currently loaded model ID, or null if no model is in memory.
  String? get currentModelId => _currentModelId;

  /// Whether a load/unload operation is currently in progress.
  bool get isBusy => _isBusy;

  /// Full ModelConfig for the currently loaded model, or null.
  Future<ModelConfig?> currentModel() async {
    if (_currentModelId == null) return null;
    try {
      final models = await loadModelCatalog();
      return models.firstWhere((m) => m.id == _currentModelId);
    } catch (_) {
      return null;
    }
  }

  /// Get current model name synchronously (for UI display).
  String get currentModelName {
    if (_currentModelId == null) return '未加载';
    try {
      final models = loadModelCatalogSync();
      final found = models.firstWhere((m) => m.id == _currentModelId);
      return found.name;
    } catch (_) {
      return '$_currentModelId';
    }
  }

  /// Synchronous catalog access for UI display (cached).
  static List<ModelConfig>? _syncCache;
  static Future<void> ensureSyncCache() async {
    if (_syncCache == null) {
      _syncCache = await loadModelCatalog();
    }
  }

  static List<ModelConfig> loadModelCatalogSync() {
    return _syncCache ?? [];
  }

  /// Load a model into the inference engine.
  /// If another model is already loaded, it will be unloaded first.
  Future<bool> loadModel(String modelId) async {
    if (_currentModelId == modelId && state == ModelLifecycleState.loaded) {
      debugPrint('[ModelManager] $modelId already loaded');
      return true;
    }

    _isBusy = true;
    try {
      if (_currentModelId != null && _currentModelId != modelId) {
        debugPrint('[ModelManager] Unloading $_currentModelId before loading $modelId');
        await unloadModel();
      }

      state = ModelLifecycleState.loading;
      final path = await getModelPath(modelId);
      if (path == null) {
        debugPrint('[ModelManager] File not found: $modelId.gguf');
        _currentModelId = null;
        state = ModelLifecycleState.idle;
        return false;
      }

      debugPrint('[ModelManager] Loading model from: $path');
      final ok = await _inference.loadModel(path);
      if (ok) {
        _currentModelId = modelId;
        state = ModelLifecycleState.loaded;
        debugPrint('[ModelManager] Loaded: $modelId ($path)');
        return true;
      } else {
        debugPrint('[ModelManager] loadModel() returned false for $modelId');
        _currentModelId = null;
        state = ModelLifecycleState.idle;
        return false;
      }
    } catch (e, st) {
      debugPrint('[ModelManager] Load failed: $e\n$st');
      _currentModelId = null;
      state = ModelLifecycleState.idle;
      return false;
    } finally {
      _isBusy = false;
    }
  }

  /// Unload the currently loaded model.
  Future<bool> unloadModel() async {
    if (_isBusy || _currentModelId == null) return true;

    final id = _currentModelId!;
    _isBusy = true;
    try {
      state = ModelLifecycleState.unloading;
      await _inference.unloadModel();
      debugPrint('[ModelManager] Unloaded: $id');
      _currentModelId = null;
      state = ModelLifecycleState.idle;
      return true;
    } catch (e, st) {
      debugPrint('[ModelManager] Unload failed: $e\n$st');
      state = ModelLifecycleState.idle;
      return false;
    } finally {
      _isBusy = false;
    }
  }

  /// Check if a model file exists on disk.
  Future<bool> isModelCached(String modelId) async {
    final path = await getModelPath(modelId);
    return path != null;
  }

  /// Get the full filesystem path for a downloaded model, or null if not cached.
  Future<String?> getModelPath(String modelId) async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final file = File('${appDir.path}/models/$modelId.gguf');
      return file.existsSync() ? file.path : null;
    } catch (_) {
      return null;
    }
  }

  /// Get the cached model size in bytes, or 0 if not cached.
  Future<int> getCachedSize(String modelId) async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final file = File('${appDir.path}/models/$modelId.gguf');
      return file.existsSync() ? await file.length() : 0;
    } catch (_) {
      return 0;
    }
  }

  /// Get total size of all cached models.
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
    } catch (_) {
      return 0;
    }
  }

}

// ---------------------------------------------------------------------------
// Riverpod providers
// ---------------------------------------------------------------------------

final modelManagerProvider = StateNotifierProvider<ModelManagerNotifier, ModelLifecycleState>((ref) {
  final inference = ref.read(inferenceServiceProvider);
  return ModelManagerNotifier(inference);
});
