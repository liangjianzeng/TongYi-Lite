// ============================================================
// Model metadata, mirror entries, and download task state.
// All model configurations live here; the UI reads from it.
// ============================================================

// ------------------------------------------------------------------
// 模型类型
// ------------------------------------------------------------------
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

// ------------------------------------------------------------------
// 镜像条目 — 一个可下载的来源
// ------------------------------------------------------------------
class MirrorEntry {
  final String url;        // 完整下载 URL
  final String source;     // "hf-mirror" / "modelscope" / "huggingface"

  const MirrorEntry(this.url, this.source);

  @override
  String toString() => 'Mirror($source: ${url.replaceAll(RegExp(r'https://[^/]+'), 'https://***'))}';
}

// ------------------------------------------------------------------
// 模型配置 — 一个可供下载的 GGUF 模型
// ------------------------------------------------------------------
class ModelConfig {
  final String id;
  final String name;
  final ModelType type;

  /// 镜像优先级从高到低（国内优先）
  final List<MirrorEntry> mirrors;

  final int sizeBytes;
  final String sizeMBDisplay;
  final bool recommended;
  final int minRamMB; // Minimum free RAM needed (MB)
  final String? sha256Hash; // Optional integrity check hash

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
  });

  /// Best (first) mirror URL
  String get bestMirrorUrl => mirrors.first.url;

  /// Human-readable size in MB
  int get sizeMB => sizeBytes ~/ (1024 * 1024);

  @override
  String toString() => 'ModelConfig($id, ${sizeMBDisplay}, type=${modelTypeLabel(type)})';
}

// ------------------------------------------------------------------
// 内置模型列表（硬编码 + 可扩展）
// ------------------------------------------------------------------
List<ModelConfig> builtInModels() {
  return [
    ModelConfig(
      id: 'qwen3-1.7b-q4_k_m',
      name: 'Qwen3-1.7B Instruct (Q4_K_M)',
      type: ModelType.text,
      mirrors: [
        MirrorEntry(
          'https://hf-mirror.com/Qwen/Qwen3-1.7B-Instruct-GGUF/resolve/main/qwen3-1.7b-instruct-q4_k_m.gguf',
          'hf-mirror',
        ),
        MirrorEntry(
          'https://modelscope.cn/guanpengchuan/Qwen3-1.7B-Instruct-GGUF/resolve/main/qwen3-1.7b-instruct-q4_k_m.gguf',
          'modelscope',
        ),
        MirrorEntry(
          'https://huggingface.co/Qwen/Qwen3-1.7B-Instruct-GGUF/resolve/main/qwen3-1.7b-instruct-q4_k_m.gguf',
          'huggingface',
        ),
      ],
      sizeBytes: 1200 * 1024 * 1024,
      sizeMBDisplay: '1.2 GB',
      recommended: true,
      minRamMB: 1200,
    ),
    ModelConfig(
      id: 'qwen3-1.7b-q5_k_m',
      name: 'Qwen3-1.7B (Q5_K_M)',
      type: ModelType.text,
      mirrors: [
        MirrorEntry(
          'https://hf-mirror.com/Qwen/Qwen3-1.7B-Instruct-GGUF/resolve/main/qwen3-1.7b-instruct-q5_k_m.gguf',
          'hf-mirror',
        ),
        MirrorEntry(
          'https://modelscope.cn/guanpengchuan/Qwen3-1.7B-Instruct-GGUF/resolve/main/qwen3-1.7b-instruct-q5_k_m.gguf',
          'modelscope',
        ),
        MirrorEntry(
          'https://huggingface.co/Qwen/Qwen3-1.7B-Instruct-GGUF/resolve/main/qwen3-1.7b-instruct-q5_k_m.gguf',
          'huggingface',
        ),
      ],
      sizeBytes: 1450 * 1024 * 1024,
      sizeMBDisplay: '1.5 GB',
      recommended: false,
      minRamMB: 1500,
    ),
    ModelConfig(
      id: 'qwen3-0.6b-q4_k_m',
      name: 'Qwen3-0.6B Instruct (Q4_K_M)',
      type: ModelType.text,
      mirrors: [
        MirrorEntry(
          'https://hf-mirror.com/Qwen/Qwen3-0.6B-Instruct-GGUF/resolve/main/Qwen3-0.6B-Instruct-Q4_K_M.gguf',
          'hf-mirror',
        ),
        MirrorEntry(
          'https://modelscope.cn/guanpengchuan/Qwen3-0.6B-Instruct-GGUF/resolve/main/Qwen3-0.6B-Instruct-Q4_K_M.gguf',
          'modelscope',
        ),
        MirrorEntry(
          'https://huggingface.co/Qwen/Qwen3-0.6B-Instruct-GGUF/resolve/main/Qwen3-0.6B-Instruct-Q4_K_M.gguf',
          'huggingface',
        ),
      ],
      sizeBytes: 420 * 1024 * 1024,
      sizeMBDisplay: '420 MB',
      recommended: true,
      minRamMB: 500,
    ),
    ModelConfig(
      id: 'qwen3.5-4b-q4_k_m',
      name: 'Qwen3.5-4B Instruct (Q4_K_M)',
      type: ModelType.vision,
      mirrors: [
        MirrorEntry(
          'https://hf-mirror.com/Qwen/Qwen3.5-4B-Instruct-GGUF/resolve/main/Qwen3.5-4B-Instruct-Q4_K_M.gguf',
          'hf-mirror',
        ),
        MirrorEntry(
          'https://modelscope.cn/guanpengchuan/Qwen3.5-4B-Instruct-GGUF/resolve/main/Qwen3.5-4B-Instruct-Q4_K_M.gguf',
          'modelscope',
        ),
        MirrorEntry(
          'https://huggingface.co/Qwen/Qwen3.5-4B-Instruct-GGUF/resolve/main/Qwen3.5-4B-Instruct-Q4_K_M.gguf',
          'huggingface',
        ),
      ],
      sizeBytes: 2500 * 1024 * 1024,
      sizeMBDisplay: '2.5 GB',
      recommended: true,
      minRamMB: 3500,
    ),
  ];
}

