// TTS 全链路现场诊断探针（纯 Dart，与 app 完全同路径的 vendored edge_tts）。
//
// 逐段输出：
//   ① voices/list HTTP 状态（音色列表能不能拉）
//   ② WebSocket 握手是否被拒（403 = Sec-MS-GEC 失效 / 401 = token 失效 /
//      101 = 握手成功）
//   ③ 服务端 turn 消息原文（403 时会带 X-Err / 空 audio 时只有 turn.end）
//   ④ 最终合成字节数（OK / EMPTY / ERR）
//
// 运行：~/flutter/bin/cache/dart-sdk/bin/dart run tool/tts_diag_probe.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:edge_tts/edge_tts.dart';
import 'package:edge_tts/src/constants.dart';
import 'package:edge_tts/src/drm.dart';

const voicesToTry = [
  'zh-CN-XiaoxiaoNeural',
  'zh-CN-YunxiNeural',
  'zh-CN-XiaoyiNeural',
  'zh-TW-HsiaoChengNeural',
  'en-US-AndrewMultilingualNeural',
];

const zhText = '你好，这是语音播报的试听效果。';

Future<void> step1VoicesList() async {
  print('=== ① voices/list ===');
  final gec = generateSecMsGec();
  final url = Uri.parse('$voiceListUrl?trustedclienttoken=$trustedClientToken'
      '&Sec-MS-GEC=$gec&Sec-MS-GEC-Version=$secMsGecVersion');
  final client = HttpClient()..userAgent = null;
  try {
    final req = await client.getUrl(url).timeout(const Duration(seconds: 15));
    voiceHeaders.forEach((k, v) => req.headers.set(k, v));
    final resp = await req.close().timeout(const Duration(seconds: 15));
    final body = await resp.transform(utf8.decoder).join();
    print('HTTP ${resp.statusCode}  bodyLen=${body.length}');
    if (resp.statusCode != 200) {
      print('body head: ${body.substring(0, body.length.clamp(0, 300))}');
    } else {
      final n = (jsonDecode(body) as List).length;
      print('音色总数 = $n');
    }
  } catch (e) {
    print('EXC: ${e.runtimeType}: $e');
  } finally {
    client.close(force: true);
  }
}

Future<void> step2RawHandshake() async {
  print('\n=== ② WebSocket 握手（裸连，看 HTTP 拒绝码）===');
  final gec = generateSecMsGec();
  final ws = '$wssUrl?TrustedClientToken=$trustedClientToken'
      '&ConnectionId=${generateUuidHex()}'
      '&Sec-MS-GEC=$gec'
      '&Sec-MS-GEC-Version=$secMsGecVersion';
  print('Sec-MS-GEC = $gec');
  print('Sec-MS-GEC-Version = $secMsGecVersion');
  final client = HttpClient()..userAgent = null;
  try {
    final socket = await WebSocket.connect(ws,
        headers: {...wssHeaders, 'Cookie': 'muid=${generateMuid()};'},
        customClient: client).timeout(const Duration(seconds: 15));
    print('握手成功（101 Switching Protocols）');
    await socket.close();
  } catch (e) {
    print('握手失败: ${e.runtimeType}: $e');
  } finally {
    client.close(force: true);
  }
}

/// 手工跑一遍 WebSocket 全流程，打印服务端每一条 text 消息原文。
Future<void> step3RawProtocol(String voice) async {
  print('\n=== ③ 协议原文（voice=$voice）===');
  final gec = generateSecMsGec();
  final ws = '$wssUrl?TrustedClientToken=$trustedClientToken'
      '&ConnectionId=${generateUuidHex()}'
      '&Sec-MS-GEC=$gec'
      '&Sec-MS-GEC-Version=$secMsGecVersion';
  final client = HttpClient()..userAgent = null;
  var audioBytes = 0;
  var textMsgs = 0;
  var binMsgs = 0;
  try {
    final socket = await WebSocket.connect(ws,
        headers: {...wssHeaders, 'Cookie': 'muid=${generateMuid()};'},
        customClient: client)
        .timeout(const Duration(seconds: 15));
    final ts = generateTimestamp();
    socket.add('X-Timestamp:$ts\r\n'
        'Content-Type:application/json; charset=utf-8\r\n'
        'Path:speech.config\r\n\r\n'
        '{"context":{"synthesis":{"audio":{"metadataoptions":'
        '{"sentenceBoundaryEnabled":"false","wordBoundaryEnabled":"false"}'
        ',"outputFormat":"$audioFormat"}}}}');
    final ssml =
        '<speak version="1.0" xmlns="http://www.w3.org/2001/10/synthesis" '
        'xmlns:mstts="https://www.w3.org/2001/mstts" xml:lang="zh-CN">'
        '<voice name="$voice"><prosody rate="+0%" pitch="+0Hz" volume="+0%">'
        '${zhText.replaceAll(RegExp(r'[&<>]'), '')}</prosody></voice></speak>';
    socket.add('X-RequestId:${generateUuidHex()}\r\n'
        'Content-Type:application/ssml+xml\r\n'
        'X-Timestamp:${ts}Z\r\nPath:ssml\r\n\r\n$ssml');
    await for (final msg in socket.timeout(const Duration(seconds: 20))) {
      if (msg is String) {
        textMsgs++;
        print('TEXT#${textMsgs}: ${msg.substring(0, msg.length.clamp(0, 400))}');
        if (msg.contains('Path:turn.end')) break;
      } else if (msg is List<int>) {
        binMsgs++;
        audioBytes += msg.length;
      }
    }
    await socket.close();
  } catch (e) {
    print('EXC: ${e.runtimeType}: $e');
  } finally {
    client.close(force: true);
  }
  print('text消息=$textMsgs  二进制消息=$binMsgs  audioBytes=$audioBytes');
}

Future<void> step4Library(String voice) async {
  print('\n=== ④ vendored 库 toBytes（voice=$voice）===');
  try {
    final bytes = await Communicate(
      text: zhText,
      voice: voice,
      rate: '+0%',
      pitch: '+0Hz',
      volume: '+0%',
    ).toBytes().timeout(const Duration(seconds: 30));
    print(bytes.isEmpty ? 'EMPTY（0 字节，app 侧即静默失败）' : 'OK(${bytes.length}B)');
    if (bytes.isNotEmpty) {
      final f = File('/tmp/tts_diag_probe.mp3');
      await f.writeAsBytes(Uint8List.fromList(bytes));
      print('已落盘 ${f.path}');
    }
  } catch (e) {
    print('ERR: ${e.runtimeType}: $e');
  }
}

Future<void> main() async {
  await step1VoicesList();
  await step2RawHandshake();
  await step3RawProtocol(voicesToTry.first);
  await step4Library(voicesToTry.first);
  print('\n=== ⑤ 多音色实测 ===');
  for (final v in voicesToTry) {
    try {
      final bytes = await Communicate(
              text: zhText, voice: v, rate: '+0%', pitch: '+0Hz', volume: '+0%')
          .toBytes()
          .timeout(const Duration(seconds: 30));
      print('${v.padRight(36)} ${bytes.isEmpty ? "EMPTY" : "OK(${bytes.length}B)"}');
    } catch (e) {
      print('${v.padRight(36)} ERR:${e.runtimeType} ${e.toString().substring(0, e.toString().length.clamp(0, 140))}');
    }
  }
  print('\ndone');
}
