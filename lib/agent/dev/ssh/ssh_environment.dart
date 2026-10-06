/// SSH 开发环境服务（Dev Agent Phase B）—— 全局连接状态机 + 命令执行 + SFTP。
///
/// 仿 DSH-Phone `tunnel_service.dart` 的连接/认证模式（真机验证过）：
/// - 密钥优先（SSHKeyPair.fromPem），密码兜底（onPasswordRequest）；
/// - keep-alive 保活 + 主机密钥 TOFU（首次记录指纹，后续比对，可清除）；
/// - 输出健壮解码（UTF-8 → GBK → 宽松 UTF-8）。
///
/// 安全：仅作为 SSH **客户端**；默认目标 Termux sshd（127.0.0.1:8022），
/// 不暴露任何服务端口。连接层不感知工具/沙箱，工具层负责护栏。
library;

import 'dart:async' show TimeoutException;
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart' show ChangeNotifier, debugPrint;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'secret_store.dart' show resolveSshSecrets;
import 'ssh_credentials.dart';

/// 连接状态。
enum SshStatus { idle, connecting, connected, failed }

/// 单次 SFTP 读取上限（对齐 DSH-Phone 8MB 经验，防移动端 OOM）。
const int kSshMaxReadBytes = 8 * 1024 * 1024;

/// 连接/认证超时。
const Duration kSshConnectTimeout = Duration(seconds: 15);
const Duration kSshAuthTimeout = Duration(seconds: 20);

final class SshEnvironmentService extends ChangeNotifier {
  SshEnvironmentService._();

  /// 全局单例。
  static final SshEnvironmentService instance = SshEnvironmentService._();

  SshStatus _status = SshStatus.idle;
  SSHClient? _client;
  SshConfig? _activeConfig;
  String? _lastError;
  Map<String, String> _hostKeys = <String, String>{};

  SshStatus get status => _status;

  /// 当前生效配置（用于 UI 展示）。
  SshConfig? get activeConfig => _activeConfig;

  String? get lastError => _lastError;

  /// 是否已认证连接。
  bool get isConnected =>
      _status == SshStatus.connected && _client != null;

  /// 确保连接：未连接 → 连接；配置不同 → 自动切换；配置相同 → 复用。
  /// 返回是否处于已连接状态；失败原因见 [lastError]。
  Future<bool> ensureConnected(SshConfig config) async {
    await connect(config);
    return isConnected;
  }

  /// 建立连接（幂等：已连接且配置相同则跳过）。
  Future<void> connect(SshConfig config) async {
    // P2-D3：密钥从安全存储回填（JSON 只留空槽位；内存配置自带密钥则直通）。
    SshConfig cfg = config;
    try {
      cfg = await resolveSshSecrets(config);
    } on Exception catch (_) {}
    if (!cfg.isComplete) {
      _fail('SSH 配置不完整（host/port/username/认证）');
      return;
    }
    if (isConnected && _activeConfig != null) {
      // 配置未变：直接复用现有连接。
      if (_sameConfig(_activeConfig!, cfg)) return;
      await disconnect();
    }
    _status = SshStatus.connecting;
    _lastError = null;
    // 连接前预载主机指纹（onVerifyHostKey 是同步回调，须用内存缓存）。
    _hostKeys = await _loadHostKeys();
    notifyListeners();
    SSHClient? client;
    try {
      final socket = await SSHSocket.connect(cfg.host, cfg.port,
          timeout: kSshConnectTimeout);

      final List<SSHKeyPair>? identities;
      if (cfg.authType == SshAuthType.key) {
        try {
          identities = SSHKeyPair.fromPem(cfg.privateKeyPem ?? '',
              (cfg.keyPassphrase ?? '').isEmpty
                  ? null
                  : cfg.keyPassphrase);
        } catch (_) {
          // 旧版向导曾生成 checkint/公钥格式错误的密钥，永远无法认证。
          throw const FormatException(
              '密钥无法解析——旧版向导生成的坏格式密钥，请重跑「连接 Termux / 远程电脑」向导重新生成并安装');
        }
      } else {
        identities = null;
      }

      client = SSHClient(
        socket,
        username: cfg.username,
        identities: identities,
        onPasswordRequest: cfg.authType == SshAuthType.key
            ? null
            : () async => cfg.password,
        keepAliveInterval: const Duration(seconds: 10),
        onVerifyHostKey: (hostkeyType, fingerprint) =>
            _verifyHostKey(cfg, hostkeyType, fingerprint),
        // 注：fork 回调签名 = (typeName: String, fingerprint: Uint8List)。
      );

      // 传输关闭通知。
      client.done.then(
        (_) => _onTransportClosed(client!, failed: false),
        onError: (Object e) {
          debugPrint('[SSH] transport error: $e');
          _onTransportClosed(client!, failed: true);
        },
      );

      await client.authenticated.timeout(kSshAuthTimeout);
      if (client != _client) {
        // 并发断开守卫：期间被 disconnect 替换则放弃。
        client.close();
        throw const SocketException('SSH 连接已被替换，放弃本次');
      }
      _client = client;
      _activeConfig = cfg;
      _status = SshStatus.connected;
      notifyListeners();
      debugPrint('[SSH] connected ${config.username}@${config.host}:${config.port}');
    } catch (e) {
      debugPrint('[SSH] connect failed: $e');
      if (client != null && client != _client) client.close();
      _fail('连接失败：$e');
    }
  }