// ------------------------------------------------------------------
// 下载任务状态
// ------------------------------------------------------------------
enum DownloadState { idle, downloading, paused, completed, failed, verifying }

String downloadStateLabel(DownloadState state) {
  switch (state) {
    case DownloadState.idle:
      return '待下载';
    case DownloadState.downloading:
      return '下载中';
    case DownloadState.paused:
      return '已暂停';
    case DownloadState.completed:
      return '已完成';
    case DownloadState.failed:
      return '失败';
    case DownloadState.verifying:
      return '校验中';
  }
}

class DownloadTask {
  final String modelId;
  DownloadState state;
  int downloadedBytes;   // 已下载的字节数（含续传）
  int totalBytes;        // 文件总大小
  String? errorMessage;
  DateTime? startTime;
  DateTime? endTime;

  DownloadTask({
    required this.modelId,
    this.state = DownloadState.idle,
    this.downloadedBytes = 0,
    this.totalBytes = 0,
    this.errorMessage,
  });

  double get progress => totalBytes > 0 ? downloadedBytes / totalBytes : 0.0;
  String get progressPercent => '${(progress * 100).toStringAsFixed(1)}%';

  /// Human-readable downloaded size (e.g. "640 MB")
  String get downloadedDisplay {
    final mb = downloadedBytes / (1024 * 1024);
    if (mb >= 1024) return '${(mb / 1024).toStringAsFixed(1)} GB';
    return '${mb.toStringAsFixed(0)} MB';
  }

  /// Human-readable total size
  String get totalDisplay {
    final mb = totalBytes / (1024 * 1024);
    if (mb >= 1024) return '${(mb / 1024).toStringAsFixed(1)} GB';
    return '${mb.toStringAsFixed(0)} MB';
  }

  /// Estimated time remaining in seconds (simplified)
  int get etaSeconds {
    if (state != DownloadState.downloading || progress >= 1.0) return 0;
    final elapsed = DateTime.now().difference(startTime ?? DateTime.now());
    if (elapsed.inSeconds <= 0) return 0;
    final rate = downloadedBytes / elapsed.inSeconds;
    final remaining = totalBytes - downloadedBytes;
    return (remaining / rate).round();
  }

  String get etaDisplay {
    final s = etaSeconds;
    if (s <= 0) return '--';
    if (s < 60) return '${s}s';
    if (s < 3600) return '${s ~/ 60}m ${s % 60}s';
    return '${s ~/ 3600}h ${(s % 3600) ~/ 60}m';
  }

  DownloadTask copyWith({
    DownloadS
