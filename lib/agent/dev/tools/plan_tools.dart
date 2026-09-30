/// 开发计划工具（Dev Agent Phase C）—— 跨回合的结构化步骤计划。
///
/// 与 todo（回合内即时清单）区分：plan 持久化绑定到 DevTask，
/// 状态机推进（进行中步骤 → done），DevContext 注入摘要。
/// 全部经 [DevStore] 读写，无 SSH 依赖。
library;

import '../../tool_definition.dart';
import '../task.dart';
import '../workspace_store.dart';

/// 从任务列表找任务；不存在返回 null。
Future<DevTask?> _findTask(DevStore store, String taskId) async {
  final tasks = await store.loadTasks();
  return tasks.where((t) => t.id == taskId).firstOrNull;
}

/// 解析步骤数组参数（[{title, detail?, verify?}]）；非法条目丢弃。
List<DevPlanStep> _parseSteps(List<dynamic> raw, {bool? done}) {
  final out = <DevPlanStep>[];
  for (final item in raw) {
    if (item is! Map<String, dynamic>) continue;
    final title = (item['title'] as String?)?.trim();
    if (title == null || title.isEmpty) continue;
    out.add(DevPlanStep(
      id: 's${out.length + 1}',
      title: title,
      detail: (item['detail'] as String?)?.trim() ?? '',
      verify: (item['verify'] as String?)?.trim(),
      done: done ?? (item['done'] as bool?) ?? false,
    ));
  }
  return out;
}

/// 创建/替换任务的计划。参数：`task_id`（必填）、`steps`（步骤数组）。
ToolDefinition createPlanCreateTool({DevStore? store}) {
  return ToolDefinition(
    name: 'plan_create',
    description:
        '为开发任务创建/替换结构化执行计划：有序步骤 + 每步完成标准（verify）。'
        'task_id 为当前任务 id（来自工作区上下文）。'
        '步骤：{"title": 步骤标题, "detail": 实施要点, "verify": 完成标准}。',
    parameters: {
      'type': 'object',
      'properties': {
        'task_id': {'type': 'string', 'description': '开发任务 id'},
        'steps': {
          'type': 'array',
          'description': '有序步骤列表',
          'items': {
            'type': 'object',
            'properties': {
              'title': {'type': 'string', 'description': '步骤标题'},
              'detail': {'type': 'string', 'description': '实施要点'},
              'verify': {'type': 'string', 'description': '完成标准'},
            },
            'required': ['title'],
          },
        },
      },
      'required': ['task_id', 'steps'],
    },
    timeout: const Duration(seconds: 10),
    execute: (args) async {
      final taskId = (args['task_id'] as String?)?.trim() ?? '';
      final rawSteps = args['steps'] as List? ?? const [];
      if (taskId.isEmpty) return ToolResult.error('缺少 task_id 参数');
      final steps = _parseSteps(rawSteps);
      if (steps.isEmpty) return ToolResult.error('steps 为空或格式非法');
      final s = store ?? DevStore();
      final task = await _findTask(s, taskId);
      if (task == null) return ToolResult.error('任务不存在：$taskId');
      final updated = task.copyWith(
        plan: DevPlan(steps: steps, currentStep: 0),
        status: DevTaskStatus.implementing,
        updatedAt: DateTime.now(),
      );
      await s.saveTask(updated);
      return ToolResult(
        content: '计划已建立（${steps.length} 步），当前第 1 步：'
            '${steps.first.title}'
            '${steps.first.verify != null ? '（完成标准：${steps.first.verify}）' : ''}',
      );
    },
  );
}

