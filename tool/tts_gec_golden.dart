// v2 token golden 对照工具：打印固定时间戳的 Dart 端 token，
// 与 Python 参考实现（上游 drm.py 转录）输出做 diff。
// 运行：~/flutter/bin/cache/dart-sdk/bin/dart run tool/tts_gec_golden.dart [ts ...]
import 'package:edge_tts/src/constants.dart';
import 'package:edge_tts/src/gec_v2.dart';

void main(List<String> args) {
  final stamps = args.isEmpty
      ? <int>[
          1791888000, 0, 999999999, 1234567890, 1760000000, 1760000300,
          1846809161, 1768428921, 1714153003, 1858436640, 1633481396,
          1865863138, 1643948984, 1679469777,
        ]
      : args.map(int.parse).toList();
  for (final t in stamps) {
    print('$t ${generateSecMsGecV2(t, trustedClientToken)}');
  }
  print('# secMsGecVersion=$secMsGecVersion');
}
