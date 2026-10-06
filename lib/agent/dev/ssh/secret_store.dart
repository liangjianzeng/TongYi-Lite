/// SSH 密钥/密码安全存储（P2-D3）。
///
/// 旧版把 `privateKeyPem/keyPassphrase/password` 明文存在 settings JSON。
/// 本模块提供：抽象 [SshSecretStore]（生产 = flutter_secure_storage，
/// Android EncryptedSharedPreferences；测试 = 内存实现）+ 两条核心链路：
/// - [migrateSshSecrets]：设置加载时把 JSON 里的明文密钥搬进安全存储，
///   settings 里只留空槽位（一次性迁移，幂等）；
/// - [resolveSshSecrets]：SSH 连接前回填密钥（安全存储优先，JSON 兜底
///   兼容未迁移数据）。
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'ssh_credentials.dart';

/// 密钥字段键名。
const String kSecretKeyPem = 'privateKeyPem';
const String kSecretKeyPass = 'keyPassphrase';
const String kSecretPassword = 'password';

/// 抽象存储（键 = `ssh_<configId>_<field>`）。
abstract class SshSecretStore {
  Future<Map<String, String>> read(String configId);
  Future<void> write(String configId, Map<String, String> secrets);
  Future<void> delete(String configId);
}

/// 生产实现：flutter_secure_storage。
class FlutterSshSecretStore implements SshSecretStore {
  final FlutterSecureStorage _storage;
  FlutterSshSecretStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  String _k(String configId, String field) => 'ssh_${configId}_$field';

  @override
  Future<Map<String, String>> read(String configId) async {
    final out = <String, String>{};
    for (final field in const [kSecretKeyPem, kSecretKeyPass, kSecretPassword]) {
      final v = await _storage.read(key: _k(configId, field));
      if (v != null && v.isNotEmpty) out[field] = v;
    }
    return out;
  }

  @override
  Future<void> write(String configId, Map<String, String> secrets) async {
    for (final e in secrets.entries) {
      await _storage.write(key: _k(configId, e.key), value: e.value);
    }
  }

  @override
  Future<void> delete(String configId) async {
    for (final field in const [kSecretKeyPem, kSecretKeyPass, kSecretPassword]) {
      await _storage.delete(key: _k(configId, field));
    }
  }
}

/// 内存实现（测试/无平台通道场景）。
class InMemorySshSecretStore implements SshSecretStore {
  final Map<String, Map<String, String>> _data = {};
  @override
  Future<Map<String, String>> read(String configId) async =>
      Map.of(_data[configId] ?? const {});
  @override
  Future<void> write(String configId, Map<String, String> secrets) async =>
      _data[configId] = Map.of(secrets);
  @override
  Future<void> delete(String configId) async => _data.remove(configId);
}

/// 可注入的全局存储（默认 flutter_secure_storage；测试可替换）。
SshSecretStore sshSecretStore = FlutterSshSecretStore();

/// 配置里是否带了明文密钥（待迁移）。
bool hasPlaintextSecrets(SshConfig c) =>
    ((c.privateKeyPem ?? '').isNotEmpty) ||
    ((c.keyPassphrase ?? '').isNotEmpty) ||
    ((c.password ?? '').isNotEmpty);

/// 提取配置中的非空密钥字段。
Map<String, String> _extractSecrets(SshConfig c) => {
      if ((c.privateKeyPem ?? '').isNotEmpty)
        kSecretKeyPem: c.privateKeyPem!,
      if ((c.keyPassphrase ?? '').isNotEmpty)
        kSecretKeyPass: c.keyPassphrase!,
      if ((c.password ?? '').isNotEmpty) kSecretPassword: c.password!,
    };

/// 迁移一批配置：带明文密钥的写入安全存储并剥离；
/// 返回剥离后的配置列表（无变化时返回 null，调用方免 persist）。
Future<List<SshConfig>?> migrateSshSecrets(List<SshConfig> configs,
    {SshSecretStore? store}) async {
  final st = store ?? sshSecretStore;
  var changed = false;
  final out = <SshConfig>[];
  for (final c in configs) {
    if (c.id.isEmpty || !hasPlaintextSecrets(c)) {
      out.add(c);
      continue;
    }
    try {
      await st.write(c.id, _extractSecrets(c));
    } on Exception {
      // 安全存储不可用（极少见）：保留明文，连接仍可用（fail-open）。
      out.add(c);
      continue;
    }
    changed = true;
    out.add(SshConfig(
      id: c.id,
      name: c.name,
      host: c.host,
      port: c.port,
      username: c.username,
      authType: c.authType,
      // 密钥剥离：JSON 不再落地。
    ));
  }
  return changed ? out : null;
}

/// 连接前回填密钥：安全存储优先，配置自带值兜底（兼容未迁移/无法迁移）。
Future<SshConfig> resolveSshSecrets(SshConfig config,
    {SshSecretStore? store}) async {
  if (config.id.isEmpty) return config;
  if ((config.privateKeyPem ?? '').isNotEmpty ||
      (config.password ?? '').isNotEmpty) {
    // 已带完整密钥（如向导刚生成的内存配置）直接用。
    return config;
  }
  final Map<String, String> secrets;
  try {
    secrets = await (store ?? sshSecretStore).read(config.id);
  } on Exception {
    return config;
  }
  if (secrets.isEmpty) return config;
  return SshConfig(
    id: config.id,
    name: config.name,
    host: config.host,
    port: config.port,
    username: config.username,
    authType: config.authType,
    privateKeyPem:
        secrets[kSecretKeyPem] ?? config.privateKeyPem,
    keyPassphrase:
        secrets[kSecretKeyPass] ?? config.keyPassphrase,
    password: secrets[kSecretPassword] ?? config.password,
  );
}
