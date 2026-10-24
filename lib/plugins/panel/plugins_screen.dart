/// 插件治理面板（P6）。
///
/// 放在 `lib/plugins/panel/` 而不是 `lib/screens/`：面板是**平台自带的功能**，
/// 宿主只负责在设置页放一个入口。这样"平台能自己解释自己"这件事属于平台，
/// 将来换一套 UI 也不影响内核（架构门 B/C 也允许这一侧 import flutter + 内核）。
///
/// 面板的四条设计立场：
/// 1. **状态诚实**：`待功能 / 被拒 / 失败 / 未启用` 各有各的样子与出路，绝不统一显示成"可用"；
/// 2. **一屏能自解释**：详情里有 fiber 状态、effect 树、占用的槽、最近日志、失败原文；
/// 3. **作者视角**：显示 `plugin.json` 原文与声明的能力/权限，用户改参数不用改文件；
/// 4. **平台自己吃自己的狗粮**：详情页的操作按钮走 `app.plugins.detail.action` 契约槽。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:plugin_kernel/plugin_kernel.dart';

import '../host/host_profiles.dart';
import '../plugin_host.dart';

/// 面板入口（设置页跳转用）。
class PluginsScreen extends ConsumerStatefulWidget {
  const PluginsScreen({super.key, this.pluginsDirHint, this.embedded = false});

  /// true = 无 Scaffold/AppBar 的内嵌形态（供左栏「插件」面板直陈承载）。
  final bool embedded;

  /// 用户插件该放哪儿（宿主给的话术，内核不知道路径规则）。
  final String? pluginsDirHint;

  @override
  ConsumerState<PluginsScreen> createState() => _PluginsScreenState();
}

class _PluginsScreenState extends ConsumerState<PluginsScreen> {
  bool _busy = false;

