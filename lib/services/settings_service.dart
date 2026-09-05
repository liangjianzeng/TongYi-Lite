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

  /// 是否启用 dspark 投机加速，按模型 id 逐个开关（默认全关）。
  /// 仅对目录声明 dspark 草稿头（config.dspark）且草稿文件已下载完整的模型
  /// 生效——与 MTP 互斥（原生层二选一），互不影响。
  final Map<String, bool> dsparkEnabledByModel;

  /// 全局 dspark 功能总开关（默认关闭）。用于控制整个 APP 的 dspark 是否
  /// 「可见可用」：
  /// - 关闭（默认）：模型卡片不显示各模型的 dspark 开关，加载模型时也强制
  ///   不启用（即使某模型曾配置开启）。
  /// - 开启：模型列表卡片显示声明了草稿头模型的 dspark 开关，用户可逐个
  ///   配置；加载时按 `enableDsparkFeature && dsparkEnabled(modelId)` 决定
  ///   是否带上草稿模型。
  /// 端侧 Q1_0 等低比特模型上 dspark 收益有限（验证批摊不动权重读取，
  /// 净吞吐≈基线甚至更低），故默认关闭，按需开启。
  final bool enableDsparkFeature;

  /// 启动后自动加载的「默认模型」id。null = 未设置。
  /// 用户在模型管理页对某个已缓存模型勾选「设为默认」后持久化；
  /// 启动进入首页时若该模型已缓存则自动加载，保证开箱即用。
  final String? defaultModelId;

  /// 已配置的 OpenAI 兼容远程模型列表（可配多个，密钥明文存本地）。
  final List<ApiModelConfig> apiModels;

  /// 当前激活的 API 模型 id。null = 停用 API 接入（仅用本地模型）。
  /// 路由策略：本地模型优先，仅当本地模型未加载/加载失败时才走激活的 API。
  final String? activeApiModelId;

  // ---------------------------------------------------------------
  // 智能体（Agent）配置
  // ---------------------------------------------------------------

  /// 智能体模式总开关。默认开启：无工具时一轮直答（与普通聊天一致），
  /// 有工具调用时进入工具循环。关闭 = 完全走普通聊天路径。
  final bool agentEnabled;

  /// 智能体驱动模型来源：'local'（本地端侧模型）/ 'api'（API 接入模型）。
  /// null = 跟随默认路由（本地优先，API 兜底）。
  final String? agentModelSource;

  /// 智能体驱动模型 id（对应本地模型目录 id 或 API 模型配置 id）。
  /// 与 [agentModelSource] 成对使用；source 为 null 时忽略。
  final String? agentModelId;

  /// 智能体模式的上下文长度（n_ctx）。独立于普通聊天的 [contextSize]：
  /// 工具循环需要额外空间容纳「工具调用 + 结果回填」历史。
  final int agentNctx;

  /// 工具循环轮次上限（1~20）。默认 5：端侧速度有限，轮次过多体验差。
  final int agentMaxRounds;

  /// 每轮生成的 token 预算。默认 512：足够输出一次工具调用 JSON 或一段回答。
  final int agentTokensPerRound;

  /// 单工具执行超时（毫秒）。默认 15s：防止工具卡死拖住整个循环。
  final int agentToolTimeoutMs;

  /// 是否允许并行工具调用（预留能力，默认关闭）。
  final bool agentAllowParallelTools;

  /// 联网搜索工具总开关（默认关闭：web_search 默认不注册，需手动开启）。
  final bool webSearchEnabled;

  /// 联网搜索 SearXNG provider 的自建实例地址（对齐 DSH 默认值）。
  /// 默认 `http://127.0.0.1:8080`；私有实例需配 apiKey 并以 Bearer 发送。
  final String webSearchSearXngBaseUrl;

  /// SearXNG 实例的 API key（私有实例才需要；空 = 无需密钥）。
  final String? webSearchSearXngApiKey;

  /// 单次 SearXNG 搜索最多返回来源条数（对齐 DSH 默认 8）。
  final int webSearchSearXngMaxResults;

  /// 单次 SearXNG 搜索超时毫秒（默认 15s，与端侧工具超时对齐）。
  final int webSearchSearXngTimeoutMs;

  /// SearXNG 搜索语言（如 "zh-CN"）；空 = 不指定。
  final String? webSearchSearXngLanguage;

  /// SearXNG 搜索分类（如 "general","news"）；空 = 不指定。
  final String? webSearchSearXngCategories;

  /// shell 执行工具开关（默认开启：端侧能力向强扩展，不自我设限；
  /// 用户可在设置中关闭）。
  final bool agentShellEnabled;

  /// python_exec 工具开关（默认开启：嵌入式 CPython，脚本能力向强扩展；
  /// 未集成 Chaquopy 时工具优雅降级为明确错误）。
  final bool agentPythonEnabled;

  /// 沙箱完整文件系统授权（对照 DSH danger-full-access）：开启后允许
  /// 智能体经用户逐次审批访问公共目录/完整文件系统（依赖
  /// MANAGE_EXTERNAL_STORAGE / All-Files-Access）。
  final bool agentFullFileAccess;

  /// 长期记忆开关（memory_set/memory_get）。默认**关闭**：跨会话持久化
  /// 的记忆可能积累偶发错误（不同模型/情况误写），开启后由用户显式配置。
  final bool agentMemoryEnabled;

  /// 推理引擎：是否默认加载视觉投影器（mmproj）。默认 true（针对有投影器的
  /// 模型）；关闭后视觉模型仅文本推理，不加载投影器。
  final bool autoLoadMmproj;

  /// 推理引擎：GPU/CPU 占用率监控呈现（模型状态栏底部双色线）。默认开启。
  final bool showResourceMonitor;

  /// 占用率采样周期（秒），0~30。默认 0：仅推理时事件驱动采样（空闲不采样，
  /// 省电）；>0：每隔 N 秒周期性采样（空闲也更新线条）。
  final int resourceSampleIntervalSec;

  /// 按模型启用的工具清单：`{modelId: [toolName]}`。空 = 使用该模型
  /// 目录声明的默认工具集（agentDefaults.enabledTools）。
  final Map<String, List<String>> agentToolsByModel;

  /// 按模型的 agent 配置覆盖：`{modelId: {maxRounds, tokensPerRound, nctx}}`。
  /// 覆盖全局默认值（模型目录 agentDefaults 合并到用户设置）。
  final Map<String, Map<String, dynamic>> agentByModel;

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
    Map<String, bool>? dsparkEnabledByModel,
    this.enableDsparkFeature = false,
    this.defaultModelId,
    List<ApiModelConfig>? apiModels,
    this.activeApiModelId,
    // ---- 智能体（Agent）----
    this.agentEnabled = true,
    this.agentModelSource,
    this.agentModelId,
    this.agentNctx = 8192,
    this.agentMaxRounds = 5,
    this.agentTokensPerRound = 512,
    this.agentToolTimeoutMs = 15000,
    this.agentAllowParallelTools = false,
    this.webSearchEnabled = false,
    this.webSearchSearXngBaseUrl = 'http://127.0.0.1:8080',
    this.webSearchSearXngApiKey,
    this.webSearchSearXngMaxResults = 8,
    this.webSearchSearXngTimeoutMs = 15000,
    this.webSearchSearXngLanguage,
    this.webSearchSearXngCategories,
    this.agentShellEnabled = true,
    this.agentPythonEnabled = true,
    this.agentFullFileAccess = false,
    // 长期记忆默认关闭（跨会话记忆可能积累偶发错误，默认不启用）。
    this.agentMemoryEnabled = false,
    // ---- 推理引擎 ----
    this.autoLoadMmproj = true,
    this.showResourceMonitor = true,
    this.resourceSampleIntervalSec = 1,
    Map<String, List<String>>? agentToolsByModel,
    Map<String, Map<String, dynamic>>? agentByModel,
  })  : mtpEnabledByModel = mtpEnabledByModel ?? const {},
        dsparkEnabledByModel = dsparkEnabledByModel ?? const {},
        apiModels = apiModels ?? const [],
        agentToolsByModel = agentToolsByModel ?? const {},
        agentByModel = agentByModel ?? const {};

  /// 便捷读取：某个模型是否启用 MTP（未配置视为关闭）。
  bool mtpEnabled(String modelId) => mtpEnabledByModel[modelId] ?? false;

  /// 便捷读取：某个模型是否启用 dspark（未配置视为关闭）。
  bool dsparkEnabled(String modelId) => dsparkEnabledByModel[modelId] ?? false;

  /// 便捷读取：某个模型启用的工具清单。空列表 = 跟随该模型目录声明的
  /// agentDefaults.enabledTools（目录合并逻辑在 agent 接入层）。
  List<String> agentToolsFor(String modelId) =>
      agentToolsByModel[modelId] ?? const [];

  /// 便捷读取：某个模型的 agent 配置覆盖（未配置返回 null）。
  Map<String, dynamic>? agentConfigFor(String modelId) =>
      agentByModel[modelId];

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
      Map<String, bool>? dsparkEnabledByModel,
      bool? enableDsparkFeature,
      String? defaultModelId,
      // defaultModelId 为可空 String，无法用 `?? this` 区分「未传」与「清空」，
      // 故增加显式清空标记，供取消默认模型时使用。
      bool clearDefaultModel = false,
      List<ApiModelConfig>? apiModels,
      String? activeApiModelId,
      // activeApiModelId 同样可空，需显式标记以区分「未传」与「停用」。
      bool clearActiveApiModel = false,
      // ---- 智能体（Agent）----
      bool? agentEnabled,
      String? agentModelSource,
      String? agentModelId,
      // agentModelSource/agentModelId 均可空，需显式标记区分「未传」与「清空」。
      bool clearAgentModel = false,
      int? agentNctx,
      int? agentMaxRounds,
      int? agentTokensPerRound,
      int? agentToolTimeoutMs,
      bool? agentAllowParallelTools,
      bool? webSearchEnabled,
      String? webSearchSearXngBaseUrl,
      String? webSearchSearXngApiKey,
      int? webSearchSearXngMaxResults,
      int? webSearchSearXngTimeoutMs,
      String? webSearchSearXngLanguage,
      String? webSearchSearXngCategories,
      bool? agentShellEnabled,
      bool? agentPythonEnabled,
      bool? agentFullFileAccess,
      bool? agentMemoryEnabled,
      // ---- 推理引擎 ----
      bool? autoLoadMmproj,
      bool? showResourceMonitor,
      int? resourceSampleIntervalSec,
      Map<String, List<String>>? agentToolsByModel,
      Map<String, Map<String, dynamic>>? agentByModel}) {
    return InferenceSettings(
      enableGpu: enableGpu ?? this.enableGpu,
      gpuLayers: gpuLayers ?? this.gpuLayers,
      contextSize: contextSize ?? this.contextSize,
      enableThinking: enableThinking ?? this.enableThinking,
      gpuBackend: gpuBackend ?? this.gpuBackend,
      mtpEnabledByModel: mtpEnabledByModel ?? this.mtpEnabledByModel,
      enableMtpFeature: enableMtpFeature ?? this.enableMtpFeature,
      dsparkEnabledByModel:
          dsparkEnabledByModel ?? this.dsparkEnabledByModel,
      enableDsparkFeature: enableDsparkFeature ?? this.enableDsparkFeature,
      defaultModelId: clearDefaultModel
          ? null
          : defaultModelId ?? this.defaultModelId,
      apiModels: apiModels ?? this.apiModels,
      activeApiModelId: clearActiveApiModel
          ? null
          : activeApiModelId ?? this.activeApiModelId,
      agentEnabled: agentEnabled ?? this.agentEnabled,
      agentModelSource: clearAgentModel
          ? null
          : agentModelSource ?? this.agentModelSource,
      agentModelId: clearAgentModel
          ? null
          : agentModelId ?? this.agentModelId,
      agentNctx: agentNctx ?? this.agentNctx,
      agentMaxRounds: agentMaxRounds ?? this.agentMaxRounds,
      agentTokensPerRound: agentTokensPerRound ?? this.agentTokensPerRound,
      agentToolTimeoutMs: agentToolTimeoutMs ?? this.agentToolTimeoutMs,
      agentAllowParallelTools:
          agentAllowParallelTools ?? this.agentAllowParallelTools,
      webSearchEnabled: webSearchEnabled ?? this.webSearchEnabled,
      webSearchSearXngBaseUrl:
          webSearchSearXngBaseUrl ?? this.webSearchSearXngBaseUrl,
      webSearchSearXngApiKey:
          webSearchSearXngApiKey ?? this.webSearchSearXngApiKey,
      webSearchSearXngMaxResults:
          webSearchSearXngMaxResults ?? this.webSearchSearXngMaxResults,
      webSearchSearXngTimeoutMs:
          webSearchSearXngTimeoutMs ?? this.webSearchSearXngTimeoutMs,
      webSearchSearXngLanguage:
          webSearchSearXngLanguage ?? this.webSearchSearXngLanguage,
      webSearchSearXngCategories:
          webSearchSearXngCategories ?? this.webSearchSearXngCategories,
      agentShellEnabled: agentShellEnabled ?? this.agentShellEnabled,
      agentPythonEnabled: agentPythonEnabled ?? this.agentPythonEnabled,
      agentFullFileAccess:
          agentFullFileAccess ?? this.agentFullFileAccess,
      agentMemoryEnabled: agentMemoryEnabled ?? this.agentMemoryEnabled,
      autoLoadMmproj: autoLoadMmproj ?? this.autoLoadMmproj,
      showResourceMonitor: showResourceMonitor ?? this.showResourceMonitor,
      resourceSampleIntervalSec:
          resourceSampleIntervalSec ?? this.resourceSampleIntervalSec,
      agentToolsByModel: agentToolsByModel ?? this.agentToolsByModel,
      agentByModel: agentByModel ?? this.agentByModel,
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
        'dsparkEnabledByModel': dsparkEnabledByModel,
        'enableDsparkFeature': enableDsparkFeature,
        'defaultModelId': defaultModelId,
        'apiModels': apiModels.map((m) => m.toJson()).toList(),
        'activeApiModelId': activeApiModelId,
        // ---- 智能体（Agent）----
        'agentEnabled': agentEnabled,
        'agentModelSource': agentModelSource,
        'agentModelId': agentModelId,
        'agentNctx': agentNctx,
        'agentMaxRounds': agentMaxRounds,
        'agentTokensPerRound': agentTokensPerRound,
        'agentToolTimeoutMs': agentToolTimeoutMs,
        'agentAllowParallelTools': agentAllowParallelTools,
        'webSearchEnabled': webSearchEnabled,
        'webSearchSearXngBaseUrl': webSearchSearXngBaseUrl,
        'webSearchSearXngApiKey': webSearchSearXngApiKey,
        'webSearchSearXngMaxResults': webSearchSearXngMaxResults,
        'webSearchSearXngTimeoutMs': webSearchSearXngTimeoutMs,
        'webSearchSearXngLanguage': webSearchSearXngLanguage,
        'webSearchSearXngCategories': webSearchSearXngCategories,
        'agentShellEnabled': agentShellEnabled,
        // 修复遗留：python_exec 与完整文件访问开关此前未写入 toJson，
        // 保存后读回会静默丢配置（默认值兜底）。
        'agentPythonEnabled': agentPythonEnabled,
        'agentFullFileAccess': agentFullFileAccess,
        'agentMemoryEnabled': agentMemoryEnabled,
        // ---- 推理引擎 ----
        'autoLoadMmproj': autoLoadMmproj,
        'showResourceMonitor': showResourceMonitor,
        'resourceSampleIntervalSec': resourceSampleIntervalSec,
        'agentToolsByModel': agentToolsByModel,
        'agentByModel': agentByModel,
      };

  factory InferenceSettings.fromJson(Map<String, dynamic> json) {
    return InferenceSettings(
      // 缺省/旧文件未存该字段时默认开启 GPU：auto 后端会在无 GPU 时自动
      // 回落 CPU，V0.1.5 已验证 Adreno 825 OpenCL/Vulkan 均正常。
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
      // dspark：按模型 map + 全局开关，旧配置无此字段时默认全关（向后兼容）。
      dsparkEnabledByModel: _parseBoolMap(json['dsparkEnabledByModel']),
      enableDsparkFeature: json['enableDsparkFeature'] as bool? ?? false,
      defaultModelId: json['defaultModelId'] as String?,
      // 旧配置缺这两个字段时默认空列表 + 停用，向后兼容。
      apiModels: _parseApiModels(json['apiModels']),
      activeApiModelId: json['activeApiModelId'] as String?,
      // 智能体（Agent）：旧配置缺字段时用默认值，向后兼容。
      agentEnabled: json['agentEnabled'] as bool? ?? true,
      agentModelSource: json['agentModelSource'] as String?,
      agentModelId: json['agentModelId'] as String?,
      agentNctx: (json['agentNctx'] as num?)?.toInt() ?? 8192,
      agentMaxRounds: (json['agentMaxRounds'] as num?)?.toInt() ?? 5,
      agentTokensPerRound:
          (json['agentTokensPerRound'] as num?)?.toInt() ?? 512,
      agentToolTimeoutMs:
          (json['agentToolTimeoutMs'] as num?)?.toInt() ?? 15000,
      agentAllowParallelTools:
          json['agentAllowParallelTools'] as bool? ?? false,
      webSearchEnabled: json['webSearchEnabled'] as bool? ?? false,
      // 联网搜索 SearXNG 配置：旧配置缺字段时用默认值（向后兼容）。
      webSearchSearXngBaseUrl:
          json['webSearchSearXngBaseUrl'] as String? ?? 'http://127.0.0.1:8080',
      webSearchSearXngApiKey: json['webSearchSearXngApiKey'] as String?,
      webSearchSearXngMaxResults:
          (json['webSearchSearXngMaxResults'] as num?)?.toInt() ?? 8,
      webSearchSearXngTimeoutMs:
          (json['webSearchSearXngTimeoutMs'] as num?)?.toInt() ?? 15000,
      webSearchSearXngLanguage:
          json['webSearchSearXngLanguage'] as String?,
      webSearchSearXngCategories:
          json['webSearchSearXngCategories'] as String?,
      agentShellEnabled: json['agentShellEnabled'] as bool? ?? true,
      agentPythonEnabled: json['agentPythonEnabled'] as bool? ?? true,
      agentFullFileAccess: json['agentFullFileAccess'] as bool? ?? false,
      // 长期记忆默认关闭（旧配置缺字段时向后兼容）。
      agentMemoryEnabled: json['agentMemoryEnabled'] as bool? ?? false,
      // 推理引擎扩展：旧配置缺字段时用默认值（投影器默认加载、监控默认开启）。
      autoLoadMmproj: json['autoLoadMmproj'] as bool? ?? true,
      showResourceMonitor: json['showResourceMonitor'] as bool? ?? true,
      resourceSampleIntervalSec:
          (json['resourceSampleIntervalSec'] as num?)?.toInt() ?? 1,
      agentToolsByModel: _parseAgentTools(json['agentToolsByModel']),
      agentByModel: _parseAgentByModel(json['agentByModel']),
    );
  }

  /// 解析按模型工具清单：`{modelId: [toolName]}`。格式非法时返回空 map（不崩）。
  static Map<String, List<String>> _parseAgentTools(Object? raw) {
    if (raw is! Map) return const {};
    final result = <String, List<String>>{};
    raw.forEach((k, v) {
      if (v is List) {
        result[k.toString()] =
            v.map((e) => e.toString()).where((s) => s.isNotEmpty).toList();
      }
    });
    return result;
  }

  /// 解析按模型 agent 配置：`{modelId: {maxRounds, tokensPerRound, nctx}}`。
  /// 格式非法时返回空 map（不崩）。
  static Map<String, Map<String, dynamic>> _parseAgentByModel(Object? raw) {
    if (raw is! Map) return const {};
    final result = <String, Map<String, dynamic>>{};
    raw.forEach((k, v) {
      if (v is Map) {
        result[k.toString()] = Map<String, dynamic>.from(v);
      }
    });
    return result;
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
  /// 解析按模型 bool map（如 dsparkEnabledByModel）；格式非法时返回空 map。
  static Map<String, bool> _parseBoolMap(Object? raw) {
    if (raw is! Map) return const {};
    return raw.map((k, v) => MapEntry(k.toString(), v as bool? ?? false));
  }

  static Map<String, bool> _migrateLegacyMtp(Map<String, dynamic> json) {
    final map = json['mtpEnabledByModel'] as Map<String, dynamic>?;
    if (map != null) {
      return map.map((k, v) => MapEntry(k, v as bool? ?? false));
    }
    // 仅有旧版全局 enableMtp 时保持默认全关：无法定位具体模型（不迁移为开，
    // 见 AGENTS.md 约定），由用户在模型列表重新逐个开启。
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
  ///
  /// 原子写入：先写 `.tmp` 再 rename。此前直接 writeAsString，崩溃/断电时
  /// 可能留下半截 JSON——load 全部回落默认值，用户配置静默丢失。rename 在
  /// 同目录上是原子操作，损坏面收敛为「完整旧文件或完整新文件」。
  Future<void> save(InferenceSettings settings) async {
    final path = await _resolvePath();
    final tmp = File('$path.tmp');
    await tmp.writeAsString(jsonEncode(settings.toJson()));
    await tmp.rename(path);
  }
}
