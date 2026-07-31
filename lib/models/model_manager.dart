import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../models/model_info.dart';

/// Manages model caching and local storage.
class ModelManager {
  static final ModelManager _instance = ModelManager._internal();
  factory ModelManager() => _instance;
  ModelManager._internal();

  /// All built-in available models (read-only list).
  List<ModelConfig> get allModels => builtInModels();

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
