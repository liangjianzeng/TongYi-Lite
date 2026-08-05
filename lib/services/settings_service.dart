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

  /// 是否启用 MTP（多 token 预测）加速，按模型 id 逐个开关（默认全关）。
  /// 仅对带 NextN 头的模型生效——MTP 的 draft/verify/process 三次完整前向
  /// 开销在端侧通常不划算，用户可在模型列表对每个支持的模型手动开启，
  /// 互不影响。
  final Map<String, bool> mtpEnabledByModel;

  const InferenceSettings({
    // 默认开启 GPU：与 gpuLayers=100 全量卸载一致；在 settingsProvider
    // 异步 _load() 完成前，UI/加载逻辑若读取默认值，仍应走 GPU 路径，
    // 避免启动后首次加载模型意外落到 CPU。
    this.enableGpu = true,
    this.gpuLayers = 100,
    this.contextSize = 4096,
    this.enableThinking = false,
    this.gpuBackend = 'auto',
    Map<String, bool>? mtpEnabledByModel,
  }) : mtpEnabledByModel = mtpEnabledByModel ?? const {};

  /// 便捷读取：某个模型是否启用 MTP（未配置视为关闭）。
  bool mtpEnabled(String modelId) => mtpEnabledByModel[modelId] ?? false;

  InferenceSettings copyWith(
      {bool? enableGpu,
      int? gpuLayers,
      int? contextSize,
      bool? enableThinking,
      String? gpuBackend,
      Map<String, bool>? mtpEnabledByModel}) {
    return InferenceSettings(
      enableGpu: enableGpu ?? this.enableGpu,
      gpuLayers: gpuLayers ?? this.gpuLayers,
      contextSize: contextSize ?? this.contextSize,
      enableThinking: enableThinking ?? this.enableThinking,
      gpuBackend: gpuBackend ?? this.gpuBackend,
      mtpEnabledByModel: mtpEnabledByModel ?? this.mtpEnabledByModel,
    );
  }

  Map<String, dynamic> toJson() => {
        'enableGpu': enableGpu,
        'gpuLayers': gpuLayers,
        'contextSize': contextSize,
        'enableThinking': enableThinking,
        'gpuBackend': gpuBackend,
        'mtpEnabledByModel': mtpEnabledByModel,
      };

  factory InferenceSettings.fromJson(Map<String, dynamic> json) {
    return InferenceSettings(
      // 缺省/旧文件未存该字段时默认开启 GPU：auto 后端会在无 GPU 时自动
      // 回落 CPU，V0.1.3 已验证 Adreno 825 OpenCL/Vulkan 均正常。
      enableGpu: json['enableGpu'] as bool? ?? true,
      gpuLayers: (json['gpuLayers'] as num?)?.toInt() ?? 100,
      contextSize: (json['contextSize'] as num?)?.toInt() ?? 4096,
      enableThinking: json['enableThinking'] as bool? ?? false,
      gpuBackend: json['gpuBackend'] as String? ?? 'auto',
      // 旧版本存的是全局 bool enableMtp：若读到它，则映射为所有支持模型的
      // 默认值，保证老配置不丢。
      mtpEnabledByModel: _migrateLegacyMtp(json),
    );
  }

  /// 兼容旧配置：旧字段 `enableMtp`（全局 bool）→ 新的按模型 map。
  /// 旧值 true 时无法知道用户开了哪个模型，统一不迁移（保持默认全关），
  /// 由用户重新按模型开启；旧值 false 即默认全关，无需迁移。
  static Map<String, bool> _migrateLegacyMtp(Map<String, dynamic> json) {
    final legacy = json['enableMtp'] as bool? ?? false;
    if (!legacy) return const {};
    final map = json['mtpEnabledByModel'] as Map<String, dynamic>?;
    if (map == null) return const {};
    return map.map((k, v) => MapEntry(k, v as bool? ?? false));
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
