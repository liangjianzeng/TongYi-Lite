// ============================================================
// Model Storage Service — 持久化模型文件存储管理
// 
// 设计目标：
// 1. 使用公共外部目录（/sdcard/TongYiLite/models）实现永久存储
//    - 重装 APK 后数据保留
//    - 用户可手动管理模型文件
// 2. 支持扫描多个位置查找已有模型
// ============================================================

import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:flutter/foundation.dart' show debugPrint;

/// 模型存储服务 — 统一管理模型文件的存储位置
class ModelStorageService {
  static final ModelStorageService _instance = ModelStorageService._internal();
  factory ModelStorageService() => _instance;
  ModelStorageService._internal();

  // 持久化存储文件夹名（重装 APK 后仍保留，因为不在 app-private 目录下）
  static const String _appFolder = 'TongYiLite';

  /// 解析外部存储卷根下的模型目录。优先用 getExternalStorageDirectory() 推导的真实
  /// 卷根（如 /storage/emulated/0），回退到传统的 /sdcard 软链，避免硬编码路径在
  /// 部分机型/Android 版本上失效。
  Future<String> _resolveExternalModelsDir() async {
    try {
      final ext = await getExternalStorageDirectory();
      if (ext != null) {
        // ext = /storage/emulated/0/Android/data/<pkg>/files
        // 向上 4 级到达卷根 /storage/emulated/0
        var root = ext;
        for (var i = 0; i < 4 && root.parent.path != root.path; i++) {
          root = root.parent;
        }
        return p.join(root.path, _appFolder, 'models');
      }
    } catch (e) {
      debugPrint('[ModelStorage] Failed to resolve external root: $e');
    }
    return p.join('/sdcard', _appFolder, 'models');
  }

  /// 获取模型存储根目录（优先外部存储，回退到内部存储）
  Future<Directory> getModelsRootDir() async {
    final externalPath = await _resolveExternalModelsDir();
    final externalDir = Directory(externalPath);
    try {
      if (!await externalDir.exists()) {
        await externalDir.create(recursive: true);
        debugPrint('[ModelStorage] Created directory: ${externalDir.path}');
      }

      // 验证可写性
      final testFile = File(p.join(externalDir.path, '.write_test'));
      await testFile.writeAsString('test');
      await testFile.delete();

      debugPrint('[ModelStorage] Using external storage: ${externalDir.path}');
      return externalDir;
    } catch (e) {
      debugPrint('[ModelStorage] Failed to use external storage: $e');
    }

    // 2. 回退到内部存储（app_flutter/models）
    return await _getFallbackDir();
  }

  /// 回退方案：使用内部存储（Flutter app_flutter 目录）
  Future<Directory> _getFallbackDir() async {
    // Flutter 的 app_flutter/models 路径
    final dir = Directory('/data/data/com.dgxspark.tongyilite/app_flutter/models');
    
    // 尝试创建目录
    try {
      if (!await dir.exists()) {
        await dir.create(recursive: true);
        debugPrint('[ModelStorage] Created internal directory: ${dir.path}');
      }
      debugPrint('[ModelStorage] Using internal storage: ${dir.path}');
      return dir;
    } catch (e) {
      debugPrint('[ModelStorage] Failed to create internal directory: $e');
      // 最后回退到 applicationDocumentsDirectory
      final appDir = await getApplicationDocumentsDirectory();
      final fallbackDir = Directory(p.join(appDir.path, 'models'));
      await fallbackDir.create(recursive: true);
      debugPrint('[ModelStorage] Fallback to app docs: ${fallbackDir.path}');
      return fallbackDir;
    }
  }

  /// 获取模型文件路径
  Future<String> getModelPath(String modelId) async {
    final dir = await getModelsRootDir();
    return p.join(dir.path, '${modelId}.gguf');
  }

  /// Check if model file exists locally
  Future<bool> isModelCached(String modelId) async {
    try {
      final path = await getModelPath(modelId);
      return File(path).exists();
    } catch (_) {
      return false;
    }
  }

  /// Get local file size if cached
  Future<int> getCachedSize(String modelId) async {
    try {
      final path = await getModelPath(modelId);
      final file = File(path);
      if (await file.exists()) {
        return await file.length();
      }
    } catch (_) {}
    return 0;
  }

  /// Check total cached model size in bytes
  Future<int> getTotalCachedSize() async {
    try {
      final dir = await getModelsRootDir();
      if (!await dir.exists()) return 0;
      
      int total = 0;
      await for (final entity in dir.list(recursive: true)) {
        if (entity is File && entity.path.endsWith('.gguf')) {
          total += await entity.length();
        }
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  /// Scan for existing models on device（多位置扫描）
  Future<List<String>> scanExistingModels() async {
    final cachedIds = <String>{};

    // 1. 扫描外部存储主目录（递归，模型通常直接放这里）
    final externalPath = await _resolveExternalModelsDir();
    await _scanDirectory(Directory(externalPath), cachedIds, recursive: true);

    // 2. 扫描内部存储（app_flutter/models）- Flutter 默认存储位置
    await _scanDirectory(
      Directory('/data/data/com.dgxspark.tongyilite/app_flutter/models'),
      cachedIds,
      recursive: true,
    );

    // 3. 扫描 Download / DCIM 目录（仅顶层，避免递归扫全盘导致极慢/权限异常）
    await _scanDirectory(Directory('/sdcard/Download'), cachedIds, recursive: false);
    await _scanDirectory(Directory('/sdcard/DCIM'), cachedIds, recursive: false);

    // 4. 回退到 applicationDocumentsDirectory
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final internalModels = Directory(p.join(appDir.path, 'models'));
      if (await internalModels.exists()) {
        await _scanDirectory(internalModels, cachedIds, recursive: true);
      }
    } catch (_) {}

    debugPrint('[ModelStorage] Found ${cachedIds.length} cached models: $cachedIds');
    return cachedIds.toList();
  }

  /// Scan directory for .gguf files. [recursive] 控制是否递归子目录；
  /// 系统广目录（Download/DCIM）应传 false，避免扫全盘。
  Future<void> _scanDirectory(Directory dir, Set<String> cachedIds, {bool recursive = true}) async {
    if (!await dir.exists()) return;
    
    try {
      await for (final entity in dir.list(recursive: recursive)) {
        if (entity is File && entity.path.endsWith('.gguf')) {
          final id = p.basenameWithoutExtension(entity.path);
          cachedIds.add(id);
        }
      }
    } catch (e) {
      debugPrint('[ModelStorage] Scan error in ${dir.path}: $e');
    }
  }

  /// Format file size for display
  static String formatSize(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(1)} GB';
    }
    if (bytes >= 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(0)} MB';
    }
    if (bytes >= 1024) {
      return '${(bytes / 1024).toStringAsFixed(0)} KB';
    }
    return '$bytes B';
  }

  /// Get the public storage path for user reference
  static String getPublicStoragePath() => p.join('/sdcard', _appFolder, 'models');
}

/// Global singleton access
final modelStorageService = ModelStorageService();
