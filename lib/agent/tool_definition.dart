/// 工具定义模型 —— 参照 DSH `defineTool` 的白名单原则：
/// 给模型的 schema 只暴露 `name/description/parameters`，执行体绝不外泄。
library;

/// 一次工具调用的执行结果，回填给模型（参照 DSH `createToolResultMessage`）。
class ToolResult {
  /// 回填模型的文本内容。
  final String content;

  /// 是否失败；失败时 [content] 为可读错误信息。
  final bool isError;

  const ToolResult({required this.content, this.isError = false});

  factory ToolResult.error(String message) =>
      ToolResult(content: message, isError: true);
}

/// 模型请求的一次工具调用（参照 DSH `ToolCallBlock`）。
class ToolCall {
  /// 调用 id，用于结果关联（参照 DSH `CallId`）。
  final String id;

  /// 工具名。
  final String name;

  /// 解析后的参数；解析失败时为 null。
  final Map<String, dynamic>? arguments;

  const ToolCall({
    required this.id,
    required this.name,
    this.arguments,
  });
}

/// 一个可注册的工具（参照 DSH `ToolDefinition`）。
class ToolDefinition {
  /// 工具名（必须唯一）。
  final String name;

  /// 发送给模型的工具说明。
  final String description;

  /// 参数的 JSON Schema 对象（仅描述，白名单原则）。
  final Map<String, dynamic> parameters;

  /// 执行函数：入参为模型解析后的参数，返回回填结果。
  final Future<ToolResult> Function(Map<String, dynamic> args) execute;

  /// 并行安全声明（预留：DSH `isConcurrencySafe`）。
  /// 返回 true 表示可与兄弟调用并行；默认 false（独占/串行）。
  final bool Function(Map<String, dynamic> args)? isConcurrencySafe;

  /// 合作式超时预算（预留：DSH `timeoutMs`）。执行体应能响应取消。
  final Duration? timeout;

  const ToolDefinition({
    required this.name,
    required this.description,
    required this.parameters,
    required this.execute,
    this.isConcurrencySafe,
    this.timeout,
  });

  /// 是否声明为并行安全（未声明视为独占）。
  bool concurrencySafeFor(Map<String, dynamic> args) =>
      isConcurrencySafe?.call(args) ?? false;
}
