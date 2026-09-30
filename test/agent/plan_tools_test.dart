import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:tongyi_lite/agent/dev/task.dart';
import 'package:tongyi_lite/agent/dev/tools/plan_tools.dart';
import 'package:tongyi_lite/agent/dev/workspace_store.dart';

void main() {
  late Directory tmp;
  late DevStore store;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('plan_tools_test');
    store = DevStore(baseDirOverride: tmp.path);
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// 预置一个任务。
  Future<void> seedTask() async {
    await store.saveTask(DevTask(
      id: 't1',
      title: '实现 SSH 工具',
      workspaceId: 'ws_1',
      status: DevTaskStatus.planning,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    ));
  }

  group('plan_create', () {
    test('创建计划：3 步 + 验证标准，任务进入 implementing', () async {
      await seedTask();
      final tool = createPlanCreateTool(store: store);
      final result = await tool.execute({
        'task_id': 't1',
        'steps': [
          {'title': '步骤一', 'detail': '写代码', 'verify': '编译通过'},
          {'title': '步骤二', 'verify': '测试通过'},
          {'title': '步骤三'},
        ],
      });
      expect(result.isError, isFalse);
      expect(result.content, contains('计划已建立（3 步）'));
      expect(result.content, contains('步骤一'));
      expect(result.content, contains('完成标准：编译通过'));
      final task = (await store.loadTasks()).first;
      expect(task.status, DevTaskStatus.implementing);
      expect(task.plan!.steps.length, 3);
    });

    test('非法步骤丢弃；全空报错', () async {
      await seedTask();
      final tool = createPlanCreateTool(store: store);
      final result = await tool.execute({
        'task_id': 't1',
        'steps': [
          {'title': ''},
          {'no_title': true},
        ],
      });
      expect(result.isError, isTrue);
      expect(result.content, contains('steps 为空'));
    });

    test('任务不存在报错', () async {
      final tool = createPlanCreateTool(store: store);
      final result = await tool.execute({
        'task_id': 'nope',
        'steps': [
          {'title': 'x'},
        ],
      });
      expect(result.isError, isTrue);
      expect(result.content, contains('任务不存在'));
    });
  });

  group('plan_update mark_done', () {
    test('标记完成自动推进下一步', () async {
      await seedTask();
      await createPlanCreateTool(store: store).execute({
        'task_id': 't1',
        'steps': [
          {'title': 'A'},
          {'title': 'B'},
        ],
      });
      final tool = createPlanUpdateTool(store: store);
      final result = await tool.execute({
        'task_id': 't1',
        'action': 'mark_done',
        'step_id': 's1',
      });
      expect(result.isError, isFalse);
      expect(result.content, contains('已完成：A'));
      expect(result.content, contains('下一步：B'));
      final task = (await store.loadTasks()).first;
      expect(task.plan!.steps[0].done, isTrue);
      expect(task.plan!.nextPendingIndex, 1);
    });

    test('全部完成 → 进入 verifying', () async {
      await seedTask();
      await createPlanCreateTool(store: store).execute({
        'task_id': 't1',
        'steps': [
          {'title': 'A'},
          {'title': 'B'},
        ],
      });
      final tool = createPlanUpdateTool(store: store);
      await tool.execute({
        'task_id': 't1',
        'action': 'mark_done',
        'step_id': 's1',
      });
      final result = await tool.execute({
        'task_id': 't1',
        'action': 'mark_done',
        'step_id': 's2',
      });
      expect(result.content, contains('全部 2 步已完成'));
      final task = (await store.loadTasks()).first;
      expect(task.status, DevTaskStatus.verifying);
      expect(task.plan!.allDone, isTrue);
    });

    test('取消完成（done=false）', () async {
      await seedTask();
      await createPlanCreateTool(store: store).execute({
        'task_id': 't1',
        'steps': [
          {'title': 'A'},
        ],
      });
      final tool = createPlanUpdateTool(store: store);
      await tool.execute({
        'task_id': 't1',
        'action': 'mark_done',
        'step_id': 's1',
      });
      final result = await tool.execute({
        'task_id': 't1',
        'action': 'mark_done',
        'step_id': 's1',
        'done': false,
      });
      expect(result.content, contains('已取消完成'));
      final task = (await store.loadTasks()).first;
      expect(task.plan!.steps[0].done, isFalse);
    });
  });

  group('plan_update add_step', () {
    test('追加步骤', () async {
      await seedTask();
      await createPlanCreateTool(store: store).execute({
        'task_id': 't1',
        'steps': [
          {'title': 'A'},
        ],
      });
      final tool = createPlanUpdateTool(store: store);
      final result = await tool.execute({
        'task_id': 't1',
        'action': 'add_step',
        'step': {'title': '新步骤', 'verify': '冒烟通过'},
      });
      expect(result.isError, isFalse);
      expect(result.content, contains('现在共 2 步'));
      final task = (await store.loadTasks()).first;
      expect(task.plan!.steps.last.id, 's2');
      expect(task.plan!.steps.last.verify, '冒烟通过');
    });
  });

  group('plan_list', () {
    test('列出步骤与状态', () async {
      await seedTask();
      await createPlanCreateTool(store: store).execute({
        'task_id': 't1',
        'steps': [
          {'title': 'A', 'verify': '编译'},
          {'title': 'B'},
        ],
      });
      await createPlanUpdateTool(store: store).execute({
        'task_id': 't1',
        'action': 'mark_done',
        'step_id': 's1',
      });
      final result = await createPlanListTool(store: store).execute({
        'task_id': 't1',
      });
      expect(result.content, contains('当前进行：B'));
      expect(result.content, contains('✅ s1 A'));
      expect(result.content, contains('▶  s2 B')); // 前缀与 id 前各一空格
    });
  });

  group('DevPlan 模型', () {
    test('fromJson 过滤非法步骤', () {
      final plan = DevPlan.fromJson({
        'steps': [
          {'id': 's1', 'title': 'ok', 'done': true},
          'not-a-map',
          {'no_title': true},
          {'id': 's2', 'title': 'ok2'},
        ],
        'currentStep': 0,
      });
      expect(plan!.steps.length, 2);
      expect(plan!.steps[0].done, isTrue);
    });
  });
}
