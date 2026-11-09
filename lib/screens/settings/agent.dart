part of '../settings_screen.dart';

class AgentSettingsBody extends ConsumerStatefulWidget {
  const AgentSettingsBody();

  @override
  ConsumerState<AgentSettingsBody> createState() => AgentSettingsBodyState();
}


class AgentSettingsBodyState extends ConsumerState<AgentSettingsBody> {

  /// 全局记忆条目（null = 加载中；记忆管理卡用）。
  List<MapEntry<String, String>>? _memoryEntries;

  /// 全局 AGENTS.md 路径与字节数（-1 = 不存在）。
  String? _agentsMdPath;
  int _agentsMdLen = -1;

  /// 开发模式状态监听：SSH 连接/工作区激活是异步后台变化，
  /// 必须监听 ChangeNotifier 才能实时刷新（否则"测试连接成功但页面显示未连接"）。
  VoidCallback? _devStateListener;


  @override
  void initState() {
    super.initState();
    _loadAgentsMdInfo();
    _loadMemoryEntries();
    final listener = () {
      if (mounted) setState(() {});
    };
    _devStateListener = listener;
    SshEnvironmentService.instance.addListener(listener);
    DevSessionController.instance.addListener(listener);
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

  // ================= 记忆管理（查看/删除，与 memory.json 同存储） =================

  Future<void> _loadMemoryEntries() async {
    final entries =
        await readGlobalMemorySnapshot(maxEntries: 100, maxValueChars: 200);
    if (!mounted) return;
    setState(() => _memoryEntries = entries);
  }

  Future<void> _confirmDeleteMemoryEntry(String key) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除记忆：$key'),
        content: const Text('删除后智能体将不再记得该条内容，无法恢复。'),
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
    await deleteGlobalMemoryEntry(key);
    await _loadMemoryEntries();
  }

