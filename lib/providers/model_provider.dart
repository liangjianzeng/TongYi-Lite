import 'dart:io';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../models/model_info.dart';
import '../services/inference_service.dart';
import 'shared_providers.dart' show inferenceServiceProvider;

/// Lifecycle state of the currently loaded model.
enum ModelLifecycleState { idle, loading, loaded, unloading }

class ModelManagerNotifier extends StateNotifier<ModelLifecycleState> {
  final InferenceService _inference;
  String? _currentModelId;
  bool _isBusy = false;

  ModelManagerNotifier(this._inference) : super(ModelLifecycleState.idle);

  String? get currentModelId => _currentModelId;
  bool get isBusy => _isBusy;

  Future<ModelConfig?> currentModel() async {
    if (_currentModelId == null) return null;
    try {
      final models = await loadModelCatalog();
      return models.firstWhere((m) => m.id == _currentModelId);
    } on Exception catch (_) {
      return null;
    }
  }

  String get currentModelName {
    if (_currentModelId == null) return '未加载';
    try {
      final syncCache = loadModelCatalogSync();
      return syncCache.firstWhere((m) => m.id == _currentModelId).name;
    } on Exception catch (_) {
      return '$_currentModelId';
    }
  }

  static List<ModelConfig>? _syncCache;
  static Future<void> ensureSyncCache() async {
    if (_syncCache == null) _syncCache = await loadModelCatalog();
  }

  static List<ModelConfig> loadModelCatalogSync() => _syncCache ?? [];

  Future<bool> loadModel(String modelId) async {
    if (_currentModelId == modelId && state == ModelLifecycleState.loaded) return true;
    _isBusy = true;
    try {
      if (_currentModelId != null && _currentModelId != modelId) {
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
      final ok = await _inference.loadModel(path);
      if (ok) {
        _currentModelId = modelId;
        state = ModelLifecycleState.loaded;
        debugPrint('[ModelManager] Loaded: $modelId');
        return true;
      } else {
        _currentModelId = null;
        state = ModelLifecycleState.idle;
        return false;
      }
    } on Exception catch (e, st) {
      debugPrint('[ModelManager] Load failed: $e\n$st');
      _currentModelId = null;
      state = ModelLifecycleState.idle;
      return false;
    } finally {
      _isBusy = false;
    }
  }

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
    } on Exception catch (e, st) {
      debugPrint('[ModelManager] Unload failed: $e\n$st');
      state = ModelLifecycleState.idle;
      return false;
    } finally {
      _isBusy = false;
    }
  }

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
}

final modelManagerProvider = StateNotifierProvider<ModelManagerNotifier, ModelLifecycleState>((ref) {
  final inference = ref.read(inferenceServiceProvider);
  return ModelManagerNotifier(inference);
});
