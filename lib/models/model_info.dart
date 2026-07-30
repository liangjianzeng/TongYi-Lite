// ============================================================
// Model metadata, mirror entries, and download task state.
// All model configurations live here; the UI reads from it.
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

class MirrorEntry {
  final String url;
  final String source;

  const MirrorEntry(this.url, this.source);

  @override
  @override
  String toString() {
    final masked = url.replaceAll(RegExp(r'https://[^/]+'), 'https://***');
    return 'Mirror($source: $masked)';
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

  String get bestMirrorUrl => mirrors.first.url;
  int get sizeMB => sizeBytes ~/ (1024 * 1024);

  @override
  String toString() => 'ModelConfig($id, ${sizeMBDisplay}, type=${modelTypeLabel(type)})';
}

List<ModelConfig> builtInModels() {
  return [
    ModelConfig(
      id: 'qwen3-1.7b-q4_k_m',
      name: 'Qwen3-1.7B Instruct (Q4_K_M)',
      type: ModelType.text,
      mirrors: [
        MirrorEntry('https://hf-mirror.com/Qwen/Qwen3-1.7B-Instruct-GGUF/resolve/main/qwen3-1.7b-instruct-q4_k_m.gguf', 'hf-mirror'),
        MirrorEntry('https://modelscope.cn/guanpengchuan/Qwen3-1.7B-Instruct-GGUF/resolve/main/qwen3-1.7b-instruct-q4_k_m.gguf', 'modelscope'),
        MirrorEntry('https://huggingface.co/Qwen/Qwen3-1.7B-Instruct-GGUF/resolve/main/qwen3-1.7b-instruct-q4_k_m.gguf', 'huggingface'),
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
        MirrorEntry('https://hf-mirror.com/Qwen/Qwen3-1.7B-Instruct-GGUF/resolve/main/qwen3-1.7b-instruct-q5_k_m.gguf', 'hf-mirror'),
        MirrorEntry('https://modelscope.cn/guanpengchuan/Qwen3-1.7B-Instruct-GGUF/resolve/main/qwen3-1.7b-instruct-q5_k_m.gguf', 'modelscope'),
        MirrorEntry('https://huggingface.co/Qwen/Qwen3-1.7B-Instruct-GGUF/resolve/main/qwen3-1.7b-instruct-q5_k_m.gguf', 'huggingface'),
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
        MirrorEntry('https://hf-mirror.com/Qwen/Qwen3-0.6B-Instruct-GGUF/resolve/main/Qwen3-0.6B-Instruct-Q4_K_M.gguf', 'hf-mirror'),
        MirrorEntry('https://modelscope.cn/guanpengchuan/Qwen3-0.6B-Instruct-GGUF/resolve/main/Qwen3-0.6B-Instruct-Q4_K_M.gguf', 'modelscope'),
        MirrorEntry('https://huggingface.co/Qwen/Qwen3-0.6B-Instruct-GGUF/resolve/main/Qwen3-0.6B-Instruct-Q4_K_M.gguf', 'huggingface'),
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
        MirrorEntry('https://hf-mirror.com/Qwen/Qwen3.5-4B-Instruct-GGUF/resolve/main/Qwen3.5-4B-Instruct-Q4_K_M.gguf', 'hf-mirror'),
        MirrorEntry('https://modelscope.cn/guanpengchuan/Qwen3.5-4B-Instruct-GGUF/resolve/main/Qwen3.5-4B-Instruct-Q4_K_M.gguf', 'modelscope'),
        MirrorEntry('https://huggingface.co/Qwen/Qwen3.5-4B-Instruct-GGUF/resolve/main/Qwen3.5-4B-Instruct-Q4_K_M.gguf', 'huggingface'),
      ],
      sizeBytes: 2500 * 1024 * 1024,
      sizeMBDisplay: '2.5 GB',
      recommended: true,
      minRamMB: 3500,
    ),
  ];
}

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

  double get progress => totalBytes > 0 ? downloadedBytes / totalBytes : 0.0;
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
