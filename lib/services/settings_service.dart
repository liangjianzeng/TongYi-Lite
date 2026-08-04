import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 推理引擎相关的用户设置（GPU 加速开关 + 卸载层数 + 后端选择 + 上下文大小）。
///
/// 默认关闭 GPU 加速（用户可在设置页开启；开启后 auto 优先选 OpenCL，
/// 与 Vulkan 在 Adreno 825 上实测等效、均无数值崩坏），卸载层数默认 100
/// （全量卸载；llama.cpp 会自动 clamp 到模型实际层数），
/// 上下文大小默认 4096，最大 65536。
class InferenceSettings {
  final bool enableGpu;
  final int gpuLayers;
  final int contextSize;

  /// 是否允许 Qwen3 思考模式（<think> 链）。默认关闭 = 直接作答，响应更快。
  final bool enableThinking;

  /// GPU 后端选择：'cpu' / 'vulkan' / 'opencl' / 'auto'。
  /// 默认 'auto'：优先 OpenCL（Adreno 825 上 OpenCL 驱动高度优化，与 Vulkan
  /// 实测吞吐几乎等价；两者均经真机验证可正常输出，无数值崩坏）。用户可切到
  /// Vulkan 对比。llama.rn 在 Android 上即用 OpenCL 后端，Adreno 700+ 可用。
  final String gpuBackend;

  const InferenceSettings({
    // 默认关闭 GPU：避免"设置未持久化/重启回退默认"时悄悄占用 GPU 内存；
    // 用户显式开启后，auto 会优先选 OpenCL（与 Vulkan 在 Adreno 825 上等效，
    // 均经真机验证无数值崩坏）。
    this.enableGpu = false,
    this.gpuLayers = 100,
    this.contextSize = 4096,
    this.enableThinking = false,
    this.gpuBackend = 'auto',
  });

  InferenceSettings copyWith(
      {bool? enableGpu,
      int? gpuLayers,
      int? contextSize,
      bool? enableThinking,
      String? gpuBackend}) {
    return InferenceSettings(
      enableGpu: enableGpu ?? this.enableGpu,
      gpuLayers: gpuLayers ?? this.gpuLayers,
      contextSize: contextSize ?? this.contextSize,
      enableThinking: enableThinking ?? this.enableThinking,
      gpuBackend: gpuBackend ?? this.gpuBackend,
    );
  }

  Map<String, dynamic> toJson() => {
        'enableGpu': enableGpu,
        'gpuLayers': gpuLayers,
        'contextSize': contextSize,
        'enableThinking': enableThinking,
        'gpuBackend': gpuBackend,
      };

  factory InferenceSettings.fromJson(Map<String, dynamic> json) {
    return InferenceSettings(
      // 缺省/旧文件未存该字段时回落纯 CPU（安全路径，规避坏掉的 Vulkan）。
      enableGpu: json['enableGpu'] as bool? ?? false,
      gpuLayers: (json['gpuLayers'] as num?)?.toInt() ?? 20,
      contextSize: (json['contextSize'] as num?)?.toInt() ?? 4096,
      enableThinking: json['enableThinking'] as bool? ?? false,
      gpuBackend: json['gpuBackend'] as String? ?? 'auto',
    );
  }
}

/// 基于本地 JSON 文件的轻量设置持久化（不引入额外依赖，复用 path_provider）。
///
/// 文件位于应用文档目录下的 `inference_settings.json`。
class SettingsService {
  static const _fileName = 'inference_settings.json';

  Future<String> _resolvePath() async {
    final dir = await getApplicationDocumentsDirectory();
    return p.join(dir.path, _fileName);
  }

  /// 读取设置；文件不存在或损坏时返回默认值。
  Future<InferenceSettings> load() async {
    try {
      final path = await _resolvePath();
      final file = File(path);
      if (!await file.exists()) return const InferenceSettings();
      final content = await file.readAsString();
      if (content.trim().isEmpty) return const InferenceSettings();
      final json = jsonDecode(content) as Map<String, dynamic>;
      return InferenceSettings.fromJson(json);
    } catch (e) {
      // 任何解析错误都回落到默认值，避免影响主流程。
      return const InferenceSettings();
    }
  }

  /// 写入设置。失败时抛出异常由调用方处理。
  Future<void> save(InferenceSettings settings) async {
    final path = await _resolvePath();
    final file = File(path);
    await file.writeAsString(jsonEncode(settings.toJson()));
  }
}
