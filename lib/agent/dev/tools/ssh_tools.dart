/// SSH 开发环境工具（Dev Agent Phase B）—— 默认不注册，设置开启后挂载。
///
/// 依赖 `SshEnvironmentService`（已连接）；未连接返回明确错误并提示
/// 模型/用户先建立连接。命令走危险命令黑名单（deny/ask 策略）。
/// 路径以"相对当前工作区"呈现，执行层映射到远端根目录。
library;

import 'dart:convert';

import '../../builtin_tools/shell_tool.dart'
    show kShellOutputLimit; // 复用同一截断上限语义
import '../../sandbox.dart' show withEscalationFields;
import '../../tool_definition.dart';
import '../safety.dart';
import '../ssh/ssh_environment.dart';
import '../workspace.dart';
import '../workspace_store.dart';

/// 单次远端读文件上限（与本地 read_file 对齐）。
const int kSshReadFileLimit = 8192;

/// 单次远端写入上限（与本地 write_file 对齐）。
const int kSshWriteFileLimit = 65536;

/// 解析远端工作区根目录。
///
/// - workspaceId 缺失/默认 → 错误（默认工作区是本地，无远端路径）；
/// - 工作区不存在 → 错误；backend 非远端 → 错误；remotePath 空 → 错误。
/// 返回 `(root, workspace)`。
Future<({String root, DevWorkspace workspace})> _resolveRemoteRoot(
    String? workspaceId) async {
  if (workspaceId == null || workspaceId == DevWorkspace.kDefaultId) {
    throw StateError('当前工作区是本地默认工作区，没有远端路径。'
        '请先切换到 Termux/远程电脑工作区，或使用本地文件工具');
  }
  final store = DevStore();
  final workspaces = await store.loadWorkspaces();
  final ws = workspaces.where((w) => w.id == workspaceId).firstOrNull;
  if (ws == null) {
    throw StateError('工作区不存在：$workspaceId');
  }
  if (!ws.isRemote) {
    throw StateError('工作区「${ws.name}」是本地后端，无远端路径');
  }
  final root = (ws.remotePath ?? '').trim();
  if (root.isEmpty) {
    throw StateError('工作区「${ws.name}」未配置远端路径（remotePath）');
  }
  return (root: root, workspace: ws);
}

/// 相对路径 → 远端绝对路径（相对基于工作区远端根目录）。
String _toRemotePath(String root, String rawPath) {
  final trimmed = rawPath.trim();
  if (trimmed.isEmpty) return root;
  if (trimmed.startsWith('/')) return trimmed; // 已是绝对路径
  return '$root/${trimmed.replaceAll(RegExp(r'^\./'), '')}';
}

/// 共享：在远端工作区执行命令（git/verify/ssh 工具共用）。
///
/// [buildCommand]：接收远端根目录，返回要执行的完整命令。
/// 内部做：工作区解析 → 危险命令黑名单 → 连接检查 → 执行 → 截断。
Future<ToolResult> sshRunInWorkspace(
  Map<String, dynamic> args,
  String Function(String root) buildCommand, {
  Duration timeout = const Duration(seconds: 15),
  int outputLimit = kShellOutputLimit,
}) async {
  String fullCommand;
  try {
    final wsId = effectiveWorkspaceOf(args);
    final remote = await _resolveRemoteRoot(wsId);
    fullCommand = buildCommand(remote.root);
  } on StateError catch (e) {
    return ToolResult.error('${e.message}（ssh 工具需要远端工作区）');
  }
  final danger = checkDangerousCommand(fullCommand);
  if (danger != null) {
    return ToolResult.error('危险命令被拒绝：$danger');
  }
  final ssh = SshEnvironmentService.instance;
  if (!ssh.isConnected) {
    return ToolResult.error('SSH 未连接：${ssh.lastError ?? '请先在设置中连接开发环境'}');
  }
  try {
    final output = await ssh.run(fullCommand, timeout: timeout);
    final trimmed = (output ?? '').trim();
    final truncated = trimmed.length > outputLimit
        ? '${trimmed.substring(0, outputLimit)}\n…（已截断）'
        : trimmed;
    return ToolResult(content: truncated.isEmpty ? '（无输出）' : truncated);
  } catch (e) {
    return ToolResult.error('SSH 命令执行失败：$e');
  }
}

