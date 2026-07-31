import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../models/model_catalog.dart';
import '../models/model_info.dart';

/// Manages model caching and local storage.
/// Delegates download logic to DownloadService; this class only handles
/// file-system queries (isModelCached, getCachedSize, allModels, etc.).
///
/// 模型目录由 [ModelCatalog] 从 assets/models_catalog.json（可选远程）加载，
/// 不再写死在代码里。应用启动时需调用一次 [init()]。
class ModelManager {
  static final ModelManager _instance = ModelManager._internal();
  factory ModelManager() => _instance;
  ModelManager._internal();

  List<ModelConfig> _models = const [];

  /// 应用启动时调用一次：从配置文件（可选远程）加载模型目录。
  Future<void> init() async {
    _models = await ModelCatalog.load();
  }

  /// 所有可用模型（加载完成前为空列表）。
  List<ModelConfig> get allModels => _models;

  /// 取推荐/默认模型。
  ModelConfig? get recommendedModel {
    if (_models.isEmpty) return null;
    for (final m in _models) {
      if (m.recommended) return m;
    }
    return _models.first;
  }

  /// 按 ID 取模型。
  ModelConfig? getModel(String id) {
    for (final m in _models) {
      if (m.id == id) return m;
    }
    return null;
  }

  Future<Directory> _getModelsDir() async {
    final appDir = await getApplicationDocumentsDirectory();
    return Directory('${appDir.path}/models');
  }

  /// Check if model file exists locally
  Future<bool> isModelCached(String modelId) async {
    try {
      final dir = await _getModelsDir();
      final file = File(p.join(dir.path, '${modelId}.gguf'));
      return await file.exists();
    } catch (_) {
      return false;
    }
  }

  /// Get local file size if cached
  Future<int> getCachedSize(String modelId) async {
    try {
      final dir = await _getModelsDir();
      final file = File(p.join(dir.path, '${modelId}.gguf'));
      if (await file.exists()) {
        return await file.length();
      }
    } catch (_) {}
    return 0;
  }

  /// Check total cached model size in bytes
  Future<int> getTotalCachedSize() async {
    try {
      final dir = await _getModelsDir();
      if (!await dir.exists()) return 0;
      int total = 0;
      for (final entity in dir.listSync()) {
        if (entity is File && entity.path.endsWith('.gguf')) {
          total += await entity.length();
        }
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  /// Check if device has enough memory for a model (stub - uses estimate)
  Future<bool> hasEnoughMemory(int minRamMB) async {
    // In production, this would query native side via JNI.
    // For now, assume sufficient RAM (>2GB available).
    return true;
  }

  /// Check all models and return recommendations (stub)
  Future<List<Map<String, dynamic>>> checkAllModels() async {
    final cached = <String>[];
    try {
      final dir = await _getModelsDir();
      if (await dir.exists()) {
        for (final entity in dir.listSync()) {
          if (entity is File && entity.path.endsWith('.gguf')) {
            cached.add(p.basenameWithoutExtension(entity.path));
          }
        }
      }
    } catch (_) {}

    return [
      {'cached': cached, 'freeMB': 5120, 'totalMB': 8192},
    ];
  }
}
