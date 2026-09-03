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

/// 校验工具参数（对照 DSH `validateArgs`）：执行前统一检查必填字段，
/// 返回可读违规列表（空表示通过）。错误信息明确列出缺失参数名与用途，
/// 便于模型理解并补全参数后重试——这是「shell_exec 永远缺参数」的根治层。
///
/// 规则：
/// - `required` 中声明的字段必须存在；
/// - 字符串必填参数不允许空串（trim 后为空视为缺失）；
/// - 其余类型只做存在性检查（工具自身做值域校验）。
List<String> validateRequiredArguments(
  Map<String, dynamic> args,
  Map<String, dynamic> schema,
) {
  final violations = <String>[];
  final required = schema['required'];
  if (required is! List || required.isEmpty) return violations;

  final props = schema['properties'];
  for (final key in required) {
    final name = key.toString();
    final value = args[name];
    String? usage;
    if (props is Map && props[name] is Map) {
      usage = (props[name] as Map)['description']?.toString();
    }
    if (value == null) {
      violations.add('缺少必填参数 $name${usage != null ? '（$usage）' : ''}');
    } else if (value is String && value.trim().isEmpty) {
      violations.add('必填参数 $name 不能为空${usage != null ? '（$usage）' : ''}');
    }
  }
  return violations;
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