/// ssh_exec：在远端执行命令（cwd 相对工作区）。
ToolDefinition createSshExecTool() {
  return ToolDefinition(
    name: 'ssh_exec',
    description:
        '在 SSH 开发环境（Termux/远程电脑）执行 shell 命令。'
        '命令默认在工作区远端根目录下运行。输出截断到 ${kShellOutputLimit} 字符，超时 15s。'
        '需要完整文件系统访问时带 sandbox_permissions 请求用户批准。'
        '危险命令（rm -rf /、reboot、git push --force 等）会被拒绝。',
    parameters: withEscalationFields({
      'type': 'object',
      'properties': {
        'command': {'type': 'string', 'description': '要执行的 shell 命令'},
        'cwd': {'type': 'string', 'description': '可选：相对当前工作区的目录（默认工作区根）'},
      },
      'required': ['command'],
    }),
    timeout: const Duration(seconds: 15),
    execute: (args) async {
      final command = (args['command'] as String?)?.trim() ?? '';
      if (command.isEmpty) return ToolResult.error('缺少 command 参数');
      final cwd = (args['cwd'] as String?)?.trim() ?? '';
      // 工作区 → 远端根目录映射。
      String fullCommand;
      try {
        final wsId = effectiveWorkspaceOf(args);
        final remote = await _resolveRemoteRoot(wsId);
        fullCommand = cwd.isEmpty
            ? 'cd ${remote.root} && $command'
            : 'cd ${_toRemotePath(remote.root, cwd)} && $command';
      } on StateError catch (e) {
        return ToolResult.error('${e.message}（ssh 工具需要远端工作区）');
      }
      // 危险命令黑名单。
      final danger = checkDangerousCommand(fullCommand);
      if (danger != null) {
        return ToolResult.error('危险命令被拒绝：$danger。'
            '请改用安全的等价操作，或向用户说明需求');
      }
      // 连接检查。
      final ssh = SshEnvironmentService.instance;
      if (!ssh.isConnected) {
        return ToolResult.error('SSH 未连接：${ssh.lastError ?? '请先在设置中连接开发环境'}');
      }
      try {
        final output = await ssh.run(fullCommand,
            timeout: const Duration(seconds: 15));
        final trimmed = (output ?? '').trim();
        final truncated = trimmed.length > kShellOutputLimit
            ? '${trimmed.substring(0, kShellOutputLimit)}\n…（已截断）'
            : trimmed;
        return ToolResult(content: truncated.isEmpty ? '（无输出）' : truncated);
      } catch (e) {
        return ToolResult.error('SSH 命令执行失败：$e');
      }
    },
  );
}

/// ssh_read_file：远端读文件（SFTP）。
ToolDefinition createSshReadFileTool() {
  return ToolDefinition(
    name: 'ssh_read_file',
    description:
        '读取 SSH 开发环境中当前工作区文件的内容。path 为相对工作区的路径。'
        '读取前 ${kSshReadFileLimit} 字符，超过部分截断。',
    parameters: {
      'type': 'object',
      'properties': {
        'path': {'type': 'string', 'description': '相对当前工作区的文件路径'},
      },
      'required': ['path'],
    },
    timeout: const Duration(seconds: 15),
    execute: (args) async {
      final rawPath = (args['path'] as String?)?.trim() ?? '';
      if (rawPath.isEmpty) return ToolResult.error('缺少 path 参数');
      String remotePath;
      try {
        final wsId = effectiveWorkspaceOf(args);
        final remote = await _resolveRemoteRoot(wsId);
        remotePath = _toRemotePath(remote.root, rawPath);
      } on StateError catch (e) {
        return ToolResult.error('${e.message}（ssh 工具需要远端工作区）');
      }
      final ssh = SshEnvironmentService.instance;
      if (!ssh.isConnected) {
        return ToolResult.error('SSH 未连接：${ssh.lastError ?? '请先在设置中连接开发环境'}');
      }
      try {
        final bytes = await ssh.readFileBytes(remotePath);
        final content = utf8.decode(bytes, allowMalformed: true);
        return ToolResult(
          content: content.length <= kSshReadFileLimit
              ? content
              : '${content.substring(0, kSshReadFileLimit)}\n…（已截断）',
        );
      } catch (e) {
        return ToolResult.error('远端读取失败：$e');
      }
    },
  );
}

/// ssh_write_file：远端写文件（SFTP，覆盖截断）。
ToolDefinition createSshWriteFileTool() {
  return ToolDefinition(
    name: 'ssh_write_file',
    description:
        '写入文本到 SSH 开发环境中当前工作区文件（覆盖，目录自动创建）。'
        'path 为相对工作区的路径，单次上限 ${kSshWriteFileLimit ~/ 1024}KB。',
    parameters: {
      'type': 'object',
      'properties': {
        'path': {'type': 'string', 'description': '相对当前工作区的文件路径'},
        'content': {'type': 'string', 'description': '完整文件内容'},
      },
      'required': ['path', 'content'],
    },
    timeout: const Duration(seconds: 15),
    execute: (args) async {
      final rawPath = (args['path'] as String?)?.trim() ?? '';
      final content = (args['content'] as String?) ?? '';
      if (rawPath.isEmpty) return ToolResult.error('缺少 path 参数');
      if (content.isEmpty) return ToolResult.error('content 为空');
      if (content.length > kSshWriteFileLimit) {
        return ToolResult.error('内容过大（>${kSshWriteFileLimit ~/ 1024}KB）');
      }
      String remotePath;
      try {
        final wsId = effectiveWorkspaceOf(args);
        final remote = await _resolveRemoteRoot(wsId);
        remotePath = _toRemotePath(remote.root, rawPath);
      } on StateError catch (e) {
        return ToolResult.error('${e.message}（ssh 工具需要远端工作区）');
      }
      final ssh = SshEnvironmentService.instance;
      if (!ssh.isConnected) {
        return ToolResult.error('SSH 未连接：${ssh.lastError ?? '请先在设置中连接开发环境'}');
      }
      try {
        await ssh.writeFileBytes(remotePath, utf8.encode(content));
        return ToolResult(content: '已写入 $rawPath（${content.length} 字符）');
      } catch (e) {
        return ToolResult.error('远端写入失败：$e');
      }
    },
  );
}
