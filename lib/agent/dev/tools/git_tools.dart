/// Git 工具组（Dev Agent Phase C）—— 经 SSH 在远端工作区执行 git 命令。
///
/// 安全：commit 本地操作默认允许；push 属"影响远端"操作，工具声明
/// sandbox_permissions 升级字段，模型须带 justification 请求用户批准。
/// 破坏性命令（reset --hard / push --force）被黑名单拒绝。
/// 连接自动建立（按工作区绑定的配置），无需用户手动连接。
library;

import '../../sandbox.dart' show withEscalationFields;
import '../../tool_definition.dart';
import '../ssh/ssh_credentials.dart' show SshConfig;
import 'ssh_tools.dart' show sshRunInWorkspace;

/// bash 单引号转义（message 安全入 `git commit -m '...'`）。
String _singleQuote(String s) => "'${s.replaceAll("'", r"'\''")}'";

/// git_status：分支 + 改动概览。
ToolDefinition createGitStatusTool({List<SshConfig> sshConfigs = const []}) {
  return ToolDefinition(
    name: 'git_status',
    description:
        '查看当前工作区 git 仓库状态：当前分支、改动文件、未跟踪文件。'
        '开发任务开始时先调用确认基线。',
    parameters: const {'type': 'object'},
    timeout: const Duration(seconds: 15),
    execute: (args) async {
      return sshRunInWorkspace(args, (root) {
        return 'cd $root && git status --short --branch 2>/dev/null || '
            'echo "NOT_A_GIT_REPO"';
      }, sshConfigs: sshConfigs);
    },
  );
}

/// git_diff：查看改动内容（默认未暂存）。
ToolDefinition createGitDiffTool({List<SshConfig> sshConfigs = const []}) {
  return ToolDefinition(
    name: 'git_diff',
    description:
        '查看当前工作区改动：文件统计 + 具体 diff。'
        '可选 file 只看单个文件；staged=true 看已暂存改动。'
        '输出按 4000 字符截断，大改动先看统计再按文件细看。',
    parameters: {
      'type': 'object',
      'properties': {
        'file': {'type': 'string', 'description': '可选：只看某个文件'},
        'staged': {'type': 'boolean', 'description': '是否看已暂存改动（默认 false）'},
      },
    },
    timeout: const Duration(seconds: 15),
    execute: (args) async {
      final file = (args['file'] as String?)?.trim() ?? '';
      final staged = (args['staged'] as bool?) ?? false;
      return sshRunInWorkspace(args, (root) {
        final scope = staged ? '--staged' : '';
        final fileArg = file.isEmpty ? '' : ' $file';
        return 'cd $root && git diff $scope$fileArg --stat && '
            'echo "---" && git diff $scope$fileArg';
      }, sshConfigs: sshConfigs);
    },
  );
}

/// git_log：最近提交。
ToolDefinition createGitLogTool({List<SshConfig> sshConfigs = const []}) {
  return ToolDefinition(
    name: 'git_log',
    description:
        '查看最近提交历史（默认最近 10 条，一行摘要）。'
        '可选 n 指定条数。',
    parameters: {
      'type': 'object',
      'properties': {
        'n': {'type': 'number', 'description': '条数（默认 10）'},
      },
    },
    timeout: const Duration(seconds: 15),
    execute: (args) async {
      final n = ((args['n'] as num?)?.toInt() ?? 10).clamp(1, 50);
      return sshRunInWorkspace(args, (root) {
        return 'cd $root && git log --oneline -$n 2>/dev/null || '
            'echo "NOT_A_GIT_REPO"';
      }, sshConfigs: sshConfigs);
    },
  );
}

/// git_commit：暂存并提交（本地操作，默认允许）。
ToolDefinition createGitCommitTool({List<SshConfig> sshConfigs = const []}) {
  return ToolDefinition(
    name: 'git_commit',
    description:
        '提交当前工作区改动：files 为要提交的文件（相对工作区，可用 "." 提交全部），'
        'message 为提交说明。提交前建议先 git_diff 自查。'
        '这是本地操作，不需要批准。',
    parameters: {
      'type': 'object',
      'properties': {
        'files': {
          'type': 'array',
          'description': '要提交的文件（相对工作区；"." 提交全部改动）',
          'items': {'type': 'string'},
        },
        'message': {'type': 'string', 'description': '提交说明'},
      },
      'required': ['files', 'message'],
    },
    timeout: const Duration(seconds: 15),
    execute: (args) async {
      final rawFiles = args['files'] as List? ?? const [];
      final message = (args['message'] as String?)?.trim() ?? '';
      if (rawFiles.isEmpty) return ToolResult.error('files 为空（"." 提交全部）');
      if (message.isEmpty) return ToolResult.error('message 为空');
      final files = [
        for (final f in rawFiles)
          if (f is String && f.trim().isNotEmpty) f.trim(),
      ];
      if (files.isEmpty) return ToolResult.error('files 为空');
      return sshRunInWorkspace(args, (root) {
        final addArgs = files.join(' ');
        return 'cd $root && git add $addArgs && git commit -m ${_singleQuote(message)}';
      }, sshConfigs: sshConfigs);
    },
  );
}

/// git_push：推送远端（影响远端 → 需用户批准，走沙箱升级通道）。
ToolDefinition createGitPushTool({List<SshConfig> sshConfigs = const []}) {
  return ToolDefinition(
    name: 'git_push',
    description:
        '推送当前分支到远端仓库。会改动远端代码，需要用户批准：'
        '请带 sandbox_permissions + justification 请求批准后执行。',
    parameters: withEscalationFields({
      'type': 'object',
      'properties': {
        'remote': {'type': 'string', 'description': '可选：远端名（默认 origin）'},
        'branch': {'type': 'string', 'description': '可选：分支名（默认当前分支）'},
      },
    }),
    timeout: const Duration(seconds: 30),
    execute: (args) async {
      // 危险命令检查：push --force 在黑名单内（checkDangerousCommand 覆盖）。
      return sshRunInWorkspace(args, (root) {
        final remote = (args['remote'] as String?)?.trim() ?? 'origin';
        final branch = (args['branch'] as String?)?.trim() ?? '';
        final branchArg = branch.isEmpty ? '' : ' $branch';
        return 'cd $root && git push $remote$branchArg';
      }, timeout: const Duration(seconds: 30), sshConfigs: sshConfigs);
    },
  );
}
