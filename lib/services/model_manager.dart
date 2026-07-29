import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../models/model_info.dart';

/// Manages model downloads, caching, and local storage.
/// Model source: https://huggingface.co/Qwen/Qwen3-1.7B-Instruct-GGUF
/// (with fallback mirror for China: https://modelscope.cn)
class ModelManager {
  static final ModelManager _instance = ModelManager._internal();
  factory ModelManager() => _instance;
  ModelManager._internal();

  static const List<ModelConfig> _models = [
    ModelConfig(
      id: 'qwen3-1.7b-q4_k_m',
      name: 'Qwen3-1.7B Instruct (Q4_K_M)',
      type: ModelType.text,
      url: 'https://huggingface.co/Qwen/Qwen3-1.7B-Instruct-GGUF/resolve/main/qwen3-1.7b-instruct-q4_k_m.gguf',
      mirrorUrl: 'https://modelscope.cn/guanpengchuan/Qwen3-1.7B-Instruct-GGUF/resolve/main/qwen3-1.7b-instruct-q4_k_m.gguf',
      sizeBytes: 1200 * 1024 * 1024, // ~1.2 GB
      sizeMBDisplay: '1.2 GB',
      recommended: true,
      minRamMB: 1200,
    ),
    ModelConfig(
      id: 'qwen3-1.7b-q5_k_m',
      name: 'Qwen3-1.7B (Q5_K_M)',
      type: ModelType.text,
      url: 'https://huggingface.co/Qwen/Qwen3-1.7B-Instruct-GGUF/resolve/main/qwen3-1.7b-instruct-q5_k_m.gguf',
      mirrorUrl: 'https://modelscope.cn/guanpengchuan/Qwen3-1.7B-Instruct-GGUF/resolve/main/qwen3-1.7b-instruct-q5_k_m.gguf',
      sizeBytes: 1450 * 1024 * 1024,
      sizeMBDisplay: '1.5 GB',
      recommended: false,
      minRamMB: 1500,
    ),
    ModelConfig(
      id: 'qwen3-0.6b-q4_k_m',
      name: 'Qwen3-0.6B Instruct (Q4_K_M)',
      type: ModelType.text,
      url: 'https://huggingface.co/Qwen/Qwen3-0.6B-Instruct-GGUF/resolve/main/Qwen3-0.6B-Instruct-Q4_K_M.gguf',
      mirrorUrl: 'https://modelscope.cn/guanpengchuan/Qwen3-0.6B-Instruct-GGUF/resolve/main/Qwen3-0.6B-Instruct-Q4_K_M.gguf',
      sizeBytes: 420 * 1024 * 1024,
      sizeMBDisplay: '420 MB',
      recommended: true,
      minRamMB: 500,
    ),
    ModelConfig(
      id: 'qwen2.5-vl-3b-q4_k_m',
      name: 'Qwen2.5-VL-3B Instruct (Q4_K_M)',
      type: ModelType.vision,
      url: 'https://huggingface.co/Qwen/Qwen2.5-VL-3B-Instruct-GGUF/resolve/main/Qwen2.5-VL-3B-Instruct-Q4_K_M.gguf',
      mirrorUrl: 'https://modelscope.cn/guanpengchuan/Qwen2.5-VL-3B-Instruct-GGUF/resolve/main/Qwen2.5-VL-3B-Instruct-Q4_K_M.gguf',
      sizeBytes: 2000 * 1024 * 1024,
      sizeMBDisplay: '2.0 GB',
      recommended: false,
      minRamMB: 3000,
    ),
  ];

  /// Get all available models (local + remote)
  List<ModelConfig> get allModels => _models;

  /// Get recommended/default model
  ModelConfig get recommendedModel => _models.firstWhere((m) => m.recommended);

  /// Get a model by ID
  ModelConfig? getModel(String id) => _models.firstWhere((m) => m.id == id, orElse: () => _models.first);

  /// Check if model file exists locally
  Future<bool> isModelCached(String modelId) async {
    final dir = await _getModelsDir();
    final file = File(join(dir.path, '${modelId}.gguf'));
    return await file.exists();
  }

  /// Get local file size if cached
  Future<int> getCachedSize(String modelId) async {
    final dir = await _getModelsDir();
    final file = File(join(dir.path, '${modelId}.gguf'));
    if (await file.exists()) {
      return await file.length();
    }
    return 0;
  }

