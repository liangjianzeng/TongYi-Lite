/// 工具防护（Phase 2）—— 对照 DSH `ctx.tools.guard()` 的单调 deny。
///
/// guard 只能 **deny**（never force-allow）或 abstain（放弃判断）。
/// 单调 deny：任一个 guard 返回 deny 即否决执行，不继续后续 guard。
library;

import '../dev/safety.dart' show checkDangerousCommand;
import '../tool_definition.dart';

/// guard 决策（单调 deny）。
enum GuardDecisionKind {
  deny,    // 否决执行（reason 为模型可见原因）
  abstain, // 本 guard 不判断
}

final class GuardDecision {
  final GuardDecisionKind kind;
  final String? reason;
  const GuardDecision(this.kind, {this.reason});

  static GuardDecision abstain() =>
      const GuardDecision(GuardDecisionKind.abstain);

  static GuardDecision deny(String reason) =>
      GuardDecision(GuardDecisionKind.deny, reason: reason);

  bool get isDeny => kind == GuardDecisionKind.deny;
}

/// 单次 guard 判断（纯同步，不阻塞）。
typedef ToolGuard = GuardDecision Function(ToolCall call,
    Map<String, dynamic> args);

/// 模型缓存保护 guard（AGENTS.md 铁律：卸载会清掉已下载模型缓存）。
/// 对照 DSH 模型缓存保护 guard（§6.5）。
final ToolGuard modelCacheGuard = (ToolCall call, Map<String, dynamic> args) {
  final cmd = (args['command'] as String? ?? '').toLowerCase();
  if (call.name == 'shell_exec' && cmd.contains('model_cache')) {
    return GuardDecision.deny(
        '模型缓存目录受保护。删除模型请用 model_manager，不要用 shell 直接 rm。');
  }
  if (call.name == 'shell_exec' && cmd.contains('models/')) {
    return GuardDecision.deny('模型目录受保护。删除模型请用 model_manager。');
  }
  final path = (args['path'] as String? ?? '').toLowerCase();
  if ((call.name == 'write_file' || call.name == 'edit_file') &&
      path.contains('/model_cache/')) {
    return GuardDecision.deny('模型缓存目录受保护，禁止直接读写。');
  }
  return GuardDecision.abstain();
};

/// 破坏性 shell 命令 guard（A2 生产接线）：复用 dev/safety 的
/// [checkDangerousCommand]（命令位判定、宁可漏杀不可误杀——越界 rm/
/// mkfs/dd/重启关机/su/git 硬重置等真破坏形态才拦）。
/// 此前该判定只被 Dev 工具内部调用，通用 shell_exec 无防护；现挂进
/// 六段流水线 guard 层，所有路线的 shell_exec 统一过筛。
/// 回归表：test/agent/dev_safety_matrix_test.dart。
final ToolGuard dangerousCommandShellGuard =
    (ToolCall call, Map<String, dynamic> args) {
  if (call.name != 'shell_exec') return GuardDecision.abstain();
  final cmd = args['command'] as String? ?? '';
  if (cmd.trim().isEmpty) return GuardDecision.abstain();
  final hit = checkDangerousCommand(cmd);
  if (hit != null) {
    return GuardDecision.deny('破坏性命令被拒绝：$hit');
  }
  return GuardDecision.abstain();
};
