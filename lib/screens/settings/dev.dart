part of '../settings_screen.dart';

// =========================================================================
// 开发者 Tab：开发模式 + SSH 自动连接向导 + 工作区管理 + 危险命令策略。
// 设计目标（用户反馈）：能自动的绝不手填——密钥自动生成、命令一键复制、
// 连接自动建立、Termux 项目目录自动创建。用户只做"复制粘贴一条命令"。
// =========================================================================
class DevSettingsBody extends ConsumerStatefulWidget {
  const DevSettingsBody();

  @override
  ConsumerState<DevSettingsBody> createState() => DevSettingsBodyState();
}

class DevSettingsBodyState extends ConsumerState<DevSettingsBody> {
  /// SSH 连接/工作区激活是异步后台变化，监听 ChangeNotifier 实时刷新。
  VoidCallback? _devStateListener;

  /// 免 SSH 通道测试 / Termux APK 下载 进行中标记。
  bool _testingIntent = false;
  bool _downloadingTermux = false;

  /// 免 SSH 通道测试结果（持久显示，SnackBar 真机上抓不到）。
  String? _intentTestResult;

  /// 上次「免 SSH 通道测试」是否成功。
  ///
  /// 判色必须用这个状态位，**不能用文案 `contains('可用')`** ——
  /// 「Termux 未安装：**可用**下方按钮自动下载」「免 SSH 通道不可**用**」两条失败
  /// 文案都含"可用"，旧版把失败渲染成绿色成功（可用性评估 P1-2）。
  bool _intentTestOk = false;

  /// 当前激活工作区下的任务（懒加载；新建/删除后刷新）。
  List<DevTask> _devTasks = const [];
  bool _devTasksLoaded = false;

  @override
  void initState() {
    super.initState();
    final listener = () {
      if (mounted) {
        // 工作区切换会改变任务过滤范围，一并重载。
        _reloadDevTasks();
        setState(() {});
      }
    };
    _devStateListener = listener;
    SshEnvironmentService.instance.addListener(listener);
    DevSessionController.instance.addListener(listener);
    _reloadDevTasks();
  }

