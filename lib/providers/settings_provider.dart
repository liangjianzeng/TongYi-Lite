import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/api_model.dart';
import '../services/settings_service.dart';

/// 持有推理引擎设置（GPU 开关 / 卸载层数），并在变更时持久化到本地文件。
class SettingsNotifier extends StateNotifier<InferenceSettings> {
  final SettingsService _service;

  SettingsNotifier(this._service) : super(const InferenceSettings()) {
    _load();
  }

  Future<void> _load() async {
    final loaded = await _service.load();
    if (mounted) state = loaded;
  }

  Future<void> setEnableGpu(bool value) async {
    state = state.copyWith(enableGpu: value);
    await _persist();
  }

  Future<void> setGpuLayers(int value) async {
    // 防御性夹紧，避免越界值进入原生层。
    final clamped = value.clamp(0, 999);
    state = state.copyWith(gpuLayers: clamped);
    await _persist();
  }

  /// 设置 GPU 后端（'cpu' / 'vulkan' / 'opencl' / 'auto'）。
  Future<void> setGpuBackend(String value) async {
    const allowed = {'cpu', 'vulkan', 'opencl', 'auto'};
    if (!allowed.contains(value)) return;
    state = state.copyWith(gpuBackend: value);
    await _persist();
  }

  /// 设置上下文大小（KV 缓存窗口）。上限 65536，下限 1。
  Future<void> setContextSize(int value) async {
    // 防御性夹紧，避免越界值进入原生层。
    final clamped = value.clamp(1, 65536);
    state = state.copyWith(contextSize: clamped);
    await _persist();
  }

  /// 设置是否允许 Qwen3 思考模式。默认关闭（直接作答）。
  Future<void> setEnableThinking(bool value) async {
    state = state.copyWith(enableThinking: value);
    await _persist();
  }

  /// 设置某个模型是否启用 MTP（多 token 预测）加速。按模型 id 独立开关，
  /// 互不影响——仅对带 NextN 头的模型生效，用户可在模型列表逐个开启。
  Future<void> setEnableMtp(String modelId, bool value) async {
    final updated = Map<String, bool>.from(state.mtpEnabledByModel);
    updated[modelId] = value;
    state = state.copyWith(mtpEnabledByModel: updated);
    await _persist();
  }

  /// 设置全局 MTP 功能总开关（默认关闭）。关闭时模型卡片不显示各模型 MTP
  /// 开关，加载模型也强制不启用；开启后模型卡片显示支持 MTP 模型的开关，
  /// 用户可逐个配置。
  Future<void> setEnableMtpFeature(bool value) async {
    state = state.copyWith(enableMtpFeature: value);
    await _persist();
  }

  /// 设置「默认加载」模型。传 null 表示取消默认。
  /// 持久化到 inference_settings.json（与 MTP 等其他设置同一文件），
  /// 退出 App 不会丢失；启动自动加载逻辑按此 id 加载模型。
  Future<void> setDefaultModel(String? modelId) async {
    if (state.defaultModelId == modelId) return;
    // 传 null 表示取消默认：必须显式置 clearDefaultModel=true，
    // 否则 copyWith 里的 `defaultModelId ?? this.defaultModelId` 会吞掉 null，
    // 导致一旦选过就再也无法反选（旧值被保留）。
    state = state.copyWith(
        defaultModelId: modelId, clearDefaultModel: modelId == null);
    await _persist();
  }

  // ---------------------------------------------------------------
  // OpenAI 兼容远程模型（API 接入）
  // ---------------------------------------------------------------

  /// 新增一个 API 模型配置。
  Future<void> addApiModel(ApiModelConfig config) async {
    state = state.copyWith(
      apiModels: [...state.apiModels, config],
    );
    await _persist();
  }

  /// 更新一个已有 API 模型配置（按 id 定位；不存在则忽略）。
  Future<void> updateApiModel(ApiModelConfig config) async {
    state = state.copyWith(
      apiModels: [
        for (final m in state.apiModels)
          if (m.id == config.id) config else m,
      ],
    );
    await _persist();
  }

  /// 删除一个 API 模型配置；若删除的是当前激活模型，自动停用 API。
  Future<void> deleteApiModel(String id) async {
    final removedActive = state.activeApiModelId == id;
    state = state.copyWith(
      apiModels: state.apiModels.where((m) => m.id != id).toList(),
      activeApiModelId: removedActive ? null : state.activeApiModelId,
      clearActiveApiModel: removedActive,
    );
    await _persist();
  }

