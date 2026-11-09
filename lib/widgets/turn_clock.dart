// ============================================================
// 回合秒级时钟（2026-10-25 阶段 4 计时器收敛）。
//
// 此前每张执行中的工具卡/思考卡各自开一个 Ticker（N 卡 N 个、每帧回调、
// 组件重建计时清零）。收敛为全 app **一个** 1s Timer + ValueNotifier<int>
// 广播：卡片只在 mounted 时监听，秒数变化才 setState。
// ============================================================

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show State, StatefulWidget;

class TurnClock {
  TurnClock._();
  static final TurnClock instance = TurnClock._();

  /// 每秒自增的 tick（监听方用它触发 setState，实际耗时用 DateTime 差值）。
  final ValueNotifier<int> tick = ValueNotifier<int>(0);
  Timer? _timer;
  int _refs = 0;

  /// 卡片 mount 时调用；引用计数归零自动停表（空闲零开销）。
  void acquire() {
    _refs++;
    _timer ??= Timer.periodic(const Duration(seconds: 1), (_) {
      tick.value = tick.value + 1;
    });
  }

  void release() {
    _refs = (_refs - 1).clamp(0, _refs);
    if (_refs == 0) {
      _timer?.cancel();
      _timer = null;
    }
  }
}

/// TurnClock 监听三件套的 State mixin：acquire + addListener / removeListener +
/// release 此前在 _ThinkingIndicatorState / _ToolActivityCardState /
/// _ThinkingStreamCardState 三处各抄一份（含 dispose 兜底），行为完全相同，
/// 收敛到这里消重；tick 统一触发一次 setState（秒级刷新头部耗时，实际耗时
/// 仍用 DateTime 差值，组件重建不丢）。
///
/// 用法：开时钟调 [turnClockStart]（幂等），关时钟 / dispose 调 [turnClockStop]
/// （幂等），开关成对调用即可，不关心引用计数。
mixin TurnClockListener<T extends StatefulWidget> on State<T> {
  /// 时钟是否已挂在本 State 上（防重复 acquire / 双重 release）。
  bool _clockOn = false;

  /// 开秒级时钟：acquire 引用计数 + 挂 tick 监听（已开则无操作）。
  void turnClockStart() {
    if (_clockOn) return;
    _clockOn = true;
    TurnClock.instance.acquire();
    TurnClock.instance.tick.addListener(_onTick);
  }

  /// 停秒级时钟：摘 tick 监听 + release（未开则无操作）；dispose 必须调用。
  void turnClockStop() {
    if (!_clockOn) return;
    _clockOn = false;
    TurnClock.instance.tick.removeListener(_onTick);
    TurnClock.instance.release();
  }

  /// 秒级 tick → setState 刷新。
  void _onTick() {
    if (mounted) setState(() {});
  }
}
