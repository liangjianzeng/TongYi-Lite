/// 工具输出溢写（Phase 2）—— 对照 DSH Part 10.13。
///
/// 语义：工具结果过大时，best-effort 落盘，模型只看到「省略 + 定位符」；
/// 失败时保留原文（绝不丢内容）。`read_file` 结果跳过（防 read/spill 循环）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../observability/quiet_fail.dart';
import '../session/event.dart';
import '../session/log.dart';
import '../tool_definition.dart';

/// 溢写决策：是否把工具结果从内联视图省略（落盘）。
final class SpillDecision {
  final bool spilled;
  final String? locator;
  final int bytesOmitted;

  const SpillDecision({this.spilled = false, this.locator, this.bytesOmitted = 0});

  /// 模型看到的内联内容：溢写时替换为「省略 + 定位符」。
  String contentForModel(String original) {
    if (!spilled || locator == null) return original;
    return '[工具结果过大，$bytesOmitted 字节已省略。完整结果已落盘于：'
        '$locator（可用 read_file 指定 offset 回读）]';
  }
}

/// 溢写存储抽象：best-effort 落盘，返回定位符（可注入便于测试）。
typedef SpillStore = Future<String> Function(Uint8List bytes);

/// 端侧溢写（默认 maxInlineTokens=4096，端侧预算小）。
final class Spill {
  /// 内联 token 预算；超过则溢写。
  final int maxInlineTokens;
  /// 落盘器。
  final SpillStore store;

  Spill({this.maxInlineTokens = 4096, required this.store});

  /// 粗略 token 估算（chars/4，整数除法，偏保守）。
  int estimateTokens(String s) {
    final t = s.length ~/ 4;
    return t < 1 ? 1 : t;
  }

  /// 是否该溢写该工具结果；溢写时追加 [kEventSpillLocate]（log-only，不进模型历史）。
  Future<SpillDecision> decide(
    SessionLog log,
    ToolCall call,
    ToolResult result,
  ) async {
    // 防 read/spill 循环：read_file 的结果总是内联。
    if (call.name == 'read_file') {
      return const SpillDecision();
    }
    final tokens = estimateTokens(result.content);
    if (tokens <= maxInlineTokens) {
      return const SpillDecision();
    }
    // 真 UTF-8 字节数（旧实现把 UTF-16 码元数当字节命名/展示，CJK 场景虚高 ~3 倍）。
    final bytes = utf8.encode(result.content);
    try {
      final locator = await store(bytes);
      log.append(
        kEventSpillLocate,
        {
          'callId': call.id,
          'locator': locator,
          'bytes': bytes.length,
          'bytesOmitted': bytes.length,
        },
        source: {'kind': 'tool', 'callId': call.id},
      );
      return SpillDecision(spilled: true, locator: locator, bytesOmitted: bytes.length);
    } catch (e, st) {
      // best-effort：失败保留原文（绝不丢内容）——**必须兜全部异常**：store 是
      // 真实文件写入，磁盘满/路径非法抛 FileSystemException，旧窄 catch(FormatException)
      // 会穿透到 _safeExecute，把已成功执行的工具结果整体替换成"流水线异常"，
      // 模型误判工具失败并重试，与文件头契约相悖（2026-11-09 健康度评审 P1）。
      quietFail('spill.store', e, st);
      return const SpillDecision();
    }
  }
}