  Future<void> _switchProfile(String? name) async {
    final service = ref.read(pluginHostProvider).valueOrNull;
    final profiles = ref.read(hostProfilesProvider).valueOrNull;
    if (service == null || profiles == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('方案档现在用不了：插件平台还没就绪'),
              duration: Duration(seconds: 2)),
        );
      }
      return;
    }
    setState(() => _busy = true);
    String message;
    try {
      final r = await profiles.switchTo(service, name,
          sink: SettingsProfileSink.fromWidgetRef(ref));
      final notes = r.notes.isEmpty ? '' : '；${r.notes.first}';
      final kv = r.resetKv ? '；下一轮会重新理解上下文' : '';
      message = name == null
          ? '已不用方案档，回到逐个开关$notes'
          : '已切到「$name」：开着 ${r.enabled.length} 个插件$notes$kv';
    } catch (e) {
      message = '换档没成功：$e';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(message), duration: const Duration(seconds: 3)));
      setState(() {});
    }
  }

  /// 「新建方案档」：先问清楚，再落盘，**建完不切过去**。
  ///
  /// 为什么不顺手切过去：用户点的是"建一个"，不是"换成这个"。
  /// 偷偷换档 = 插件集、人格、模型一起变，而用户以为只是存了个草稿。
  Future<void> _createProfile() async {
    final service = ref.read(pluginHostProvider).valueOrNull;
    final profiles = ref.read(hostProfilesProvider).valueOrNull;
    if (service == null || profiles == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('方案档现在用不了：插件平台还没就绪'),
              duration: Duration(seconds: 2)),
        );
      }
      return;
    }
    final draft = await showDialog<_ProfileDraft>(
      context: context,
      builder: (_) => _NewProfileDialog(
        service: service,
        // 预勾 = 现在真正开着的那些（读 previewProfile：与 runtime 同一个 compose，不会两边不一）。
        initial: service.previewProfile(profiles.active).enabled,
      ),
    );
    if (draft == null || !mounted) return;

    setState(() => _busy = true);
    String message;
    try {
      final r =
          await profiles.create(draft.name, draft.enabled, note: draft.note);
      message = switch (r) {
        Ok<void>() =>
          '建好了「${draft.name.trim()}」：里面开着 ${draft.enabled.length} 个插件（还没切过去，点它的卡片才生效）',
        Err(:final failure) =>
          '${failure.message}${failure.hint == null ? '' : '：${failure.hint}'}',
      };
    } catch (e) {
      // 面板不许因为宿主 IO 异常而红屏。
      message = '建方案档没成功：$e';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(message), duration: const Duration(seconds: 3)));
      setState(() {});
    }
  }

  /// 删掉一个方案档。这是**不可撤销的文件删除**，所以确认框里三句话必须说清：
  ///
  /// ① 删的只是那份档文件，**插件本身和它们各自存的参数一概不动**（用户最怕"档没了插件也没了"）；
  /// ② 它要是当前在用的档，删完会回到"不用档（逐个开关）" —— 插件开关恢复成自己一个个设的样子；
  /// ③ **读不动的坏档也能从这儿删**：手机上没有文件管理器时，这是坏档唯一的出路。
  Future<void> _deleteProfile(String name) async {
    final service = ref.read(pluginHostProvider).valueOrNull;
    final profiles = ref.read(hostProfilesProvider).valueOrNull;
    if (service == null || profiles == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('方案档现在用不了：插件平台还没就绪'),
              duration: Duration(seconds: 2)),
        );
      }
      return;
    }
    final wasActive = profiles.active == name;
    final broken = profiles.store().brokenProfiles().any((e) => e.name == name);
    final count = service.previewProfile(name).enabled.length;

    final go = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('删掉方案档「$name」？'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (broken)
              const Text('这个档现在读不动（文件内容有问题）。删掉它是让它从列表里消失的办法。')
            else
              Text('这个档开着 $count 个插件${wasActive ? '，而且正在用它' : '，现在没在用'}。'),
            const SizedBox(height: 6),
            if (wasActive) const Text('删完会回到「不用档（逐个开关）」：插件开关恢复成你自己一个个设的样子。'),
            Text('删的是 ${profiles.dirPath}/$name.json。'
                '插件本身、以及它们各自存的参数都不动 —— 想再用就重新建一个同名档。'),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消')),
          FilledButton(
            key: const Key('profile-delete-confirm'),
            style: FilledButton.styleFrom(
                backgroundColor:
                    Theme.of(dialogContext).colorScheme.errorContainer),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删掉'),
          ),
        ],
      ),
    );
    if (go != true || !mounted) return;

    setState(() => _busy = true);
    String message;
    try {
      final deleted = await profiles.delete(name);
      if (!deleted) {
        // 文件早就不在了（比如用户在文件管理器里删过）：不撒谎说"删掉了"，也不报错吓人的。
        message = '那份档文件本来就不存在，列表已经刷新';
      } else {
        message = wasActive ? '删掉了「$name」，已回到「不用档（逐个开关）」' : '删掉了「$name」';
      }
      await service.reload();
    } catch (e) {
      message = '删方案档没成功：$e';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(message), duration: const Duration(seconds: 3)));
      setState(() {});
    }
  }

  Future<void> _run(Future<Object?> Function(PluginService service) action,
      {String? okMessage}) async {
    final service = ref.read(pluginHostProvider).valueOrNull;
    if (service == null) {
      // 别静默吞掉：面板上的按钮点了没反应，比报错更难查。
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('插件平台还没就绪，稍后再试'), duration: Duration(seconds: 2)),
        );
      }
      return;
    }
    setState(() => _busy = true);
    String? message;
    try {
      final r = await action(service);
      message = _messageOf(r) ?? okMessage;
    } catch (e) {
      // 面板自身不许因为插件的异常而红屏。
      message = '操作没成功：$e';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (message != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(message), duration: const Duration(seconds: 3)));
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(pluginHostProvider);
    final service = async.valueOrNull;

    final refreshButton = IconButton(
      tooltip: '重新扫描插件目录',
      icon: _busy
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2))
          : const Icon(Icons.refresh),
      onPressed: service == null || _busy
          ? null
          : () => _run((s) => s.reload(), okMessage: '已重新扫描'),
    );
    final body = service == null
        ? Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                async.isLoading ? '正在装载插件平台…' : '插件平台没能启动，聊天不受影响。',
                textAlign: TextAlign.center,
              ),
            ),
          )
        : _PluginList(
            service: service,
            busy: _busy,
            profiles: ref.watch(hostProfilesProvider).valueOrNull,
            onSwitchProfile: _switchProfile,
            onCreateProfile: _createProfile,
            onDeleteProfile: _deleteProfile,
            pluginsDirHint: widget.pluginsDirHint,
            onToggle: (id, on) => _run((s) => s.setEnabled(id, on)),
            onRetry: (id) => _run((s) => s.retry(id), okMessage: '已重试'),
            onSaveParams: (id, patch) => _run(
                (s) => s.setConfig(id: id, patch: patch),
                okMessage: '已保存设置'),
            onResetParams: (id) => _run((s) => s.resetConfig(id: id),
                okMessage: '已恢复默认（清掉你的改动与本次临时试的值）'),
            onTrialParams: (id, patch) => _run(
                (s) => s.trialConfig(id: id, patch: patch),
                okMessage: '只在这次会话生效（不落盘；重启就回到原值）'),
          );
    if (widget.embedded) {
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
            child:
                Align(alignment: Alignment.centerRight, child: refreshButton),
          ),
          Expanded(child: body),
        ],
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('插件'), actions: [refreshButton]),
      body: body,
    );
  }
}

/// 把各种返回值折算成给用户看的一句话（面板只说人话）。
String? _messageOf(Object? r) {
  if (r is Outcome<PluginChangeResult>) {
    final v = r.valueOrNull;
    if (r.isErr) return r.failureOrNull!.message;
    if (v == null) return null;
    // **"成功返回"不等于做成了**：`setConfig` / `retry` 把 apply 失败、冲突这类结果
    // 也包成 `Ok(PluginChangeResult)`（面板一个分支就能画完）。以前这里只看 Ok/Err，
    // 于是对着一个根本没生效的操作回一句「已更新」—— 受理了但没干活，还被报成成功。
    if (v.application == PluginApplication.failed) {
      final f = v.failure;
      if (f == null) return '这个操作没做成';
      return '${f.message}${f.hint == null ? '' : ' —— ${f.hint}'}';
    }
    final warns = v.warnings;
    final head = v.changed ? '已更新' : '没有变化';
    // 要重启才生效的也不能含糊成"已更新"：用户会以为现在就能用。
    final tail = v.application == PluginApplication.restartRequired
        ? '（还没生效：${v.restartReason ?? '要重启/重新启用'}）'
        : '';
    return '$head${warns.isEmpty ? '' : '（${warns.length} 条提醒：${warns.first}）'}$tail';
  }
  return null;
}

