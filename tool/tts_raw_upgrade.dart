// 裸 HTTP Upgrade 探针：拿到 403 的完整响应头/响应体（Dart 的
// WebSocketException 把细节吞了，这里用 HttpClient 手工发 Upgrade 请求）。
// 运行：~/flutter/bin/cache/dart-sdk/bin/dart run tool/tts_raw_upgrade.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:edge_tts/src/constants.dart';
import 'package:edge_tts/src/drm.dart';

String _nonce() {
  final r = Random.secure();
  const chars =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  return List.generate(22, (_) => chars[r.nextInt(chars.length)]).join();
}

Future<void> probe(String label, Uri url, Map<String, String> headers) async {
  print('\n=== $label ===');
  // 裸 HTTP Upgrade 只能用 https://（HttpClient 不认 wss scheme）。
  if (url.scheme == 'wss') url = url.replace(scheme: 'https');
  if (url.scheme == 'ws') url = url.replace(scheme: 'http');
  print('URL: $url');
  final client = HttpClient()..userAgent = null;
  try {
    final req = await client.openUrl('GET', url).timeout(const Duration(seconds: 12));
    headers.forEach((k, v) => req.headers.set(k, v));
    req.headers.set('Connection', 'Upgrade');
    req.headers.set('Upgrade', 'websocket');
    req.headers.set('Sec-WebSocket-Key', _nonce());
    req.headers.set('Sec-WebSocket-Version', '13');
    final resp = await req.close().timeout(const Duration(seconds: 12));
    print('status = ${resp.statusCode} ${resp.reasonPhrase}');
    resp.headers.forEach((k, v) => print('  < $k: ${v.join(', ')}'));
    final body = await resp.transform(utf8.decoder).join();
    print('body(${body.length}): ${body.substring(0, body.length.clamp(0, 800))}');
    await resp.drain<void>();
  } catch (e) {
    print('EXC ${e.runtimeType}: $e');
  } finally {
    client.close(force: true);
  }
}

Future<void> main() async {
  final gec = generateSecMsGec();
  final base = {
    ...baseHeaders,
    'Origin': 'chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold',
    'Cookie': 'muid=${generateMuid()};',
  };

  await probe('A. edge/v1 全参（现状）', Uri.parse(
      '$wssUrl?TrustedClientToken=$trustedClientToken&ConnectionId=${generateUuidHex()}'
      '&Sec-MS-GEC=$gec&Sec-MS-GEC-Version=$secMsGecVersion'), base);

  await probe('B. edge/v1 仅 TrustedClientToken', Uri.parse(
      '$wssUrl?TrustedClientToken=$trustedClientToken&ConnectionId=${generateUuidHex()}'), base);

  await probe('C. 旧 /v2/tts（无 Sec-MS-GEC）', Uri.parse(
      'https://$baseUrl/v2/tts?speech_version=20200413&format=audio-24khz-48kbitrate-mono-mp3'
      '&lang=zh-CN&name=zh-CN-XiaoxiaoNeural&ssml=true&text=${Uri.encodeComponent('你好，测试。')}'),
      base);

  await probe('D. voices/list 对照（已知 200）', Uri.parse(
      '$voiceListUrl?trustedclienttoken=$trustedClientToken'
      '&Sec-MS-GEC=$gec&Sec-MS-GEC-Version=$secMsGecVersion'),
      {...baseHeaders, 'Authority': 'speech.platform.bing.com'});

  print('\ndone');
}
