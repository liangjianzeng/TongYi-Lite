// ============================================================
// Model metadata, mirror entries, and download task state.
// All model configurations live in assets/models_catalog.json
// and are loaded dynamically via ModelCatalog.load().
// ============================================================

enum ModelType { text, vision }

String modelTypeLabel(ModelType type) {
  switch (type) {
    case ModelType.text:
      return 'text';
    case ModelType.vision:
      return 'vision';
  }
}

String modelTypeIcon(ModelType type) {
  switch (type) {
    case ModelType.text:
      return '\u{1F4AC}'; // 💬
    case ModelType.vision:
      return '\u{1F5BC}\u{FE0F}'; // 🖼️
  }
}

/// 去掉模型名里括号内的精度/量化说明（如 "Qwen3.5-0.8B (Q4_K_M MTP)" → "Qwen3.5-0.8B"），
/// 用于界面显示以缩短长度。仅去掉末尾的括号段；无括号时原样返回。
String cleanModelName(String name) {
  final trimmed = name.trim();
  final match = RegExp(r'\s*\([^()]*\)\s*$').firstMatch(trimmed);
  if (match == null) return trimmed;
  return trimmed.substring(0, match.start).trim();
}

class MirrorEntry {
  final String url;
  final String source;

  const MirrorEntry(this.url, this.source);

  @override
  String toString() {
    final masked = url.replaceAll(RegExp(r'https://[^/]+'), 'https://***');
    return 'Mirror($source: $masked)';
  }

  factory MirrorEntry.fromJson(Map<String, dynamic> json) {
    return MirrorEntry(json['url'] as String, json['source'] as String);
  }
}

ModelType modelTypeFromJson(String value) {
  switch (value.toLowerCase()) {
    case 'vision':
      return ModelType.vision;
    case 'text':
    default:
      return ModelType.text;
  }
}

/// 多模态投影器（mmproj）配置 —— 用于「text + mmproj 两文件」形态的视觉模型。
///
/// 与 [ModelConfig] 的关系：
/// - 模型 `mmproj == null` 且 `type == vision` → **单文件自包含 VL**（如 QWEN3），
///   只需下载/加载主 gguf 一个文件，视觉编码器内置于其中；
/// - 模型 `mmproj != null` → **text + mmproj 两文件**（如 QWEN3.5），需额外下载/加载
///   投影器 gguf，主模型才能理解图片。
///
/// 原生层按 mmproj 是否存在决定是否加载投影器，两形态共用同一套加载路径。
class MmprojConfig {
  final List<MirrorEntry> mirrors;
  final int sizeBytes;
  final String sizeMBDisplay;
  final String? sha256Hash;

  const MmprojConfig({
    required this.mirrors,
    required this.sizeBytes,
    required this.sizeMBDisplay,
    this.sha256Hash,
  });

  String get bestMirrorUrl => mirrors.first.url;
  int get sizeMB => sizeBytes ~/ (1024 * 1024);

  @override
  String toString() => 'MmprojConfig(${sizeMBDisplay})';

  factory MmprojConfig.fromJson(Map<String, dynamic> json) {
    // mmproj 文件较小，用 sizeMB（而非主模型的 sizeGB）估算。
    final sizeMB = (json['sizeMB'] as num?)?.toDouble() ?? 0.0;
    return MmprojConfig(
      mirrors: (json['mirrors'] as List)
          .map((e) => MirrorEntry.fromJson(e as Map<String, dynamic>))
          .toList(),
      sizeBytes: (sizeMB * 1024 * 1024).round(),
      sizeMBDisplay: json['sizeMBDisplay'] as String? ?? '${sizeMB.toStringAsFixed(1)} MB',
      sha256Hash: json['sha256Hash'] as String?,
    );
  }
}

class ModelConfig {
  final String id;
  final String name;
  final ModelType type;
  final List<MirrorEntry> mirrors;
  final int sizeBytes;
  final String sizeMBDisplay;
  final bool recommended;
  final int minRamMB;
  final String? sha256Hash;
  final bool mtp;

  /// 特性标签（如 "推荐" / "速度快"），用于 UI 展示的小 chip。
  final List<String> tags;

  /// 可选的 mmproj 投影器配置。null + type=vision → 单文件自包含 VL。
  final MmprojConfig? mmproj;

  const ModelConfig({
    required this.id,
    required this.name,
    required this.type,
    required this.mirrors,
    required this.sizeBytes,
    required this.sizeMBDisplay,
    this.recommended = false,
    this.minRamMB = 0,
    this.sha256Hash,
    this.mtp = false,
    this.tags = const [],
    this.mmproj,
  });

