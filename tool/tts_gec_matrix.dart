// Sec-MS-GEC 403 参数矩阵探针：固定文本/音色，逐个改 Sec-MS-GEC-Version /
// Origin / Cookie，看哪一种组合能拿到 101 握手 + 音频。
// 运行：~/flutter/bin/cache/dart-sdk/bin/dart run tool/tts_gec_matrix.dart
import 'dart:async';
import 'dart:io';

import 'package:edge_tts/src/constants.dart';
import 'package:edge_tts/src/drm.dart';

const voice = 'zh-CN-XiaoxiaoNeural';
const text = '你好，这是语音播报的试听效果。';

Future<void> clockCheck() async {
  final client = HttpClient()..userAgent = null;
  try {
    final req = await client.getUrl(Uri.parse(
        '$voiceListUrl?trustedclienttoken=$trustedClientToken'));
    final resp = await req.close().timeout(const Duration(seconds: 12));
    await resp.drain<void>();
    final serverDate = resp.headers.value('date');
    if (serverDate != null) {
      final s = HttpDate.parse(serverDate);
      final local = DateTime.now().toUtc();
      final skew = s.difference(local).inSeconds;
      print('server Date = $serverDate');
      print('local  UTC  = ${HttpDate.format(local)}');
      print('>>> 时钟偏差 server-local = $skew 秒（|skew|>=300 会让 Sec-MS-GEC 失效）');
    }
  } catch (e) {
    print('clockCheck EXC: $e');
  } finally {
    client.close(force: true);
  }
}

Future<String> tryConnect({
  required String gecVersion,
  String? origin,
  bool withCookie = true,
  bool withSecMsGec = true,
}) async {
  final gec = generateSecMsGec();
  final params = <String>[
    'TrustedClientToken=$trustedClientToken',
    'ConnectionId=${generateUuidHex()}',
    if (withSecMsGec) 'Sec-MS-GEC=$gec',
    'Sec-MS-GEC-Version=$gecVersion',
  ];
  final ws = '$wssUrl?${params.join('&')}';
  final headers = <String, String>{...baseHeaders,
    'Pragma': 'no-cache',
    'Cache-Control': 'no-cache',
    if (origin != null) 'Origin': origin,
  };
  if (withCookie) headers['Cookie'] = 'muid=${generateMuid()};';
  final client = HttpClient()..userAgent = null;
  try {
    final socket = await WebSocket.connect(ws, headers: headers,
        customClient: client).timeout(const Duration(seconds: 12));
    final ts = generateTimestamp();
    socket.add('X-Timestamp:$ts\r\nContent-Type:application/json; charset=utf-8\r\n'
        'Path:speech.config\r\n\r\n{"context":{"synthesis":{"audio":{'
        '"metadataoptions":{"sentenceBoundaryEnabled":"false",'
        '"wordBoundaryEnabled":"false"},"outputFormat":"$audioFormat"}}}}');
    final ssml = '<speak version="1.0" xmlns="http://www.w3.org/2001/synthesis" '
        'xmlns:mstts="https://www.w3.org/2001/mstts" xml:lang="zh-CN">'
        '<voice name="$voice"><prosody rate="+0%" pitch="+0Hz" volume="+0%">'
        '$text</prosody></voice></speak>';
    socket.add('X-RequestId:${generateUuidHex()}\r\n'
        'Content-Type:application/ssml+xml\r\nX-Timestamp:${ts}Z\r\n'
        'Path:ssml\r\n\r\n$ssml');
    var audio = 0;
    var errHeader = '';
    await for (final msg in socket.timeout(const Duration(seconds: 15))) {
      if (msg is String) {
        if (msg.contains('X-Err') || msg.contains('Path:turn')) {
          errHeader = msg.split('\r\n\r\n').first.replaceAll('\r\n', ' | ');
        }
        if (msg.contains('Path:turn.end')) break;
      } else if (msg is List<int>) {
        audio += msg.length;
      }
    }
    await socket.close();
    return audio == 0 ? '101 但 0 字节音频  [$errHeader]' : '✅ OK ${audio}B';
  } on WebSocketException catch (e) {
    final m = RegExp(r'HTTP status code: (\d+)').firstMatch(e.toString());
    return 'HTTP ${m?.group(1) ?? '?'}';
  } catch (e) {
    return 'EXC ${e.runtimeType}';
  } finally {
    client.close(force: true);
  }
}

Future<void> main() async {
  print('--- 时钟核对 ---');
  await clockCheck();

  const versions = [
    '1-143.0.3650.75', // 当前 vendored 常量
    '1-142.0.3595.94',
    '1-141.0.3537.92',
    '1-140.0.3485.0',
    '1-138.0.3351.87',
    '1-131.0.2903.112',
    '1-120.0.2210.91',
  ];
  print('\n--- Sec-MS-GEC-Version 矩阵（Origin=chrome-extension）---');
  for (final v in versions) {
    final r = await tryConnect(gecVersion: v);
    print('${v.padRight(22)} $r');
  }

  final best = '1-143.0.3650.75';
  print('\n--- 其它头/参数变体（version=$best）---');
  final variants = <String, Future<String> Function()>{
    'Origin=https://www.bing.com': () => tryConnect(gecVersion: best, origin: 'https://www.bing.com'),
    '无 Origin': () => tryConnect(gecVersion: best, origin: null),
    '无 Cookie': () => tryConnect(gecVersion: best, withCookie: false),
    '无 Sec-MS-GEC': () => tryConnect(gecVersion: best, withSecMsGec: false),
  };
  for (final e in variants.entries) {
    print('${e.key.padRight(30)} ${await e.value()}');
  }
  print('\ndone');
}