class _PluginList extends StatelessWidget {
  _PluginList({
    required this.service,
    required this.busy,
    required this.onToggle,
    required this.onRetry,
    required this.onSaveParams,
    required this.onResetParams,
    required this.onTrialParams,
    this.profiles,
    this.onSwitchProfile,
    this.onCreateProfile,
    this.onDeleteProfile,
    this.pluginsDirHint,
  });

  final PluginService service;
  final bool busy;
  final HostProfiles? profiles;
  final void Function(String? name)? onSwitchProfile;
  final Future<void> Function()? onCreateProfile;
  final Future<void> Function(String name)? onDeleteProfile;
  final void Function(String id, bool on) onToggle;
  final void Function(String id) onRetry;
  final void Function(String id, Map<String, Object?> patch) onSaveParams;

  /// 「恢复默认」：清掉的只是**用户层**，方案档与插件声明的默认值都留着（判据在内核 `resetConfig`）。
  final void Function(String id) onResetParams;

  /// 「先试试这组值」：只写进**会话层**（不落盘，重启就没）。判据与保存同一条 —— 试试也会真的念给用户听。
  final void Function(String id, Map<String, Object?> patch) onTrialParams;
  final String? pluginsDirHint;

  @override
  Widget build(BuildContext context) {
    final views = service.view();
    final on = views.where((v) => v.running).length;
    final gated =
        views.where((v) => v.loaded.status == PluginLoadStatus.gated).length;
    final rejected =
        views.where((v) => v.loaded.status == PluginLoadStatus.rejected).length;

    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      children: [
        Text('已启用 $on/${views.length}',
            style: Theme.of(context).textTheme.titleMedium),
        if (views.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Text('还没有插件。内置的「你好示例 / 英语听写」在开关里打开就有图标了。'),
          )
        else if (gated + rejected > 0)
          Padding(
            padding: const EdgeInsets.only(top: 2, bottom: 8),
            child: Text(
              [
                if (gated > 0) '$gated 个在等功能',
                if (rejected > 0) '$rejected 个声明有问题',
              ].join('，'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        if (profiles case final hp?)
          _ProfileSection(
            service: service,
            profiles: hp,
            busy: busy,
            onCreate: onCreateProfile,
            onDelete: onDeleteProfile,
            onSwitch: onSwitchProfile ?? (_) {},
          ),
        _CapabilitySection(service: service, busy: busy),
        if (pluginsDirHint != null)
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 12),
            child: Text('第三方插件放：$pluginsDirHint（每个目录一个 plugin.json）',
                style: Theme.of(context).textTheme.bodySmall),
          ),
        for (final group in _groupBySource(views)) ...[
          Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 4),
            child:
                Text(group.$1, style: Theme.of(context).textTheme.labelLarge),
          ),
          for (final v in group.$2)
            _PluginTile(
              service: service,
              view: v,
              busy: busy,
              onToggle: onToggle,
              onRetry: onRetry,
              onSaveParams: onSaveParams,
              onResetParams: onResetParams,
              onTrialParams: onTrialParams,
            ),
        ],
      ],
    );
  }

  List<(String, List<PluginView>)> _groupBySource(List<PluginView> views) {
    final builtin = views
        .where((v) => v.loaded.descriptor.source == PluginSource.builtin)
        .toList();
    final user = views
        .where((v) => v.loaded.descriptor.source != PluginSource.builtin)
        .toList();
    return [
      if (builtin.isNotEmpty) ('内置', builtin),
      if (user.isNotEmpty) ('你装的', user),
    ];
  }
}

class _PluginTile extends StatelessWidget {
  const _PluginTile({
    required this.service,
    required this.view,
    required this.busy,
    required this.onToggle,
    required this.onRetry,
    required this.onSaveParams,
    required this.onResetParams,
    required this.onTrialParams,
  });

  final PluginService service;
  final PluginView view;
  final bool busy;
  final void Function(String id, bool on) onToggle;
  final void Function(String id) onRetry;
  final void Function(String id, Map<String, Object?> patch) onSaveParams;

  /// 「恢复默认」：清掉的只是**用户层**，方案档与插件声明的默认值都留着（判据在内核 `resetConfig`）。
  final void Function(String id) onResetParams;

  /// 「先试试这组值」：只写进**会话层**（不落盘，重启就没）。判据与保存同一条 —— 试试也会真的念给用户听。
  final void Function(String id, Map<String, Object?> patch) onTrialParams;