  /// 断开连接（幂等）。
  Future<void> disconnect() async {
    final client = _client;
    _client = null;
    _activeConfig = null;
    if (client != null) {
      try {
        client.close();
      } catch (_) {}
    }
    if (_status != SshStatus.idle) {
      _status = SshStatus.idle;
      notifyListeners();
    }
  }

  /// 连接探测：已连接时执行 `echo ok` 验证存活；失败自动标记断开。
  Future<bool> probe() async {
    if (!isConnected) return false;
    try {
      final out = await run('echo ok', timeout: const Duration(seconds: 5));
      return out?.trim() == 'ok';
    } catch (_) {
      _onTransportClosed(_client!, failed: true);
      return false;
    }
  }

  /// 远程执行一条命令，返回合并 stdout+stderr 的文本；失败抛异常。
  ///
  /// 注意（DSH-Phone 教训）：`client.run` 本身就是经远程 bash 执行，
  /// 不要再包一层 `sh -c '...'`（单引号嵌套冲突）。
  ///
  /// 超时处理（真机教训）：`client.run` 等待 stdout+stderr 双流 EOF，
  /// 命令 fork 后台进程等会让 stderr 不关 → future 永久挂起；超时后必须
  /// 断开连接（触发底层流关闭，释放泄漏的 session 通道），并把状态标记
  /// 断开，提示接入层"已断开可重连"。
  Future<String?> run(String command,
      {Duration timeout = const Duration(seconds: 15)}) async {
    final client = _client;
    if (client == null) throw const SocketException('SSH 未连接');
    try {
      final bytes = await client.run(command).timeout(timeout);
      return _decode(bytes);
    } on TimeoutException {
      debugPrint('[SSH] run timeout: $command');
      _onTransportClosed(client, failed: true);
      throw const SocketException(
          'SSH 命令执行超时，连接已断开（可重新连接后重试）');
    }
  }

  /// P2-D4：打开 SFTP 会话（workspace_sync 递归同步用）；未连接抛异常。
  Future<SftpClient> openSftp() async {
    final client = _client;
    if (client == null) throw const SocketException('SSH 未连接');
    return client.sftp();
  }

  /// 远程读取文件（SFTP），上限 [kSshMaxReadBytes]；失败抛异常。
  Future<Uint8List> readFileBytes(String path,
      {int? maxBytes}) async {
    final client = _client;
    if (client == null) throw const SocketException('SSH 未连接');
    final sftp = await client.sftp();
    try {
      final f = await sftp.open(path, mode: SftpFileOpenMode.read);
      try {
        final limit = (maxBytes ?? kSshMaxReadBytes).clamp(1, kSshMaxReadBytes);
        return await f.readBytes(length: limit);
      } finally {
        await f.close();
      }
    } finally {
      sftp.close();
    }
  }

