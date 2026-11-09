/// best-effort 角落的统一遥测通道（2026-11-09 健康度整改）。
///
/// 语义：这些 catch 吞掉的失败**不该影响主流程**（降级本就是正确行为），
/// 但"静默蒸发"= 不可观测 = 事故排障盲区——契约宣称"绝不丢内容""环境
/// 快照尽力注入"的角落，真出事时最怕的就是无从证明它到底有没有发生。
/// 统一 `[quiet-fail]` 前缀：logcat / 推理日志按一个关键字即可检索，
/// tag 按角落区分（点分域，如 'spill.store'）。
library;

import 'package:flutter/foundation.dart' show debugPrint;

/// 记录一次被吞掉的 best-effort 失败。[tag] 为角落标识；[stack] 可选，
/// 仅在堆栈有诊断价值时传（避免日志噪音）。
void quietFail(String tag, Object error, [StackTrace? stack]) {
  debugPrint('[quiet-fail] $tag: $error${stack == null ? '' : '\n$stack'}');
}
