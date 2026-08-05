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