  /// 远程写入文件（SFTP，覆盖截断）；失败抛异常。
  Future<void> writeFileBytes(String path, List<int> bytes) async {
    final client = _client;
    if (client == null) throw const SocketException('SSH 未连接');
    if (bytes.length > kSshMaxReadBytes) {
      throw ArgumentError('写入过大（>${kSshMaxReadBytes ~/ 1024 / 1024}MB）');
    }
    final sftp = await client.sftp();
    try {
      final f = await sftp.open(path,
          mode: SftpFileOpenMode.write |
              SftpFileOpenMode.create |
              SftpFileOpenMode.truncate);
      try {
        await f.writeBytes(Uint8List.fromList(bytes));
      } finally {
        await f.close();
      }
    } finally {
      sftp.close();
    }
  }

  // ---------------------------------------------------------------------------
  // 主机密钥 TOFU
  // ---------------------------------------------------------------------------

  Future<File> _hostKeysFile() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'dev', 'ssh'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return File(p.join(dir.path, 'hostkeys.json'));
  }

  Future<Map<String, String>> _loadHostKeys() async {
    try {
      final f = await _hostKeysFile();
      if (!f.existsSync()) return <String, String>{};
      final decoded = jsonDecode(f.readAsStringSync());
      if (decoded is Map<String, dynamic>) {
        return decoded.map((k, v) => MapEntry(k, v.toString()));
      }
    } catch (_) {}
    return <String, String>{};
  }

  Future<void> _persistHostKeys() async {
    final f = await _hostKeysFile();
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode(_hostKeys), flush: true);
    await tmp.rename(f.path);
  }

  /// TOFU 校验（同步回调，用内存缓存）：key = `host:port`。
  /// - 首次 → 记录指纹接受（fire-and-forget 落盘）；
  /// - 后续一致 → 接受；不一致 → 拒绝（设置页可清除重试）。
  ///
  /// 回调形参：typeName（如 "ssh-ed25519"）+ fingerprint（原始字节）。
  bool _verifyHostKey(SshConfig config, String typeName, Uint8List fingerprint) {
    final hex = fingerprint.map((b) =>
        b.toRadixString(16).padLeft(2, '0')).join(':');
    final key = '${config.host}:${config.port}';
    final saved = _hostKeys[key];
    if (saved == null) {
      _hostKeys[key] = hex;
      _persistHostKeys().catchError((_) {});
      return true;
    }
    if (saved == hex) return true;
    _lastError = '主机密钥指纹与上次不一致（$typeName），已拒绝连接。'
        '若服务端更换密钥，请清除保存的指纹后重试';
    return false;
  }

  /// 清除全部已保存主机指纹（设置页入口）。
  Future<void> clearHostKeyFingerprints() async {
    _hostKeys = <String, String>{};
    final f = await _hostKeysFile();
    if (f.existsSync()) f.deleteSync();
  }

  // ---------------------------------------------------------------------------
  // 内部
  // ---------------------------------------------------------------------------

  bool _sameConfig(SshConfig a, SshConfig b) =>
      a.host == b.host &&
      a.port == b.port &&
      a.username == b.username &&
      a.authType == b.authType;

  void _onTransportClosed(SSHClient client, {required bool failed}) {
    if (_client != client) return; // 已被替换/断开
    _client = null;
    _activeConfig = null;
    _status = failed ? SshStatus.failed : SshStatus.idle;
    _lastError = failed ? 'SSH 连接异常断开' : null;
    notifyListeners();
  }

  void _fail(String message) {
    _lastError = message;
    _status = SshStatus.failed;
    notifyListeners();
  }

  /// 健壮解码：UTF-8 → GBK/GB2312 → 宽松 UTF-8（对齐 DSH-Phone 经验）。
  String _decode(Uint8List bytes) {
    try {
      return utf8.decode(bytes);
    } catch (_) {
      try {
        return latin1.decode(bytes);
      } catch (_) {
        return utf8.decode(bytes, allowMalformed: true);
      }
    }
  }
}