  @override
  Widget build(BuildContext context) {
    final m = view.manifest;
    final status = _StatusBadge(view: view);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        leading: const Icon(Icons.extension_outlined),
        title: Text(m.name),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(m.description, maxLines: 2, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 4),
            Wrap(spacing: 6, runSpacing: 4, children: [
              status,
              if (view.slotCount > 0)
                _chip(context, '${view.slotCount} 处界面',
                    Icons.dashboard_customize_outlined, null),
              if (view.loaded.gatedHint != null)
                _chip(context, view.loaded.gatedHint!, Icons.help_outline,
                    Colors.amber.shade700)
              else if (view.loaded.gatedOn.isNotEmpty)
                _chip(context, '缺：${view.loaded.gatedOn.join('、')}',
                    Icons.help_outline, Colors.amber.shade700),
              if (_softWarnings(view.loaded).isNotEmpty &&
                  view.loaded.gatedHint == null)
                // **弃用黄条**：还能跑，但作者该改（对齐 §7"警告不许静默"）。
                // 已经用 gatedHint 说过的不重复刷，否则一条 env 提醒变成两个黄条。
                _chip(context, '声明提醒 ${_softWarnings(view.loaded).length} 条',
                    Icons.warning_amber_rounded, Colors.orange.shade800),
              if (view.lastFailure != null)
                _chip(context, view.lastFailure!.message, Icons.error_outline,
                    Colors.red.shade700),
            ]),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (view.state == FiberState.failed ||
                view.state == FiberState.disposed)
              IconButton(
                tooltip: '重试',
                icon: const Icon(Icons.replay),
                onPressed: busy ? null : () => onRetry(view.id),
              ),
            IconButton(
              tooltip: '体检详情',
              icon: const Icon(Icons.monitor_heart_outlined),
              onPressed: () => _openDetail(context),
            ),
            Switch(
              value: service.isEnabled(view.id),
              onChanged: busy ? null : (on) => onToggle(view.id, on),
            ),
          ],
        ),
        onTap: () => _openDetail(context),
      ),
    );
  }

  void _openDetail(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _PluginDetailSheet(
        service: service,
        view: view,
        onSaveParams: onSaveParams,
        onResetParams: onResetParams,
        onTrialParams: onTrialParams,
      ),
    );
  }
}

Widget _chip(BuildContext context, String text, IconData icon, Color? color) {
  final fg = color ?? Theme.of(context).colorScheme.onSurfaceVariant;
  return Chip(
    label: Text(text, style: TextStyle(fontSize: 11, color: fg)),
    avatar: Icon(icon, size: 14, color: fg),
    visualDensity: VisualDensity.compact,
    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    padding: EdgeInsets.zero,
  );
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.view});
  final PluginView view;

  @override
  Widget build(BuildContext context) {
    final (text, color) = switch (view.loaded.status) {
      PluginLoadStatus.active => view.running
          ? ('可运行', Colors.green.shade700)
          : ('启动中（${view.state?.name ?? 'idle'}）', Colors.blueGrey),
      PluginLoadStatus.gated => ('待功能', Colors.amber.shade700),
      PluginLoadStatus.rejected => ('声明有问题', Colors.red.shade700),
      PluginLoadStatus.disabled => ('未启用', Colors.grey),
    };
    return _chip(context, text, Icons.bolt_outlined, color);
  }
}

/// 体检详情：状态 / 声明 / 参数 / effect 树 / 占用的槽 / 最近日志 / 原文。
class _PluginDetailSheet extends ConsumerStatefulWidget {
  const _PluginDetailSheet({
    required this.service,
    required this.view,
    required this.onSaveParams,
    required this.onResetParams,
    required this.onTrialParams,
  });

  final PluginService service;
  final PluginView view;
  final void Function(String id, Map<String, Object?> patch) onSaveParams;

  /// 「恢复默认」：清掉的只是**用户层**，方案档与插件声明的默认值都留着（判据在内核 `resetConfig`）。
  final void Function(String id) onResetParams;

  /// 「先试试这组值」：只写进**会话层**（不落盘，重启就没）。判据与保存同一条 —— 试试也会真的念给用户听。
  final void Function(String id, Map<String, Object?> patch) onTrialParams;

  @override
  ConsumerState<_PluginDetailSheet> createState() => _PluginDetailSheetState();
}

class _PluginDetailSheetState extends ConsumerState<_PluginDetailSheet> {
  late final Map<String, TextEditingController> _editors = {
    for (final p in widget.view.manifest.params.where((p) => !p.volatile))
      p.name: TextEditingController(text: _initialOf(p)),
  };

  String _initialOf(PluginParam p) {
    final v =
        widget.service.configStore.stackFor(widget.view.manifest).value(p.name);
    if (v == null) return p.defaultValue?.toString() ?? '';
    return '$v';
  }

  /// 这个值**从哪一层来** —— 面板必须说出来：四层配置（默认 / 方案档 / 用户 / 本次会话）里，
  /// "我改的到底生效没、是不是被方案档盖住了"是最常见也最难自查的问题。
  /// 平台早就有 `ConfigStack.layerOf`，以前只是没人调用 —— 有 API 没界面等于没有。
  String _layerTag(String name) => switch (widget.service.configStore
          .stackFor(widget.view.manifest)
          .layerOf(name)) {
        ConfigLayer.user => '你的改动',
        ConfigLayer.profile => '方案档给的',
        ConfigLayer.session => '本次会话临时',
        ConfigLayer.defaults => '插件默认',
      };