/// 更新计划。参数：`task_id`、`action`（mark_done | add_step）。
ToolDefinition createPlanUpdateTool({DevStore? store}) {
  return ToolDefinition(
    name: 'plan_update',
    description:
        '更新开发任务的计划状态：'
        'mark_done（step_id 标记完成，自动推进下一步）；'
        'add_step（追加步骤）。task_id 为当前任务 id。',
    parameters: {
      'type': 'object',
      'properties': {
        'task_id': {'type': 'string', 'description': '开发任务 id'},
        'action': {
          'type': 'string',
          'enum': ['mark_done', 'add_step'],
          'description': 'mark_done 标记步骤完成；add_step 追加步骤',
        },
        'step_id': {'type': 'string', 'description': '目标步骤 id（mark_done 用）'},
        'done': {'type': 'boolean', 'description': 'mark_done 是否完成（默认 true）'},
        'step': {
          'type': 'object',
          'description': '新步骤（add_step 用）：{title, detail?, verify?}',
          'properties': {
            'title': {'type': 'string'},
            'detail': {'type': 'string'},
            'verify': {'type': 'string'},
          },
        },
      },
      'required': ['task_id', 'action'],
    },
    timeout: const Duration(seconds: 10),
    execute: (args) async {
      final taskId = (args['task_id'] as String?)?.trim() ?? '';
      final action = (args['action'] as String?)?.trim() ?? '';
      if (taskId.isEmpty) return ToolResult.error('缺少 task_id 参数');
      final s = store ?? DevStore();
      final task = await _findTask(s, taskId);
      if (task == null) return ToolResult.error('任务不存在：$taskId');
      final plan = task.plan;
      if (plan == null) return ToolResult.error('任务还没有计划，先调用 plan_create');

      switch (action) {
        case 'mark_done':
          final stepId = (args['step_id'] as String?)?.trim() ?? '';
          if (stepId.isEmpty) return ToolResult.error('缺少 step_id 参数');
          final done = (args['done'] as bool?) ?? true;
          final idx = plan.steps.indexWhere((s) => s.id == stepId);
          if (idx < 0) return ToolResult.error('步骤不存在：$stepId');
          final steps = [
            for (var i = 0; i < plan.steps.length; i++)
              i == idx ? plan.steps[i].copyWith(done: done) : plan.steps[i],
          ];
          final updatedPlan = DevPlan(steps: steps, currentStep: plan.nextPendingIndex);
          final status = updatedPlan.allDone
              ? DevTaskStatus.verifying
              : task.status == DevTaskStatus.planning
                  ? DevTaskStatus.implementing
                  : task.status;
          final updated = task.copyWith(
            plan: updatedPlan,
            status: status,
            updatedAt: DateTime.now(),
          );
          await s.saveTask(updated);
          if (done) {
            final next = updatedPlan.steps
                .where((s) => !s.done)
                .firstOrNull;
            return ToolResult(
              content: updatedPlan.allDone
                  ? '全部 ${steps.length} 步已完成，进入验证阶段'
                  : '已完成：${plan.steps[idx].title}。'
                      '下一步：${next?.title ?? ''}'
                      '${next?.verify != null ? '（完成标准：${next!.verify}）' : ''}',
            );
          }
          return ToolResult(content: '已取消完成：${plan.steps[idx].title}');
        case 'add_step':
          final rawStep = args['step'] as Map<String, dynamic>?;
          final title = (rawStep?['title'] as String?)?.trim() ?? '';
          if (title.isEmpty) return ToolResult.error('add_step 需要 step.title');
          final newStep = DevPlanStep(
            id: 's${plan.steps.length + 1}',
            title: title,
            detail: (rawStep?['detail'] as String?)?.trim() ?? '',
            verify: (rawStep?['verify'] as String?)?.trim(),
          );
          final updated = task.copyWith(
            plan: plan.copyWith(steps: [...plan.steps, newStep]),
            updatedAt: DateTime.now(),
          );
          await s.saveTask(updated);
          return ToolResult(content: '已追加步骤：$title（现在共 ${updated.plan!.steps.length} 步）');
        default:
          return ToolResult.error('未知 action：$action（支持 mark_done / add_step）');
      }
    },
  );
}

/// 列出任务计划。
ToolDefinition createPlanListTool({DevStore? store}) {
  return ToolDefinition(
    name: 'plan_list',
    description:
        '查看开发任务的执行计划：步骤列表、完成状态、当前进行步骤与完成标准。',
    parameters: {
      'type': 'object',
      'properties': {
        'task_id': {'type': 'string', 'description': '开发任务 id'},
      },
      'required': ['task_id'],
    },
    timeout: const Duration(seconds: 10),
    execute: (args) async {
      final taskId = (args['task_id'] as String?)?.trim() ?? '';
      if (taskId.isEmpty) return ToolResult.error('缺少 task_id 参数');
      final s = store ?? DevStore();
      final task = await _findTask(s, taskId);
      if (task == null) return ToolResult.error('任务不存在：$taskId');
      final plan = task.plan;
      if (plan == null) return ToolResult.error('任务还没有计划，先调用 plan_create');
      final lines = <String>[];
      for (var i = 0; i < plan.steps.length; i++) {
        final s = plan.steps[i];
        lines.add('${s.done ? '✅' : (i == plan.nextPendingIndex ? '▶ ' : '  ')} '
            '${s.id} ${s.title}'
            '${s.verify != null ? ' [完成标准: ${s.verify}]' : ''}');
      }
      final summary = plan.allDone
          ? '全部完成'
          : '当前进行：${plan.steps[plan.nextPendingIndex].title}';
      return ToolResult(content: '$summary\n${lines.join('\n')}');
    },
  );
}
