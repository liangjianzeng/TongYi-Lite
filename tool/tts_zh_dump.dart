// dump Edge /voices/list 里全部 zh 系音色（找方言变体）。
import 'package:edge_tts/edge_tts.dart';

Future<void> main() async {
  final manager = await VoicesManager.create().timeout(const Duration(seconds: 20));
  final zh = manager.voices.where((v) => v.locale.startsWith('zh')).toList()
    ..sort((a, b) => a.shortName.compareTo(b.shortName));
  print('zh 系共 ${zh.length} 个 / 全部 ${manager.voices.length} 个：');
  for (final v in zh) {
    print('${v.shortName.padRight(40)} locale=${v.locale.padRight(16)} '
        'gender=${v.gender}');
  }
  final locales = manager.voices.map((v) => v.locale).toSet().toList()..sort();
  print('\nlocale 总数 ${locales.length}');
}