  @override
  void dispose() {
    for (final c in _editors.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.view;
    final m = v.manifest;
    final d = widget.service.diagnostics(v.id);
    final logs = (d['logs'] as List? ?? const []).cast<Map<String, Object?>>();
    final effects =
        (d['effectTree'] as List? ?? const []).cast<Map<String, Object?>>();
    final slots =
        (d['slots'] as List? ?? const []).cast<Map<String, Object?>>();
    final disposeFailures = d['disposeFailures'];
    final logFailures =
        (d['logFailures'] as List? ?? const []).cast<Map<String, Object?>>();
    final runLog =
        (d['runLog'] as List? ?? const []).cast<Map<String, Object?>>();

    return SafeArea(
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.85,
        builder: (context, controller) => ListView(
          controller: controller,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                    color: Colors.grey.shade400,
                    borderRadius: BorderRadius.circular(2)),
              ),
            ),
            Text(m.name, style: Theme.of(context).textTheme.titleLarge),
            Text('${m.id} · ${m.trust.name} · ${v.loaded.descriptor.location}',
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
            _section(context, '为什么跑不起来', [
              Text(_whyNotRunning(v),
                  style: Theme.of(context).textTheme.bodyMedium),
              if (v.lastFailure != null) ...[
                const SizedBox(height: 6),
                Text('上次的错：${v.lastFailure!.message}',
                    style: TextStyle(color: Colors.red.shade700)),
                if (v.lastFailure!.hint != null)
                  Text('怎么办：${v.lastFailure!.hint}',
                      style: Theme.of(context).textTheme.bodySmall),
              ],
            ]),
            if (_softWarnings(v.loaded).isNotEmpty)
              _section(context, '声明提醒（还能跑，但作者该改）', [
                for (final i in _softWarnings(v.loaded))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      '${i.path}：${i.message}${i.hint == null ? '' : '（${i.hint}）'}',
                      style: TextStyle(
                          fontSize: 13, color: Colors.orange.shade900),
                    ),
                  ),
              ]),
            _section(context, '它要的能力与权限', [
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final c in m.inject) _chip(context, c, Icons.link, null),
                  for (final p in m.permissions)
                    _chip(context, p.wireName, Icons.shield_outlined, null),
                ],
              ),
            ]),
            if (_editors.isNotEmpty)
              _section(context, '设置', [
                for (final p in m.params.where((p) => !p.volatile))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: switch (p.type) {
                      PluginParamType.boolean => SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                          title: Text(p.label),
                          subtitle: Text(
                            [p.description, _layerTag(p.name)]
                                .where((e) => e != null)
                                .join(' · '),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          value: _editors[p.name]!.text == 'true',
                          onChanged: (on) =>
                              setState(() => _editors[p.name]!.text = '$on'),
                        ),
                      _ => TextField(
                          controller: _editors[p.name],
                          keyboardType: p.type == PluginParamType.number
                              ? TextInputType.number
                              : null,
                          decoration: InputDecoration(
                            isDense: true,
                            labelText: p.label,
                            helperText: [
                              p.description ??
                                  (p.min != null || p.max != null
                                      ? '${p.min ?? ''} ~ ${p.max ?? ''}'
                                      : null),
                              _layerTag(p.name),
                            ].where((e) => e != null).join(' · '),
                          ),
                        ),
                    },
                  ),
                Align(
                  alignment: Alignment.centerRight,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      // 四层配置里最容易改坏的就是用户层；没有"退回默认"，用户只能凭记忆一条条打回去
                      // —— 那是把改错的代价转嫁给用户。内核 `resetConfig` 只清用户层，档与声明默认都留着。
                      TextButton(
                        onPressed: () {
                          widget.onResetParams(v.id);
                          Navigator.of(context).pop();
                        },
                        child: const Text('恢复默认'),
                      ),
                      TextButton(
                        // 「先试试」＝写进会话层：想看看 8 秒间隔什么感觉，不必先改坏设置再记得改回来。
                        // 也让四层里那条 session 层真的有人能写 —— 面板上「本次会话临时」才是实话。
                        onPressed: () {
                          widget.onTrialParams(v.id, {
                            for (final e in _editors.entries)
                              e.key: _parseParam(e.key, e.value.text),
                          });
                          Navigator.of(context).pop();
                        },
                        child: const Text('先试试这组值'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: () {
                          widget.onSaveParams(v.id, {
                            for (final e in _editors.entries)
                              e.key: _parseParam(e.key, e.value.text),
                          });
                          Navigator.of(context).pop();
                        },
                        child: const Text('保存'),
                      ),
                    ],
                  ),
                ),
              ]),
            _section(context,
                '本次运行（${runLog.length} 条 · traceId ${d['traceId'] ?? '-'}）', [
              // 每次重载换一个新 traceId：这一节只含**当前这个实例**干过的事，
              // 下面的"最近日志"是历次混在一起的，别把旧实例的失败当成现在的问题。
              if (runLog.isEmpty)
                Text('这个实例还没留下日志（刚启用或刚重载过）。',
                    style: Theme.of(context).textTheme.bodySmall),
              for (final r in runLog.take(12))
                Text('${r['message']}',
                    style: Theme.of(context).textTheme.bodySmall),
            ]),
            _section(context, '它占了哪些位置（${slots.length}）', [
              if (slots.isEmpty)
                Text('没占界面，只在背后干活。',
                    style: Theme.of(context).textTheme.bodySmall),
              for (final s in slots)
                // 让位（出过错后主动退场）的条目**已经不在界面上了**：还说"它占了这个位置"就是骗人。
                Text(
                  '${s['slot']} ← ${s['id'] ?? s['label'] ?? ''}'
                  '${s['active'] == false ? '（已让位：这条出过错，现在界面里没它）' : ''}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
            ]),
            _section(context, '启动了的资源（${effects.length}）', [
              if (effects.isEmpty)
                Text('没有登记资源。', style: Theme.of(context).textTheme.bodySmall),
              for (final e in effects)
                Text(
                    '${e['kind'] ?? e['label'] ?? '资源'} ${e['released'] == true ? '（已释放）' : ''}',
                    style: Theme.of(context).textTheme.bodySmall),
              if (disposeFailures is List && disposeFailures.isNotEmpty)
                Text('释放时出过错：$disposeFailures',
                    style: TextStyle(color: Colors.orange.shade800)),
            ]),
            _section(context, '最近日志（${logs.length}）', [
              // 环形缓冲 + 只显最近 30 条 = 插件一刷屏，真正的失败就看不见 —— 最该看见的恰恰最先看不见。
              if (logFailures.isNotEmpty) ...[
                Text('出过错的 ${logFailures.length} 条（不看最近，也该看这些）：',
                    style: TextStyle(fontSize: 12, color: Colors.red.shade700)),
                for (final r in logFailures.reversed.take(10))
                  Text('[${r['level']}] ${r['message']}',
                      style:
                          TextStyle(fontSize: 12, color: Colors.red.shade800)),
                const SizedBox(height: 4),
              ],
              if (logs.isEmpty)
                Text('还没有日志。', style: Theme.of(context).textTheme.bodySmall),
              for (final r in logs.reversed.take(30))
                Text('[${r['level']}] ${r['message']}',
                    style: Theme.of(context).textTheme.bodySmall),
            ]),
            // 平台自己吃狗粮：详情里的附加操作走冻结的契约槽（作者可以往里放诊断按钮）。
            ..._authorActions(context),
            _section(context, '声明原文（审计用）', [
              SelectableText(
                v.loaded.descriptor.rawJson ?? '（内置插件没有 JSON 原文）',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(fontFamily: 'monospace'),
              ),
            ]),
          ],
        ),
      ),
    );
  }

  List<Widget> _authorActions(BuildContext context) {
    final entries = widget.service.slots.entries('app.plugins.detail.action',
        ownerData: {'pluginId': widget.view.id});
    if (entries.isEmpty) return const [];
    return [
      _section(context, '插件自带的诊断动作', [
        for (final e in entries)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(e.contribution.label),
            subtitle: Text('${e.pluginId} · priority ${e.priority}',
                style: Theme.of(context).textTheme.bodySmall),
            onTap: () {
              // 条目渲染/执行出错就让它让位（DSH 的 abdicate 语义），面板不许跟着崩。
              widget.service.slots.reportEntryError(
                  'app.plugins.detail.action', e.id,
                  pluginId: e.pluginId);
            },
          ),
      ]),
    ];
  }

  Object? _parseParam(String name, String text) {
    final p = widget.view.manifest.params.firstWhere((x) => x.name == name);
    switch (p.type) {
      case PluginParamType.number:
        return double.tryParse(text.trim());
      case PluginParamType.boolean:
        return text.trim() == 'true';
      case PluginParamType.choice:
      case PluginParamType.text:
        return text;
    }
  }

  static String _whyNotRunning(PluginView v) {
    switch (v.loaded.status) {
      case PluginLoadStatus.active:
        return v.running
            ? '运行中，资源都挂在 effect 树上。'
            : '还没启动完成（状态 ${v.state?.name ?? 'idle'}）。';
      case PluginLoadStatus.gated:
        if (v.loaded.gatedHint != null) return v.loaded.gatedHint!;
        return '缺能力：${v.loaded.gatedOn.join('、')}。等宿主把那项能力接上就能用；'
            '如果是相机/相册/网络这类系统权限，去系统设置里允许本应用。';
      case PluginLoadStatus.rejected:
        final first = v.loaded.descriptor.issues.firstWhere((i) => i.isError,
            orElse: () => const ValidationIssue(
                path: '?',
                code: ValidationIssueCode.badType,
                message: '声明有问题'));
        return '声明有问题：${first.path} — ${first.message}${first.hint == null ? '' : '（${first.hint}）'}';
      case PluginLoadStatus.disabled:
        return v.loaded.disabledReason ?? '被你关掉了，打开开关即可。';
    }
  }
}

