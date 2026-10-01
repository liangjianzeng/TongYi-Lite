import 'dart:convert';

import 'package:dartssh2/dartssh2.dart' show SSHKeyPair;
import 'package:flutter_test/flutter_test.dart';

import 'package:tongyi_lite/agent/dev/ssh/ssh_credentials.dart';
import 'package:tongyi_lite/services/settings_service.dart';

void main() {
  group('InferenceSettings 智能体配置默认值', () {
    test('默认值符合设计（智能体开启、循环 12 轮、nctx 8192）', () {
      const s = InferenceSettings();
      expect(s.agentEnabled, isTrue);
      expect(s.agentModelSource, isNull);
      expect(s.agentModelId, isNull);
      expect(s.agentNctx, 8192);
      expect(s.agentMaxRounds, 12);
      expect(s.agentTokensPerRound, 1024);
      expect(s.agentToolTimeoutMs, 15000);
      expect(s.agentAllowParallelTools, isFalse);
      expect(s.webSearchEnabled, isFalse);
      expect(s.agentShellEnabled, isTrue);
      expect(s.agentPythonEnabled, isTrue);
      expect(s.agentFullFileAccess, isFalse);
      // 长期记忆默认关闭（跨会话记忆可能积累偶发错误）。
      expect(s.agentMemoryEnabled, isFalse);
      // 推理引擎扩展：投影器默认加载、监控默认开启、采样默认 1 秒（周期性，
      // 打开监控即可看到实时占比）。
      expect(s.autoLoadMmproj, isTrue);
      expect(s.showResourceMonitor, isTrue);
      expect(s.resourceSampleIntervalSec, 1);
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

    test('并发会话槽位：默认 1，往返一致，解析夹紧 1~4', () {
      const s = InferenceSettings();
      expect(s.agentMaxConcurrentTurns, 1);
      final restored = InferenceSettings.fromJson(s.toJson());
      expect(restored.agentMaxConcurrentTurns, 1);

      final custom = InferenceSettings.fromJson(
          {'agentMaxConcurrentTurns': 3});
      expect(custom.agentMaxConcurrentTurns, 3);
      expect(InferenceSettings.fromJson(custom.toJson()).agentMaxConcurrentTurns,
          3);
      // 越界值夹紧（手改 JSON 防御）。
      expect(
          InferenceSettings.fromJson({'agentMaxConcurrentTurns': 99})
              .agentMaxConcurrentTurns,
          4);
      expect(
          InferenceSettings.fromJson({'agentMaxConcurrentTurns': 0})
              .agentMaxConcurrentTurns,
          1);
    });

    test('旧配置（无 agent 字段）加载 → 默认值，向后兼容', () {
      final old = InferenceSettings.fromJson({
        'enableGpu': true,
        'contextSize': 4096,
        'gpuBackend': 'auto',
      });
      expect(old.agentEnabled, isTrue);
      expect(old.agentNctx, 8192);
      // 无字段 → 新默认（12 轮 / 1024 token）。
      expect(old.agentMaxRounds, 12);
      expect(old.agentTokensPerRound, 1024);
      expect(old.agentToolsByModel, isEmpty);
    });

    test('旧默认值存量迁移：5→12、512→1024；显式设置过的值不动', () {
      // 存量配置等于旧默认 → 一次性抬到新默认。
      final migrated = InferenceSettings.fromJson({
        'agentMaxRounds': 5,
        'agentTokensPerRound': 512,
      });
      expect(migrated.agentMaxRounds, 12);
      expect(migrated.agentTokensPerRound, 1024);
      // 用户显式设置过的非默认值保持不动。
      final kept = InferenceSettings.fromJson({
        'agentMaxRounds': 3,
        'agentTokensPerRound': 768,
      });
      expect(kept.agentMaxRounds, 3);
      expect(kept.agentTokensPerRound, 768);
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

  group('InferenceSettings 智能体引擎 v0.2.1 新键', () {
    test('默认值：温度 0.7 / 并发 4 / 子代理·压缩·溢写默认开', () {
      const s = InferenceSettings();
      expect(s.agentTemperature, 0.7);
      expect(s.agentMaxParallel, 4);
      expect(s.agentSubagentEnabled, isTrue);
      expect(s.agentCompactEnabled, isTrue);
      expect(s.agentSpillEnabled, isTrue);
    });

    test('toJson → fromJson 往返一致', () {
      const s = InferenceSettings(
        agentTemperature: 0.3,
        agentMaxParallel: 6,
        agentSubagentEnabled: false,
        agentCompactEnabled: false,
        agentSpillEnabled: false,
      );
      final restored = InferenceSettings.fromJson(s.toJson());
      expect(restored.agentTemperature, 0.3);
      expect(restored.agentMaxParallel, 6);
      expect(restored.agentSubagentEnabled, isFalse);
      expect(restored.agentCompactEnabled, isFalse);
      expect(restored.agentSpillEnabled, isFalse);
    });

    test('旧配置无新键 → 取安全默认（向后兼容）', () {
      final old = InferenceSettings.fromJson({'agentMaxRounds': 3});
      expect(old.agentTemperature, 0.7);
      expect(old.agentMaxParallel, 4);
      expect(old.agentSubagentEnabled, isTrue);
      expect(old.agentCompactEnabled, isTrue);
      expect(old.agentSpillEnabled, isTrue);
    });
  });

  group('InferenceSettings 开发模式（Dev Agent）', () {
    test('默认关闭（零回归）', () {
      const s = InferenceSettings();
      expect(s.devModeEnabled, isFalse);
      expect(s.devWorkspaceId, 'default');
      expect(s.sshConfigs, isEmpty);
      expect(s.dangerousCommandPolicy, 'deny');
    });

    test('toJson → fromJson 往返一致（含多 SSH 配置）', () {
      final s = InferenceSettings(
        devModeEnabled: true,
        devWorkspaceId: 'ws_1',
        sshConfigs: [
          const SshConfig(
            id: 'termux',
            name: 'Termux',
            host: '127.0.0.1',
            port: 8022,
            username: 'u0_a123',
            authType: SshAuthType.key,
            privateKeyPem: '-----BEGIN OPENSSH PRIVATE KEY-----',
          ),
          const SshConfig(
            id: 'remote-pc',
            name: '远程电脑',
            host: '192.168.1.100',
            port: 22,
            username: 'me',
            authType: SshAuthType.password,
            password: 'pw',
          ),
        ],
        dangerousCommandPolicy: 'ask',
      );
      final restored = InferenceSettings.fromJson(s.toJson());
      expect(restored.devModeEnabled, isTrue);
      expect(restored.devWorkspaceId, 'ws_1');
      expect(restored.sshConfigs.length, 2);
      expect(restored.sshConfigFor('termux')!.host, '127.0.0.1');
      expect(restored.sshConfigFor('termux')!.port, 8022);
      expect(restored.sshConfigFor('termux')!.username, 'u0_a123');
      expect(restored.sshConfigFor('termux')!.privateKeyPem,
          contains('BEGIN OPENSSH'));
      expect(restored.sshConfigFor('remote-pc')!.password, 'pw');
      expect(restored.sshConfigFor('missing'), isNull);
      expect(restored.dangerousCommandPolicy, 'ask');
    });

    test('旧版单配置 sshConfig 自动迁移为列表首项（向后兼容）', () {
      final migrated = InferenceSettings.fromJson({
        'sshConfig': {
          'host': '127.0.0.1',
          'port': 8022,
          'username': 'u0_a1',
          'authType': 'key',
          'privateKeyPem': 'KEY',
        },
      });
      expect(migrated.sshConfigs.length, 1);
      expect(migrated.sshConfigs.first.host, '127.0.0.1');
      expect(migrated.sshConfigs.first.username, 'u0_a1');
      // 迁移必须补稳定 id（否则删除失效/编辑变追加——2026-10-01 真机定案）。
      expect(migrated.sshConfigs.first.id, isNotEmpty);
    });

    test('迁移补 id 幂等：补完持久化后再次加载 id 不变', () {
      final migrated = InferenceSettings.fromJson({
        'sshConfig': {
          'host': 'h', 'port': 22, 'username': 'u', 'authType': 'password',
          'password': 'p',
        },
      });
      final firstId = migrated.sshConfigs.first.id;
      expect(firstId, isNotEmpty);
      // 迁移后的配置已带 id → 持久化后二次加载不再重新分配。
      final second = InferenceSettings.fromJson(migrated.toJson());
      expect(second.sshConfigs.single.id, firstId);
      // 空 id 的旧列表条目同样补齐。
      final list = InferenceSettings.fromJson({
        'sshConfigs': [
          {'host': 'a', 'port': 22, 'username': 'u', 'authType': 'key',
           'privateKeyPem': 'K'},
          {'host': 'b', 'port': 8022, 'username': 'u', 'authType': 'key',
           'privateKeyPem': 'K'},
        ],
      });
      expect(list.sshConfigs.every((c) => c.id.isNotEmpty), isTrue);
      expect(list.sshConfigs[0].id, isNot(list.sshConfigs[1].id));
    });

    test('旧配置无 Dev 键 → 默认关闭（向后兼容）', () {
      final old = InferenceSettings.fromJson({'agentMaxRounds': 3});
      expect(old.devModeEnabled, isFalse);
      expect(old.sshConfigs, isEmpty);
    });

    test('copyWith：clearSshConfig 清空 / 不传保留', () {
      final s = InferenceSettings(
        sshConfigs: const [
          SshConfig(
              id: 'a', host: 'h', port: 22, username: 'u',
              authType: SshAuthType.password, password: 'p'),
        ],
      );
      final cleared = s.copyWith(clearSshConfig: true);
      expect(cleared.sshConfigs, isEmpty);
      expect(s.copyWith().sshConfigs.length, 1);
    });

    test('sshConfigFor：空 id / 找不到返回 null', () {
      const s = InferenceSettings();
      expect(s.sshConfigFor(null), isNull);
      expect(s.sshConfigFor(''), isNull);
      expect(s.sshConfigFor('nope'), isNull);
    });
  });

  group('SshKeyGen 自动生成 ed25519 密钥', () {
    test('生成 OpenSSH 私钥 + ssh-ed25519 公钥', () {
      final keys = SshKeyGen.generate();
      expect(keys, isNotNull);
      expect(keys!.privateKeyPem, startsWith('-----BEGIN OPENSSH PRIVATE KEY-----'));
      expect(keys.privateKeyPem, endsWith('-----END OPENSSH PRIVATE KEY-----'));
      expect(keys.publicKey, startsWith('ssh-ed25519 '));
      // 每次生成不同（随机种子）。
      final keys2 = SshKeyGen.generate();
      expect(keys2!.publicKey, isNot(keys.publicKey));
    });

    test('私钥可被 dartssh2 解析（SSHKeyPair.fromPem 往返）', () {
      final keys = SshKeyGen.generate();
      expect(keys, isNotNull);
      final pairs = SSHKeyPair.fromPem(keys!.privateKeyPem);
      expect(pairs, isNotEmpty);
    });

    test('公钥含 32 字节 ed25519（base64 解码校验）', () {
      final keys = SshKeyGen.generate();
      expect(keys, isNotNull);
      final parts = keys!.publicKey.split(' ');
      expect(parts.length, 2);
      expect(parts[0], 'ssh-ed25519');
      final decoded = base64Decode(parts[1]);
      // uint32 长度前缀（4）+ 类型串 "ssh-ed25519"（11）+ 32 字节公钥。
      expect(decoded.length, 4 + 11 + 32);
      expect(utf8.decode(decoded.sublist(4, 4 + 11)), 'ssh-ed25519');
    });
  });
}
