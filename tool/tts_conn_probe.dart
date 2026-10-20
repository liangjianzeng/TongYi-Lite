// 连接层排障探针（保留复用）：验证 createTtsHttpClient() 的 connectionFactory
// 在 **HTTPS GET** 与 **WebSocket upgrade** 两条路上都还正常。
//
// 为什么单独留这个工具：dart:io 的 connectionFactory 有两个静默坑（见
// third_party/edge_tts/lib/src/http_client.dart 文件头注释）——
//   ① 设了工厂后 HttpClient 不再自己做 TLS 升级（忘了升级 = 明文打 443，
//      表现是 `Connection reset by peer` / 握手 30s 超时，而不是清楚的报错）；
//   ② 直连时工厂拿到 `cf(uri, null, null)`，wss→https 改写后的 uri.port 是 0
//      （dart:io 只在自己那条路上做 port==0→443 归一化）。
// 两个坑在真机/真服务端上的表现都是「TTS 完全不出声」，跑一次本工具即可分辨。
//
// 用法：dart run tool/tts_conn_probe.dart
import 'dart:io';

import 'package:edge_tts/src/http_client.dart';

const token = '6A5AA1D4EAFF4E9FB37E23D68491D6F4';
const host = 'speech.platform.bing.com';

Future<void> main() async {
  var failed = false;
  for (final prefer in [false, true]) {
    final tag = prefer ? 'IPv4 优先' : '默认解析';

    // A) 普通 HTTPS GET（voices/list）
    final c1 = createTtsHttpClient(preferIPv4: prefer);
    try {
      final req = await c1.getUrl(Uri.parse(
          'https://$host/consumer/speech/synthesize/readaloud/voices/list?trustedclienttoken=$token'));
      req.headers.set('Sec-MS-GEC', '0' * 16);
      final resp = await req.close().timeout(const Duration(seconds: 15));
      await resp.drain();
      final ok = resp.statusCode == 200;
      if (!ok) failed = true;
      print('[${ok ? 'OK ' : 'BAD'}][$tag] GET        -> ${resp.statusCode}');
    } catch (e) {
      failed = true;
      print('[BAD][$tag] GET        -> ERR ${e.runtimeType}: $e');
    }
    c1.close(force: true);

    // B) WebSocket upgrade（合成用的就是这条路）。故意用废 token：
    //    403 = TLS + HTTP upgrade 都通了（服务端在鉴权层拒）；超时/reset = 连接层坏了。
    final c2 = createTtsHttpClient(preferIPv4: prefer);
    try {
      final ws = await WebSocket.connect(
        'wss://$host/consumer/speech/synthesize/readaloud/edge/v1'
        '?TrustedClientToken=$token&Sec-MS-GEC=${'0' * 16}-${'0' * 64}'
        '&Sec-MS-GEC-Version=1-143.0.3650.75',
        customClient: c2,
      ).timeout(const Duration(seconds: 12));
      failed = true;
      print('[BAD][$tag] WebSocket  -> 竟然握手成功了（预期 403）');
      await ws.close();
    } on WebSocketException catch (e) {
      final ok = e.toString().contains('403');
      if (!ok) failed = true;
      print('[${ok ? 'OK ' : 'BAD'}][$tag] WebSocket  -> '
          '${ok ? '按预期被鉴权拒绝(403)，连接层正常' : e}');
    } catch (e) {
      failed = true;
      print('[BAD][$tag] WebSocket  -> ERR ${e.runtimeType}: $e');
    }
    c2.close(force: true);
  }
  exit(failed ? 1 : 0);
}