Widget _section(BuildContext context, String title, List<Widget> body) {
  return Padding(
    padding: const EdgeInsets.only(top: 14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.labelLarge),
        const Divider(height: 12),
        ...body,
      ],
    ),
  );
}

/// 设置页用的入口行（宿主只 import 这一个符号，其余细节都留在平台内部）。
class PluginsEntryTile extends ConsumerWidget {
  const PluginsEntryTile({super.key, this.pluginsDirHint});
  final String? pluginsDirHint;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      leading: const Icon(Icons.extension_outlined),
      title: const Text('插件'),
      subtitle: Text(ref.watch(pluginSummaryProvider)),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => PluginsScreen(pluginsDirHint: pluginsDirHint),
      )),
    );
  }
}

/// 方案档区块（P6 的一键换场景）。
///
/// 预览读 `service.previewProfile(name)` —— 与 runtime **同一个 compose**：
/// 这里写"开着 N 个"，切完就一定开着那些，不存在另算一套的漂移。
class _ProfileSection extends StatelessWidget {
  const _ProfileSection({
    required this.service,
    required this.profiles,
    required this.busy,
    this.onCreate,
    this.onDelete,
    required this.onSwitch,
  });

  final PluginService service;
  final HostProfiles profiles;
  final bool busy;
  final Future<void> Function()? onCreate;
  final Future<void> Function(String name)? onDelete;
  final void Function(String? name) onSwitch;

