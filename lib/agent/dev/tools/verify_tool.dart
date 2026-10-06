/// 验证循环工具（Dev Agent Phase C）—— 在工作区运行测试/构建。
///
/// 分派（L1 扩展）：远端后端（termux/remotePc）走 ssh 共享执行器（原路径）；
/// 本地后端（localApp/embedded/默认工作区）走内嵌沙箱执行器（dev_shell 同款，
/// PATH 前插 nativeLibraryDir）。默认 60s 超时（构建类任务）；输出截断 4000。
/// 失败 → 模型迭代修复 → 再跑；成功 → 接入层 tools/result hook 可推进计划。
library;

import '../../tool_definition.dart';
import '../safety.dart';
import '../ssh/ssh_credentials.dart' show SshConfig;
import '../workspace.dart';
import '../workspace_store.dart';
import 'embedded_tools.dart' show devShellRoot, executeDevShell;
import 'ssh_tools.dart' show sshRunInWorkspace;

/// run_tests：执行测试/构建命令。
ToolDefinition createRunTestsTool({List<SshConfig> sshConfigs = const []}) {
  return ToolDefinition(
    isConcurrencySafe: (_) => false, // 副作用工具：独占执行（P2-A）
    name: 'run_tests',
    description:
        '在当前工作区运行测试/构建命令，验证改动是否正确。'
        'command 为要执行的命令（如 "python -m pytest -q"、"npm test"、"flutter test"）；'
        '不传时返回常见约定并请模型补全。超时 60s，输出截断 4000 字符。'
        '失败请根据输出修复后重试，直到通过。',
    parameters: {
      'type': 'object',
      'properties': {
        'command': {'type': 'string', 'description': '测试/构建命令'},
        'cwd': {'type': 'string', 'description': '可选：相对当前工作区的目录'},
      },
      'required': ['command'],
    },
    timeout: const Duration(seconds: 60),
    execute: (args) async {
      final command = (args['command'] as String?)?.trim() ?? '';
      if (command.isEmpty) {
        return ToolResult.error('缺少 command 参数。常见约定：'
            'python 项目 "python -m pytest -q"，Node 项目 "npm test"，'
            'Flutter 项目 "flutter test"。请补全命令后重试');
      }
      final cwd = (args['cwd'] as String?)?.trim() ?? '';
      final full = cwd.isEmpty ? command : '$cwd && $command';
      // 本地工作区：内嵌沙箱执行（危险命令黑名单同通道）。
      final wsId = effectiveWorkspaceOf(args);
      final remote = wsId != null && wsId != DevWorkspace.kDefaultId
          ? await _isRemoteWorkspace(wsId)
          : false;
      if (!remote) {
        final danger = checkDangerousCommand(full);
        if (danger != null) {
          return ToolResult.error('危险命令被拒绝：$danger');
        }
        final root = await devShellRoot(wsId);
        return executeDevShell(full,
            root: root, timeout: const Duration(seconds: 60));
      }
      return sshRunInWorkspace(args, (root) {
        return cwd.isEmpty ? 'cd $root && $command' : 'cd $root/$cwd && $command';
      }, timeout: const Duration(seconds: 60), sshConfigs: sshConfigs);
    },
  );
}

/// 工作区是否存在且为远端后端（本地/默认/不存在 = 非远端）。
Future<bool> _isRemoteWorkspace(String workspaceId) async {
  try {
    final workspaces = await DevStore.resolve().loadWorkspaces();
    final ws = workspaces.where((w) => w.id == workspaceId).firstOrNull;
    return ws?.isRemote ?? false;
  } catch (_) {
    return false;
  }
}
