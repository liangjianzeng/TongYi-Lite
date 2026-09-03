/// Agent 核心循环 —— 参照 DSH `agent-loop` 的 step() 简化版。
///
/// 循环本质：模型生成 → 若含工具调用则执行 → 结果回填 → 再次调模型 →
/// 直到无工具调用返回最终回答。循环参数全部来自 [AgentConfig]，不做死配置。
library;

import 'protocol/tool_protocol.dart';
import 'tool_definition.dart';
import 'tool_registry.dart';

/// Agent 循环配置（全部可配置，不做死配置）。
class AgentConfig {
  /// 工具循环上限（1~20）。达到上限给出提示而非死循环。
  final int maxRounds;

  /// 每轮生成预算（token），由 streamFn 消费（可随轮次递减）。
  final int maxTokensPerRound;

  /// 单工具执行超时。
  final Duration toolTimeout;

  /// 预留：并行工具调用（依赖能力 + 工具声明）。
  final bool allowParallelTools;

  /// 预留：工具轨迹持久化。
  final bool persistTrajectory;

  const AgentConfig({
    this.maxRounds = 5,
    this.maxTokensPerRound = 512,
    this.toolTimeout = const Duration(seconds: 15),
    this.allowParallelTools = false,
    this.persistTrajectory = false,
  }) : assert(maxRounds >= 1 && maxRounds <= 20);
}

/// 注入的模型流式生成函数：消费消息历史 + 协议，返回解析结果。
///
/// 由调用方（本地引擎 / OpenAI 服务）注入，使循环与具体模型解耦：
/// - 本地路线：把协议工具段注入 system，流式文本交给 protocol.parseStream；
/// - API 路线：原生 tools 请求，解析 tool_calls 后直接构造 StreamOutcome。
typedef AgentStreamFn = Future<StreamOutcome> Function(
  List<Map<String, String>> messages,
  ToolProtocol protocol,
  AgentConfig config,
);

/// 工具执行活动（UI 展示用）。
class ToolActivity {
  final String name;

  /// `executing`（开始执行）| `done`（成功）| `failed`（失败/超时）。
  final String status;

  /// 执行结果内容（失败时含错误原因）。
  final String? result;

  const ToolActivity({
    required this.name,
    required this.status,
    this.result,
  });

  bool get isDone => status == 'done';
  bool get isFailed => status == 'failed';
}

/// 工具活动回调：工具执行开始/结束都会触发，供 UI 更新活动消息。
typedef AgentToolActivityCallback = Future<void> Function(ToolActivity activity);

/// 一次 agent 运行的完整结果。
class AgentRunResult {
  /// 最终回答（可能含"已达轮次上限"提示）。
  final String answer;

  /// 供 UI 展示的工具活动（如 `get_time → 成功`）。
  final List<String> activities;

  /// 实际执行的工具调用数。
  final int toolCallCount;

  const AgentRunResult({
    required this.answer,
    required this.activities,
    required this.toolCallCount,
  });
}

/// 运行一次 agent 循环。
///
/// [history] 现有对话历史（`{role, content}`，不含本轮用户消息）；
/// [userPrompt] 本轮用户消息；[modelId] 用于工具可见性校验。
Future<AgentRunResult> runAgent({
  required List<Map<String, String>> history,
  required String userPrompt,
  required ToolRegistry registry,
  required ToolProtocol protocol,
  required AgentStreamFn streamFn,
  required String modelId,
  AgentConfig config = const AgentConfig(),
  String? systemPrompt,
  AgentToolActivityCallback? onToolActivity,
}) async {
  final messages = <Map<String, String>>[
    if (systemPrompt != null && systemPrompt.isNotEmpty)
      {'role': 'system', 'content': systemPrompt},
    ...history,
    {'role': 'user', 'content': userPrompt},
  ];
  final activities = <String>[];
  var toolCallCount = 0;

  for (var round = 0; round < config.maxRounds; round++) {
    final outcome = await streamFn(messages, protocol, config);

    // 无工具调用 → 返回最终回答。
    if (!outcome.hasToolCalls) {
      return AgentRunResult(
        answer: outcome.text,
        activities: activities,
        toolCallCount: toolCallCount,
      );
    }

    // 逐个执行工具（参照 DSH executeToolCalls；并行为预留能力）。
    for (final call in outcome.toolCalls) {
      // 通知 UI：工具开始执行。
      if (onToolActivity != null) {
        await onToolActivity(ToolActivity(name: call.name, status: 'executing'));
      }

      final result = await _executeTool(
        registry, call, modelId, config.toolTimeout);
      toolCallCount++;
      activities.add('${call.name} → ${result.isError ? '失败' : '成功'}');

      // 通知 UI：工具执行结束（成功/失败）。
      if (onToolActivity != null) {
        await onToolActivity(ToolActivity(
          name: call.name,
          status: result.isError ? 'failed' : 'done',
          result: result.content,
        ));
      }

      // 结果回填为 user 角色消息（参照 DSH createToolResultMessage）。
      messages.add({
        'role': 'user',
        'content': '工具调用结果(${call.name}):\n${result.content}',
        if (call.id.isNotEmpty) 'toolCallId': call.id,
      });
    }
  }

  // 达到轮次上限：明确提示而非死循环。
  return AgentRunResult(
    answer: '[已达到工具调用轮次上限 ${config.maxRounds}，请简化任务或直接提问]',
    activities: activities,
    toolCallCount: toolCallCount,
  );
}

/// 执行单个工具：未知工具 / 执行异常均回填可读错误并继续。
///
/// 错误处理三层防护（对 Future 错误最健壮）：
/// 1. execute 同步 throw（非 async 实现）→ try-catch；
/// 2. execute 返回的 Future 异步错误 → `.then(onError:)`；
/// 3. timeout 超时 / 链路错误 → 外层 catch 兜底。
Future<ToolResult> _executeTool(
  ToolRegistry registry,
  ToolCall call,
  String modelId,
  Duration timeout,
) async {
  final ToolDefinition? tool;
  try {
    tool = registry.lookup(call.name, modelId: modelId);
  } catch (e) {
    return ToolResult.error('工具查找失败: $e');
  }

  if (tool == null) {
    return ToolResult.error('未知工具 "${call.name}"（当前模型不可用）');
  }

  final args = call.arguments ?? const <String, dynamic>{};

  // 执行前统一必填校验（对照 DSH validateArgs）：缺参数时给出明确引导，
  // 回填给模型补全参数后重试，而不是直接执行失败。
  final violations = validateRequiredArguments(args, tool.parameters);
  if (violations.isNotEmpty) {
    return ToolResult.error('工具 "${call.name}" 参数不完整：${violations.join('；')}。请补全参数后重试');
  }

  final Future<ToolResult> future;
  try {
    future = tool.execute(args);
  } catch (e) {
    // execute 同步抛错（非 async 实现）。
    return ToolResult.error('工具 "${call.name}" 执行失败: $e');
  }

  try {
    return await future
        .then<ToolResult>(
          (value) => value,
          onError: (Object e, StackTrace st) =>
              ToolResult.error('工具 "${call.name}" 执行失败: $e'),
        )
        .timeout(timeout, onTimeout: () {
          return ToolResult.error('工具 "${call.name}" 执行超时');
        });
  } catch (e) {
    // timeout 阶段的错误兜底。
    return ToolResult.error('工具 "${call.name}" 执行失败: $e');
  }
}