  @override
  Widget build(BuildContext context) {
    final store = profiles.store();
    final names = store.names();
    final broken = store.brokenProfiles().map((e) => e.name).toSet();
    final active = profiles.active;
    final preview = service.previewProfile(active);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 4),
          child: Row(
            children: [
              Expanded(
                  child: Text('方案档',
                      style: Theme.of(context).textTheme.labelLarge)),
              Text(active == null ? '不用档（逐个开关）' : '当前：$active',
                  style: Theme.of(context).textTheme.bodySmall),
              if (onCreate != null)
                TextButton.icon(
                  onPressed: busy ? null : onCreate,
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('新建', style: TextStyle(fontSize: 12)),
                  style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 6)),
                ),
            ],
          ),
        ),
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            ChoiceChip(
              label: const Text('不用档'),
              selected: active == null,
              onSelected: busy ? null : (_) => onSwitch(null),
            ),
            for (final n in names)
              // `ChoiceChip` 没有 `onDeleted`/`deleteIcon`（那是 `Chip`/`FilterChip` 的参数）——
              // 所以删档的图标老实摆在标签右边，两个独立点击区：点标签=切档，点图标=删档。
              // 不用长按：手机上"藏起来的手势"等于没有手势，而误删已经被确认框挡住了。
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ChoiceChip(
                    label: Text(broken.contains(n)
                        ? '$n（读不动）'
                        : '$n · ${service.previewProfile(n).enabled.length} 件'),
                    avatar: Icon(
                        broken.contains(n)
                            ? Icons.error_outline
                            : Icons.style_outlined,
                        size: 16),
                    selected: active == n,
                    onSelected: busy ? null : (_) => onSwitch(n),
                  ),
                  if (onDelete != null)
                    IconButton(
                      key: Key('profile-delete-$n'),
                      icon: const Icon(Icons.delete_outline, size: 16),
                      visualDensity: VisualDensity.compact,
                      tooltip: '删掉方案档「$n」',
                      onPressed: busy ? null : () => onDelete!(n),
                    ),
                ],
              ),
            if (names.isEmpty)
              Text('还没有档文件：${profiles.dirPath}/<档名>.json',
                  style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
        if (active != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  preview.restrictedByProfile
                      ? '这个档只开 ${preview.enabled.length} 个插件：${preview.enabled.join('、')}'
                      : '这个档不挑插件，只统一参数${preview.config.isEmpty ? '（也没写参数）' : '：${preview.config.keys.join('、')}'}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                for (final w in preview.warnings)
                  Text('提醒：$w',
                      style: TextStyle(
                          fontSize: 12, color: Colors.orange.shade800)),
              ],
            ),
          ),
      ],
    );
  }
}

/// 警告级声明问题（弃用字段、app 版本太旧…）：**还能跑，但不该一直这样**。
///
/// 面板必须把它们显式说出来 —— 静默的警告等于没有警告，等它升级成 error 时作者已经找不着北了。
/// 写成顶层函数：列表与详情两处共用同一条过滤条件，免得两个 widget 各写一遍、慢慢漂移。
List<ValidationIssue> _softWarnings(LoadedPlugin loaded) =>
    loaded.descriptor.issues
        .where((i) => i.severity == IssueSeverity.warning)
        .toList();

/// 本机能力清单（含**被遮蔽的那份**）。
///
/// 为什么面板必须有这一页：插件"待功能"只说明它缺什么，不说明**本机到底有什么**。
/// 特别是可替换能力（`app.speak` 有离线与在线两份）——用户得看得见"现在在用哪份、
/// 另一份为什么没上"，否则离线朗读没生效就永远是一桩悬案。
/// 数据源只用 [CapabilityRegistry.list]，不在面板里另算一份可用性（同一真相原则）。
class _CapabilitySection extends StatefulWidget {
  const _CapabilitySection({required this.service, required this.busy});

  final PluginService service;
  final bool busy;

  @override
  State<_CapabilitySection> createState() => _CapabilitySectionState();
}

class _CapabilitySectionState extends State<_CapabilitySection> {
  bool _probing = false;

