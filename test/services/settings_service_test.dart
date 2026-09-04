import 'package:flutter_test/flutter_test.dart';

import 'package:tongyi_lite/services/settings_service.dart';

void main() {
  group('InferenceSettings 智能体配置默认值', () {
    test('默认值符合设计（智能体开启、循环 5 轮、nctx 8192）', () {
      const s = InferenceSettings();
      expect(s.agentEnabled, isTrue);
      expect(s.agentModelSource, isNull);
      expect(s.agentModelId, isNull);
      expect(s.agentNctx, 8192);
      expect(s.agentMaxRounds, 5);
      expect(s.agentTokensPerRound, 512);
      expect(s.agentToolTimeoutMs, 15000);
      expect(s.agentAllowParallelTools, isFalse);
      expect(s.webSearchEnabled, isFalse);
      expect(s.agentShellEnabled, isTrue);
      expect(s.agentPythonEnabled, isTrue);
      expect(s.agentFullFileAccess, isFalse);
      // 长期记忆默认关闭（跨会话记忆可能积累偶发错误）。
      expect(s.agentMemoryEnabled, isFalse);
      // 推理引擎扩展：投影器默认加载、监控默认开启、采样默认 0（仅推理时）。
      expect(s.autoLoadMmproj, isTrue);
      expect(s.showResourceMonitor, isTrue);
      expect(s.resourceSampleIntervalSec, 0);
      expect(s.agentToolsByModel, isEmpty);
      expect(s.agentByModel, isEmpty);
    });

    test('便捷读取：未配置工具/覆盖时返回空/空', () {
      const s = InferenceSettings();
      expect(s.agentToolsFor('any-model'), isEmpty);
      expect(s.agentConfigFor('any-model'), isNull);
    });
  });

  group('InferenceSettings 智能体配置持久化', () {
    test('toJson → fromJson 往返一致', () {
      const s = InferenceSettings(
        agentEnabled: false,
        agentModelSource: 'local',
        agentModelId: 'spark-x2.5-4b-q4_k_m',
        agentNctx: 16384,
        agentMaxRounds: 8,
        agentTokensPerRound: 768,
        agentToolTimeoutMs: 30000,
        agentAllowParallelTools: true,
        webSearchEnabled: true,
        agentShellEnabled: false,
        agentPythonEnabled: false,
        agentFullFileAccess: true,
        agentMemoryEnabled: true,
        autoLoadMmproj: false,
        showResourceMonitor: false,
        resourceSampleIntervalSec: 10,
        agentToolsByModel: {
          'spark-x2.5-4b-q4_k_m': ['get_time', 'calculator'],
        },
        agentByModel: {
          'spark-x2.5-4b-q4_k_m': {'maxRounds': 4, 'nctx': 32768},
        },
      );

      final restored = InferenceSettings.fromJson(s.toJson());
      expect(restored.agentEnabled, isFalse);
      expect(restored.agentModelSource, 'local');
      expect(restored.agentModelId, 'spark-x2.5-4b-q4_k_m');
      expect(restored.agentNctx, 16384);
      expect(restored.agentMaxRounds, 8);
      expect(restored.agentTokensPerRound, 768);
      expect(restored.agentToolTimeoutMs, 30000);
      expect(restored.agentAllowParallelTools, isTrue);
      expect(restored.webSearchEnabled, isTrue);
      expect(restored.agentShellEnabled, isFalse);
      expect(restored.agentPythonEnabled, isFalse);
      expect(restored.agentFullFileAccess, isTrue);
      expect(restored.agentMemoryEnabled, isTrue);
      expect(restored.autoLoadMmproj, isFalse);
      expect(restored.showResourceMonitor, isFalse);
      expect(restored.resourceSampleIntervalSec, 10);
      expect(restored.agentToolsFor('spark-x2.5-4b-q4_k_m'),
          ['get_time', 'calculator']);
      expect(restored.agentConfigFor('spark-x2.5-4b-q4_k_m'),
          {'maxRounds': 4, 'nctx': 32768});
    });

    test('旧配置（无 agent 字段）加载 → 默认值，向后兼容', () {
      final old = InferenceSettings.fromJson({
        'enableGpu': true,
        'contextSize': 4096,
        'gpuBackend': 'auto',
      });
      expect(old.agentEnabled, isTrue);
      expect(old.agentNctx, 8192);
      expect(old.agentMaxRounds, 5);
      expect(old.agentToolsByModel, isEmpty);
    });

    test('agentToolsByModel 解析非法格式不崩', () {
      final restored = InferenceSettings.fromJson({
        'agentToolsByModel': 'bad',
        'agentByModel': 42,
      });
      expect(restored.agentToolsByModel, isEmpty);
      expect(restored.agentByModel, isEmpty);
    });

    test('copyWith 取消指定模型（clearAgentModel）', () {
      const s = InferenceSettings(
        agentModelSource: 'api',
        agentModelId: 'abc',
      );
      final cleared = s.copyWith(clearAgentModel: true);
      expect(cleared.agentModelSource, isNull);
      expect(cleared.agentModelId, isNull);
      // 不传则保留旧值。
      expect(s.copyWith().agentModelId, 'abc');
    });
  });
}