  /// Check if device has enough RAM for a model
  Future<bool> hasEnoughMemory(ModelConfig model) async {
    final mem = await _getMemoryInfo();
    final availableMB = mem['freeMB'] as int;
    return availableMB >= model.minRamMB;
  }

  /// Get a recommendation with memory check (green/yellow/red)
  Future<MemoryRecommendation> checkAllModels() async {
    final recommendations = <ModelRecommendation>[];
    final mem = await _getMemoryInfo();
    final freeMB = mem['freeMB'] as int;

    for (final model in _models) {
      ColorStatus status;
      if (freeMB >= model.minRamMB * 2) {
        status = ColorStatus.green; // plenty of RAM
      } else if (freeMB >= model.minRamMB) {
        status = ColorStatus.yellow; // tight but OK
      } else {
        status = ColorStatus.red; // not enough memory
      }
      recommendations.add(ModelRecommendation(model: model, status: status));
    }

    return MemoryRecommendation(
      freeMB: freeMB,
      totalMB: mem['totalMB'] as int,
      recommendations: recommendations,
    );
  }

  /// Download model to local cache
  Future<DownloadProgress> downloadModel(
    ModelConfig model, {
    ProgressCallback? onProgress,
  }) async {
    final dir = await _getModelsDir();
    final file = File(join(dir.path, '${model.id}.gguf'));
    final tempFile = File('${file.path}.tmp');

    // Resume from partial download
    int downloadedBytes = 0;
    if (await tempFile.exists()) {
      downloadedBytes = await tempFile.length();
    }

    final request = await HttpClient().openUrl('GET', Uri.parse(model.url));
    // We'll use a simpler approach with Dio (already in pubspec)

    // For now, just note that download needs Dio http package
    // This will be implemented with full Dio + resume support
    return DownloadProgress(
      modelId: model.id,
      totalBytes: model.sizeBytes,
      receivedBytes: downloadedBytes,
      status: DownloadStatus.inProgress,
    );
  }

  Future<Directory> _getModelsDir() async {
    final appDir = await getApplicationDocumentsDirectory();
    return Directory('${appDir.path}/models');
  }

  Map<String, int> _memoryCache = {};

  Future<Map<String, int>> _getMemoryInfo() async {
    if (_memoryCache.isNotEmpty) return _memoryCache;

    // Return dummy values - would be populated by native side in production
    _memoryCache = {'freeMB': 5120, 'totalMB': 8192};
    return _memoryCache;
  }
}

// ----- Supporting data classes -----

enum ModelType { text, vision, stt, tts }

enum ColorStatus { green, yellow, red }

enum DownloadStatus { pending, inProgress, paused, completed, failed }

class ModelConfig {
  final String id;
  final String name;
  final ModelType type;
  final String url;
  final String mirrorUrl;
  final int sizeBytes;
  final String sizeMBDisplay;
  final bool recommended;
  final int minRamMB; // Minimum free RAM needed (MB)

  const ModelConfig({
    required this.id,
    required this.name,
    required this.type,
    required this.url,
    required this.mirrorUrl,
    required this.sizeBytes,
    required this.sizeMBDisplay,
    this.recommended = false,
    this.minRamMB = 0,
  });
}

class ModelRecommendation {
  final ModelConfig model;
  final ColorStatus status;
  ModelRecommendation({required this.model, required this.status});
}

class MemoryRecommendation {
  final int freeMB;
  final int totalMB;
  final List<ModelRecommendation> recommendations;
  MemoryRecommendation({
    required this.freeMB,
    required this.totalMB,
    required this.recommendations,
  });
}

class DownloadProgress {
  final String modelId;
  final int totalBytes;
  final int receivedBytes;
  final DownloadStatus status;
  DownloadProgress({
    required this.modelId,
    required this.totalBytes,
    required this.receivedBytes,
    this.status = DownloadStatus.pending,
  });

  double get progress => totalBytes > 0 ? receivedBytes / totalBytes : 0.0;
  String get progressPercent => '${(progress * 100).toStringAsFixed(1)}%';
}

typedef ProgressCallback = void Function(DownloadProgress progress);
