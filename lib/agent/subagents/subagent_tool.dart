/// 子代理工具（DSH Part 11）—— 模型自主调用 `subagent` 工具委派重活。
///
/// 白名单 schema：仅暴露 `task` / `mode`。执行体经 [SubagentProvider.start]
/// 创建并运行子代理，把最终结果回填为工具结果（§10.5 映射）。
library;

import '../tool_definition.dart';
import 'provider.dart';

/// 构造 [ToolDefinition]（闭包捕获具体 [SubagentProvider]，每 turn 新建）。
/// 子代理与父共享同一 registry；深度/上下文由 provider 内
/// [SubagentDepthCounter] / [completedTurnPrefix] 保证正确。
ToolDefinition createSubagentTool(SubagentProvider provider) {
  return ToolDefinition(
    name: 'subagent',
    description:
        'Delegate a task to an in-process subagent. mode "spawn" = fresh '
        'context (no parent history); "fork" = inherit the completed turns '
        'so far. The subagent runs to a final answer and returns it here.',
    parameters: {
      'type': 'object',
      'properties': {
        'task': {
          'type': 'string',
          'description':
              'The concrete task to delegate (self-contained; the subagent '
              'cannot see this conversation).',
        },
        'mode': {
          'type': 'string',
          'enum': ['spawn', 'fork'],
          'description':
              'spawn = start fresh (no parent context); fork = inherit '
              'completed parent turns (default: spawn).',
        },
      },
      'required': ['task'],
    },
    execute: (args) async {
      final task = (args['task'] as String? ?? '').trim();
      if (task.isEmpty) {
        return ToolResult.error('subagent 需要非空 task');
      }
      final mode = args['mode'] as String? ?? 'spawn';
      if (mode != 'spawn' && mode != 'fork') {
        return ToolResult.error('subagent mode 只能是 spawn 或 fork');
      }
      final request = SubagentStartRequest(task: task, mode: mode);
      try {
        final run = await provider.start(request);
        final result = await run.result;
        return ToolResult(content: result.output, isError: result.isError);
      } on SubagentMaxDepthExceeded catch (e) {
        return ToolResult.error(
            '子代理委派深度超限（上限 $kSubagentMaxDepth）：$e');
      } on Exception catch (e) {
        return ToolResult.error('子代理运行失败: $e');
      }
    },
  );
}