  Future<void> _confirmClearMemory() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空全部记忆'),
        content: const Text('将删除全部长期记忆条目，无法恢复。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('清空')),
        ],
      ),
    );
    if (ok != true) return;
    await clearGlobalMemory();
    await _loadMemoryEntries();
  }

  /// 记忆管理列表（嵌在长期记忆开关下方；随开关关闭置灰）。
  Widget _buildMemoryManager(bool enabled) {
    final entries = _memoryEntries;
    if (!enabled) {
      return const Padding(
        padding: EdgeInsets.only(left: 16, right: 16, bottom: 8),
        child: Text('已关闭；开启后自动注入每回合系统提示',
            style: TextStyle(fontSize: 12, color: Colors.grey)),
      );
    }
    if (entries == null) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: SizedBox(
            height: 20,
            width: 20,
            child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    if (entries.isEmpty) {
      return const Padding(
        padding: EdgeInsets.only(left: 16, right: 16, bottom: 8),
        child: Text('暂无记忆。对话里说"记住……"即可写入',
            style: TextStyle(fontSize: 12, color: Colors.grey)),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(left: 16, right: 16, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final e in entries)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text('${e.key}: ${e.value}',
                        style: const TextStyle(fontSize: 12)),
                  ),
                  InkWell(
                    onTap: () => _confirmDeleteMemoryEntry(e.key),
                    child:
                        const Icon(Icons.close, size: 16, color: Colors.grey),
                  ),
                ],
              ),
            ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: _confirmClearMemory,
              child: const Text('清空全部', style: TextStyle(fontSize: 12)),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _loadAgentsMdInfo() async {
    final base = await getApplicationSupportDirectory();
    final file = File(p.join(base.path, 'AGENTS.md'));
    if (!mounted) return;
    setState(() {
      _agentsMdPath = file.path;
      _agentsMdLen = file.existsSync() ? file.lengthSync() : -1;
    });
  }

  // ================= ⑤ 用户技能管理（直接落盘 SKILL.md） =================

  /// 查看内置技能内容（只读），可「另存为我的技能」 customized 后覆盖内置。
  /// 编辑自定义热词（多行文本，每行一个；随设置持久化）。
  /// P2-B：添加 MCP server（名称 + 端点 URL）。
  Future<void> _showAddMcpServerDialog(SettingsNotifier notifier) async {
    final nameCtrl = TextEditingController();
    final urlCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('添加 MCP server'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              decoration:
                  const InputDecoration(labelText: '名称（工具前缀 mcp_<名称>_）'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: urlCtrl,
              decoration: const InputDecoration(
                  labelText: '端点 URL（如 http://主机:3000/mcp）'),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('保存')),
        ],
      ),
    );
    // 弹窗关闭即取走文本并释放控制器（原实现从不 dispose，每次弹窗泄漏两个）。
    final name = nameCtrl.text.trim();
    final url = urlCtrl.text.trim();
    nameCtrl.dispose();
    urlCtrl.dispose();
    if (ok != true) return;
    if (name.isEmpty || url.isEmpty) return;
    await notifier.upsertMcpServer(McpServerConfig(
      id: 'mcp_${DateTime.now().millisecondsSinceEpoch}',
      name: name,
      url: url,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);

    // ---- 能力快照（与 chat_provider._engineCapabilitiesFor 同源规则）----
    // api → 原生工具调用 + 并行 5；local/跟随默认 → Prompt-JSON + 并行 2。
    final isApi = settings.agentModelSource == 'api';
    final capsMaxParallel = isApi ? 5 : 2;
    // ---- 双场景档：API 档读写 agentApi* 专键，local 档读写原平铺键 ----
    final profMaxRounds =
        isApi ? settings.agentApiMaxRounds : settings.agentMaxRounds;
    final profTokensPerRound =
        isApi ? settings.agentApiTokensPerRound : settings.agentTokensPerRound;
    final profToolTimeoutMs =
        isApi ? settings.agentApiToolTimeoutMs : settings.agentToolTimeoutMs;
    final profTemperature =
        isApi ? settings.agentApiTemperature : settings.agentTemperature;
    final profAllowParallel = isApi
        ? settings.agentApiAllowParallelTools
        : settings.agentAllowParallelTools;
    final profMaxParallel =
        isApi ? settings.agentApiMaxParallel : settings.agentMaxParallel;
    final profTokensMax = isApi ? 32768 : 16384;
    final effectiveParallel = profAllowParallel ? profMaxParallel : 1;
    final parallelNote = isApi
        ? 'API 路线能力上限 5 路；实际并发 = min(设置值, 能力上限)'
        : '本地路线能力上限 2 路（prompt-JSON 协议）；实际并发 = min(设置值, 2)';

    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ============ ⓪ 智能体模式总开关（首排） ============
          // 关闭 = 普通聊天：不注入系统提示词/工具定义/AGENTS.md/Skills，
          // prefill 最小，本地小模型友好；打开才走工具循环。
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: _buildToggleTitle(
                '🤖 智能体模式',
                settings.agentEnabled,
                notifier.setAgentEnabled,
                subtitle: settings.agentEnabled
                    ? '开：走智能体循环（注入系统提示词 + 工具定义，可多步调用工具）'
                    : '关：简单聊天直连模型，不注入系统提示词/工具说明，'
                        'prefill 最小；下方所有智能体设置暂不生效',
              ),
            ),
          ),

          const SizedBox(height: 10),

          // ================= ⓪b 对话区文字大小（不受智能体开关门控）=================
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: _buildSliderRow(
                label: '对话文字大小',
                value: (settings.chatTextScale * 100).round(),
                min: 70,
                max: 130,
                divisions: 12,
                display: '${(settings.chatTextScale * 100).round()}%',
                onChanged: (v) => notifier.setChatTextScale(v / 100),
                hint: '对话区文字整体缩放（气泡/思考/工具卡/时间戳），'
                    '默认 100% = 当前字号，可放大缩小前后 30%',
              ),
            ),
          ),

          const SizedBox(height: 10),

          // 关闭总开关时置灰全部子项（不可交互，直观反映"暂不生效"）。
          Opacity(
            opacity: settings.agentEnabled ? 1.0 : 0.45,
            child: IgnorePointer(
              ignoring: !settings.agentEnabled,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ================= ① 引擎状态（能力总览）=================
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SizedBox(height: 8),
                          _buildSectionHeader('🤖 驱动模型', context),
                          const Text(
                            '指定智能体由哪个模型驱动；能力徽标随选择实时变化',
                            style: TextStyle(fontSize: 12, color: Colors.grey),
                          ),
                          const SizedBox(height: 8),
                          _buildAgentModelSelector(context, ref, settings),
                          const SizedBox(height: 10),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              _capChip(isApi ? '场景档：API 档' : '场景档：本地档',
                                  ok: true),
                              _capChip(isApi ? '协议：原生工具调用' : '协议：Prompt-JSON',
                                  ok: true),
                              _capChip('工具调用：支持', ok: true),
                              _capChip('并行上限：$capsMaxParallel 路',
                                  ok: capsMaxParallel > 1),
                              _capChip(
                                  isApi
                                      ? '上下文：由服务端决定'
                                      : '上下文：${settings.agentNctx} tok',
                                  ok: true),
                              _capChip('上下文压缩',
                                  ok: settings.agentCompactEnabled),
                              _capChip('输出溢写', ok: settings.agentSpillEnabled),
                              _capChip('子代理',
                                  ok: settings.agentSubagentEnabled),
                            ],
                          ),
                          const SizedBox(height: 12),
                          _buildPromptTierRow(settings, notifier, isApi: isApi),
                        ],
                      ),
                    ),
                  ),

                  // ================= ①b 人格 =================
                  // 人格卡已撤（2026-10-25 用户定案）：人格有独立侧栏面板
                  // （切换/新建/编辑/删除都在那里），这里不再重复一份。

                  const SizedBox(height: 10),

                  // ================= ② 核心执行参数 =================
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildSectionHeader('🔁 执行参数', context),
                          _buildSliderRow(
                            label: '单轮最大步数',
                            value: profMaxRounds,
                            min: 1,
                            max: 100,
                            divisions: 99,
                            display: '$profMaxRounds 步',
                            onChanged: (v) => isApi
                                ? notifier.setAgentApiMaxRounds(v)
                                : notifier.setAgentMaxRounds(v),
                            hint: '一次提问内最多几次模型请求（含工具往返）；'
                                '${isApi ? 'API 档默认 16' : '端侧建议 3–12（默认 12）'}，'
                                '复杂任务可调到 100',
                          ),
                          _buildSliderRow(
                            label: '并发会话槽位',
                            value: settings.agentMaxConcurrentTurns,
                            min: 1,
                            max: 4,
                            divisions: 3,
                            display: '${settings.agentMaxConcurrentTurns} 个',
                            onChanged: (v) =>
                                notifier.setAgentMaxConcurrentTurns(v),
                            hint: '同时允许执行回合的会话数量（默认 1）。'
                                'API 驱动可真正并行；本地模型受引擎限制，'
                                '同一时刻仍只能跑一个会话，其余会提示槽位已满',
                          ),
                          _buildSliderRow(
                            label: '每回合搜索上限',
                            value: settings.agentMaxSearchesPerTurn,
                            min: 1,
                            max: 10,
                            divisions: 9,
                            display: '${settings.agentMaxSearchesPerTurn} 次',
                            onChanged: (v) =>
                                notifier.setAgentMaxSearchesPerTurn(v),
                            hint: 'web_search 每回合最多调用次数（DSH max_uses 语义，默认 5）；'
                                '达到上限拒绝联网、强制基于已有结果回答，杜绝反复搜索',
                          ),
                          _buildSliderRow(
                            label: '每步生成预算',
                            value: profTokensPerRound,
                            min: 128,
                            max: profTokensMax,
                            divisions: (profTokensMax - 128) ~/ 256,
                            display: _formatKValue(profTokensPerRound, 'token'),
                            onChanged: (v) => isApi
                                ? notifier.setAgentApiTokensPerRound(v)
                                : notifier.setAgentTokensPerRound(v),
                            hint: isApi
                                ? 'API 档每步生成 token 上限（默认 8192，云端模型吃满思考）'
                                : '本地档每步生成 token 上限（默认 1024）',
                          ),
                          _buildSliderRow(
                            label: '工具执行超时',
                            value: profToolTimeoutMs,
                            min: 1000,
                            max: 120000,
                            divisions: 119,
                            display: _formatTimeout(profToolTimeoutMs),
                            onChanged: (v) => isApi
                                ? notifier.setAgentApiToolTimeoutMs(v)
                                : notifier.setAgentToolTimeoutMs(v),
                            hint: '单工具超时，防止卡死循环；工具自声明超时优先'
                                '（${isApi ? 'API 档默认 30 秒' : '本地档默认 15 秒'}）',
                          ),
                          _buildDoubleSliderRow(
                            label: '生成温度',
                            value: profTemperature,
                            min: 0.0,
                            max: 2.0,
                            divisions: 20,
                            display: profTemperature.toStringAsFixed(1),
                            onChanged: (v) => isApi
                                ? notifier.setAgentApiTemperature(v)
                                : notifier.setAgentTemperature(v),
                            hint: '工具决策建议 0.3–0.7；创意直答可到 1.0+（默认 0.7）',
                          ),
                          _buildSliderRow(
                            label: '思考失控守卫阈值',
                            value: settings.agentThinkingMaxChars,
                            min: 1000,
                            max: 65536,
                            divisions: 129,
                            display: settings.agentThinkingMaxChars >= 1000
                                ? '${(settings.agentThinkingMaxChars / 1000).toStringAsFixed(1)}k 字'
                                : '${settings.agentThinkingMaxChars} 字',
                            onChanged: (v) =>
                                notifier.setAgentThinkingMaxChars(v),
                            hint: '按**累计**思考字数计（多段思考连写也合计，默认 6000）；'
                                '超限且还没产出答案/工具调用即主动止损。'
                                '确实需要长推理的模型调大此值',
                          ),
                          SwitchListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: const Text('工具步也允许思考',
                                style: TextStyle(fontSize: 13)),
                            subtitle: Text(
                              '默认关：智能体的工具决策步不思考（只需产出一次工具调用），'
                              '端侧思考失控（动辄几万字独白把预算吃光）几乎都发生在那一步；'
                              '组织最终答案时仍允许思考。打开 = 每步都允许（同旧版行为）',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 11, color: Colors.grey[600]),
                            ),
                            value: settings.agentThinkingOnToolSteps,
                            onChanged: (v) =>
                                notifier.setAgentThinkingOnToolSteps(v),
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 10),

                  // ================= ②a 执行质量观测（C3） =================
                  _ExecutionQualityCard(),

                  const SizedBox(height: 10),

                  // ================= ②b API 档专属参数（仅 API 驱动可见）=================
                  // 这些参数只对云端 API 驱动有意义；本地短 KV 模型驱动时整卡
                  // 隐藏，不再让不生效的配置淹没本地用户。
                  if (isApi) ...[
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _buildSectionHeader('☁️ API 档专属', context),
                            Text(
                              '仅 API 接入驱动智能体时生效；切回本地模型驱动时'
                              '本卡自动隐藏',
                              style: TextStyle(
                                  fontSize: 12, color: Colors.grey.shade600),
                            ),
                            _buildSliderRow(
                              label: '目标无人值守轮数',
                              value: settings.agentGoalMaxRounds,
                              min: 1,
                              max: 20,
                              divisions: 19,
                              display: '${settings.agentGoalMaxRounds} 轮',
                              onChanged: (v) =>
                                  notifier.setAgentGoalMaxRounds(v),
                              hint: 'goal 未完成时自动续跑的最大回合数'
                                  '（goal_set/exit_plan 生效，默认 8）',
                            ),
                            _buildSliderRow(
                              label: 'API 上下文压缩预算',
                              value: settings.agentApiContextBudget,
                              min: 4096,
                              max: 131072,
                              divisions: 31,
                              display: _formatKValue(
                                  settings.agentApiContextBudget, 'token'),
                              onChanged: (v) =>
                                  notifier.setAgentApiContextBudget(v),
                              hint: '投影历史超此值即自动压缩（默认 32k）；'
                                  '配置了端点窗口时取较小值',
                            ),
                            // 子代理专用模型（P3-2）：重活/子任务可走更便宜的
                            // API 配置，主回答仍走主模型。
                            if (settings.agentSubagentEnabled &&
                                settings.apiModels.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(
                                    left: 4, right: 4, top: 8),
                                child: DropdownButtonFormField<String>(
                                  value: settings.agentSubagentApiModelId,
                                  isDense: true,
                                  isExpanded: true,
                                  decoration: const InputDecoration(
                                    labelText: '子代理专用模型',
                                    hintText: '跟随主模型',
                                    isDense: true,
                                    border: OutlineInputBorder(),
                                  ),
                                  items: [
                                    const DropdownMenuItem(
                                        value: '', child: Text('跟随主模型')),
                                    for (final cfg in settings.apiModels)
                                      DropdownMenuItem(
                                          value: cfg.id,
                                          child: Text(cfg.name,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis)),
                                  ],
                                  onChanged: (v) => notifier
                                      .setAgentSubagentApiModelId(v ?? ''),
                                ),
                              ),
                            // 压缩摘要专用模型（P1-B 按步模型路由）：上下文
                            // 压缩的旧区摘要交给更便宜的模型。
                            if (settings.agentCompactEnabled &&
                                settings.apiModels.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(
                                    left: 4, right: 4, top: 8),
                                child: DropdownButtonFormField<String>(
                                  value: settings.agentCompressionApiModelId,
                                  isDense: true,
                                  isExpanded: true,
                                  decoration: const InputDecoration(
                                    labelText: '压缩摘要专用模型',
                                    hintText: '跟随子代理模型',
                                    isDense: true,
                                    border: OutlineInputBorder(),
                                  ),
                                  items: [
                                    const DropdownMenuItem(
                                        value: '', child: Text('跟随子代理模型')),
                                    for (final cfg in settings.apiModels)
                                      DropdownMenuItem(
                                          value: cfg.id,
                                          child: Text(cfg.name,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis)),
                                  ],
                                  onChanged: (v) => notifier
                                      .setAgentCompressionApiModelId(v ?? ''),
                                ),
                              ),
                            const Divider(height: 20),
                            _buildSectionHeader('🔌 MCP 远程工具', context),
                            if (settings.mcpServers.isEmpty)
                              Text(
                                  '暂未配置。可接入任意 MCP server（Streamable HTTP）'
                                  '扩展工具生态。',
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.grey.shade600))
                            else
                              for (final s in settings.mcpServers)
                                ListTile(
                                  contentPadding: EdgeInsets.zero,
                                  dense: true,
                                  visualDensity: VisualDensity.compact,
                                  leading: Icon(s.enabled
                                      ? Icons.lan
                                      : Icons.lan_outlined),
                                  title: Text(s.name,
                                      style: const TextStyle(fontSize: 14)),
                                  subtitle: Text(s.url,
                                      style: const TextStyle(
                                          fontSize: 11, color: Colors.grey)),
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Switch(
                                        value: s.enabled,
                                        onChanged: (v) =>
                                            notifier.upsertMcpServer(
                                                s.copyWith(enabled: v)),
                                      ),
                                      IconButton(
                                        icon: const Icon(Icons.delete_outline,
                                            size: 18),
                                        onPressed: () =>
                                            notifier.removeMcpServer(s.id),
                                      ),
                                    ],
                                  ),
                                ),
                            TextButton.icon(
                              onPressed: () =>
                                  _showAddMcpServerDialog(notifier),
                              icon: const Icon(Icons.add, size: 16),
                              label: const Text('添加 MCP server'),
                            ),
                            Text(
                              '填远程 MCP 端点（如 http://主机:3000/mcp）；'
                              '工具以 mcp_<服务>_<名> 注册，失败自动跳过。',
                              style: TextStyle(
                                  fontSize: 11, color: Colors.grey.shade500),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                  ],

                  // ================= ②c 本地档专属参数（仅本地模型驱动可见）=================
                  if (!isApi) ...[
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _buildSectionHeader('📱 本地档专属', context),
                            Text(
                              '仅本地模型驱动智能体时生效；这些参数面向端侧短 KV '
                              '上下文，切到 API 驱动时本卡自动隐藏',
                              style: TextStyle(
                                  fontSize: 12, color: Colors.grey.shade600),
                            ),
                            _buildSliderRow(
                              label: '智能体上下文长度',
                              value: settings.agentNctx,
                              min: 1024,
                              max: 65536,
                              divisions: 63,
                              display:
                                  _formatKValue(settings.agentNctx, 'token'),
                              onChanged: (v) => notifier.setAgentNctx(v),
                              hint: '本地引擎 n_ctx，独立于普通聊天；工具历史越多'
                                  '所需越大（默认 8192）。修改后需重载模型生效',
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                  ],

                  const SizedBox(height: 10),

                  // ================= ③ 上下文管理 =================
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildSectionHeader('🗜️ 上下文管理', context),
                          _buildToggleTitle(
                            '超限自动压缩',
                            settings.agentCompactEnabled,
                            notifier.setAgentCompactEnabled,
                            subtitle: '上下文超限时自动裁剪旧轮工具结果（追加摘要 + 影子遮蔽，'
                                '日志永不删原文）。关闭 = 超限直接报错终止',
                          ),
                          const Divider(height: 24),
                          _buildToggleTitle(
                            '超长工具输出溢写',
                            settings.agentSpillEnabled,
                            notifier.setAgentSpillEnabled,
                            subtitle: '单条工具结果超过约 4k token 时落盘，模型侧只留摘要与文件定位，'
                                '可按需读回；省上下文显著',
                          ),
                          const Divider(height: 24),
                          _buildToggleTitle(
                            '回合轨迹落盘（排障/评估）',
                            settings.agentTraceExportEnabled,
                            notifier.setAgentTraceExportEnabled,
                            subtitle:
                                '每回合把完整事件流写 ApplicationSupport/traces/*.jsonl，'
                                '供离线回放与质量评估；默认关',
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 10),

                  // ================= ④ 能力与并行 =================
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildSectionHeader('🧩 能力与并行', context),
                          _buildToggleTitle(
                            '🛠️ 并行工具调用',
                            profAllowParallel,
                            isApi
                                ? notifier.setAgentApiAllowParallelTools
                                : notifier.setAgentAllowParallelTools,
                            subtitle: '模型一次要多个工具时并发执行（$parallelNote）；'
                                '当前生效并发：$effectiveParallel',
                          ),
                          if (profAllowParallel && capsMaxParallel > 2)
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: _buildSliderRow(
                                label: '并发上限',
                                value: profMaxParallel
                                    .clamp(2, capsMaxParallel)
                                    .toInt(),
                                min: 2,
                                max: capsMaxParallel,
                                divisions: capsMaxParallel - 1,
                                display:
                                    '${profMaxParallel.clamp(2, capsMaxParallel)} 路',
                                onChanged: (v) => isApi
                                    ? notifier.setAgentApiMaxParallel(v)
                                    : notifier.setAgentMaxParallel(v),
                                hint: '同时执行的工具数上限（按驱动模型能力封顶 $capsMaxParallel）',
                              ),
                            )
                          else if (settings.agentAllowParallelTools)
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                '本地路线并发固定 2 路（能力上限）；换 API 驱动可调更高',
                                style: TextStyle(
                                    fontSize: 12, color: Colors.grey.shade600),
                              ),
                            ),
                          const Divider(height: 24),
                          _buildToggleTitle(
                            '🤝 子代理（subagent）',
                            settings.agentSubagentEnabled,
                            notifier.setAgentSubagentEnabled,
                            subtitle: '模型可派生独立子代理执行大任务的子任务（spawn/fork）。'
                                '固定约束：嵌套 ≤ 2 层、子代理内不可申请沙箱升级、每层独立预算',
                          ),
                          // 子代理/压缩摘要专用模型（API 档专属）已移入
                          // 「☁️ API 档专属」卡。
                          const Divider(height: 24),
                          _buildToggleTitle(
                            '🌐 联网搜索',
                            settings.webSearchEnabled,
                            notifier.setWebSearchEnabled,
                            subtitle:
                                '允许调用 web_search/get_weather（实例地址在「API 接入」页配置）',
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 10),

                  // ================= ⑤ 指令文件 =================
                  // Skills 管理已独立到「能力」Tab 的技能卡（2026-10-25 用户
                  // 定案：两处重复列表，智能体 Tab 不再放）。
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildSectionHeader('📄 指令文件', context),

                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            leading: const Icon(Icons.description_outlined),
                            title: Text(
                              _agentsMdLen < 0
                                  ? 'AGENTS.md 指令文件（未创建）'
                                  : 'AGENTS.md 指令文件（${_agentsMdLen} 字节）',
                              style: const TextStyle(fontSize: 14),
                            ),
                            subtitle: const Text('注入系统提示的全局指令（角色、偏好、约束），点按编辑',
                                style: TextStyle(fontSize: 12)),
                            trailing: const Icon(Icons.edit_outlined, size: 18),
                            onTap: _editAgentsMd,
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 10),

                  // ================= ⑥ 工具 =================
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildSectionHeader('🧰 工具', context),
                          Text(
                            '核心工具恒可用：时间 / 计算 / 待办 / 便签 / 单位换算 / 文件读写检索。'
                            '以下高级工具按需开启：',
                            style: TextStyle(
                                fontSize: 12, color: Colors.grey.shade600),
                          ),
                          const SizedBox(height: 4),
                          SwitchListTile(
                            title: const Text('🖥️ Shell 执行（shell_exec）',
                                style: TextStyle(fontSize: 14)),
                            subtitle: const Text(
                                '设备 shell 命令执行（app 权限内），逐次弹窗审批',
                                style: TextStyle(fontSize: 12)),
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            value: settings.agentShellEnabled,
                            onChanged: notifier.setAgentShellEnabled,
                          ),
                          SwitchListTile(
                            title: const Text('🐍 Python 执行（python_exec）',
                                style: TextStyle(fontSize: 14)),
                            subtitle: const Text(
                                '嵌入式 CPython 跑脚本（计算/数据处理/文件/网络）',
                                style: TextStyle(fontSize: 12)),
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            value: settings.agentPythonEnabled,
                            onChanged: notifier.setAgentPythonEnabled,
                          ),
                          SwitchListTile(
                            title: const Text(
                                '🧠 长期记忆（memory_set / memory_get）',
                                style: TextStyle(fontSize: 14)),
                            subtitle: const Text(
                                '跨会话持久记忆（默认开）：模型可记住偏好/事实，'
                                '并自动注入每回合系统提示',
                                style: TextStyle(fontSize: 12)),
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            value: settings.agentMemoryEnabled,
                            onChanged: (v) {
                              notifier.setAgentMemoryEnabled(v);
                              _loadMemoryEntries();
                            },
                          ),
                          _buildMemoryManager(settings.agentMemoryEnabled),
                          SwitchListTile(
                            title: const Text('📂 完整文件访问授权',
                                style: TextStyle(fontSize: 14)),
                            subtitle: const Text(
                                '允许经逐次批准访问公共目录/完整文件系统'
                                '（All-Files-Access，默认关）',
                                style: TextStyle(fontSize: 12)),
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            value: settings.agentFullFileAccess,
                            onChanged: notifier.setAgentFullFileAccess,
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 10),

                  // ================= ⑦ 高级 / 开发者 =================
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildSectionHeader('🧪 高级 / 开发者', context),
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            leading: const Icon(Icons.folder_outlined),
                            title: const Text('智能体数据目录',
                                style: TextStyle(fontSize: 14)),
                            subtitle: const Text(
                                '会话事件日志(JSONL) / 溢写文件 / 技能 / AGENTS.md',
                                style: TextStyle(fontSize: 12)),
                            trailing: const Icon(Icons.chevron_right, size: 18),
                            onTap: _showDataDirs,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '扩展接缝（代码级）：agent/pre-step 可否决单步；tools/result 只读审计；'
                            '流水线 pre/post-execute 可拦截改写。',
                            style: TextStyle(
                                fontSize: 11, color: Colors.grey.shade500),
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 10),


                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------- 小部件 ----------------

  /// 能力徽标：绿=支持/开，灰=关或不可用。
  /// 智能体提示词档位（2026-10-27 K90 真机定案）。
  ///
  /// 精简档是给**本地小模型**的：短身份 + 4 条工具纪律 + 核心工具白名单，
  /// 技能目录与 AGENTS.md 不再常驻 prefill。真机（K90/Adreno 830 +
  /// Ling-3.0-tiny Q4_0 OpenCL）实测：完整档系统提示 19507 字符 / 4580 token
  /// 时，tiny 模型整回合不调工具却输出「已查询到当前天气」「文件已保存
  /// /home/user/go.py」——答非所问的根因是提示词体量，不是后端。
  /// API 档恒为完整档（大模型扛得住完整纪律，瘦身反降工具遵循率）。
  Widget _buildPromptTierRow(InferenceSettings settings,
      SettingsNotifier notifier, {required bool isApi}) {
    const labels = {'auto': '自动（推荐）', 'compact': '精简', 'full': '完整'};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('提示词档位', style: TextStyle(fontSize: 13)),
        const SizedBox(height: 2),
        Text(
          isApi
              ? 'API 档恒用完整提示词（11 条工具纪律 + 任务执行纪律 + 全量工具'
                  '清单 + 技能目录），本项不影响 API。'
              : '本地小模型（tiny / 2B 级）建议自动：系统提示只留短身份与 4 条'
                  '工具纪律，工具收进核心白名单，技能目录与 AGENTS.md 不再常驻'
                  '——实测完整档 4.5k token 会把 tiny 逼成「不调工具、编造已执行」。',
          style: const TextStyle(fontSize: 11, color: Colors.grey),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final mode in const ['auto', 'compact', 'full'])
              ChoiceChip(
                label: Text(labels[mode]!),
                selected: settings.agentPromptTierMode == mode,
                onSelected: (_) async {
                  await notifier.setAgentPromptTierMode(mode);
                  if (mounted) setState(() {});
                },
              ),
          ],
        ),
      ],
    );
  }

  Widget _capChip(String label, {required bool ok}) {
    final color = ok ? Colors.teal : Colors.grey;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 11, color: color),
      ),
    );
  }

  /// 浮点滑块行（温度）。紧凑排版同 [_buildSliderRow]。
  Widget _buildDoubleSliderRow({
    required String label,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String display,
    required ValueChanged<double> onChanged,
    String? hint,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                  child: Text(label, style: const TextStyle(fontSize: 12))),
              Text(display,
                  style: const TextStyle(
                      fontWeight: FontWeight.w500, fontSize: 12)),
            ],
          ),
          SizedBox(
            height: 34,
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              divisions: divisions,
              label: display,
              onChanged: onChanged,
            ),
          ),
          if (hint != null)
            Text(hint,
                style: const TextStyle(fontSize: 11, color: Colors.grey)),
        ],
      ),
    );
  }

  // ---------------- 对话框 ----------------

  /// AGENTS.md 编辑对话框（全局文件）。
  Future<void> _editAgentsMd() async {
    final base = await getApplicationSupportDirectory();
    final file = File(p.join(base.path, 'AGENTS.md'));
    final initial = file.existsSync() ? file.readAsStringSync() : '';
    if (!mounted) return;
    final controller = TextEditingController(text: initial);
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('AGENTS.md 指令文件'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '作为低权威 workspace guidance 注入系统提示。\n${file.path}',
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: controller,
              maxLines: 12,
              minLines: 6,
              autofocus: true,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: '例如：回答一律用中文；先列计划再执行…',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('保存')),
        ],
      ),
    );
    // 弹窗关闭即取走文本并释放控制器（原实现从不 dispose，每次弹窗泄漏）。
    final content = controller.text;
    controller.dispose();
    if (saved != true) return;
    try {
      if (content.trim().isEmpty) {
        if (file.existsSync()) file.deleteSync();
      } else {
        file.writeAsStringSync(content);
      }
    } catch (_) {/* 只读分区等情况：忽略，状态刷新会如实反映 */}
    _loadAgentsMdInfo();
  }

  /// 智能体数据目录对话框（可复制路径）。
  Future<void> _showDataDirs() async {
    final base = await getApplicationSupportDirectory();
    if (!mounted) return;
    final dirs = <String, String>{
      '会话事件日志': p.join(base.path, 'sessions'),
      '工具输出溢写': p.join(base.path, 'agent_spill'),
      '用户技能': p.join(base.path, 'skills'),
      'AGENTS.md': _agentsMdPath ?? p.join(base.path, 'AGENTS.md'),
    };
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('智能体数据目录'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final e in dirs.entries)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(e.key,
                        style: const TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w600)),
                    subtitle: Text(e.value,
                        style: const TextStyle(fontSize: 11),
                        overflow: TextOverflow.ellipsis),
                    trailing: IconButton(
                      icon: const Icon(Icons.copy, size: 16),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: e.value));
                        ScaffoldMessenger.of(dialogContext).showSnackBar(
                          SnackBar(content: Text('已复制 ${e.key} 路径')),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('关闭')),
        ],
      ),
    );
  }

  /// 驱动模型选择器：显示当前选择，点击弹出选择对话框。
  /// API 模型显示**配置名**（无名称回退模型名）而非内部 id——此前直接显示
  /// agentModelId（ApiModelConfig 的 uuid），用户看到的是一串 key。
  Widget _buildAgentModelSelector(
      BuildContext context, WidgetRef ref, InferenceSettings settings) {
    final String currentLabel;
    if (settings.agentModelSource == null) {
      currentLabel = '跟随默认（本地优先，API 兜底）';
    } else if (settings.agentModelSource == 'local') {
      currentLabel = '本地：${settings.agentModelId}';
    } else {
      String displayName = settings.agentModelId ?? '';
      for (final cfg in settings.apiModels) {
        if (cfg.id == settings.agentModelId) {
          displayName = cfg.name.isEmpty ? cfg.model : cfg.name;
          break;
        }
      }
      currentLabel = 'API：$displayName';
    }

    return InkWell(
      onTap: () => _pickAgentModel(context, ref, settings),
      borderRadius: BorderRadius.circular(8),
      child: InputDecorator(
        decoration: const InputDecoration(
          border: OutlineInputBorder(),
          suffixIcon: Icon(Icons.arrow_drop_down),
        ),
        child: Text(currentLabel, style: const TextStyle(fontSize: 13)),
      ),
    );
  }

  /// 弹出「选择智能体驱动模型」对话框：跟随默认 / 本地模型 / API 模型。
  Future<void> _pickAgentModel(
      BuildContext context, WidgetRef ref, InferenceSettings settings) async {
    final catalog = await loadModelCatalog();
    if (!context.mounted) return;
    final notifier = ref.read(settingsProvider.notifier);
    final apiModels = settings.apiModels;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('选择智能体驱动模型'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(
            shrinkWrap: true,
            children: [
              ListTile(
                leading: const Icon(Icons.auto_awesome),
                title: const Text('跟随默认'),
                subtitle: const Text('本地优先，API 兜底'),
                selected: settings.agentModelSource == null,
                onTap: () {
                  Navigator.pop(dialogContext);
                  notifier.setAgentModel(null, null);
                },
              ),
              const Divider(height: 24),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 4),
                child:
                    Text('本地模型', style: TextStyle(fontWeight: FontWeight.w600)),
              ),
              for (final m in catalog)
                ListTile(
                  leading: const Icon(Icons.storage),
                  title: Text(cleanModelName(m.name),
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle:
                      Text(m.id, maxLines: 1, overflow: TextOverflow.ellipsis),
                  selected: settings.agentModelSource == 'local' &&
                      settings.agentModelId == m.id,
                  onTap: () {
                    Navigator.pop(dialogContext);
                    notifier.setAgentModel('local', m.id);
                  },
                ),
              if (apiModels.isNotEmpty) ...[
                const Divider(height: 24),
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 4),
                  child: Text('API 接入模型',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                ),
                for (final cfg in apiModels)
                  ListTile(
                    leading: const Icon(Icons.cloud),
                    title: Text(cfg.name.isEmpty ? cfg.model : cfg.name,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(cfg.id,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    selected: settings.agentModelSource == 'api' &&
                        settings.agentModelId == cfg.id,
                    onTap: () {
                      Navigator.pop(dialogContext);
                      notifier.setAgentModel('api', cfg.id);
                    },
                  ),
              ] else
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Text('暂无 API 模型，请先在「API 接入」配置',
                      style: TextStyle(color: Colors.grey)),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消')),
        ],
      ),
    );
  }
}

/// token 类大数值的 k 级显示：1024→"1k"、1536→"1.5k"、960→"960"。
/// [unit] 如 'token'；注意按 1024 进位（token/字节语义），不用 1000。
String _formatKValue(int v, String unit) {
  if (v >= 1024 && v % 1024 == 0) return '${v ~/ 1024}k $unit';
  if (v > 1024) return '${(v / 1024).toStringAsFixed(1)}k $unit';
  return '$v $unit';
}

/// 毫秒 → 可读时长（如 15000 → "15 秒"）。
String _formatTimeout(int ms) {
  if (ms < 1000) return '$ms 毫秒';
  if (ms % 1000 == 0) return '${ms ~/ 1000} 秒';
  return '${(ms / 1000).toStringAsFixed(1)} 秒';
}

// =========================================================================
// Tab 5: 关于
// =========================================================================