  String get bestMirrorUrl => mirrors.first.url;
  int get sizeMB => sizeBytes ~/ (1024 * 1024);

  /// 该模型是否支持视觉理解（type == vision）。
  /// 注意：单文件 VL 与 text+mmproj 两文件形态都归入 true，
  /// 原生层依据 [mmproj] 是否存在决定加载方式。
  bool get supportsVision => type == ModelType.vision;

  /// 需要 mmproj 的模型，其总下载体积（主 gguf + mmproj）。
  int get totalBytes => sizeBytes + (mmproj?.sizeBytes ?? 0);

  @override
  String toString() => 'ModelConfig($id, ${sizeMBDisplay}, type=${modelTypeLabel(type)}, '
      'mmproj=${mmproj == null ? '单文件VL' : '两文件+mmproj'})';

  factory ModelConfig.fromJson(Map<String, dynamic> json) {
    final sizeGB = (json['sizeGB'] as num?)?.toDouble() ?? 0.0;
    return ModelConfig(
      id: json['id'] as String,
      name: json['name'] as String,
      type: modelTypeFromJson(json['type'] as String? ?? 'text'),
      mirrors: (json['mirrors'] as List)
          .map((e) => MirrorEntry.fromJson(e as Map<String, dynamic>))
          .toList(),
      sizeBytes: (sizeGB * 1024 * 1024 * 1024).round(),
      sizeMBDisplay: json['sizeMBDisplay'] as String? ?? '${sizeGB.toStringAsFixed(1)} GB',
      recommended: json['recommended'] as bool? ?? false,
      minRamMB: json['minRamMB'] as int? ?? 0,
      sha256Hash: json['sha256Hash'] as String?,
      mtp: json['mtp'] as bool? ?? false,
      tags: (json['tags'] as List?)?.map((e) => e as String).toList() ??
          const [],
      mmproj: json['mmproj'] != null
          ? MmprojConfig.fromJson(json['mmproj'] as Map<String, dynamic>)
          : null,
    );
  }
}

// ===================================================================
// Download task state
// ===================================================================

enum DownloadState { idle, downloading, paused, completed, failed, verifying }

String downloadStateLabel(DownloadState state) {
  switch (state) {
    case DownloadState.idle: return '待下载';
    case DownloadState.downloading: return '下载中';
    case DownloadState.paused: return '已暂停';
    case DownloadState.completed: return '已完成';
    case DownloadState.failed: return '失败';
    case DownloadState.verifying: return '校验中';
  }
}

class DownloadTask {
  final String modelId;
  DownloadState state;
  int downloadedBytes;
  int totalBytes;
  String? errorMessage;
  DateTime? startTime;
  DateTime? endTime;

  DownloadTask({
    required this.modelId,
    this.state = DownloadState.idle,
    this.downloadedBytes = 0,
    this.totalBytes = 0,
    this.errorMessage,
    this.startTime,
    this.endTime,
  });

  double get progress => totalBytes > 0
      // catalog 的 sizeBytes 是按 sizeGB 估算的，实际下载文件可能更大，
      // downloadedBytes 可能短暂超过 totalBytes —— 进度条必须封顶到 100%，
      // 避免出现「进度超过 100%」的视觉异常。
      ? (downloadedBytes / totalBytes).clamp(0.0, 1.0)
      : 0.0;
  String get progressPercent => '${(progress * 100).toStringAsFixed(1)}%';

  String get downloadedDisplay {
    final mb = downloadedBytes / (1024 * 1024);
    if (mb >= 1024) return '${(mb / 1024).toStringAsFixed(1)} GB';
    return '${mb.toStringAsFixed(0)} MB';
  }

  String get totalDisplay {
    final mb = totalBytes / (1024 * 1024);
    if (mb >= 1024) return '${(mb / 1024).toStringAsFixed(1)} GB';
    return '${mb.toStringAsFixed(0)} MB';
  }

  DownloadTask copyWith({
    DownloadState? state,
    int? downloadedBytes,
    int? totalBytes,
    String? errorMessage,
    DateTime? startTime,
    DateTime? endTime,
  }) {
    return DownloadTask(
      modelId: modelId,
      state: state ?? this.state,
      downloadedBytes: downloadedBytes ?? this.downloadedBytes,
      totalBytes: totalBytes ?? this.totalBytes,
      errorMessage: errorMessage ?? this.errorMessage,
      startTime: startTime ?? this.startTime,
      endTime: endTime ?? this.endTime,
    );
  }
}
