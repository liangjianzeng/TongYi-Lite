/// SSH 开发环境工具（Dev Agent Phase B）—— 默认不注册，设置开启后挂载。
///
/// 连接策略（真机教训：别让用户手动连接）：
/// - 工具执行前按工作区绑定的配置**自动连接**（配置不完整/缺失给出明确诊断）；
/// - 执行中连接断开 → 自动重连一次并重试；
/// - 错误信息带 `[SSH]` 前缀并区分未配置/连接失败/执行失败，防模型幻觉成功。
/// 路径以"相对当前工作区"呈现，执行层映射到远端根目录。
library;

import 'dart:convert';

import '../../builtin_tools/shell_tool.dart'
    show kShellOutputLimit; // 复用同一截断上限语义
import '../../sandbox.dart' show withEscalationFields;
import '../../tool_definition.dart';
import '../safety.dart';
import '../ssh/ssh_credentials.dart' show SshConfig;
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
Future<({String root, DevWorkspace workspace})> resolveRemoteRoot(
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
String toRemotePath(String root, String rawPath) {
  final trimmed = rawPath.trim();
  if (trimmed.isEmpty) return root;
  if (trimmed.startsWith('/')) return trimmed; // 已是绝对路径
  return '$root/${trimmed.replaceAll(RegExp(r'^\./'), '')}';
}

/// 确保 SSH 连接（按工作区绑定的配置自动连接/切换）。
///
/// 返回错误信息（null = 已连接可用）。
Future<String?> ensureSshConnectionFor(
    SshEnvironmentService ssh, DevWorkspace ws, List<SshConfig> sshConfigs) async {
  // 已连接且配置匹配（都未绑定或绑定相同）：直接复用。
  if (ssh.isConnected) {
    final activeId = ssh.activeConfig?.id;
    final wsId = ws.sshConfigId;
    if (wsId == null || wsId.isEmpty || activeId == wsId) return null;
    // 绑定不同配置：需要切换。
  }
  SshConfig? cfg;
  final wsId = ws.sshConfigId;
  if (wsId == null || wsId.isEmpty) {
    // 未绑定配置：自动取列表里第一份完整配置。
    for (final c in sshConfigs) {
      if (c.isComplete) {
        cfg = c;
        break;
      }
    }
    if (cfg == null) {
      return 'SSH 未配置：请在「设置 → 开发者」中配置 Termux/远程电脑连接（自动生成密钥即可）';
    }
  } else {
    for (final c in sshConfigs) {
      if (c.id == wsId) {
        cfg = c;
        break;
      }
    }
    if (cfg == null || !cfg.isComplete) {
      return 'SSH 配置不完整：工作区「${ws.name}」绑定的连接配置缺失或未填完整，请在「设置 → 开发者」中补全';
    }
  }
  if (!await ssh.ensureConnected(cfg)) {
    return 'SSH 连接失败：${ssh.lastError ?? '未知原因'}'
        '（请确认 Termux 已安装 openssh 且已执行 sshd）';
  }
  return null;
}

/// P2-D2：读取远端工作区根目录的 AGENTS.md（SFTP，≤64KB）。
/// 任何失败（无远端工作区/未配置/连接失败/文件不存在）返回 null，
/// 调用方静默降级为只注入本地 AGENTS.md。
Future<String?> readRemoteAgentsMd(
    String? workspaceId, List<SshConfig> sshConfigs) async {
  try {
    final remote = await resolveRemoteRoot(workspaceId);
    final sshErr = await ensureSshConnectionFor(
        SshEnvironmentService.instance, remote.workspace, sshConfigs);
    if (sshErr != null) return null;
    final path = toRemotePath(remote.root, 'AGENTS.md');
    final bytes = await SshEnvironmentService.instance
        .readFileBytes(path, maxBytes: 65536);
    return utf8.decode(bytes, allowMalformed: true);
  } on Exception {
    return null;
  } on StateError {
    return null;
  }
}

/// 共享：在远端工作区执行命令（git/verify/ssh 工具共用）。
///
/// [buildCommand]：接收远端根目录，返回要执行的完整命令。
/// 内部做：工作区解析 → 自动连接 → 危险命令黑名单 → 执行 → 断连重连重试 → 截断。
Future<ToolResult> sshRunInWorkspace(
  Map<String, dynamic> args,
  String Function(String root) buildCommand, {
  List<SshConfig> sshConfigs = const [],
  Duration timeout = const Duration(seconds: 30),
  int outputLimit = kShellOutputLimit,
}) async {
  String fullCommand;
  DevWorkspace ws;
  try {
    final wsId = effectiveWorkspaceOf(args);
    final remote = await resolveRemoteRoot(wsId);
    ws = remote.workspace;
    fullCommand = buildCommand(remote.root);
  } on StateError catch (e) {
    return ToolResult.error('${e.message}（ssh 工具需要远端工作区）');
  }
  final danger = checkDangerousCommand(fullCommand);
  if (danger != null) {
    return ToolResult.error('危险命令被拒绝：$danger');
  }
  final ssh = SshEnvironmentService.instance;
  final connError = await ensureSshConnectionFor(ssh, ws, sshConfigs);
  if (connError != null) {
    return ToolResult.error('[SSH] $connError');
  }
  // 执行；连接类失败自动重连一次。
  for (var attempt = 0; attempt < 2; attempt++) {
    try {
      final output = await ssh.run(fullCommand, timeout: timeout);
      final trimmed = (output ?? '').trim();
      final truncated = trimmed.length > outputLimit
          ? '${trimmed.substring(0, outputLimit)}\n…（已截断）'
          : trimmed;
      return ToolResult(content: truncated.isEmpty ? '（无输出）' : truncated);
    } catch (e) {
      if (!ssh.isConnected && attempt == 0) {
        // 连接断了：自动重连一次再试。
        final retry = await ensureSshConnectionFor(ssh, ws, sshConfigs);
        if (retry == null) continue;
      }
      return ToolResult.error('[SSH] 命令执行失败：$e');
    }
  }
  return ToolResult.error('[SSH] 命令执行失败（已重试一次）');
}

/// ssh_exec：在远端执行命令（cwd 相对工作区）。
ToolDefinition createSshExecTool({List<SshConfig> sshConfigs = const []}) {
  return ToolDefinition(
    isConcurrencySafe: (_) => false, // 副作用工具：独占执行（P2-A）
    name: 'ssh_exec',
    description:
        '在 SSH 开发环境（Termux/远程电脑）执行 shell 命令。'
        '命令默认在工作区远端根目录下运行。输出截断到 ${kShellOutputLimit} 字符，超时 30s。'
        '需要完整文件系统访问时带 sandbox_permissions 请求用户批准。'
        '危险命令（rm -rf /、reboot、git push --force 等）会被拒绝。'
        '连接会自动建立，无需手动操作。',
    parameters: withEscalationFields({
      'type': 'object',
      'properties': {
        'command': {'type': 'string', 'description': '要执行的 shell 命令'},
        'cwd': {'type': 'string', 'description': '可选：相对当前工作区的目录（默认工作区根）'},
      },
      'required': ['command'],
    }),
    timeout: const Duration(seconds: 30),
    execute: (args) async {
      final command = (args['command'] as String?)?.trim() ?? '';
      if (command.isEmpty) return ToolResult.error('缺少 command 参数');
      final cwd = (args['cwd'] as String?)?.trim() ?? '';
      // 工作区 → 远端根目录映射。
      String fullCommand;
      try {
        final wsId = effectiveWorkspaceOf(args);
        final remote = await resolveRemoteRoot(wsId);
        fullCommand = cwd.isEmpty
            ? 'cd ${remote.root} && $command'
            : 'cd ${toRemotePath(remote.root, cwd)} && $command';
        final ssh = SshEnvironmentService.instance;
        final connError =
            await ensureSshConnectionFor(ssh, remote.workspace, sshConfigs);
        if (connError != null) {
          return ToolResult.error('[SSH] $connError');
        }
        // 危险命令黑名单（连接后执行前检查）。
        final danger = checkDangerousCommand(fullCommand);
        if (danger != null) {
          return ToolResult.error('危险命令被拒绝：$danger。'
              '请改用安全的等价操作，或向用户说明需求');
        }
        for (var attempt = 0; attempt < 2; attempt++) {
          try {
            final output = await ssh.run(fullCommand,
                timeout: const Duration(seconds: 30));
            final trimmed = (output ?? '').trim();
            final truncated = trimmed.length > kShellOutputLimit
                ? '${trimmed.substring(0, kShellOutputLimit)}\n…（已截断）'
                : trimmed;
            return ToolResult(
                content: truncated.isEmpty ? '（无输出）' : truncated);
          } catch (e) {
            if (!ssh.isConnected && attempt == 0) {
              final retry =
                  await ensureSshConnectionFor(ssh, remote.workspace, sshConfigs);
              if (retry == null) continue;
            }
            return ToolResult.error('[SSH] 命令执行失败：$e');
          }
        }
        return ToolResult.error('[SSH] 命令执行失败（已重试一次）');
      } on StateError catch (e) {
        return ToolResult.error('${e.message}（ssh 工具需要远端工作区）');
      }
    },
  );
}

/// ssh_read_file：远端读文件（SFTP）。
ToolDefinition createSshReadFileTool({List<SshConfig> sshConfigs = const []}) {
  return ToolDefinition(
    name: 'ssh_read_file',
    description:
        '读取 SSH 开发环境中当前工作区文件的内容。path 为相对工作区的路径。'
        '读取前 ${kSshReadFileLimit} 字符，超过部分截断。连接自动建立。',
    parameters: {
      'type': 'object',
      'properties': {
        'path': {'type': 'string', 'description': '相对当前工作区的文件路径'},
      },
      'required': ['path'],
    },
    timeout: const Duration(seconds: 30),
    execute: (args) async {
      final rawPath = (args['path'] as String?)?.trim() ?? '';
      if (rawPath.isEmpty) return ToolResult.error('缺少 path 参数');
      String remotePath;
      DevWorkspace ws;
      try {
        final wsId = effectiveWorkspaceOf(args);
        final remote = await resolveRemoteRoot(wsId);
        ws = remote.workspace;
        remotePath = toRemotePath(remote.root, rawPath);
      } on StateError catch (e) {
        return ToolResult.error('${e.message}（ssh 工具需要远端工作区）');
      }
      final ssh = SshEnvironmentService.instance;
      final connError = await ensureSshConnectionFor(ssh, ws, sshConfigs);
      if (connError != null) {
        return ToolResult.error('[SSH] $connError');
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
        return ToolResult.error('[SSH] 远端读取失败：$e');
      }
    },
  );
}

/// ssh_write_file：远端写文件（SFTP，覆盖截断）。
ToolDefinition createSshWriteFileTool({List<SshConfig> sshConfigs = const []}) {
  return ToolDefinition(
    isConcurrencySafe: (_) => false, // 副作用工具：独占执行（P2-A）
    name: 'ssh_write_file',
    description:
        '写入文本到 SSH 开发环境中当前工作区文件（覆盖，目录自动创建）。'
        'path 为相对工作区的路径，单次上限 ${kSshWriteFileLimit ~/ 1024}KB。连接自动建立。',
    parameters: {
      'type': 'object',
      'properties': {
        'path': {'type': 'string', 'description': '相对当前工作区的文件路径'},
        'content': {'type': 'string', 'description': '完整文件内容'},
      },
      'required': ['path', 'content'],
    },
    timeout: const Duration(seconds: 30),
    execute: (args) async {
      final rawPath = (args['path'] as String?)?.trim() ?? '';
      final content = (args['content'] as String?) ?? '';
      if (rawPath.isEmpty) return ToolResult.error('缺少 path 参数');
      if (content.isEmpty) return ToolResult.error('content 为空');
      if (content.length > kSshWriteFileLimit) {
        return ToolResult.error('内容过大（>${kSshWriteFileLimit ~/ 1024}KB）');
      }
      String remotePath;
      DevWorkspace ws;
      try {
        final wsId = effectiveWorkspaceOf(args);
        final remote = await resolveRemoteRoot(wsId);
        ws = remote.workspace;
        remotePath = toRemotePath(remote.root, rawPath);
      } on StateError catch (e) {
        return ToolResult.error('${e.message}（ssh 工具需要远端工作区）');
      }
      final ssh = SshEnvironmentService.instance;
      final connError = await ensureSshConnectionFor(ssh, ws, sshConfigs);
      if (connError != null) {
        return ToolResult.error('[SSH] $connError');
      }
      try {
        await ssh.writeFileBytes(remotePath, utf8.encode(content));
        return ToolResult(content: '已写入 $rawPath（${content.length} 字符）');
      } catch (e) {
        return ToolResult.error('[SSH] 远端写入失败：$e');
      }
    },
  );
}
