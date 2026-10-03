/// 子代理工具（DSH Part 11）—— 模型自主调用 `subagent` 工具委派重活。
///
/// 白名单 schema：`task` / `mode` / `run_in_background`。前台执行等待结果
/// 回填；后台执行立即返回 id，完成通知经 [onBackgroundDone] 注入父回合
/// （DSH 后台子代理政策：独立委派一条消息并发起，跑的时候继续干别的）。
/// 续轮经 [createSubagentSendMessageTool]（DSH `send_message` 语义）。
library;

import 'dart:async' show unawaited;

import '../tool_definition.dart';
import 'provider.dart';

/// 构造 subagent 工具（闭包捕获具体 [SubagentProvider]，每 turn 新建）。
///
/// [onBackgroundDone]：后台子代理完成/失败时的通知回调（接入层注入，
/// 转投父回合 step 收件箱 + UI 可见痕迹）；null = 后台结果无人接收。
ToolDefinition createSubagentTool(
  SubagentProvider provider, {
  void Function(String notice)? onBackgroundDone,
}) {
  return ToolDefinition(
    name: 'subagent',
    description:
        '把一个自包含的子任务委派给子代理执行。子代理只返回最终结果，'
        '不返回中间过程——task 必须写成完整的独立任务书（背景、目标、'
        '要求、交付物），它看不到这段对话。默认前台等待结果；多个互相'
        '独立的委派应在同一条消息里一起发起（可 run_in_background 并行），'
        '继续做别的活，仅当下一步依赖该结果时才前台等待。',
    parameters: {
      'type': 'object',
      'properties': {
        'task': {
          'type': 'string',
          'description':
              '完整的独立任务书（self-contained；子代理看不到这段对话）',
        },
        'mode': {
          'type': 'string',
          'enum': ['spawn', 'fork'],
          'description':
              'spawn = 全新上下文（默认）；fork = 继承父已完成回合的前缀',
        },
        'run_in_background': {
          'type': 'boolean',
          'description':
              'true = 后台执行，立即返回子代理 id，完成时收到系统通知'
              '（默认 false = 前台等待结果）',
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
      final background = args['run_in_background'] == true;
      final request = SubagentStartRequest(task: task, mode: mode);
      try {
        final run = await provider.start(request);
        if (background) {
          if (onBackgroundDone != null) {
            unawaited(run.result.then((r) {
              final head = r.isError
                  ? '后台子代理失败（stopReason=${r.stopReason ?? 'error'}）'
                  : '后台子代理已完成';
              onBackgroundDone(
                  '$head（id=${run.id}）。结果如下：\n${r.output}');
            }));
          }
          return ToolResult(
              content: '已在后台启动子代理（id=${run.id}）。'
                  '完成时会收到 [系统通知]；期间请继续其他工作，'
                  '不要轮询等待。需要中途补充指令时用 send_message。');
        }
        final result = await run.result;
        var content = result.output;
        if (content.isEmpty) {
          content = '（子代理没有产出文本结果，stopReason='
              '${result.stopReason ?? 'unknown'}）';
        }
        // 停止原因诚实回传（DSH 语义）：非 completed 附注，防半成品冒充完成。
        if (result.stopReason != null && result.stopReason != 'completed') {
          content = '$content\n'
              '[注意：子代理因 ${result.stopReason} 提前结束，'
              '以上是部分输出，不代表任务全部完成]';
        }
        content = '$content\n(子代理 id=${run.id}：需要让它继续/补充时'
            '可用 send_message 指定该 id)';
        return ToolResult(content: content, isError: result.isError);
      } on SubagentMaxDepthExceeded catch (e) {
        return ToolResult.error(
            '子代理委派深度超限（上限 $kSubagentMaxDepth）：$e');
      } on Exception catch (e) {
        return ToolResult.error('子代理运行失败: $e');
      }
    },
  );
}

/// send_message 工具（DSH `tool-subagent-control` 语义）：向可续轮子代理
/// 追加指令并再跑一回合；结果作为工具结果回填。
ToolDefinition createSubagentSendMessageTool(SubagentProvider provider) {
  return ToolDefinition(
    name: 'send_message',
    description:
        '向之前委派的子代理追加指令（用 subagent 返回的 id），'
        '它会带着之前的上下文继续执行并返回新结果。'
        '适合：追问细节、让它修正产出、补充材料后再跑一轮。',
    parameters: {
      'type': 'object',
      'properties': {
        'subagent_id': {
          'type': 'string',
          'description': 'subagent 结果里返回的子代理 id',
        },
        'message': {
          'type': 'string',
          'description': '追加给子代理的指令（它能看到此前全部往来）',
        },
      },
      'required': ['subagent_id', 'message'],
    },
    execute: (args) async {
      final id = (args['subagent_id'] as String?)?.trim() ?? '';
      final message = (args['message'] as String?)?.trim() ?? '';
      if (id.isEmpty) return ToolResult.error('缺少 subagent_id 参数');
      if (message.isEmpty) return ToolResult.error('缺少 message 参数');
      try {
        final result = await provider.sendMessage(id, message);
        return ToolResult(content: result.output, isError: result.isError);
      } on Exception catch (e) {
        return ToolResult.error('send_message 失败: $e');
      }
    },
  );
}
