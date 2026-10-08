// 长图切块规划器自检（纯 VM 单进程可跑，无需 flutter_tools）：
//   C:\src\flutter\bin\cache\dart-sdk\bin\dart.exe run tool/plan_selfcheck.dart
// 覆盖 test/services/long_image_service_test.dart 中规划部分的等价断言。
import 'package:tongyi_lite/services/long_image_plan.dart';

int failures = 0;

void check(bool ok, String what) {
  if (!ok) {
    failures++;
    print('FAIL: $what');
  }
}

void expectFullCoverage(List<List<int>> plan, int height, String tag) {
  if (plan.isEmpty) {
    check(false, '$tag: 计划为空');
    return;
  }
  int? prevY;
  final covered = List<bool>.filled(height, false);
  for (final s in plan) {
    final y = s[0], h = s[1];
    check(h > 0, '$tag: 块高>0 ($y,$h)');
    check(y >= 0 && y + h <= height, '$tag: 越界 ($y,$h)');
    if (prevY != null) check(y > prevY, '$tag: y 严格递增 ($prevY -> $y)');
    prevY = y;
    for (var i = y; i < y + h && i < height; i++) covered[i] = true;
  }
  check(covered.every((e) => e), '$tag: 存在未覆盖行');
}

void main() {
  // 非长图不切。
  check(planLongImageSlices(width: 100, height: 150).isEmpty, '1.5x 不切');
  check(planLongImageSlices(width: 100, height: 200).isEmpty, '2.0x 不切');
  check(planLongImageSlices(width: 0, height: 100).isEmpty, '宽 0 → 空');
  check(planLongImageSlices(width: 100, height: 0).isEmpty, '高 0 → 空');

  // 典型手机长截图。
  final typical = planLongImageSlices(width: 768, height: 2772);
  check(typical.length > 1 && typical.length <= 10, '典型长图块数 2..10 (${typical.length})');
  expectFullCoverage(typical, 2772, '768x2772');

  // 超长图封顶。
  final huge = planLongImageSlices(width: 768, height: 60000, maxSlices: 10);
  check(huge.length <= 11, '超长图 ≤11 块 (${huge.length})');
  expectFullCoverage(huge, 60000, '768x60000');

  // 边界。
  expectFullCoverage(planLongImageSlices(width: 100, height: 201), 201, '100x201');

  // 尺寸扫描（与生产参数组合）：长图完整覆盖，非长图必须不切。
  for (final w in [256, 768, 1080, 1280]) {
    for (final h in [(256 * 2.5).round(), 5000, 12345, 99999, 249997]) {
      final p = planLongImageSlices(width: w, height: h);
      if (h > w * 2) {
        expectFullCoverage(p, h, '${w}x$h');
      } else {
        check(p.isEmpty, '${w}x$h 非长图不应切块');
      }
    }
  }

  // 随机扫描：任何宽高组合不得丢内容 / 不得乱序（区间推进法覆盖检查，O(块数)）。
  var seed = 20261008;
  int rnd(int n) {
    seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF;
    return seed % n;
  }
  for (var i = 0; i < 200000; i++) {
    final w = 1 + rnd(2000);
    final h = 1 + rnd(120000);
    final p = planLongImageSlices(width: w, height: h);
    if (h > w * 2) {
      if (p.isEmpty) {
        check(false, '随机 ${w}x$h 长图却未切块');
        continue;
      }
      var ok = true;
      int? prevY;
      var need = 0;
      for (final s in p) {
        final y = s[0], hh = s[1];
        if (hh <= 0 || y < 0 || y + hh > h || (prevY != null && y <= prevY)) {
          ok = false;
          break;
        }
        if (y > need) {
          ok = false; // 间隙 = 丢内容
          break;
        }
        if (y + hh > need) need = y + hh;
        prevY = y;
      }
      if (ok && need < h) ok = false;
      if (!ok) {
        failures++;
        print('FAIL: 随机 ${w}x$h 非法 ${p.map((e) => e.join(",")).join(";")}');
        if (failures > 5) break;
      }
    } else {
      check(p.isEmpty, '随机 ${w}x$h 非长图不应切块');
    }
  }

  print(failures == 0
      ? 'SELF-CHECK PASSED (planner: 边界 + 典型 + 扫描 + 随机 20000 例)'
      : 'SELF-CHECK FAILED: $failures');
  if (failures > 0) throw StateError('plan_selfcheck failed');
}
