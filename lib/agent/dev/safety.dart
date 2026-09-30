/// Dev 安全护栏（Dev Agent Phase B）—— 危险命令黑名单。
///
/// 策略：
/// - `deny`（默认）：命中黑名单直接拒绝，模型收到可读错误；
/// - `ask`：设置放宽后，命中黑名单转用户审批（复用 AgentSandboxApprover）。
/// 检测 = 正则模式匹配（命令文本级启发式，覆盖常见破坏性/逃逸写法）。
library;

/// 危险命令策略。
enum DangerousCommandPolicy { deny, ask }

/// 黑名单模式：`[名称, 正则, 说明]`。
const List<List<String>> kDangerousCommandPatterns = [
  ['rm -rf 根目录', r'(^|[;&|]\s*)(rm\s+-rf\s+(/|\$HOME|\$PWD/\.\.))', '删除根目录'],
  ['格式化', r'\bmkfs\b|\bmke2fs\b|\bformat\b', '格式化磁盘'],
  ['dd 直写设备', r'\bdd\s+[^|]*of=/dev/', '直写块设备'],
  ['重启/关机', r'\breboot\b|\bshutdown\b|\binit\s+[06]\b|\bpoweroff\b', '重启/关机'],
  ['挂载', r'\bmount\b|\bumount\b', '挂载文件系统'],
  ['提权', r'(^|[;&|]\s*)su\b|\bsudo\s+', '提权'],
  ['git 硬重置', r'git\s+reset\s+--hard', '丢弃提交'],
  ['git 强推', r'git\s+push\s+[^|]*--force', '强制推送'],
  ['管道装软件', r'(curl|wget)\s+[^|]*\|\s*(sh|bash|python)\b', '下载并执行'],
  ['清空内存', r'\bsync\b|\becho\s+[^|]*>\s*/proc/sys', '内核参数直写'],
  ['修改系统文件', r'(^|[;&|]\s*)(sed|echo|tee)\s+[^|]*>\s*/etc/', '系统配置直写'],
  ['删除系统目录', r'rm\s+-rf\s+(/usr|/system|/data|/vendor)', '删除系统目录'],
  ['chmod 递归全开', r'chmod\s+-R\s+777\s+/', '权限全开'],
];

/// 检查命令是否命中黑名单；命中返回 `[名称] 说明` 格式的可读拒绝原因。
String? checkDangerousCommand(String command, {bool allowAsk = false}) {
  final trimmed = command.trim();
  if (trimmed.isEmpty) return null;
  for (final entry in kDangerousCommandPatterns) {
    try {
      if (RegExp(entry[1], caseSensitive: false).hasMatch(trimmed)) {
        return '${entry[0]}（${entry[2]}）';
      }
    } catch (_) {
      // 模式非法则跳过（fail-open 于模型，不阻断合法命令）。
    }
  }
  return null;
}
