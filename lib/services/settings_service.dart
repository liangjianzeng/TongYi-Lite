import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/api_model.dart';

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

  /// 全局 MTP 功能总开关（默认关闭）。用于控制整个 APP 的 MTP 是否
  /// 「可见可用」：
  /// - 关闭（默认）：模型卡片不显示各模型的 MTP 开关，加载模型时也强制
  ///   不启用 MTP（即使某模型曾配置开启）。
  /// - 开启：模型列表卡片显示各支持 MTP 模型的开关，用户可逐个配置；
  ///   加载时按 `enableMtpFeature && mtpEnabled(modelId)` 决定是否启用。
  /// 端侧 MTP 性能差收益差，故默认关闭，仅高端机用户按需打开测试。
  final bool enableMtpFeature;

  /// 启动后自动加载的「默认模型」id。null = 未设置。
  /// 用户在模型管理页对某个已缓存模型勾选「设为默认」后持久化；
  /// 启动进入首页时若该模型已缓存则自动加载，保证开箱即用。
  final String? defaultModelId;

  /// 已配置的 OpenAI 兼容远程模型列表（可配多个，密钥明文存本地）。
  final List<ApiModelConfig> apiModels;

  /// 当前激活的 API 模型 id。null = 停用 API 接入（仅用本地模型）。
  /// 路由策略：本地模型优先，仅当本地模型未加载/加载失败时才走激活的 API。
  final String? activeApiModelId;

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
    this.enableMtpFeature = false,
    this.defaultModelId,
    List<ApiModelConfig>? apiModels,
    this.activeApiModelId,
  })  : mtpEnabledByModel = mtpEnabledByModel ?? const {},
        apiModels = apiModels ?? const [];

  /// 便捷读取：某个模型是否启用 MTP（未配置视为关闭）。
  bool mtpEnabled(String modelId) => mtpEnabledByModel[modelId] ?? false;

  /// 便捷读取：当前激活的 API 模型配置；未激活/不存在返回 null。
  ApiModelConfig? activeApiModel() {
    if (activeApiModelId == null) return null;
    for (final cfg in apiModels) {
      if (cfg.id == activeApiModelId) return cfg;
    }
    return null;
  }

  InferenceSettings copyWith(
      {bool? enableGpu,
      int? gpuLayers,
      int? contextSize,
      bool? enableThinking,
      String? gpuBackend,
      Map<String, bool>? mtpEnabledByModel,
      bool? enableMtpFeature,
      String? defaultModelId,
      // defaultModelId 为可空 String，无法用 `?? this` 区分「未传」与「清空」，
      // 故增加显式清空标记，供取消默认模型时使用。
      bool clearDefaultModel = false,
      List<ApiModelConfig>? apiModels,
      String? activeApiModelId,
      // activeApiModelId 同样可空，需显式标记以区分「未传」与「停用」。
      bool clearActiveApiModel = false}) {
    return InferenceSettings(
      enableGpu: enableGpu ?? this.enableGpu,
      gpuLayers: gpuLayers ?? this.gpuLayers,
      contextSize: contextSize ?? this.contextSize,
      enableThinking: enableThinking ?? this.enableThinking,
      gpuBackend: gpuBackend ?? this.gpuBackend,
      mtpEnabledByModel: mtpEnabledByModel ?? this.mtpEnabledByModel,
      enableMtpFeature: enableMtpFeature ?? this.enableMtpFeature,
      defaultModelId: clearDefaultModel
          ? null
          : defaultModelId ?? this.defaultModelId,
      apiModels: apiModels ?? this.apiModels,
      activeApiModelId: clearActiveApiModel
          ? null
          : activeApiModelId ?? this.activeApiModelId,
    );
  }

  Map<String, dynamic> toJson() => {
        'enableGpu': enableGpu,
        'gpuLayers': gpuLayers,
        'contextSize': contextSize,
        'enableThinking': enableThinking,
        'gpuBackend': gpuBackend,
        'mtpEnabledByModel': mtpEnabledByModel,
        'enableMtpFeature': enableMtpFeature,
        'defaultModelId': defaultModelId,
        'apiModels': apiModels.map((m) => m.toJson()).toList(),
        'activeApiModelId': activeApiModelId,
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
      // 全局 MTP 开关：旧配置无此字段时默认关闭（向后兼容）。
      enableMtpFeature: json['enableMtpFeature'] as bool? ?? false,
      defaultModelId: json['defaultModelId'] as String?,
      // 旧配置缺这两个字段时默认空列表 + 停用，向后兼容。
      apiModels: _parseApiModels(json['apiModels']),
      activeApiModelId: json['activeApiModelId'] as String?,
    );
  }

  /// 解析 API 模型列表；缺字段/格式非法时返回空列表（不崩）。
  static List<ApiModelConfig> _parseApiModels(Object? raw) {
    if (raw is! List) return const [];
    final list = <ApiModelConfig>[];
    for (final e in raw) {
      if (e is Map<String, dynamic>) {
        list.add(ApiModelConfig.fromJson(e));
      } else if (e is Map) {
        list.add(ApiModelConfig.fromJson(Map<String, dynamic>.from(e)));
      }
    }
    return list;
  }

  /// 兼容旧配置：旧字段 `enableMtp`（全局 bool）→ 新的按模型 map。
  ///
  /// 关键修复：文件里若已存在 `mtpEnabledByModel`（当前版本标准格式），
  /// **必须原样采用**，不能因为缺少顶层 `enableMtp` 字段就整体丢弃——
  /// 否则每次 reload 都会把用户按模型开启的 MTP 开关清空，导致 MTP 永远不生效。
  /// 仅当 `mtpEnabledByModel` 缺失（老版本只有全局 `enableMtp:true`）时，
  /// 因无法定位具体模型而保持默认全关，由用户重新按模型开启。
  static Map<String, bool> _migrateLegacyMtp(Map<String, dynamic> json) {
    final map = json['mtpEnabledByModel'] as Map<String, dynamic>?;
    if (map != null) {
      return map.map((k, v) => MapEntry(k, v as bool? ?? false));
    }
    // 仅有旧版全局 enableMtp：true 且未迁移过时，保持默认全关（无法知道开了哪个模型）。
    final legacy = json['enableMtp'] as bool? ?? false;
    if (!legacy) return const {};
    return const {};
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
