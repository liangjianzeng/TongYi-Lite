// 方言能力实测：XiaoxiaoDialectsNeural + SSML <lang> 各省口音在 Edge 免费接口
// 上是否出音频；顺带试 Azure 独有的陕西男声 YuntaNeural。
import 'package:edge_tts/edge_tts.dart';

const text = '你吃饭了没有？今天天气真好，咱们出去转一转。';

Future<String> probe(String voice, {String? dialect}) async {
  try {
    final bytes = await Communicate(
      text: text,
      voice: voice,
      dialectLocale: dialect,
    ).toBytes().timeout(const Duration(seconds: 25));
    return bytes.isEmpty ? 'EMPTY' : 'OK(${bytes.length}B)';
  } catch (e) {
    return 'ERR:${e.runtimeType}';
  }
}

Future<void> main() async {
  print('XiaoxiaoDialects 基础（无 lang）: ${await probe('zh-CN-XiaoxiaoDialectsNeural')}');
  const dialects = [
    'sichuan', 'henan', 'hunan', 'hubei', 'shandong', 'shanxi', 'anhui',
    'gansu', 'hebei', 'guizhou', 'yunnan', 'guangxi', 'liaoning', 'shaanxi',
    'tianjin', 'chongqing',
  ];
  for (final d in dialects) {
    final r = await probe('zh-CN-XiaoxiaoDialectsNeural',
        dialect: 'zh-CN-$d');
    print('zh-CN-${d.padRight(10)} $r');
  }
  print('shaanxi-YuntaNeural(男)      ${await probe('zh-CN-shaanxi-YuntaNeural')}');
  print('done');
}
