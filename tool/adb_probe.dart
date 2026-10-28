// ADB 真机自检（宿主侧取证用，不参与 app 构建）。
//
// 验证 app 内纯 Dart ADB 客户端的握手 / RSA 认证 / shell_v2 / exec(abb_exec) /
// sync push-pull / 截图 是否被**真 adbd** 接受 —— 协议细节只有连真机才算数。
//
// 用法：
//   TONGYI_LIVE_ADB=1 dart run tool/adb_probe.dart <host:port> [--key ~/.android/adbkey] \
//       [--cmd 'getprop ro.product.model'] [--selftest]
//
// 门控对齐 data_api_live_test 口径：没有 TONGYI_LIVE_ADB=1 一律拒绝连真机。
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:tongyi_lite/agent/adb/adb_client.dart';
import 'package:tongyi_lite/agent/adb/adb_connection.dart';
import 'package:tongyi_lite/agent/adb/adb_rsa.dart';

int _failures = 0;

void _check(String name, bool ok, [String detail = '']) {
  _failures += ok ? 0 : 1;
  print('${ok ? "PASS" : "FAIL"}  $name${detail.isEmpty ? "" : "  — $detail"}');
}

Future<void> main(List<String> args) async {
  if (Platform.environment['TONGYI_LIVE_ADB'] != '1') {
    stderr.writeln('需要 TONGYI_LIVE_ADB=1（真机门控）');
    exitCode = 2;
    return;
  }
  var target = '127.0.0.1:5555';
  String? keyPath;
  String? command;
  var selftest = false;
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--key' && i + 1 < args.length) {
      keyPath = args[++i];
    } else if (args[i] == '--cmd' && i + 1 < args.length) {
      command = args[++i];
    } else if (args[i] == '--selftest') {
      selftest = true;
    } else if (!args[i].startsWith('--')) {
      target = args[i];
    }
  }
  final parts = target.split(':');
  final host = parts.first;
  final port = int.parse(parts.length > 1 ? parts[1] : '5555');
  keyPath ??= '${Platform.environment['HOME']}/.android/adbkey';
  final AdbRsaKeyPair key;
  try {
    key = AdbRsaKeyPair.fromPem(await File(keyPath).readAsString());
  } catch (e) {
    // 以前这里直接抛栈：使用者只看到 fromPem 的一行 FormatException，不知道钥匙在哪儿。
    print('✗ 私钥不可用（$keyPath）：$e\n'
        '  需要 AOSP 风格的 ~/.android/adbkey（PKCS#1 PEM）。\n'
        '  app 侧钥匙见「设置 → 开发者 → 远程控制（ADB）」：可看指纹、导出公钥、导入已有 adbkey。');
    exitCode = 1;
    return;
  }

  enableAdbFrameDebugFromEnvironment();
  final sw = Stopwatch()..start();
  final AdbClient client;
  try {
    client = await AdbClient.connect(host: host, port: port, key: key);
  } catch (e) {
    // 连不上是验收里最常见的分支：给可读结论，别甩未捕获异常。
    print('✗ 连接失败 $host:$port —— $e');
    exitCode = 1;
    return;
  }
  final id = client.identity();
  print('CONNECT ${client.serial}  ${id.model} / ${id.device} '
      'android=${id.properties['ro.build.version.release']} '
      'sdk=${id.properties['ro.build.version.sdk']}  ${sw.elapsedMilliseconds}ms');
  _check('握手 + RSA 认证', id.model.isNotEmpty, 'model=${id.model}');

  if (command != null) {
    final r = await client.shell(command);
    print('CMD> $command\n${r.merged}\n(exit=${r.exitCode})');
  }

  if (selftest) {
    // 1) shell_v2：stdout/stderr 分离 + 真退出码（子帧头按 id+payload_size 解）
    final r = await client.shell("echo out-A; echo err-B >&2; exit 7");
    _check('shell_v2 stdout', r.stdout.trim() == 'out-A', jsonEncode(r.stdout));
    _check('shell_v2 stderr 分离', r.stderr.trim() == 'err-B', jsonEncode(r.stderr));
    _check('shell_v2 退出码', r.exitCode == 7, 'exit=${r.exitCode}');

    // 2) 中文 + 管道（UTF-8 全链路）
    final zh = await client.shell('echo 中文测试 | tr -d "\\n"');
    _check('shell UTF-8', zh.stdout == '中文测试', jsonEncode(zh.stdout));

    // 3) exec:（abb_exec）二进制安全 —— 截图必须是合法 PNG
    final png = await client.screenshot();
    final isPng = png.length > 8 &&
        png[0] == 0x89 &&
        png[1] == 0x50 &&
        png[2] == 0x4e &&
        png[3] == 0x47;
    _check('exec-out 截图 PNG 无损', isPng, '${png.length}B head='
        '${png.take(4).map((b) => b.toRadixString(16)).join()}');

    // 4) sync push → stat → pull → 校验和一致（含 >64KB 触发多帧停等）
    final rnd = Random(20261027);
    final blob = Uint8List.fromList(List.generate(300 * 1024, (_) => rnd.nextInt(256)));
    const remote = '/data/local/tmp/tongyi_lite_adb_probe.bin';
    await client.push(blob, remote, mode: 0x1a4);
    final st = await client.stat(remote);
    _check('push 后 stat 大小一致', st != null && st.size == blob.length,
        'stat=${st?.size} want=${blob.length}');
    final back = await client.pull(remote);
    _check('pull 字节完全一致',
        sha256.convert(back).toString() == sha256.convert(blob).toString(),
        '${back.length}B vs ${blob.length}B');
    final mode = st?.mode ?? 0;
    _check('push 保留权限 0644', (mode & 0xfff) == 0x1a4, 'mode=0o${mode.toRadixString(8)}');
    await client.shell('rm -f $remote');
    _check('清理临时文件', await client.stat(remote) == null);

    // 5) 列目录
    final entries = await client.ls('/data/local/tmp');
    _check('sync LIST 可用', entries.isNotEmpty, '${entries.length} 项');

    // 6) logcat -d（一次性导出，不常驻）
    final log = await client.logcat(lines: 20);
    _check('logcat -d', log.trim().isNotEmpty, '${log.length} 字');
  }

  await client.close();
  print(_failures == 0
      ? 'ALL PASS (${sw.elapsedMilliseconds}ms)'
      : '$_failures 项失败 (${sw.elapsedMilliseconds}ms)');
  exitCode = _failures == 0 ? 0 : 1;
}
