// TTS 音色逐个实测探针：用 vendored edge_tts（与 app 完全同路径）对五地区
// 音色各合成一段文本，报告 异常/空音频/正常，定位"有些音色无法播放试听"。
// 运行：C:\src\flutter\bin\cache\dart-sdk\bin\dart.exe run tool/tts_voice_probe.dart
import 'dart:async';

import 'package:edge_tts/edge_tts.dart';

const keptLocales = ['zh-CN', 'zh-HK', 'zh-TW', 'en-US', 'en-GB'];

const zhText = '你好，这是语音播报的试听效果。';
const enText = 'Hello, this is a voice preview test.';

Future<String> probe(String voice, String text) async {
  try {
    final bytes = await Communicate(
      text: text,
      voice: voice,
      rate: '+0%',
      pitch: '+0Hz',
      volume: '+0%',
    ).toBytes().timeout(const Duration(seconds: 25));
    if (bytes.isEmpty) return 'EMPTY';
    return 'OK(${bytes.length}B)';
  } catch (e) {
    return 'ERR:${e.runtimeType}: ${e.toString().substring(0, e.toString().length.clamp(0, 120))}';
  }
}

Future<void> main() async {
  final manager = await VoicesManager.create().timeout(const Duration(seconds: 20));
  final voices = manager.voices
      .where((v) => keptLocales.any((l) => v.locale.startsWith(l)))
      .toList()
    ..sort((a, b) => a.shortName.compareTo(b.shortName));
  print('五地区音色共 ${voices.length} 个，开始逐个实测...\n');

  for (final v in voices) {
    final isEn = v.locale.startsWith('en');
    final zh = await probe(v.shortName, zhText);
    final en = isEn ? await probe(v.shortName, enText) : '-';
    print('${v.shortName.padRight(38)} 中文=$zh  英文=$en  gender=${v.gender}');
  }
  print('\ndone');
}
