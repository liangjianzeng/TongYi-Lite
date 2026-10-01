/// 内置工具聚合 —— 注册表可扩展，这里提供对齐 DSH 能力的完整起步集。
///
/// 工具按类别分组：
/// - 核心（默认启用）：get_time / calculator / todo / note / unit_converter / memory
/// - 文件（默认启用）：read_file / write_file / edit_file / list_files / search_text
/// - 网络（默认关，设置开启）：web_search / get_weather
/// - 系统（默认关，设置开启）：shell_exec
///
/// 具体启用由接入层按配置决定（createBuiltinTools 全量创建，接入层过滤）。
library;

export 'calculator.dart' show createCalculatorTool;
export 'export_file_tool.dart' show createExportFileTool, kArtifactExtensions;
export 'file_tools.dart'
    show
        createEditFileTool,
        createListFilesTool,
        createReadFileTool,
        createSearchTextTool,
        createWriteFileTool;
export 'get_time.dart' show createGetTimeTool;
export 'memory_tool.dart' show createMemoryGetTool, createMemorySetTool;
export 'note_tool.dart' show createNoteListTool, createNoteTakeTool, resetNoteStore;
export 'python_tool.dart' show createPythonExecTool;
export 'shell_tool.dart' show createShellExecTool;
export 'todo_tool.dart' show createTodoListTool, createTodoWriteTool, resetTodoStore;
export 'unit_converter_tool.dart' show createUnitConverterTool;
export 'weather_tool.dart' show createGetWeatherTool;
export 'web_search_tool.dart' show createWebSearchTool;
// Dev Agent 工具组（开发模式开启后注册）。
export '../dev/tools/git_tools.dart'
    show
        createGitCommitTool,
        createGitDiffTool,
        createGitLogTool,
        createGitPushTool,
        createGitStatusTool;
export '../dev/tools/plan_tools.dart'
    show createPlanCreateTool, createPlanListTool, createPlanUpdateTool;
export '../dev/tools/ssh_tools.dart'
    show
        createSshExecTool,
        createSshReadFileTool,
        createSshWriteFileTool;
export '../dev/tools/verify_tool.dart' show createRunTestsTool;

import '../dev/ssh/ssh_credentials.dart' show SshConfig;
import '../dev/tools/git_tools.dart';
import '../dev/tools/plan_tools.dart';
import '../dev/tools/ssh_tools.dart';
import '../dev/tools/verify_tool.dart';
import '../tool_definition.dart';
import 'calculator.dart';
import 'export_file_tool.dart';
import 'file_tools.dart';
import 'get_time.dart';
import 'memory_tool.dart';
import 'note_tool.dart';
import 'python_tool.dart';
import 'shell_tool.dart';
import 'todo_tool.dart';
import 'unit_converter_tool.dart';
import 'weather_tool.dart';
import 'web_search_tool.dart';

/// 核心工具名（默认启用；模型侧始终可见）。
const List<String> kCoreToolNames = [
  'get_time',
  'calculator',
  'todo_write',
  'todo_list',
  'note_take',
  'note_list',
  'unit_converter',
  'memory_set',
  'memory_get',
  'read_file',
  'write_file',
  'edit_file',
  'list_files',
  'search_text',
  'export_file',
];

/// 网络/系统工具名（默认关闭；设置开启后可见）。
const List<String> kOptionalToolNames = [
  'web_search',
  'get_weather',
  'shell_exec',
  'python_exec',
];

/// Dev 开发工具名（开发模式开启后可见；默认关闭）。
const List<String> kDevToolNames = [
  'git_status',
  'git_diff',
  'git_log',
  'git_commit',
  'git_push',
  'plan_create',
  'plan_update',
  'plan_list',
  'ssh_exec',
  'ssh_read_file',
  'ssh_write_file',
  'run_tests',
];

/// 创建全部内置工具（全量；接入层按配置过滤启用集）。
///
/// [webSearchMaxSearchesPerTurn]：web_search 每回合调用上限（DSH max_uses
/// 语义，默认 5），接入层按设置传入。
/// [includeDevTools]：Dev Agent 工具组（开发模式开启时 true）。
/// [devSshConfigs]：SSH 连接配置快照（回合级），Dev 工具据此自动连接。
List<ToolDefinition> createBuiltinTools({
    int webSearchMaxSearchesPerTurn = 5,
    bool includeDevTools = false,
    List<SshConfig> devSshConfigs = const []}) => [
      createGetTimeTool(),
      createCalculatorTool(),
      createTodoWriteTool(),
      createTodoListTool(),
      createNoteTakeTool(),
      createNoteListTool(),
      createUnitConverterTool(),
      createMemorySetTool(),
      createMemoryGetTool(),
      createReadFileTool(),
      createWriteFileTool(),
      createEditFileTool(),
      createListFilesTool(),
      createSearchTextTool(),
      createExportFileTool(),
      createWebSearchTool(
          maxSearchesPerTurn: webSearchMaxSearchesPerTurn),
      createGetWeatherTool(),
      createShellExecTool(),
      createPythonExecTool(),
      // Dev Agent 工具组（开发模式开启后由接入层过滤启用）。
      if (includeDevTools) ...[
        createGitStatusTool(sshConfigs: devSshConfigs),
        createGitDiffTool(sshConfigs: devSshConfigs),
        createGitLogTool(sshConfigs: devSshConfigs),
        createGitCommitTool(sshConfigs: devSshConfigs),
        createGitPushTool(sshConfigs: devSshConfigs),
        createPlanCreateTool(),
        createPlanUpdateTool(),
        createPlanListTool(),
        createSshExecTool(sshConfigs: devSshConfigs),
        createSshReadFileTool(sshConfigs: devSshConfigs),
        createSshWriteFileTool(sshConfigs: devSshConfigs),
        createRunTestsTool(sshConfigs: devSshConfigs),
      ],
    ];