  @override
  void dispose() {
    final listener = _devStateListener;
    if (listener != null) {
      SshEnvironmentService.instance.removeListener(listener);
      DevSessionController.instance.removeListener(listener);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 插件入口已从「开发者」搬去「能力」Tab（2026-10-24 用户定案：插件/技能是智能体的
          // 能力扩展面，不该混在 Dev Agent/SSH 这堆里）。这里只留一句去路，别让人以为功能没了。
          _buildModeCard(settings, notifier),
          const SizedBox(height: 10),
          _buildConnectionsCard(settings, notifier),
          const SizedBox(height: 10),
          _buildAdbCard(settings, notifier),
          const SizedBox(height: 10),
          _buildWorkspacesCard(settings, notifier),
          const SizedBox(height: 10),
          _buildDevTasksCard(settings, notifier),
          const SizedBox(height: 10),
          _buildSafetyCard(settings, notifier),
        ],
      ),
    );
  }

  // ---------------- ADB 远程控制（另一台手机）----------------

  /// 「远程控制（ADB）」卡：总开关 + 目标机白名单 + 设备授权密钥。
  ///
  /// 放在开发者 Tab 与「连接」卡同区（都是"连别的机器"），但**不受开发模式开关
  /// 约束** —— adb 工具的注册只看 [InferenceSettings.adbEnabled]（用户定案：
  /// 设置里开一下就能用，不做逐次审批）。
  Widget _buildAdbCard(InferenceSettings settings, SettingsNotifier notifier) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildToggleTitle(
              '📱 远程控制（ADB）',
              settings.adbEnabled,
              (v) async {
                await notifier.setAdbEnabled(v);
                if (mounted) setState(() {});
              },
              subtitle: settings.adbEnabled
                  ? '开：智能体可用 adb 工具直连下面白名单里的手机（点击/滑动/输入/截屏/装包/日志）'
                  : '关：adb 工具不注册，模型完全看不见（默认）',
            ),
            const SizedBox(height: 4),
            Text(
              'app 内置 ADB 客户端，走 Wi-Fi 直连，无需电脑也无需安装 adb。\n'
              '目标手机需先进入 TCP 模式（电脑上 `adb tcpip 5555`，重启后失效；或开发者选项里'
              '的「无线调试」——注意无线调试端口走 TLS，本版不支持，请用 tcpip 那种）。\n'
              '首次连接时目标机屏幕会弹「允许 USB 调试」，勾选"一律允许"后点确定。',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600, height: 1.35),
            ),
            const Divider(height: 18),
            Row(
              children: [
                Expanded(
                  child: Text('目标手机（${settings.adbTargets.length}）',
                      style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey.shade600,
                          fontWeight: FontWeight.w600)),
                ),
                TextButton.icon(
                  onPressed: () => _showAdbTargetDialog(notifier, null),
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('添加', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
            if (settings.adbTargets.isEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 4),
                child: Text('还没添加目标机。添加时填 ip:5555（Tailscale 网段可直接 ping 通）。',
                    style:
                        TextStyle(fontSize: 11, color: Colors.grey.shade500)),
              ),
            for (final t in settings.adbTargets)
              ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                leading: Switch(
                  value: t.enabled,
                  onChanged: (v) =>
                      notifier.upsertAdbTarget(t.copyWith(enabled: v)),
                ),
                title: Text(t.name.isEmpty ? t.serial : t.name,
                    style: const TextStyle(fontSize: 13)),
                subtitle: Text(
                    '${t.serial}${t.port == 5555 ? '' : '  ⚠️ 非常规端口'}',
                    style:
                        TextStyle(fontSize: 11, color: Colors.grey.shade600)),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.edit_outlined, size: 18),
                      tooltip: '编辑',
                      onPressed: () => _showAdbTargetDialog(notifier, t),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.delete_outline, size: 18),
                      tooltip: '删除',
                      onPressed: () async {
                        final ok = await showDialog<bool>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: const Text('删除目标机'),
                            content: Text('删除「${t.name.isEmpty ? t.serial : t.name}」？'),
                            actions: [
                              TextButton(
                                  onPressed: () => Navigator.pop(ctx, false),
                                  child: const Text('取消')),
                              TextButton(
                                  onPressed: () => Navigator.pop(ctx, true),
                                  child: const Text('删除')),
                            ],
                          ),
                        );
                        if (ok == true) await notifier.removeAdbTarget(t.id);
                      },
                    ),
                  ],
                ),
              ),
            const Divider(height: 18),
            FutureBuilder<String>(
              // 密钥只在读到时才生成（进设置页不该顺手做 2048 位生成）。
              future: _adbKeyFingerprintFuture,
              builder: (context, snap) {
                return Row(
                  children: [
                    Expanded(
                      child: Text(
                        snap.hasError
                            ? '授权密钥异常：${snap.error}'
                            : (snap.data == null || snap.data!.isEmpty
                                ? '设备授权密钥：尚未生成'
                                : '设备授权密钥：指纹 ${snap.data}'),
                        style: TextStyle(
                            fontSize: 11,
                            color: snap.hasError
                                ? Colors.red.shade700
                                : Colors.grey.shade600),
                      ),
                    ),
                    TextButton(
                      onPressed: () => _showAdbKeyDialog(),
                      child: const Text('公钥/导入', style: TextStyle(fontSize: 12)),
                    ),
                    TextButton(
                      onPressed: () => _regenAdbKey(),
                      child: const Text('重新生成', style: TextStyle(fontSize: 12)),
                    ),
                  ],
                );
              },
            ),
            if (settings.adbEnabled && settings.adbTargets.isNotEmpty) ...[
              const Divider(height: 18),
              TextButton.icon(
                onPressed: _adbSelfTest,
                icon: const Icon(Icons.network_check, size: 16),
                label: const Text('连接自检（逐台握手，验证是否已授权）',
                    style: TextStyle(fontSize: 12)),
              ),
              for (final line in _adbSelfTestLines)
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: Text(line,
                      style: TextStyle(
                          fontSize: 11,
                          color: line.startsWith('✓')
                              ? Colors.green.shade700
                              : Colors.red.shade700)),
                ),
            ],
          ],
        ),
      ),
    );
  }

  String? _adbKeyFingerprintCache;

  Future<String> get _adbKeyFingerprintFuture async {
    if (_adbKeyFingerprintCache != null) return _adbKeyFingerprintCache!;
    final key = await loadOrCreateAdbKey(FlutterAdbSecretStore());
    return _adbKeyFingerprintCache = adbKeyFingerprint(key);
  }

  Future<void> _regenAdbKey() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重新生成授权密钥'),
        content: const Text(
            '所有已授权过的手机都会**掉授权**，需要在每台手机上重新点一次「允许 USB 调试」'
            '（或先在手机上撤销本机的授权记录）。确定要继续？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('重新生成')),
        ],
      ),
    );
    if (ok != true) return;
    final store = FlutterAdbSecretStore();
    await store.delete(kAdbKeySlot);
    _adbKeyFingerprintCache = null;
    await _adbKeyFingerprintFuture;
    if (mounted) setState(() {});
  }

  /// 公钥查看 / 导入已有 `~/.android/adbkey`。
  ///
  /// 导入的价值：那台电脑上早已授权过手机时，用同一把私钥可**免掉重新弹框**。
  Future<void> _showAdbKeyDialog() async {
    final store = FlutterAdbSecretStore();
    final key = await loadOrCreateAdbKey(store);
    if (!mounted) return;
    final pub = adbPublicKeyLine(key);
    final ctrl = TextEditingController();
    final choice = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('设备授权密钥'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              SelectableText(pub,
                  style: const TextStyle(fontSize: 10, fontFamily: 'monospace')),
              const SizedBox(height: 10),
              Text('粘贴电脑上 ~/.android/adbkey 的内容可导入（导入后这些电脑授权过的手机免重新弹框）：',
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
              const SizedBox(height: 6),
              TextField(
                controller: ctrl,
                maxLines: 4,
                style: const TextStyle(fontSize: 10, fontFamily: 'monospace'),
                decoration: const InputDecoration(
                    isDense: true,
                    border: OutlineInputBorder(),
                    hintText: '-----BEGIN RSA PRIVATE KEY-----'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, 1),
              child: const Text('复制公钥')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, 2),
              child: const Text('导入私钥')),
        ],
      ),
    );
    // 弹窗关闭即取走私钥文本并释放控制器（原实现从不 dispose，每次弹窗泄漏）。
    final pem = ctrl.text.trim();
    ctrl.dispose();
    if (choice == 1) {
      await Clipboard.setData(ClipboardData(text: pub));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('公钥已复制（与 adbkey.pub 首段应完全一致）')));
      }
    } else if (choice == 2) {
      if (pem.isEmpty) return;
      try {
        await importAdbPrivateKeyPem(store, pem);
        _adbKeyFingerprintCache = null;
        await _adbKeyFingerprintFuture;
        if (mounted) setState(() {});
      } on FormatException catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('导入失败：${e.message}')));
        }
      }
    }
  }

  final List<String> _adbSelfTestLines = [];

  /// 逐台握手自检：把"连不上到底是没开 tcpip、没授权，还是 IP 变了"说清。
  Future<void> _adbSelfTest() async {
    setState(() {
      _adbSelfTestLines.clear();
    });
    final store = FlutterAdbSecretStore();
    final key = await loadOrCreateAdbKey(store);
    for (final t in ref.read(settingsProvider).adbTargets.where((e) => e.enabled)) {
      final sw = Stopwatch()..start();
      try {
        final c = await AdbClient.connect(host: t.host, port: t.port, key: key);
        final id = c.identity();
        await c.close();
        _adbSelfTestLines.add('✓ ${t.serial}  ${id.model}  ${sw.elapsedMilliseconds}ms');
      } catch (e) {
        _adbSelfTestLines.add('✗ ${t.serial}  ${e.toString().split('\n').first}');
      }
      if (mounted) setState(() {});
    }
  }

  /// 添加/编辑目标机（名称 + `ip:port` 一行输入，端口可省）。
  Future<void> _showAdbTargetDialog(
      SettingsNotifier notifier, AdbTarget? existing) async {
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final serialCtrl =
        TextEditingController(text: existing == null ? '' : existing.serial);
    var errorText = '';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(existing == null ? '添加目标手机' : '编辑目标手机'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(
                    isDense: true, labelText: '名称（如 小米13 主力机）'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: serialCtrl,
                autofocus: true,
                decoration: InputDecoration(
                    isDense: true,
                    labelText: '地址（ip:5555，端口可省略）',
                    errorText: errorText.isEmpty ? null : errorText),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
            TextButton(
              onPressed: () {
                final parsed = AdbTarget.parseSerial(serialCtrl.text);
                if (parsed == null) {
                  setDialogState(() => errorText = '填 ip:5555 这种形式');
                  return;
                }
                Navigator.pop(ctx, true);
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    // 弹窗关闭即取走文本并释放控制器（原实现从不 dispose，每次弹窗泄漏两个）。
    final serialText = serialCtrl.text;
    final nameText = nameCtrl.text.trim();
    serialCtrl.dispose();
    nameCtrl.dispose();
    if (ok != true) return;
    final parsed = AdbTarget.parseSerial(serialText)!;
    await notifier.upsertAdbTarget((existing ??
            const AdbTarget(id: '', name: '', host: '', port: 5555))
        .copyWith(
            name: nameText.isEmpty ? parsed.host : nameText,
            host: parsed.host,
            port: parsed.port));
  }

  // ---------------- 总开关 ----------------

  Widget _buildModeCard(InferenceSettings settings, SettingsNotifier notifier) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildToggleTitle(
              '🛠️ 开发模式（Dev Agent）',
              settings.devModeEnabled,
              (v) async {
                await notifier.setDevModeEnabled(v);
                if (mounted) setState(() {});
              },
              subtitle: settings.devModeEnabled
                  ? '开：注册 git/规划/SSH/测试工具，可连 Termux/远程电脑做 AI 编程'
                  : '关：现有智能体行为完全不变（默认）',
            ),
            const SizedBox(height: 4),
            Text(
              '开启后：对话里的智能体可直接读写手机 Termux / 远程电脑上的项目，'
              '执行 git 提交、跑测试。连接由下方向导完成：'
              '远程电脑填账号密码即可，Termux 走自动密钥。',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
            ),
            // P2-D1：Dev 工具逐组开关（默认全开 = 旧行为）。
            if (settings.devModeEnabled) ...[
              const Divider(height: 20),
              Text('工具组开关（默认全开）',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
              for (final g in const [
                ('git', 'Git（状态/diff/log/提交/推送）'),
                ('ssh', 'SSH（执行/读写远端文件）'),
                ('sync', '工作区同步（workspace_sync）'),
                ('plan', '计划（plan_create/update/list）'),
                ('task', '任务（task_create/list）'),
                ('verify', '测试验证（run_tests）'),
              ])
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text(g.$2, style: const TextStyle(fontSize: 13)),
                  value: settings.devToolGroupEnabled(g.$1),
                  onChanged: (v) => notifier.setDevToolGroupEnabled(g.$1, v),
                ),
            ],
          ],
        ),
      ),
    );
  }

  // ---------------- 连接配置（多目标：Termux / 远程电脑） ----------------

  Widget _buildConnectionsCard(
      InferenceSettings settings, SettingsNotifier notifier) {
    final ssh = SshEnvironmentService.instance;
    final sshStatusLabel = switch (ssh.status) {
      SshStatus.idle => '未连接',
      SshStatus.connecting => '连接中…',
      SshStatus.connected => '已连接',
      SshStatus.failed => '失败',
    };
    final sshStatusColor = switch (ssh.status) {
      SshStatus.connected => Colors.green,
      SshStatus.connecting => Colors.orange,
      SshStatus.failed => Colors.red,
      _ => Colors.grey,
    };
    final configs = settings.sshConfigs;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSectionHeader('🔌 SSH 连接（自动配置向导）', context),
            Row(
              children: [
                Icon(Icons.circle, size: 10, color: sshStatusColor),
                const SizedBox(width: 6),
                Text(sshStatusLabel, style: const TextStyle(fontSize: 12)),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    ssh.isConnected
                        ? '${ssh.activeConfig?.name ?? ''} '
                            '${ssh.activeConfig?.username ?? ''}@'
                            '${ssh.activeConfig?.host ?? ''}:'
                            '${ssh.activeConfig?.port ?? ''}'
                        : (ssh.status == SshStatus.failed &&
                                (ssh.lastError?.isNotEmpty ?? false))
                            ? ssh.lastError!
                            : '未连接（向导自动完成，无需手填密钥）',
                    style: TextStyle(
                        fontSize: 12,
                        color: ssh.status == SshStatus.failed
                            ? Colors.red.shade700
                            : Colors.grey.shade600),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // 自动向导入口：Termux / 远程电脑 各一个。
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: () => _showTermuxSetupDialog(context, notifier),
                  icon: const Icon(Icons.smartphone, size: 16),
                  label: const Text('📱 连接 Termux'),
                ),
                FilledButton.icon(
                  onPressed: () => _showRemotePcSetupDialog(context, notifier),
                  icon: const Icon(Icons.desktop_windows, size: 16),
                  label: const Text('💻 连接远程电脑'),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '远程电脑可用「账号密码」直接连（电脑开好 SSH 服务即可，不必装公钥）；'
              'Termux 走自动生成密钥，一条命令完成，无需 root。'
              '连接失败会给针对性诊断和修复动作。',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
            ),
            // 免 SSH 通道（RUN_COMMAND intent，L2）：工具执行优先走这里，
            // 不可用才回落 SSH。状态探测 + 一键拉起 Termux + 下载安装。
            const SizedBox(height: 8),
            Row(
              children: [
                TextButton.icon(
                  onPressed: _testingIntent
                      ? null
                      : () async {
                          setState(() {
                            _testingIntent = true;
                            _intentTestResult = null;
                          });
                          String msg;
                          var ok = false;
                          try {
                            final installed = await AppBridge.isAppInstalled(
                                AppBridge.termuxPackage);
                            if (!installed) {
                              msg = 'Termux 未安装：可用下方按钮自动下载';
                            } else {
                              final res = await TermuxIntentService.instance
                                  .run('echo ok',
                                      timeout: const Duration(seconds: 10));
                              ok = res.output.trim() == 'ok' && res.exit == 0;
                              msg = ok
                                  ? '免 SSH 通道可用（RUN_COMMAND，echo ok 往返成功）'
                                  : '通道返回异常（exit=${res.exit}，输出：${res.output.trim()}）：'
                                      '检查 allow-external-apps 是否已开启';
                            }
                            if (mounted) {
                              ScaffoldMessenger.of(context)
                                  .showSnackBar(SnackBar(content: Text(msg)));
                            }
                          } catch (e) {
                            ok = false;
                            msg = '免 SSH 通道不可用：'
                                '${e.toString().replaceAll('StateError: ', '')}';
                            if (mounted) {
                              ScaffoldMessenger.of(context)
                                  .showSnackBar(SnackBar(content: Text(msg)));
                            }
                          }
                          // 结果持久显示（SnackBar 4s 即逝，真机验收读不到）。
                          if (mounted) {
                            setState(() {
                              _intentTestResult = msg;
                              _intentTestOk = ok;
                              _testingIntent = false;
                            });
                          }
                        },
                  icon: Icon(_testingIntent ? Icons.hourglass_top : Icons.bolt,
                      size: 16),
                  label: Text(_testingIntent ? '测试中…' : '免 SSH 通道测试'),
                ),
                TextButton.icon(
                  onPressed: _downloadingTermux
                      ? null
                      : () async {
                          setState(() => _downloadingTermux = true);
                          try {
                            const apkUrl =
                                'https://github.com/termux/termux-app/releases/download/v0.118.1/termux-app_0.118.1+github-debug_arm64-v8a.apk';
                            final err =
                                await DevNativeEnv.downloadTermuxApk(apkUrl);
                            if (!mounted) return;
                            if (err != null) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text('下载失败：$err')));
                              return;
                            }
                            // 下载入队后轮询目标文件出现，再拉安装器。
                            const apkPath =
                                '/storage/emulated/0/Download/TongYi-Lite/termux.apk';
                            for (var i = 0; i < 240; i++) {
                              await Future<void>.delayed(
                                  const Duration(seconds: 5));
                              final f = File(apkPath);
                              if (await f.exists() &&
                                  await f.length() > 1024 * 1024) {
                                final installErr =
                                    await DevNativeEnv.installApk(apkPath);
                                if (mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                          content: Text(installErr == null
                                              ? '下载完成，已拉起安装器（需允许安装未知应用）'
                                              : '安装器拉起失败：$installErr')));
                                }
                                return;
                              }
                            }
                            if (mounted) {
                              ScaffoldMessenger.of(context)
                                  .showSnackBar(const SnackBar(
                                      content: Text('下载超时：请到系统通知查看进度，'
                                          '完成后在 Download/TongYi-Lite/ 找到 APK')));
                            }
                          } finally {
                            if (mounted)
                              setState(() => _downloadingTermux = false);
                          }
                        },
                  icon: Icon(
                      _downloadingTermux ? Icons.hourglass_top : Icons.download,
                      size: 16),
                  label: Text(_downloadingTermux ? '下载中…' : '下载 Termux'),
                ),
              ],
            ),
            if (_intentTestResult != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '上次测试：$_intentTestResult',
                  style: TextStyle(
                      fontSize: 12,
                      color: _intentTestOk
                          ? Colors.green.shade700
                          : Colors.red.shade700),
                ),
              ),
            // 配置列表（已保存的连接目标）。
            if (configs.isNotEmpty) ...[
              const SizedBox(height: 8),
              for (final cfg in configs)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${cfg.name.isEmpty ? '配置' : cfg.name} · '
                          '${cfg.username.isEmpty ? '?' : cfg.username}@'
                          '${cfg.host}:${cfg.port} · ${switch (cfg.authType) {
                            SshAuthType.key => '密钥',
                            SshAuthType.password => '密码',
                            SshAuthType.keyThenPassword => '密钥+密码',
                          }}',
                          style: const TextStyle(fontSize: 12),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      TextButton(
                        onPressed: () => _showSshConfigDialog(context, notifier,
                            existing: cfg),
                        child: const Text('编辑'),
                      ),
                      TextButton(
                        onPressed: () async {
                          await notifier.removeSshConfig(cfg.id);
                          if (ssh.activeConfig?.id == cfg.id) {
                            await ssh.disconnect();
                          }
                          if (mounted) setState(() {});
                        },
                        child: const Text('删除'),
                      ),
                      TextButton(
                        onPressed: () async {
                          await _connectTo(cfg);
                          if (mounted) setState(() {});
                        },
                        child: const Text('连接'),
                      ),
                    ],
                  ),
                ),
            ],
            if (ssh.isConnected) ...[
              const SizedBox(height: 6),
              Wrap(
                spacing: 4,
                children: [
                  TextButton.icon(
                    onPressed: () async {
                      await ssh.disconnect();
                      if (mounted) setState(() {});
                    },
                    icon: const Icon(Icons.link_off, size: 18),
                    label: const Text('断开'),
                  ),
                  TextButton.icon(
                    onPressed: () async {
                      await ssh.clearHostKeyFingerprints();
                      if (mounted) setState(() {});
                    },
                    icon: const Icon(Icons.fingerprint, size: 18),
                    label: const Text('清除指纹'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 连接（保持连接；[force] = 用户手点按钮 → 强制重新握手）。
  ///
  /// 注意 1：`SshEnvironmentService.connect` 失败只置内部状态不抛异常，
  /// 必须用 `isConnected` 判定结果，不能依赖 try/catch（否则永远弹"已连接"）。
  /// 注意 2：完整性判定必须在**回填凭据之后**——私钥/密码保存在安全存储里，
  /// settings 里的配置是空槽位，直接判 `isComplete` 会永远提示"配置不完整"。
  Future<bool> _connectTo(SshConfig cfg,
      {bool force = true, bool offerWorkspace = true}) async {
    SshConfig resolved = cfg;
    try {
      resolved = await resolveSshSecrets(cfg);
    } on Exception catch (_) {}
    if (!resolved.isComplete) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(resolved.usesPassword
                ? '配置不完整：请填写「用户名 + 电脑登录密码」后再连接'
                : '配置不完整：请先编辑补全用户名/私钥（或改用密码登录）')));
      }
      return false;
    }
    final ssh = SshEnvironmentService.instance;
    await ssh.connect(resolved, force: force);
    if (!mounted) return false;
    final ok = ssh.isConnected;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(ok
            ? '✅ 已连接 ${cfg.name.isEmpty ? cfg.host : cfg.name}'
            : '❌ ${_classifySshError(ssh.lastError, cfg: resolved)}')));
    // 连上 ≠ 能干活：没有激活的远端工作区，智能体收到的上下文仍是本地沙盒。
    // 所以连成功后顺势问一句要不要就地建工作区（已绑定的不再打扰）。
    if (ok && offerWorkspace) await _offerWorkspaceFor(cfg);
    return ok;
  }

  /// 连接成功后的"开工引导"：给这份连接建远端工作区并激活。
  /// 该配置已有绑定的工作区 → 静默跳过（不重复打扰）。
  Future<void> _offerWorkspaceFor(SshConfig cfg) async {
    final dev = DevSessionController.instance;
    await dev.init(preferredActiveId: ref.read(settingsProvider).devWorkspaceId);
    if (dev.workspaces.any((w) => w.isRemote && w.sshConfigId == cfg.id)) {
      return; // 已有绑定这份工作区的远端工作区 → 不再打扰。
    }
    if (!mounted) return;
    final what = cfg.name.trim().isEmpty ? cfg.host : cfg.name.trim();
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('在「$what」上开工？'),
        content: Text('已连上 $what。\n\n'
            '要不要为它建个工作区（会在电脑上建 ~/projects/<名称> 并设为当前工作区）？'
            '建好后，对话里的智能体就直接在这台电脑上读写代码、跑测试——'
            '否则它仍在手机本地目录里干活。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('先不用')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('建工作区并切过去')),
        ],
      ),
    );
    if (go != true || !mounted) return;
    final ctrl = TextEditingController(text: '我的项目');
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('在「$what」上开工'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '项目/工作区名称',
            helperText: '会在电脑上建 ~/projects/<名称> 作为工作区目录',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('创建并切过去')),
        ],
      ),
    );
    // 弹窗已关闭（结果即文本），控制器一次性回收（原实现从不 dispose，每次弹窗泄漏）。
    ctrl.dispose();
    if (name == null || name.trim().isEmpty || !mounted) return;
    final r = await createWorkspaceOnActiveConnection(name);
    if (r.ws == null) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('❌ ${r.dir}')));
      }
      return;
    }
    await ref
        .read(settingsProvider.notifier)
        .setDevWorkspaceId(r.ws!.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('✅ 已切到工作区「${r.ws!.name}」（${r.dir}）：'
            '现在让它「看项目 / 改代码 / 跑测试」都会在这台电脑上执行')));
  }

  // ---------------- Termux 自动向导 ----------------

  /// Termux 向导（诊断驱动）：
  /// 打开时探测一次 sshd → 按结果给诊断（未运行 / 被拉黑 / 正常）→
  /// 万能命令（自带 pkill+sshd 重启，顺带清 PerSourcePenalties 惩罚）→
  /// 可一键拉起 Termux → 用户名 → 真实连接。
  Future<void> _showTermuxSetupDialog(
      BuildContext context, SettingsNotifier notifier) async {
    var step = 0; // 0: 探测  1: 命令执行  2: 用户名+连接
    var probing = true;
    var probeResult = _SshdProbe.timeout;
    var generated = false;
    String? privateKeyPem;
    var command = '';
    var userName = '';
    var connecting = false;
    var probeStarted = false;
    // 向导内「免 SSH 通道」自检结果（allow-external-apps 是否生效 / Termux 是否可执行）。
    String? _wizardMsg;
    bool? _wizardOk;
    var _wizardTesting = false;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) {
          Future<void> probeAndGen() async {
            setState(() => probing = true);
            probeResult = await _probeSshd('127.0.0.1', 8022);
            if (!generated) {
              final keys = SshKeyGen.generate();
              if (keys != null) {
                generated = true;
                privateKeyPem = keys.privateKeyPem;
                command = _buildTermuxInstallCommand(keys.publicKey);
              }
            }
            probing = false;
            step = 1;
            setState(() {});
          }

          Future<void> finishConnect() async {
            setState(() => connecting = true);
            userName = userName.trim();
            final cfg = SshConfig.termuxTemplate.copyWith(
              username: userName,
              privateKeyPem: privateKeyPem,
              authType: SshAuthType.key,
            );
            await notifier.upsertSshConfig(cfg);
            final ssh = SshEnvironmentService.instance;
            await ssh.connect(cfg);
            connecting = false;
            if (!ctx.mounted) return;
            if (ssh.isConnected) {
              Navigator.pop(ctx);
              return;
            }
            Navigator.pop(ctx);
            ScaffoldMessenger.of(this.context).showSnackBar(SnackBar(
                backgroundColor: Colors.red.shade700,
                content: Text('❌ ${_classifySshError(ssh.lastError)}',
                    style: const TextStyle(fontSize: 12))));
          }

          if (!probeStarted) {
            probeStarted = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (ctx.mounted) probeAndGen();
            });
          }

          final diagnosis = switch (probeResult) {
            _SshdProbe.listening => 'sshd 运行中——还差最后一步：安装公钥',
            _SshdProbe.refused => 'sshd 没在运行（最常见的失败原因）',
            _SshdProbe.timeout => '端口无响应——大概率是之前多次连接失败后被 Termux 的 OpenSSH '
                '临时拉黑（PerSourcePenalties），越重试越连不上',
          };

          final dialog = AlertDialog(
            title: const Text('📱 Termux 自动连接向导'),
            content: SizedBox(
              width: 480,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (step == 0)
                      const Row(children: [
                        SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2)),
                        SizedBox(width: 12),
                        Text('正在检测 Termux sshd（127.0.0.1:8022）…'),
                      ])
                    else ...[
                      Text('诊断：$diagnosis',
                          style: const TextStyle(fontSize: 13)),
                      const SizedBox(height: 10),
                      // 万能命令：pkill 重启 sshd（清拉黑）+ 装公钥 + 写用户名，
                      // 三种诊断状态都靠它修复，一条到底。
                      Text('在 Termux 里粘贴执行这条命令（自动重启 sshd + 安装公钥）：',
                          style: const TextStyle(fontSize: 12)),
                      const SizedBox(height: 6),
                      _copyableCommand(ctx, command),
                      const SizedBox(height: 10),
                      Row(children: [
                        FilledButton.icon(
                          onPressed: () async {
                            // 零粘贴：RUN_COMMAND 让 Termux 自己执行安装命令。
                            final ok = await AppBridge.runInTermux(command);
                            if (!ctx.mounted) return;
                            if (ok) {
                              ScaffoldMessenger.of(this.context)
                                  .showSnackBar(const SnackBar(
                                      content: Text('已发送到 Termux 执行；若执行完未出现 '
                                          'ALL_DONE，检查 Termux 是否开启 '
                                          'allow-external-apps')));
                            } else {
                              ScaffoldMessenger.of(this.context)
                                  .showSnackBar(const SnackBar(
                                      content: Text('发送失败：Termux 未安装或'
                                          '未授权 RUN_COMMAND，请粘贴执行')));
                            }
                          },
                          icon: const Icon(Icons.bolt, size: 16),
                          label: const Text('自动执行'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton.tonalIcon(
                          onPressed: () async {
                            final ok = await AppBridge.launchApp(
                                AppBridge.termuxPackage);
                            if ((!ok) && ctx.mounted) {
                              ScaffoldMessenger.of(this.context).showSnackBar(
                                  const SnackBar(
                                      content: Text('未找到 Termux，请先安装 Termux')));
                            }
                          },
                          icon: const Icon(Icons.open_in_new, size: 16),
                          label: const Text('拉起 Termux'),
                        ),
                        const SizedBox(width: 8),
                        TextButton.icon(
                          onPressed: probing ? null : () => probeAndGen(),
                          icon: const Icon(Icons.refresh, size: 16),
                          label: Text(probing ? '检测中…' : '重新检测'),
                        ),
                      ]),
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.red.shade50,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          '⚠️ 最关键的一步（绝大多数「不行」都卡在这）：'
                          'RUN_COMMAND 免 SSH 通道要求 Termux 开启 '
                          'allow-external-apps 并【彻底重启 Termux】（不是切后台再回来）。'
                          '上面这条命令已写好该开关，但 Termux 只在启动时读 '
                          'termux.properties——没重启前，App 发来的命令会被 Termux '
                          '静默忽略，表现就是"测试超时 / 通道不可用"。'
                          '另外若未在 Termux 里跑过 termux-setup-storage，'
                          '交换文件写不进、同样会超时。请满足这两点再测。',
                          style:
                              TextStyle(fontSize: 12, color: Colors.red.shade800),
                        ),
                      ),
                      // 向导内自检：直接经 RUN_COMMAND 跑 echo ok。
                      // 通过=allow-external-apps 已生效（绿）；不通=明确指引去补重启/存储权限。
                      OutlinedButton.icon(
                        onPressed: _wizardTesting
                            ? null
                            : () async {
                                setState(() {
                                  _wizardTesting = true;
                                  _wizardMsg = null;
                                  _wizardOk = null;
                                });
                                try {
                                  final res = await TermuxIntentService.instance
                                      .run('echo ok',
                                          timeout: const Duration(
                                              seconds: 10));
                                  final ok = res.output.trim() == 'ok'
                                      && res.exit == 0;
                                  setState(() {
                                    _wizardTesting = false;
                                    _wizardOk = ok;
                                    _wizardMsg = ok
                                        ? '✅ 免 SSH 通道可用（RUN_COMMAND 往返成功），可继续。'
                                        : '❌ RUN_COMMAND 通道不通——请先：① 确认 '
                                            'termux.properties 有 '
                                            'allow-external-apps=true，② 彻底重启 '
                                            'Termux（不是切后台），③ 已在 Termux 跑过 '
                                            'termux-setup-storage；然后回来再点测试。';
                                  });
                                } on StateError catch (e) {
                                  setState(() {
                                    _wizardTesting = false;
                                    _wizardOk = false;
                                    _wizardMsg = '❌ 通道不可用：'
                                        '${e.message.replaceAll('StateError: ', '')}'
                                        '（多半是 Termux 未装 / 未开 '
                                        'allow-external-apps / 未重启）。';
                                  });
                                } catch (e) {
                                  setState(() {
                                    _wizardTesting = false;
                                    _wizardOk = false;
                                    _wizardMsg = '❌ 测试异常：$e';
                                  });
                                }
                              },
                        icon: Icon(_wizardTesting
                            ? Icons.hourglass_top
                            : Icons.bolt,
                            size: 16),
                        label: Text(_wizardTesting
                            ? '测试中…'
                            : '测试免SSH通道'),
                      ),
                      if (_wizardMsg != null) ...[
                        const SizedBox(height: 6),
                        Text(_wizardMsg!,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: _wizardOk == true
                                  ? FontWeight.w500
                                  : FontWeight.w600,
                              color: _wizardOk == true ? Colors.green : Colors.red,
                            )),
                      ],
                      if (step == 2) ...[
                        const SizedBox(height: 12),
                        TextField(
                          controller: TextEditingController(text: userName),
                          onChanged: (v) => userName = v,
                          decoration: const InputDecoration(
                            labelText: 'Termux 用户名',
                            hintText: '通常 u0_aXXX，已自动填好',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ] else ...[
                        const SizedBox(height: 6),
                        const Text('执行完命令后点「下一步」。',
                            style: TextStyle(fontSize: 11, color: Colors.grey)),
                      ],
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              if (step == 1)
                TextButton(
                  onPressed: () {
                    userName = _readSharedUserName() ?? '';
                    setState(() => step = 2);
                  },
                  child: const Text('下一步'),
                ),
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('取消'),
              ),
              if (step == 2)
                FilledButton(
                  onPressed: connecting ? null : finishConnect,
                  child: Text(connecting ? '连接中…' : '✅ 连接'),
                ),
            ],
          );
          return dialog;
        },
      ),
    );
    if (mounted) setState(() {});
  }

  /// 远程电脑向导：host/port/用户名 + **认证方式（密码 或 密钥）** + 连接。
  ///
  /// 密码登录是远程电脑最常见也最省事的路径（无需往对端装公钥），设为默认；
  /// 密钥模式仍可「自动生成密钥」并给出装公钥命令，另可选填「密码兜底」
  /// —— 填了就变成密钥优先、失败自动回落密码（[SshAuthType.keyThenPassword]）。
  Future<void> _showRemotePcSetupDialog(
      BuildContext context, SettingsNotifier notifier) async {
    final hostCtrl = TextEditingController();
    final portCtrl = TextEditingController(text: '22');
    final userCtrl = TextEditingController();
    final passCtrl = TextEditingController();
    var generated = false;
    String? publicKey;
    String? privateKeyPem;
    var command = '';
    // 默认走密码登录：远程电脑九成 scenario 是"我知道账号密码，不想折腾公钥"。
    var usePasswordLogin = true;
    var showPwd = false;
    var busy = false;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) {
          final pwd = passCtrl.text.trim();
          // 密钥模式下填了密码 = 密钥优先 + 密码兜底。
          final effectiveType = usePasswordLogin
              ? SshAuthType.password
              : (pwd.isNotEmpty
                  ? SshAuthType.keyThenPassword
                  : SshAuthType.key);
          final ready = hostCtrl.text.trim().isNotEmpty &&
              userCtrl.text.trim().isNotEmpty &&
              switch (effectiveType) {
                SshAuthType.password => pwd.isNotEmpty,
                SshAuthType.key => generated,
                SshAuthType.keyThenPassword => generated && pwd.isNotEmpty,
              };
          return AlertDialog(
            title: const Text('💻 连接远程电脑'),
            content: SizedBox(
              width: 460,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextFormField(
                      controller: hostCtrl,
                      autofocus: true,
                      decoration: const InputDecoration(
                        labelText: '电脑地址（必填）',
                        hintText: '局域网 IP 或主机名，如 192.168.1.100',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        SizedBox(
                          width: 110,
                          child: TextFormField(
                            controller: portCtrl,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: '端口',
                              hintText: '22',
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: TextFormField(
                            controller: userCtrl,
                            decoration: const InputDecoration(
                              labelText: '电脑用户名（必填）',
                              hintText: '登录电脑用的账号名',
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text('登录方式',
                        style: TextStyle(
                            fontSize: 12, color: Colors.grey.shade600)),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      children: [
                        ChoiceChip(
                          avatar: Icon(usePasswordLogin
                              ? Icons.check_circle
                              : Icons.radio_button_unchecked,
                              size: 18),
                          label: const Text('🔑 密码登录（最简单）'),
                          selected: usePasswordLogin,
                          onSelected: (_) => setState(() {
                            usePasswordLogin = true;
                            showPwd = false;
                          }),
                        ),
                        ChoiceChip(
                          avatar: Icon(!usePasswordLogin
                              ? Icons.check_circle
                              : Icons.radio_button_unchecked,
                              size: 18),
                          label: const Text('🗝️ 密钥登录（免密）'),
                          selected: !usePasswordLogin,
                          onSelected: (_) => setState(() {
                            usePasswordLogin = false;
                            showPwd = false;
                          }),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    if (usePasswordLogin) ...[
                      TextField(
                        controller: passCtrl,
                        obscureText: !showPwd,
                        onChanged: (_) => setState(() {}),
                        decoration: InputDecoration(
                          labelText: '电脑登录密码（必填）',
                          helperText: '就是你在电脑上输的那个密码；'
                              'Windows 用微软账户登录时填该账户的密码',
                          helperMaxLines: 2,
                          border: const OutlineInputBorder(),
                          suffixIcon: IconButton(
                            icon: Icon(showPwd
                                ? Icons.visibility_off
                                : Icons.visibility),
                            onPressed: () => setState(() => showPwd = !showPwd),
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '电脑需先开启 SSH 服务：Windows「设置 → 系统 → 可选功能 → OpenSSH 服务器」'
                        '并启动 sshd 服务；Linux `sudo apt install openssh-server`；'
                        'macOS「通用 → 共享 → 远程登录」。连不上多半是防火墙没放行 22 端口。',
                        style: TextStyle(
                            fontSize: 10.5, color: Colors.grey.shade600),
                      ),
                    ] else ...[
                      if (!generated)
                        FilledButton.icon(
                          onPressed: () {
                            final keys = SshKeyGen.generate();
                            if (keys != null) {
                              setState(() {
                                generated = true;
                                publicKey = keys.publicKey;
                                privateKeyPem = keys.privateKeyPem;
                                command =
                                    _buildRemoteInstallCommand(keys.publicKey);
                              });
                            }
                          },
                          icon: const Icon(Icons.key, size: 16),
                          label: const Text('🔑 自动生成密钥'),
                        )
                      else ...[
                        Text('① 在电脑上执行这条命令（把公钥装进 authorized_keys）：',
                            style: const TextStyle(fontSize: 12)),
                        const SizedBox(height: 6),
                        _copyableCommand(ctx, command),
                        const SizedBox(height: 4),
                        Text(
                          '公钥：$publicKey',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 10, color: Colors.grey.shade600),
                        ),
                      ],
                      const SizedBox(height: 10),
                      TextField(
                        controller: passCtrl,
                        obscureText: !showPwd,
                        onChanged: (_) => setState(() {}),
                        decoration: InputDecoration(
                          labelText: '密码兜底（可选）',
                          helperText: '填了则密钥认证失败时自动改用密码，两条腿走路',
                          helperMaxLines: 2,
                          border: const OutlineInputBorder(),
                          suffixIcon: IconButton(
                            icon: Icon(showPwd
                                ? Icons.visibility_off
                                : Icons.visibility),
                            onPressed: () => setState(() => showPwd = !showPwd),
                          ),
                        ),
                      ),
                    ],
                    if (busy)
                      const Padding(
                        padding: EdgeInsets.only(top: 10),
                        child: Row(children: [
                          SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2)),
                          SizedBox(width: 8),
                          Text('正在连接…', style: TextStyle(fontSize: 12)),
                        ]),
                      ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: busy ? null : () => Navigator.pop(ctx),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: (busy || !ready)
                    ? null
                    : () async {
                        setState(() => busy = true);
                        final host = hostCtrl.text.trim();
                        final user = userCtrl.text.trim();
                        final cfg = SshConfig.remotePcTemplate.copyWith(
                          name: '远程电脑',
                          host: host,
                          port: int.tryParse(portCtrl.text.trim()) ?? 22,
                          username: user,
                          authType: effectiveType,
                          privateKeyPem:
                              usePasswordLogin ? null : privateKeyPem,
                          password: pwd.isEmpty ? null : pwd,
                        );
                        await notifier.upsertSshConfig(cfg);
                        if (!ctx.mounted) return;
                        Navigator.pop(ctx);
                        await _connectTo(cfg);
                      },
                child: Text(busy
                    ? '连接中…'
                    : (ready
                        ? '保存并连接'
                        : (usePasswordLogin ? '填写地址/用户名/密码' : '先生成密钥'))),
              ),
            ],
          );
        },
      ),
    );
    // 弹窗已关闭，控制器一次性回收（原实现从不 dispose，每次弹窗泄漏四个）。
    for (final c in [hostCtrl, portCtrl, userCtrl, passCtrl]) {
      c.dispose();
    }
    if (mounted) setState(() {});
  }

  /// 可复制的命令块（选中即复制）。
  Widget _copyableCommand(BuildContext ctx, String command) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.grey.shade900,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          Expanded(
            child: SelectableText(
              command,
              style: const TextStyle(fontSize: 12, color: Colors.white),
            ),
          ),
          IconButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: command));
              if (ctx.mounted) {
                ScaffoldMessenger.of(ctx)
                    .showSnackBar(const SnackBar(content: Text('已复制，去粘贴执行即可')));
              }
            },
            icon: const Icon(Icons.copy, size: 16, color: Colors.white),
          ),
        ],
      ),
    );
  }

  /// Termux sshd 诊断探测（只在向导打开时做一次）。
  ///
  /// ⚠️ 对 Termux 的 OpenSSH 10.x **不能频繁裸探测**：TCP 连上后未认证即断开
  /// 会被 PerSourcePenalties 记惩罚（源 127.0.0.1 被拉黑后 sshd 接受连接但
  /// 不发 banner → 表现为 timeout），越探越死。refused = 没监听（不记惩罚）。
  Future<_SshdProbe> _probeSshd(String host, int port) async {
    try {
      final socket =
          await Socket.connect(host, port, timeout: const Duration(seconds: 3));
      socket.destroy();
      return _SshdProbe.listening;
    } on SocketException catch (e) {
      final msg = e.message.toLowerCase();
      if (msg.contains('refused') || e.osError?.errorCode == 111) {
        return _SshdProbe.refused; // sshd 没在监听
      }
      return _SshdProbe.timeout; // 被拉黑 / sshd 卡死
    } catch (_) {
      return _SshdProbe.timeout;
    }
  }

  /// SSH 连接失败 → 人话 + 下一步动作（不甩原始异常）。
  ///
  /// 可用性评估实锤：旧版一套 **Termux 话术** 通吃所有失败，连远程电脑失败
  /// 也在教用户"打开 Termux 重新执行安装命令"。现按目标类型（Termux/电脑）
  /// 与认证方式（密钥/密码）分流；不传 cfg（Termux 向导）按 Termux+密钥。
  String _classifySshError(String? raw, {SshConfig? cfg}) {
    return classifySshFailure(
      raw,
      target: cfg == null ? SshTargetKind.termux : sshTargetKindOf(cfg),
      passwordAuth: cfg == null ? false : sshUsesPasswordAuth(cfg),
      keyAuth: cfg == null ? true : cfg.usesKey,
    );
  }

  /// 读取 Termux 写入共享文件的用户名（/sdcard/tongyilite_ssh_user.txt）。
  /// 实锤修复：文件内容是 `USER=u0_a333` 整行，此前直接存进配置导致
  /// 用户名带 `USER=` 前缀 → 认证必败。这里剥前缀 + 兜底清洗。
  String? _readSharedUserName() {
    try {
      final f = File('/storage/emulated/0/tongyilite_ssh_user.txt');
      if (!f.existsSync()) return null;
      var v = f.readAsStringSync().trim();
      // 取第一行；兼容 KEY=VALUE / 纯用户名两种形态。
      final first = v.split('\n').first.trim();
      if (first.contains('=')) {
        v = first.split('=').last.trim();
      } else {
        v = first;
      }
      // 手机用户名形如 u0_aXXX；防止残留关键字前缀/空白。
      if (v.isEmpty || v.toLowerCase() == 'user') return null;
      return v;
    } catch (_) {
      return null;
    }
  }

  /// Termux 安装公钥 + 写用户名（一条复制即用；无存储权限不影响公钥安装）。
  String _buildTermuxInstallCommand(String publicKey) {
    // v3（2026-10-04）：追加 allow-external-apps（RUN_COMMAND 免 SSH 通道的
    // 唯一前置）+ termux-setup-storage（交换目录 /sdcard/TongYiLite 需要
    // Termux 侧存储权限）；SSH 部分保留作回退通道。
    //
    // v4（2026-10-20 可用性评估 P1-1）：中文说明**不得塞进 echo 参数** ——
    // 旧版输出 `ALL_DONE（免 SSH 通道已配置；…）`，而 UI 要求用户确认出现
    // `ALL_DONE`，混排让人无法判定成功。改为：提示单独 echo，`ALL_DONE` 独占一行且最后。
    return 'pkg install -y openssh procps 2>/dev/null; '
        'pkill sshd 2>/dev/null; sleep 1; sshd 2>/dev/null; '
        'mkdir -p ~/.ssh && echo "$publicKey" > ~/.ssh/authorized_keys && '
        'chmod 600 ~/.ssh/authorized_keys; '
        'mkdir -p ~/.termux && grep -q allow-external-apps ~/.termux/termux.properties 2>/dev/null '
        '|| echo "allow-external-apps=true" >> ~/.termux/termux.properties; '
        'termux-reload-settings 2>/dev/null; '
        'echo "USER=\$(whoami)" > /sdcard/tongyilite_ssh_user.txt 2>/dev/null || true; '
        'echo "[TongYi-Lite] 提示：如需 App 读写共享存储，请在 Termux 里再执行一次 termux-setup-storage"; '
        'echo ALL_DONE';
  }

  /// 远程电脑添加公钥命令（追加，不覆盖已有公钥）。
  String _buildRemoteInstallCommand(String publicKey) {
    return 'mkdir -p ~/.ssh && echo "$publicKey" >> ~/.ssh/authorized_keys && '
        'chmod 600 ~/.ssh/authorized_keys && echo ALL_DONE';
  }

  // ---------------- SSH 配置编辑 ----------------

  /// 编辑指定配置（existing 为空则新建）。
  ///
  /// 凭据（私钥/登录密码）平时只存在安全存储里，settings 里是空槽位 ——
  /// 所以打开编辑框前要先 [resolveSshSecrets] 回填，否则"编辑一下主机名再保存
  /// 就把密码清空了"。留空提交 = 保持原凭据不变（不会误删）。
  Future<void> _showSshConfigDialog(
      BuildContext context, SettingsNotifier notifier,
      {SshConfig? existing}) async {
    SshConfig? cfg = existing;
    if (cfg != null) {
      try {
        cfg = await resolveSshSecrets(cfg);
      } on Exception catch (_) {}
      if (!mounted) return; // 异步回填凭据后可能已离开页面。
    }
    final storedPassword = cfg?.password ?? '';
    final storedKeyPem = cfg?.privateKeyPem ?? '';
    final nameCtrl = TextEditingController(text: cfg?.name ?? '');
    final hostCtrl = TextEditingController(text: cfg?.host ?? '127.0.0.1');
    final portCtrl =
        TextEditingController(text: (cfg?.port ?? 8022).toString());
    final userCtrl = TextEditingController(text: cfg?.username ?? '');
    final passCtrl = TextEditingController(text: storedPassword);
    final keyCtrl = TextEditingController(text: storedKeyPem);
    final passPhraseCtrl = TextEditingController(text: cfg?.keyPassphrase ?? '');
    final formKey = GlobalKey<FormState>();
    var authType = cfg?.authType ?? SshAuthType.key;
    var showPwd = false;
    String? generatedPublicKey;
    var genCommand = '';
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: Text(existing == null ? '新增连接配置' : '编辑连接配置'),
          content: Form(
            key: formKey,
            child: SizedBox(
              width: 460,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextFormField(
                      controller: nameCtrl,
                      decoration: const InputDecoration(
                        labelText: '配置名称',
                        hintText: '如：Termux / 家里电脑',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: hostCtrl,
                      decoration: const InputDecoration(
                        labelText: '主机',
                        border: OutlineInputBorder(),
                      ),
                      validator: (v) =>
                          (v == null || v.trim().isEmpty) ? '请填写主机' : null,
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: portCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: '端口',
                        border: OutlineInputBorder(),
                      ),
                      validator: (v) =>
                          (int.tryParse(v ?? '') ?? 0) <= 0 ? '端口非法' : null,
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: userCtrl,
                      decoration: const InputDecoration(
                        labelText: '用户名',
                        border: OutlineInputBorder(),
                      ),
                      validator: (v) =>
                          (v == null || v.trim().isEmpty) ? '请填写用户名' : null,
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        ChoiceChip(
                          label: const Text('密钥'),
                          selected: authType == SshAuthType.key,
                          onSelected: (_) => setState(() {
                            authType = SshAuthType.key;
                            showPwd = false;
                          }),
                        ),
                        const SizedBox(width: 8),
                        ChoiceChip(
                          label: const Text('密码'),
                          selected: authType == SshAuthType.password,
                          onSelected: (_) => setState(() {
                            authType = SshAuthType.password;
                            showPwd = false;
                          }),
                        ),
                        const SizedBox(width: 8),
                        ChoiceChip(
                          label: const Text('密钥+密码兜底'),
                          selected: authType == SshAuthType.keyThenPassword,
                          onSelected: (_) => setState(() {
                            authType = SshAuthType.keyThenPassword;
                            showPwd = false;
                          }),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    if (authType != SshAuthType.password) ...[
                      Row(
                        children: [
                          Expanded(
                            child: Text('私钥（PEM / OpenSSH）',
                                style: const TextStyle(fontSize: 13)),
                          ),
                          TextButton.icon(
                            onPressed: () {
                              final keys = SshKeyGen.generate();
                              if (keys == null) return;
                              setState(() {
                                generatedPublicKey = keys.publicKey;
                                genCommand =
                                    _buildRemoteInstallCommand(keys.publicKey);
                                keyCtrl.text = keys.privateKeyPem;
                              });
                            },
                            icon: const Icon(Icons.auto_awesome, size: 16),
                            label: const Text('自动生成',
                                style: TextStyle(fontSize: 12)),
                          ),
                        ],
                      ),
                      TextFormField(
                        controller: keyCtrl,
                        minLines: 3,
                        maxLines: 8,
                        decoration: const InputDecoration(
                          hintText: '-----BEGIN OPENSSH PRIVATE KEY-----',
                          border: OutlineInputBorder(),
                          alignLabelWithHint: true,
                        ),
                        validator: (v) => (v == null || v.trim().isEmpty)
                            ? '请填写私钥，或点「自动生成」'
                            : null,
                      ),
                      if (generatedPublicKey != null) ...[
                        const SizedBox(height: 6),
                        Text('把这条命令在目标机器上执行一次（装公钥）：',
                            style: const TextStyle(fontSize: 11)),
                        const SizedBox(height: 4),
                        _copyableCommand(ctx, genCommand),
                      ],
                      const SizedBox(height: 8),
                      TextField(
                        controller: passPhraseCtrl,
                        obscureText: !showPwd,
                        decoration: InputDecoration(
                          labelText: '私钥口令（无则留空）',
                          border: const OutlineInputBorder(),
                          suffixIcon: IconButton(
                            icon: Icon(showPwd
                                ? Icons.visibility_off
                                : Icons.visibility),
                            onPressed: () => setState(() => showPwd = !showPwd),
                          ),
                        ),
                      ),
                    ],
                    if (authType != SshAuthType.key) ...[
                      const SizedBox(height: 10),
                      TextFormField(
                        controller: passCtrl,
                        obscureText: !showPwd,
                        decoration: InputDecoration(
                          labelText: '登录密码',
                          hintText: storedPassword.isEmpty
                              ? '电脑/Termux 的账号登录密码'
                              : '已保存，留空保持不变',
                          helperText: authType == SshAuthType.keyThenPassword
                              ? '密钥认证失败时自动改用这个密码'
                              : '服务端需允许密码登录（sshd_config：'
                                  'PasswordAuthentication yes）',
                          helperMaxLines: 2,
                          border: const OutlineInputBorder(),
                          suffixIcon: IconButton(
                            icon: Icon(showPwd
                                ? Icons.visibility_off
                                : Icons.visibility),
                            onPressed: () => setState(() => showPwd = !showPwd),
                          ),
                        ),
                        validator: (v) =>
                            (v == null || v.trim().isEmpty) &&
                                    storedPassword.isEmpty
                                ? '请填写密码（或改用密钥认证）'
                                : null,
                      ),
                    ],
                    const SizedBox(height: 8),
                    Text(
                      '密码/私钥保存在系统安全存储中，不会明文写进设置文件；'
                      '留空提交表示保持原凭据不变。',
                      style:
                          TextStyle(fontSize: 11, color: Colors.grey.shade600),
                    ),
                  ],
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () async {
                if (!formKey.currentState!.validate()) return;
                Navigator.pop(ctx, true);
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    // 弹窗关闭即取走文本并释放控制器（原实现从不 dispose，每次弹窗泄漏七个）。
    final nameText = nameCtrl.text.trim();
    final hostText = hostCtrl.text.trim();
    final portText = portCtrl.text.trim();
    final userText = userCtrl.text.trim();
    final keyText = keyCtrl.text.trim();
    final typedPwd = passCtrl.text.trim();
    final passPhraseText = passPhraseCtrl.text;
    for (final c in [
      nameCtrl,
      hostCtrl,
      portCtrl,
      userCtrl,
      passCtrl,
      keyCtrl,
      passPhraseCtrl
    ]) {
      c.dispose();
    }
    if (saved != true) return;
    // 兜底：existing 无稳定 id（旧配置迁移遗漏）→ 分配新 id，避免 upsert 追加。
    final stableId = (cfg?.id.trim().isNotEmpty ?? false)
        ? cfg!.id.trim()
        : 'ssh_${DateTime.now().millisecondsSinceEpoch}';
    final needKey = authType != SshAuthType.password;
    final needPassword = authType != SshAuthType.key;
    await notifier.upsertSshConfig(SshConfig(
      id: stableId,
      name: nameText,
      host: hostText,
      port: int.tryParse(portText) ?? 8022,
      username: userText,
      authType: authType,
      privateKeyPem: needKey ? keyText : null,
      keyPassphrase:
          needKey && passPhraseText.isNotEmpty ? passPhraseText : null,
      // 留空 = 保持安全存储里的原密码（编辑别的字段不该把密码清了）。
      password: needPassword
          ? (typedPwd.isEmpty ? storedPassword : typedPwd)
          : null,
    ));
    if (mounted) setState(() {});
  }

  // ---------------- 工作区 ----------------

  Widget _buildWorkspacesCard(
      InferenceSettings settings, SettingsNotifier notifier) {
    final dev = DevSessionController.instance;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSectionHeader('📁 工作区', context),
            Text(
              '文件/记忆工具跟随激活工作区；远端工作区（Termux/电脑）'
              '用 ssh_exec / ssh_read_file / ssh_write_file 操作。'
              '新增 Termux 工作区时可自动建目录。',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final ws in dev.workspaces)
                  ChoiceChip(
                    label: Text(ws.isDefault ? ws.name : ws.name),
                    selected: dev.activeWorkspaceId == ws.id,
                    onSelected: (_) async {
                      await dev.switchWorkspace(ws.id);
                      await notifier.setDevWorkspaceId(ws.id);
                      if (mounted) setState(() {});
                    },
                  ),
                TextButton.icon(
                  onPressed: () => _showWorkspaceDialog(context, notifier),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('新增'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 新增/编辑工作区对话框。
  Future<void> _showWorkspaceDialog(
      BuildContext context, SettingsNotifier notifier,
      {DevWorkspace? existing}) async {
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final pathCtrl = TextEditingController(text: existing?.remotePath ?? '');
    final formKey = GlobalKey<FormState>();
    var backend = existing?.backend ?? WorkspaceBackend.localApp;
    var sshConfigId = existing?.sshConfigId;
    var creatingDir = false;
    var browsingDir = false;
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: Text(existing == null ? '新增工作区' : '编辑工作区'),
          content: Form(
            key: formKey,
            child: SizedBox(
              width: 460,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    controller: nameCtrl,
                    autofocus: existing == null,
                    decoration: const InputDecoration(
                      labelText: '工作区名称',
                      hintText: '如：TongYi-Lite / 我的博客项目',
                      border: OutlineInputBorder(),
                    ),
                    validator: (v) =>
                        (v == null || v.trim().isEmpty) ? '请填写名称' : null,
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<WorkspaceBackend>(
                    value: backend,
                    decoration: const InputDecoration(
                      labelText: '后端',
                      border: OutlineInputBorder(),
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: WorkspaceBackend.localApp,
                        child: Text('本地沙盒（app 内目录）'),
                      ),
                      DropdownMenuItem(
                        value: WorkspaceBackend.embedded,
                        child: Text('内嵌工具沙箱（本地执行，免配置）'),
                      ),
                      DropdownMenuItem(
                        value: WorkspaceBackend.termux,
                        child: Text('Termux（手机 Linux）'),
                      ),
                      DropdownMenuItem(
                        value: WorkspaceBackend.remotePc,
                        child: Text('远程电脑'),
                      ),
                    ],
                    onChanged: (v) => setState(
                        () => backend = v ?? WorkspaceBackend.localApp),
                  ),
                  if (backend == WorkspaceBackend.termux ||
                      backend == WorkspaceBackend.remotePc) ...[
                    const SizedBox(height: 12),
                    // 绑定连接配置。
                    DropdownButtonFormField<String?>(
                      value: sshConfigId,
                      decoration: const InputDecoration(
                        labelText: '绑定连接配置',
                        border: OutlineInputBorder(),
                      ),
                      items: [
                        const DropdownMenuItem<String?>(
                          value: null,
                          child: Text('自动（第一份可用配置）'),
                        ),
                        for (final cfg in ref.read(settingsProvider).sshConfigs)
                          DropdownMenuItem<String?>(
                            value: cfg.id,
                            child: Text('${cfg.name}（${cfg.host}:${cfg.port}）'),
                          ),
                      ],
                      onChanged: (v) => setState(() => sshConfigId = v),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: pathCtrl,
                      decoration: const InputDecoration(
                        labelText: '远端路径（绝对路径）',
                        hintText: '可手填，或点下方「自动创建目录」',
                        border: OutlineInputBorder(),
                      ),
                      validator: (v) =>
                          (v == null || v.trim().isEmpty) ? '远端路径必填' : null,
                    ),
                    const SizedBox(height: 8),
                    // 两条路：自动建一个 ~/projects/<名称>，或直接浏览远端已有目录。
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: creatingDir
                                ? null
                                : () async {
                                    setState(() => creatingDir = true);
                                    try {
                                      final dir = await _autoCreateRemoteDir(
                                          nameCtrl.text);
                                      if (dir != null && ctx.mounted) {
                                        pathCtrl.text = dir;
                                      } else if (ctx.mounted) {
                                        ScaffoldMessenger.of(ctx).showSnackBar(
                                            const SnackBar(
                                                content: Text('自动创建失败：请先连接开发环境，'
                                                    '或检查用户名/密码')));
                                      }
                                    } finally {
                                      setState(() => creatingDir = false);
                                    }
                                  },
                            icon: const Icon(Icons.create_new_folder, size: 16),
                            label: Text(creatingDir
                                ? '创建中…'
                                : '🔍 自动创建 ~/projects/<名称>'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: browsingDir
                                ? null
                                : () async {
                                    setState(() => browsingDir = true);
                                    try {
                                      final dir = await _browseRemoteDir();
                                      if (dir != null && ctx.mounted) {
                                        pathCtrl.text = dir;
                                      }
                                    } finally {
                                      if (mounted) {
                                        setState(() => browsingDir = false);
                                      }
                                    }
                                  },
                            icon: const Icon(Icons.folder_open, size: 16),
                            label: Text(browsingDir
                                ? '读取中…'
                                : '📂 浏览远端目录'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () async {
                if (!formKey.currentState!.validate()) return;
                Navigator.pop(ctx, true);
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    // 弹窗关闭即取走文本并释放控制器（原实现从不 dispose，每次弹窗泄漏两个）。
    final name = nameCtrl.text.trim();
    final pathText = pathCtrl.text.trim();
    nameCtrl.dispose();
    pathCtrl.dispose();
    if (saved != true) return;
    if (name.isEmpty) return;
    final id = existing?.id ?? 'ws_${DateTime.now().millisecondsSinceEpoch}';
    await DevSessionController.instance.upsertWorkspace(DevWorkspace(
      id: id,
      name: name,
      backend: backend,
      remotePath: backend.isRemoteBackend ? pathText : null,
      sshConfigId: backend.isRemoteBackend ? sshConfigId : null,
    ));
    if (mounted) setState(() {});
  }

  /// 自动创建远端目录：连接后 `echo $HOME` + `mkdir -p ~/projects/<safe>`。
  /// （建目录本体在 `ensureRemoteProjectDir`，与聊天页的"一键开工"共用同一条路。）
  Future<String?> _autoCreateRemoteDir(String name) async {
    final ssh = SshEnvironmentService.instance;
    var cfg = ssh.isConnected ? ssh.activeConfig : null;
    cfg ??= ref
        .read(settingsProvider)
        .sshConfigs
        .where((c) => c.isComplete)
        .firstOrNull;
    if (cfg == null) return null;
    if (!await ssh.ensureConnected(cfg)) return null;
    return ensureRemoteProjectDir(name);
  }

  /// 远端目录浏览器：`ls -1p` 列子目录 → 点进去/上一级 → 「选中此目录」回填。
  /// 返回**绝对路径**（`~` 会解析成远端家目录）；取消返回 null。
  Future<String?> _browseRemoteDir() async {
    final ssh = SshEnvironmentService.instance;
    var path = '~';
    for (;;) {
      List<String> dirs;
      try {
        dirs = await listRemoteDirs(path: path);
      } on Exception catch (e) {
        if (!mounted) return null;
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('列目录失败：$e（可先点「连接」）')));
        return null;
      }
      if (!mounted) return null;
      final at = path == '~' ? '家目录 ~' : path;
      final picked = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('选择远端项目目录'),
          content: SizedBox(
            width: 420,
            height: 320,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('当前：$at',
                    style: const TextStyle(
                        fontSize: 12, fontFamily: 'monospace')),
                const SizedBox(height: 6),
                if (path != '~')
                  TextButton.icon(
                    onPressed: () => Navigator.pop(ctx, '__up__$path'),
                    icon: const Icon(Icons.arrow_upward, size: 16),
                    label: const Text('上一级', style: TextStyle(fontSize: 12)),
                  ),
                Expanded(
                  child: dirs.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text('这个目录下没有子目录（或不可读）。',
                              style: TextStyle(
                                  fontSize: 12, color: Colors.grey.shade600)),
                        )
                      : ListView.builder(
                          itemCount: dirs.length,
                          itemBuilder: (_, i) {
                            final d = dirs[i];
                            return ListTile(
                              dense: true,
                              leading: const Icon(Icons.folder, size: 18),
                              title: Text(d.split('/').last,
                                  style: const TextStyle(fontSize: 13)),
                              onTap: () => Navigator.pop(ctx, '__in__$d'),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('取消')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, path),
                child: const Text('选中此目录')),
          ],
        ),
      );
      if (picked == null) return null;
      if (picked.startsWith('__in__')) {
        path = picked.substring(6);
        continue;
      }
      if (picked.startsWith('__up__')) {
        final cur = picked.substring(6);
        final i = cur.lastIndexOf('/');
        path = i <= 0 ? '~' : cur.substring(0, i);
        continue;
      }
      if (picked == '~' || picked == r'$HOME') {
        final home = await ssh.run('echo \$HOME',
            timeout: const Duration(seconds: 30));
        final h = home?.trim() ?? '';
        return h.isEmpty ? null : h;
      }
      return picked;
    }
  }

  // ---------------- 任务与规划 ----------------

  /// 任务按激活工作区过滤（默认工作区收编无主任务），新更新的在前。
  Future<void> _reloadDevTasks() async {
    try {
      final dev = DevSessionController.instance;
      await dev.init();
      final all = await DevStore().loadTasks();
      final wsId = dev.activeWorkspaceId;
      all.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      if (!mounted) return;
      setState(() {
        _devTasks = [
          for (final t in all)
            if (taskBelongsToWorkspace(t, wsId)) t,
        ];
        _devTasksLoaded = true;
      });
    } catch (_) {
      if (mounted) _devTasksLoaded = true;
    }
  }

  static const _devTaskStatusLabels = {
    DevTaskStatus.planning: '规划中',
    DevTaskStatus.implementing: '实施中',
    DevTaskStatus.verifying: '验证中',
    DevTaskStatus.done: '已完成',
    DevTaskStatus.blocked: '受阻',
  };

  Widget _buildDevTasksCard(
      InferenceSettings settings, SettingsNotifier notifier) {
    final dev = DevSessionController.instance;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSectionHeader('📋 任务与规划', context),
            Text(
              '规划归属于工作区；点任务行设为当前任务（智能体上下文会注入其计划）。'
              '也可以直接在对话里让智能体 task_create。',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
            const SizedBox(height: 8),
            if (!_devTasksLoaded)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('加载中…', style: TextStyle(fontSize: 12)),
              )
            else if (_devTasks.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(
                  '当前工作区还没有任务',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
                ),
              )
            else
              for (final t in _devTasks)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Row(
                    children: [
                      Flexible(
                        child: Text(
                          t.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                      if (dev.activeTaskId == t.id) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            color:
                                Theme.of(context).colorScheme.primaryContainer,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child:
                              const Text('当前', style: TextStyle(fontSize: 10)),
                        ),
                      ],
                    ],
                  ),
                  subtitle: Text(
                    '${_devTaskStatusLabels[t.status] ?? t.status.name}'
                    '${t.plan != null && t.plan!.steps.isNotEmpty ? ' · 进度 ${t.plan!.steps.where((s) => s.done).length}/${t.plan!.steps.length}' : ''}',
                    style: const TextStyle(fontSize: 11),
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline, size: 18),
                    tooltip: '删除任务',
                    onPressed: () => _confirmDeleteDevTask(t),
                  ),
                  onTap: () async {
                    await DevSessionController.instance.setActiveTask(t.id);
                    if (mounted) {
                      setState(() {});
                      ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('已设为当前任务：${t.title}')));
                    }
                  },
                ),
            const SizedBox(height: 4),
            FilledButton.icon(
              onPressed: () => _showNewDevTaskDialog(context),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('新建规划'),
            ),
          ],
        ),
      ),
    );
  }

  /// 新建规划：标题 + 工作区选择（默认当前激活工作区）。
  Future<void> _showNewDevTaskDialog(BuildContext context) async {
    final dev = DevSessionController.instance;
    final titleCtrl = TextEditingController();
    final formKey = GlobalKey<FormState>();
    var workspaceId = dev.activeWorkspaceId;
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新建规划'),
        content: Form(
          key: formKey,
          child: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextFormField(
                  controller: titleCtrl,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: '任务标题',
                    hintText: '如：给搜索结果加缓存',
                    border: OutlineInputBorder(),
                  ),
                  validator: (v) =>
                      (v == null || v.trim().isEmpty) ? '请填写标题' : null,
                ),
                const SizedBox(height: 12),
                const Text('所属工作区',
                    style: TextStyle(fontSize: 12, color: Colors.grey)),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final ws in dev.workspaces)
                      ChoiceChip(
                        label: Text(ws.name),
                        selected: workspaceId == ws.id,
                        onSelected: (_) => workspaceId = ws.id,
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (!formKey.currentState!.validate()) return;
              Navigator.pop(ctx, true);
            },
            child: const Text('创建'),
          ),
        ],
      ),
    );
    // 弹窗关闭即取走标题并释放控制器（原实现从不 dispose，每次弹窗泄漏）。
    final title = titleCtrl.text.trim();
    titleCtrl.dispose();
    if (saved != true) return;
    if (title.isEmpty) return;
    final task = DevTask(
      id: newDevTaskId(),
      title: title,
      workspaceId: workspaceId == DevWorkspace.kDefaultId ? null : workspaceId,
      status: DevTaskStatus.planning,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
    await DevStore().saveTask(task);
    await dev.setActiveTask(task.id);
    await _reloadDevTasks();
    if (mounted) {
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('已创建「$title」并设为当前任务，'
              '对话里可让智能体 plan_create 填步骤')));
    }
  }

  Future<void> _confirmDeleteDevTask(DevTask t) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除任务'),
        content: Text('确定删除「${t.title}」？其计划将一并删除。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (ok != true) return;
    await DevStore().deleteTask(t.id);
    if (DevSessionController.instance.activeTaskId == t.id) {
      await DevSessionController.instance.setActiveTask(null);
    }
    await _reloadDevTasks();
  }

  // ---------------- 安全策略 ----------------

  Widget _buildSafetyCard(
      InferenceSettings settings, SettingsNotifier notifier) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSectionHeader('🛡️ 危险命令策略', context),
            Row(
              children: [
                ChoiceChip(
                  label: const Text('拒绝'),
                  selected: settings.dangerousCommandPolicy == 'deny',
                  onSelected: (_) => notifier.setDangerousCommandPolicy('deny'),
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: const Text('每次审批'),
                  selected: settings.dangerousCommandPolicy == 'ask',
                  onSelected: (_) => notifier.setDangerousCommandPolicy('ask'),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '拒绝 = 黑名单命令直接拦截（rm -rf /、reboot、git push --force 等）；'
              '每次审批 = 转用户确认。',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
            ),
          ],
        ),
      ),
    );
  }
}

/// Termux sshd 探测结论（`_probeSshd`）。
enum _SshdProbe { listening, refused, timeout }

