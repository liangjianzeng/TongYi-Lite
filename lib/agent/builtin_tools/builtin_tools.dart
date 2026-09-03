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
export 'shell_tool.dart' show createShellExecTool;
export 'todo_tool.dart' show createTodoListTool, createTodoWriteTool, resetTodoStore;
export 'unit_converter_tool.dart' show createUnitConverterTool;
export 'weather_tool.dart' show createGetWeatherTool;
export 'web_search_tool.dart' show createWebSearchTool;

import '../tool_definition.dart';
import 'calculator.dart';
import 'file_tools.dart';
import 'get_time.dart';
import 'memory_tool.dart';
import 'note_tool.dart';
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
];

/// 网络/系统工具名（默认关闭；设置开启后可见）。
const List<String> kOptionalToolNames = [
  'web_search',
  'get_weather',
  'shell_exec',
];

/// 创建全部内置工具（全量；接入层按配置过滤启用集）。
List<ToolDefinition> createBuiltinTools() => [
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
      createWebSearchTool(),
      createGetWeatherTool(),
      createShellExecTool(),
    ];
