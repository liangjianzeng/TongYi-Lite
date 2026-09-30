/// 开发会话控制器（Dev Agent）—— 全局激活状态（工作区/任务），UI 与
/// 接入层共享，ChangeNotifier 驱动界面刷新。
///
/// 工具层不依赖本类：文件/ssh 工具只消费执行参数里的 `_workspaceId`
/// （由 ToolExecutor 的 workspaceResolver 注入），路径解析纯函数可测。
library;

import 'package:flutter/foundation.dart' show ChangeNotifier, debugPrint;

import 'workspace.dart';
import 'workspace_store.dart';

final class DevSessionController extends ChangeNotifier {
  DevSessionController._();

  /// 全局单例（接入层注入点：chat_provider / settings_screen）。
  static final DevSessionController instance = DevSessionController._();

  final DevStore _store = DevStore();

  List<DevWorkspace> _workspaces = [DevWorkspace.defaultWorkspace];
  String _activeWorkspaceId = DevWorkspace.kDefaultId;
  String? _activeTaskId;
  bool _loaded = false;

  /// 是否已完成初始化加载。
  bool get loaded => _loaded;

  List<DevWorkspace> get workspaces => List.unmodifiable(_workspaces);

  String get activeWorkspaceId => _activeWorkspaceId;

  /// 激活工作区（未知 id 时回落默认）。
  DevWorkspace get activeWorkspace =>
      _workspaces.firstWhere((w) => w.id == _activeWorkspaceId,
          orElse: () => DevWorkspace.defaultWorkspace);

  /// 激活任务 id（Phase C；null = 无任务上下文）。
  String? get activeTaskId => _activeTaskId;

  /// 启动加载持久化工作区（幂等）。
  Future<void> init() async {
    if (_loaded) return;
    try {
      final saved = await _store.loadWorkspaces();
      _workspaces = [DevWorkspace.defaultWorkspace, ...saved];
      // 激活 id 悬空（被删除）时回落默认。
      if (!_workspaces.any((w) => w.id == _activeWorkspaceId)) {
        _activeWorkspaceId = DevWorkspace.kDefaultId;
      }
      _loaded = true;
      notifyListeners();
    } catch (e) {
      debugPrint('[Dev] init failed: $e');
      _loaded = true;
    }
  }

  /// 切换激活工作区；不存在则忽略。
  Future<void> switchWorkspace(String id) async {
    await init();
    if (!_workspaces.any((w) => w.id == id)) return;
    _activeWorkspaceId = id;
    notifyListeners();
  }

  /// 新增/更新工作区并持久化。
  Future<void> upsertWorkspace(DevWorkspace ws) async {
    await init();
    if (ws.isDefault) return;
    final idx = _workspaces.indexWhere((w) => w.id == ws.id);
    if (idx >= 0) {
      _workspaces[idx] = ws;
    } else {
      _workspaces.add(ws);
    }
    try {
      await _store.saveWorkspace(ws);
    } catch (e) {
      debugPrint('[Dev] save workspace failed: $e');
    }
    notifyListeners();
  }

  /// 删除工作区；删除激活的 → 回落默认。
  Future<void> deleteWorkspace(String id) async {
    await init();
    if (id == DevWorkspace.kDefaultId) return;
    _workspaces.removeWhere((w) => w.id == id);
    if (_activeWorkspaceId == id) {
      _activeWorkspaceId = DevWorkspace.kDefaultId;
    }
    try {
      await _store.deleteWorkspace(id);
    } catch (e) {
      debugPrint('[Dev] delete workspace failed: $e');
    }
    notifyListeners();
  }

  Future<void> setActiveTask(String? taskId) async {
    _activeTaskId = taskId;
    notifyListeners();
  }

  /// 供接入层（chat_provider）注入 ToolExecutor.workspaceResolver：
  /// 返回当前激活 workspaceId（开发模式关闭时由接入层返回 null → 零回归）。
  Future<String?> resolveActiveWorkspaceId() async {
    await init();
    return _activeWorkspaceId;
  }
}
