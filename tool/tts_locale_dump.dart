import 'package:edge_tts/edge_tts.dart';

Future<void> main() async {
  final manager = await VoicesManager.create().timeout(const Duration(seconds: 20));
  final locales = manager.voices.map((v) => v.locale).toSet().toList()..sort();
  final hits = locales.where((l) =>
      RegExp(r'^(zh|yue|wuu|nan|hak|gan|hsn|czh|lzh|cdo|cjy|cpx|czt|mnp|nan|wuu)', caseSensitive: false).hasMatch(l));
  print('中文相关 locale：${hits.join(", ")}');
  for (final v in manager.voices.where((v) => hits.contains(v.locale) && !v.locale.startsWith('zh'))) {
    print('${v.shortName.padRight(40)} ${v.locale} ${v.gender}');
  }
}