  Future<void> _probe(String id) async {
    setState(() => _probing = true);
    String msg;
    try {
      final r = await widget.service.capabilities.probe(id);
      msg =
          r.isOk ? '$id 试过了：能用' : '$id 试过了：${(r as Err<void>).failure.message}';
    } catch (e) {
      msg = '$id 试的时候出了意外：$e'; // 能力的 probe 可以带 IO，任何异常都不许把面板带崩
    } finally {
      if (mounted) setState(() => _probing = false);
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(msg), duration: const Duration(seconds: 3)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final entries = widget.service.capabilities.list();
    final ids = (entries.map((e) => e.key.id).toSet()).toList()..sort();

    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(bottom: 8),
      title: Text('本机能力（${ids.length}）',
          style: Theme.of(context).textTheme.labelLarge),
      subtitle: Text('插件能拿到什么，全看这张表；被遮蔽的实现也列出来',
          style: Theme.of(context).textTheme.bodySmall),
      children: [
        if (ids.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('一个能力都没注册上 —— 插件能跑，但什么都干不了。'),
          ),
        for (final id in ids)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(id,
                          style: const TextStyle(
                              fontFamily: 'monospace', fontSize: 13)),
                    ),
                    IconButton(
                      tooltip: '试一下',
                      visualDensity: VisualDensity.compact,
                      iconSize: 18,
                      onPressed: _probing ? null : () => _probe(id),
                      icon: const Icon(Icons.play_circle_outline),
                    ),
                  ],
                ),
                for (final e in widget.service.capabilities.list(id))
                  Padding(
                    padding: const EdgeInsets.only(left: 8, bottom: 2),
                    child: Row(
                      children: [
                        Icon(
                          e.impl.available
                              ? Icons.check_circle_outline
                              : Icons.radio_button_unchecked,
                          size: 15,
                          color: e.impl.available
                              ? Colors.green.shade700
                              : Colors.grey,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            '${e.ownerPluginId} · priority ${e.priority}'
                            '${e.impl.available ? '' : '：${e.impl.unavailableReason ?? '当前不可用'}'}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

/// 「新建方案档」对话框交回来的东西。
final class _ProfileDraft {
  const _ProfileDraft({required this.name, required this.enabled, this.note});

  final String name;
  final Set<String> enabled;
  final String? note;
}

/// 建一个档：起个名 + 勾插件集。
///
/// 两个刻意的设计：
/// * **预勾 = 现在真正开着的那些**（由调用方从 `previewProfile` 取，与 runtime 同源）——
///   最常用的动作就是"照现在这样存一份，再关掉几个"；
/// * **档名当场判**（内核那份判据 `profileNameProblem`），别等落盘失败才告诉用户"这个名不行"；
///   勾选项里出现的名字取自插件自己，用户看得见自己存了什么。
class _NewProfileDialog extends StatefulWidget {
  const _NewProfileDialog({required this.service, required this.initial});

  final PluginService service;
  final Set<String> initial;

  @override
  State<_NewProfileDialog> createState() => _NewProfileDialogState();
}

class _NewProfileDialogState extends State<_NewProfileDialog> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _note = TextEditingController();
  late Set<String> _picked = {...widget.initial};
  String? _nameError;

  @override
  void dispose() {
    _name.dispose();
    _note.dispose();
    super.dispose();
  }

  void _submit() {
    if (profileNameProblem(_name.text) case final problem?) {
      // 就地报错，不弹 SnackBar：用户正在填这个框，把话留在框上。
      setState(() => _nameError = problem);
      return;
    }
    Navigator.of(context).pop(_ProfileDraft(
      name: _name.text.trim(),
      enabled: {..._picked},
      note: _note.text.trim().isEmpty ? null : _note.text.trim(),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final views = widget.service.view();
    return AlertDialog(
      title: const Text('新建方案档'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                key: const Key('profile-name-field'),
                controller: _name,
                maxLength: 40,
                decoration: InputDecoration(
                  labelText: '档名',
                  hintText: '课堂 / 通勤 / 睡前',
                  errorText: _nameError,
                ),
                onChanged: (_) {
                  if (_nameError != null) setState(() => _nameError = null);
                },
              ),
              TextField(
                controller: _note,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: '备注（可留空）',
                  hintText: '这个档什么时候用',
                ),
              ),
              const SizedBox(height: 10),
              Text('这个档里开着哪些插件（取消勾选 = 在这个档里关掉它）',
                  style: Theme.of(context).textTheme.bodySmall),
              if (views.isEmpty)
                const Padding(
                    padding: EdgeInsets.all(8), child: Text('还没有插件可放进来')),
              for (final v in views)
                CheckboxListTile(
                  key: Key('profile-pick-${v.loaded.descriptor.manifest.id}'),
                  dense: true,
                  controlAffinity: ListTileControlAffinity.leading,
                  contentPadding: EdgeInsets.zero,
                  value: _picked.contains(v.loaded.descriptor.manifest.id),
                  title: Text(v.loaded.descriptor.manifest.name),
                  subtitle: Text(v.loaded.descriptor.manifest.id,
                      style: Theme.of(context).textTheme.bodySmall),
                  onChanged: (on) => setState(() {
                    final id = v.loaded.descriptor.manifest.id;
                    if (on ?? false) {
                      _picked.add(id);
                    } else {
                      _picked.remove(id);
                    }
                  }),
                ),
              const SizedBox(height: 4),
              Text('建好不会自动切过去 —— 点它的卡片才生效。',
                  style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消')),
        FilledButton(
          key: const Key('profile-create-ok'),
          onPressed: _submit,
          child: const Text('建好'),
        ),
      ],
    );
  }
}
