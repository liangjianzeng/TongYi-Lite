import 'package:flutter_riverpod/flutter_riverpod.dart';

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
