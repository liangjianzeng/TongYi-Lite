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
import '../models/model_info.dart';

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

  /// 获取模型存储根目录（优先外部存储，回退到内部存储）。
  ///
  /// 目录解析涉及多次异步 IO（外部卷根推导 + 可写性验证），且外部不可写时
  /// 会回退到内部目录。若每次调用都重新解析，外部/内部切换会导致缓存状态
  /// 判断跳变（"飘忽"）。因此进程内只解析一次并缓存，保证后续调用返回一致。
  Future<Directory> getModelsRootDir() {
    return _rootDirFuture ??= _resolveRootDirOnce();
  }

  Future<Directory>? _rootDirFuture;

  Future<Directory> _resolveRootDirOnce() async {
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

  /// 获取 mmproj 投影器文件路径（text+mmproj 两文件形态的视觉模型）。
  Future<String> getMmprojPath(String modelId) async {
    final dir = await getModelsRootDir();
    return p.join(dir.path, '${modelId}.mmproj');
  }

  /// 获取 dspark 投机草稿头文件路径（独立 GGUF，如 Bonsai-27B-dspark-Q4_1）。
  Future<String> getDsparkPath(String modelId) async {
    final dir = await getModelsRootDir();
    return p.join(dir.path, '${modelId}.dspark.gguf');
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

  /// 判断模型是否「完整」地缓存在磁盘上 —— 这是「能否当作已缓存 / 可加载」的
  /// 唯一可靠判据。
  ///
  /// 仅检查 `.gguf` 是否存在（[isModelCached]）会漏掉两类故障：
  ///  ① catalog 里 `sizeBytes` 与实文件不符时，一个被截断/不完整的 `.gguf`
  ///   仍会被当成已缓存；
  ///  ② 下载中途暂停/失败若残留 `.gguf` 或 `.gguf.tmp`，会被误判为可加载，
  ///   用户点击「加载」后因为模型文件不全而直接失败。
  ///
  /// 因此要求：`.gguf` 存在、实文件大小 ≥ catalog 预期大小的 99%（catalog 未给
  /// 大小时退化为仅存在性判断）、且不存在未完成的 `.gguf.tmp` 部分文件。
  ///
  /// text+mmproj 两文件形态（[ModelConfig.mmproj] 非空）还需 mmproj 文件完整存在，
  /// 否则视觉模型无法加载（缺投影器）。
  Future<bool> isFullyCached(ModelConfig model) async {
    // 多位置查找：全盘扫描（scanExistingModels）能找到 Download/DCIM/内部目录
    // 里的模型，而轻量校验若只查主目录会漏判 → 同一模型"时好时坏"。
    // 这里遍历所有候选目录，任一目录内模型完整即视为已缓存。
    try {
      for (final dir in await _allCandidateDirs()) {
        if (!await dir.exists()) continue;
        if (await _isFullyCachedIn(dir, model)) return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// 判断 [model] 是否「完整」地缓存在目录 [dir] 下。
  ///
  /// 仅检查 `.gguf` 是否存在会漏掉两类故障：
  ///  ① catalog 里 `sizeBytes` 与实文件不符时，一个被截断/不完整的 `.gguf`
  ///   仍会被当成已缓存；
  ///  ② 下载中途暂停/失败若残留 `.gguf` 或 `.gguf.tmp`，会被误判为可加载。
  /// 因此要求：`.gguf` 存在、实文件大小 ≥ catalog 预期大小的 99%（catalog 未给
  /// 大小时退化为仅存在性判断）。
  ///
  /// text+mmproj 两文件形态（[ModelConfig.mmproj] 非空）还需 mmproj 文件完整存在。
  ///
  /// 自愈：当主文件已完整存在时，顺带清理上次中断下载残留的 `.tmp`（如重下时
  /// 流被截断留下的 `.mmproj.tmp`）。此前「存在 .tmp 即判未缓存」会把一个
  /// 已完整可用的模型永久误判为「未下载」——点击下载又重复拉取投影器，正是
  /// 用户反馈的 bug。完整主文件 + 残留 .tmp 时，.tmp 只是过期残留，删掉即可。
  Future<bool> _isFullyCachedIn(Directory dir, ModelConfig model) async {
    try {
      final gguf = File(p.join(dir.path, '${model.id}.gguf'));
      if (!await gguf.exists()) return false;
      final size = await gguf.length();
      if (model.sizeBytes > 0 && size < (model.sizeBytes * 0.99).round()) {
        return false;
      }
      await _cleanStaleTmp(dir, model.id, '.gguf');
      // mmproj 两文件形态：投影器必须完整存在，否则视为未缓存。
      final mm = model.mmproj;
      if (mm != null) {
        final mmproj = File(p.join(dir.path, '${model.id}.mmproj'));
        if (!await mmproj.exists()) return false;
        final mmSize = await mmproj.length();
        if (mm.sizeBytes > 0 && mmSize < (mm.sizeBytes * 0.99).round()) {
          return false;
        }
        await _cleanStaleTmp(dir, model.id, '.mmproj');
      }
      // dspark 投机草稿头：必须完整存在，否则投机加速无法启用。
      final ds = model.dspark;
      if (ds != null) {
        final dspark = File(p.join(dir.path, '${model.id}.dspark.gguf'));
        if (!await dspark.exists()) return false;
        final dsSize = await dspark.length();
        if (ds.sizeBytes > 0 && dsSize < (ds.sizeBytes * 0.99).round()) {
          return false;
        }
        await _cleanStaleTmp(dir, model.id, '.dspark.gguf');
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 主文件（`.gguf` / `.mmproj`）已完整时，清理上次中断下载残留的对应 `.tmp`。
  /// 失败静默忽略（尽力而为的自愈），不影响缓存判定结果。
  Future<void> _cleanStaleTmp(Directory dir, String modelId, String suffix) async {
    try {
      final tmp = File(p.join(dir.path, '$modelId$suffix.tmp'));
      if (await tmp.exists()) {
        await tmp.delete();
        debugPrint('[ModelStorage] 清理残留 $suffix.tmp: ${tmp.path}');
      }
    } catch (_) {}
  }

  /// 返回所有可能的模型存储目录（主目录 + 内部 + Download + DCIM + app docs），
  /// 与 [scanExistingModels] 的扫描范围保持一致，避免"主目录 vs 多位置"矛盾。
  Future<List<Directory>> _allCandidateDirs() async {
    final dirs = <Directory>[];

    final externalPath = await _resolveExternalModelsDir();
    dirs.add(Directory(externalPath));

    // 内部存储（app_flutter/models）
    dirs.add(Directory('/data/data/com.dgxspark.tongyilite/app_flutter/models'));

    // 系统广目录（用户手动放入模型文件）
    dirs.add(Directory('/sdcard/Download'));
    dirs.add(Directory('/sdcard/DCIM'));

    // 回退目录（applicationDocumentsDirectory/models）
    try {
      final appDir = await getApplicationDocumentsDirectory();
      dirs.add(Directory(p.join(appDir.path, 'models')));
    } catch (_) {}

    return dirs;
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
        if (entity is File &&
            (entity.path.endsWith('.gguf') || entity.path.endsWith('.mmproj'))) {
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