  /// 激活/停用某个 API 模型。传 null 表示停用（不启用 API 接入）。
  /// 路由策略：本地模型优先，仅当本地不可用时才走激活的 API。
  Future<void> setActiveApiModel(String? modelId) async {
    // 校验：仅允许激活列表内存在的 id（或 null 停用）。
    if (modelId != null &&
        !state.apiModels.any((m) => m.id == modelId)) {
      return;
    }
    if (state.activeApiModelId == modelId) return;
    state = state.copyWith(
        activeApiModelId: modelId, clearActiveApiModel: modelId == null);
    await _persist();
  }

  // ---------------------------------------------------------------
  // 智能体（Agent）
  // ---------------------------------------------------------------

  /// 智能体模式总开关。
  Future<void> setAgentEnabled(bool value) async {
    state = state.copyWith(agentEnabled: value);
    await _persist();
  }

  /// 指定/取消智能体驱动模型。
  /// - source='local' → [modelId] 为本地模型目录 id；
  /// - source='api' → [modelId] 为 API 模型配置 id；
  /// - 传 (null, null) 表示取消指定，跟随默认路由（本地优先，API 兜底）。
  Future<void> setAgentModel(String? source, String? modelId) async {
    if (source == null && modelId == null) {
      // 取消指定：必须显式 clearAgentModel=true，否则 copyWith 吞掉 null。
      if (state.agentModelId == null) return;
      state = state.copyWith(clearAgentModel: true);
      await _persist();
      return;
    }
    if (source != 'local' && source != 'api') return;
    if (modelId == null || modelId.isEmpty) return;
    // API 模型必须存在于配置列表内，否则拒绝。
    if (source == 'api' && !state.apiModels.any((m) => m.id == modelId)) {
      return;
    }
    if (state.agentModelSource == source && state.agentModelId == modelId) {
      return;
    }
    state = state.copyWith(
        agentModelSource: source, agentModelId: modelId);
    await _persist();
  }

  /// 智能体模式上下文长度（n_ctx）。夹紧到 1~65536。
  Future<void> setAgentNctx(int value) async {
    final clamped = value.clamp(1, 65536);
    state = state.copyWith(agentNctx: clamped);
    await _persist();
  }

  /// 工具循环轮次上限（1~20）。
  Future<void> setAgentMaxRounds(int value) async {
    final clamped = value.clamp(1, 20);
    state = state.copyWith(agentMaxRounds: clamped);
    await _persist();
  }

  /// 每轮生成 token 预算（128~16384，16k 上限按需配置）。
  Future<void> setAgentTokensPerRound(int value) async {
    final clamped = value.clamp(128, 16384);
    state = state.copyWith(agentTokensPerRound: clamped);
    await _persist();
  }

  /// 单工具执行超时（毫秒，1s~120s）。
  Future<void> setAgentToolTimeoutMs(int value) async {
    final clamped = value.clamp(1000, 120000);
    state = state.copyWith(agentToolTimeoutMs: clamped);
    await _persist();
  }

  /// 并行工具调用（预留能力）。
  Future<void> setAgentAllowParallelTools(bool value) async {
    state = state.copyWith(agentAllowParallelTools: value);
    await _persist();
  }

  /// 联网搜索工具总开关。
  Future<void> setWebSearchEnabled(bool value) async {
    state = state.copyWith(webSearchEnabled: value);
    await _persist();
  }

  /// shell 执行工具开关。
  Future<void> setAgentShellEnabled(bool value) async {
    state = state.copyWith(agentShellEnabled: value);
    await _persist();
  }

  /// python_exec 工具开关。
  Future<void> setAgentPythonEnabled(bool value) async {
    state = state.copyWith(agentPythonEnabled: value);
    await _persist();
  }

  /// 沙箱完整文件访问授权（danger-full-access 前置）。
  Future<void> setAgentFullFileAccess(bool value) async {
    state = state.copyWith(agentFullFileAccess: value);
    await _persist();
  }

  Future<void> _persist() async {
    try {
      await _service.save(state);
    } catch (_) {
      // 持久化失败不应阻断 UI 交互；内存状态已更新。
    }
  }
}

final settingsServiceProvider =
    Provider<SettingsService>((ref) => SettingsService());

final settingsProvider =
    StateNotifierProvider<SettingsNotifier, InferenceSettings>((ref) {
  final service = ref.watch(settingsServiceProvider);
  return SettingsNotifier(service);
});
