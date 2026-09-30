/// SSH 开发环境配置（Dev Agent Phase B）。
///
/// 默认目标：Termux sshd（127.0.0.1:8022）。认证：ed25519 密钥优先，
/// 密码兜底。密钥/密码明文存 settings JSON（对齐现有 apiModels 密钥明文
/// 先例；后续可迁移 flutter_secure_storage）。
library;

/// SSH 认证类型。
enum SshAuthType { key, password }

/// SSH 连接配置。
final class SshConfig {
  final String host;
  final int port;
  final String username;
  final SshAuthType authType;
  final String? privateKeyPem;
  final String? keyPassphrase;
  final String? password;

  const SshConfig({
    this.host = '127.0.0.1',
    this.port = 8022,
    this.username = '',
    this.authType = SshAuthType.key,
    this.privateKeyPem,
    this.keyPassphrase,
    this.password,
  });

  bool get isComplete =>
      host.trim().isNotEmpty &&
      port > 0 &&
      username.trim().isNotEmpty &&
      (authType == SshAuthType.password
          ? (password ?? '').isNotEmpty
          : (privateKeyPem ?? '').isNotEmpty);

  SshConfig copyWith({
    String? host,
    int? port,
    String? username,
    SshAuthType? authType,
    String? privateKeyPem,
    String? keyPassphrase,
    String? password,
  }) {
    return SshConfig(
      host: host ?? this.host,
      port: port ?? this.port,
      username: username ?? this.username,
      authType: authType ?? this.authType,
      privateKeyPem: privateKeyPem ?? this.privateKeyPem,
      keyPassphrase: keyPassphrase ?? this.keyPassphrase,
      password: password ?? this.password,
    );
  }

  Map<String, dynamic> toJson() => {
        'host': host,
        'port': port,
        'username': username,
        'authType': authType.name,
        if (privateKeyPem != null) 'privateKeyPem': privateKeyPem,
        if (keyPassphrase != null) 'keyPassphrase': keyPassphrase,
        if (password != null) 'password': password,
      };

  static SshConfig? fromJson(Map<String, dynamic> json) {
    final host = (json['host'] as String?)?.trim() ?? '';
    final username = (json['username'] as String?)?.trim() ?? '';
    if (host.isEmpty || username.isEmpty) return null;
    final auth = SshAuthType.values
        .where((t) => t.name == json['authType'])
        .firstOrNull;
    return SshConfig(
      host: host,
      port: (json['port'] as num?)?.toInt() ?? 8022,
      username: username,
      authType: auth ?? SshAuthType.key,
      privateKeyPem: (json['privateKeyPem'] as String?)?.trim(),
      keyPassphrase: (json['keyPassphrase'] as String?)?.trim(),
      password: (json['password'] as String?)?.trim(),
    );
  }
}
