part of '../settings_screen.dart';

class ApiSettingsBody extends ConsumerWidget {
  const ApiSettingsBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final apiModels = settings.apiModels;
    final activeId = settings.activeApiModelId;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Icon(Icons.cloud_queue,
                      color: Theme.of(context).colorScheme.primary),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      '本地模型优先：仅当本地模型不可用时，才自动使用下方激活的 API 模型。',
                      style: TextStyle(fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(child: _buildSectionHeader('已配置的 API 模型', context)),
              FilledButton.icon(
                onPressed: () => _showApiModelDialog(context, ref),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('添加'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (apiModels.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(
                child:
                    Text('尚未配置任何 API 模型', style: TextStyle(color: Colors.grey)),
              ),
            )
          else
            for (final cfg in apiModels)
              _buildApiModelCard(context, ref, cfg, activeId == cfg.id),
          const SizedBox(height: 20),
          _buildSectionHeader('当前激活', context),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildToggleTitle(
                    '启用 API 接入',
                    activeId != null,
                    (v) {
                      // 打开时激活当前列表首个可用模型；关闭时停用。
                      ref.read(settingsProvider.notifier).setActiveApiModel(v
                          ? (activeId ??
                              (apiModels.isNotEmpty
                                  ? apiModels.first.id
                                  : null))
                          : null);
                    },
                    subtitle: activeId != null
                        ? '当前激活：${_activeApiName(apiModels, activeId)}'
                        : '未启用 API，聊天仅使用本地模型',
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          // 联网搜索（SearXNG 实例地址等）：与 API 接入同属"外部服务"配置。
          const WebSearchSettingsBody(),
          const SizedBox(height: 20),
          // 图像生成（局域网 Unsloth Studio）：同为外部服务配置，能力移植自汪柴。
          const ImageGenSettingsBody(),
        ],
      ),
    );
  }

  Widget _buildApiModelCard(
      BuildContext context, WidgetRef ref, ApiModelConfig cfg, bool isActive) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.cloud,
                    size: 20, color: isActive ? Colors.green : Colors.grey),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(cfg.name,
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold)),
                ),
                if (isActive)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.green,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Text('已激活',
                        style: TextStyle(fontSize: 11, color: Colors.white)),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(cfg.baseUrl,
                style: const TextStyle(fontSize: 12, color: Colors.grey)),
            Text('模型：${cfg.model}', style: const TextStyle(fontSize: 12)),
            Text(
              'temp=${cfg.effectiveTemperature.toStringAsFixed(2)} · '
              'max_tokens=${cfg.effectiveMaxTokens}'
              '${cfg.contextWindow != null ? ' · 上下文=${cfg.contextWindow}' : ''}',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: isActive
                      ? OutlinedButton.icon(
                          onPressed: () => ref
                              .read(settingsProvider.notifier)
                              .setActiveApiModel(null),
                          icon: const Icon(Icons.power_off, size: 16),
                          label: const Text('停用'),
                        )
                      : FilledButton.icon(
                          onPressed: () => ref
                              .read(settingsProvider.notifier)
                              .setActiveApiModel(cfg.id),
                          icon: const Icon(Icons.play_arrow, size: 16),
                          label: const Text('激活'),
                        ),
                ),
                IconButton(
                  icon: const Icon(Icons.edit, size: 20),
                  tooltip: '编辑',
                  onPressed: () =>
                      _showApiModelDialog(context, ref, existing: cfg),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 20),
                  tooltip: '删除',
                  onPressed: () => _confirmDeleteApiModel(context, ref, cfg),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDeleteApiModel(
      BuildContext context, WidgetRef ref, ApiModelConfig cfg) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('删除 API 模型'),
        content: Text('确定删除「${cfg.name}」吗？删除后其密钥一并移除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true) {
      ref.read(settingsProvider.notifier).deleteApiModel(cfg.id);
    }
  }

  String? _activeApiName(List<ApiModelConfig> list, String? id) {
    if (id == null) return null;
    for (final cfg in list) {
      if (cfg.id == id) return cfg.name;
    }
    return null;
  }

  void _showApiModelDialog(BuildContext context, WidgetRef ref,
      {ApiModelConfig? existing}) {
    showDialog(
      context: context,
      builder: (_) =>
          _ApiModelDialog(existing: existing, isEditing: existing != null),
    );
  }
}

class _ApiModelDialog extends ConsumerStatefulWidget {
  const _ApiModelDialog({this.existing, required this.isEditing});

  final ApiModelConfig? existing;
  final bool isEditing;

  @override
  ConsumerState<_ApiModelDialog> createState() => _ApiModelDialogState();
}

class _ApiModelDialogState extends ConsumerState<_ApiModelDialog> {
  late final TextEditingController _name;
  late final TextEditingController _baseUrl;
  late final TextEditingController _apiKey;
  late final TextEditingController _model;
  late final TextEditingController _temp;
  late final TextEditingController _maxTokens;
  late final TextEditingController _contextWindow;

  String? _testResult;
  bool _testing = false;
  bool _visionCapable = false;
  // 思考强度（每条 API 配置独立；不干预 = 一个思考字段都不发，与旧版一致）
  ThinkingEffort _thinkingEffort = ThinkingEffort.passthrough;
  // 思考参数族覆盖（null = 按模型名/端点自动探测）
  ThinkingFamily? _thinkingFamily;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name = TextEditingController(text: e?.name ?? '');
    _baseUrl = TextEditingController(text: e?.baseUrl ?? '');
    _apiKey = TextEditingController(text: e?.apiKey ?? '');
    _model = TextEditingController(text: e?.model ?? '');
    _temp =
        TextEditingController(text: e?.temperature?.toStringAsFixed(2) ?? '');
    _maxTokens = TextEditingController(text: e?.maxTokens?.toString() ?? '');
    _contextWindow =
        TextEditingController(text: e?.contextWindow?.toString() ?? '');
    _visionCapable = e?.visionCapable ?? false;
    _thinkingEffort = thinkingEffortFromKey(e?.thinkingEffort);
    _thinkingFamily = thinkingFamilyFromKey(e?.thinkingFamily);
  }

  @override
  void dispose() {
    _name.dispose();
    _baseUrl.dispose();
    _apiKey.dispose();
    _model.dispose();
    _temp.dispose();
    _maxTokens.dispose();
    _contextWindow.dispose();
    super.dispose();
  }

  ApiModelConfig? _buildConfig() {
    final name = _name.text.trim();
    final baseUrl = _baseUrl.text.trim();
    final model = _model.text.trim();
    if (name.isEmpty || baseUrl.isEmpty || model.isEmpty) return null;
    return ApiModelConfig(
      id: widget.existing?.id ?? Uuid().v4(),
      name: name,
      baseUrl: baseUrl,
      apiKey: _apiKey.text.trim(),
      model: model,
      temperature: double.tryParse(_temp.text.trim()),
      maxTokens: int.tryParse(_maxTokens.text.trim()),
      visionCapable: _visionCapable,
      contextWindow: int.tryParse(_contextWindow.text.trim()),
      thinkingEffort: thinkingEffortToKey(_thinkingEffort),
      thinkingFamily: thinkingFamilyToKey(_thinkingFamily),
    );
  }

  Future<void> _test() async {
    final cfg = _buildConfig();
    if (cfg == null) {
      setState(() => _testResult = '请先填写 名称/baseUrl/模型名');
      return;
    }
    setState(() => _testing = true);
    final err = await ref.read(openAiServiceProvider).testConnection(cfg);
    if (!mounted) return;
    setState(() {
      _testing = false;
      _testResult = err == null ? '✅ 连接成功' : '❌ $err';
    });
  }

  Future<void> _save() async {
    final cfg = _buildConfig();
    if (cfg == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('名称 / baseUrl / 模型名 为必填')),
      );
      return;
    }
    final notifier = ref.read(settingsProvider.notifier);
    if (widget.isEditing) {
      await notifier.updateApiModel(cfg);
    } else {
      await notifier.addApiModel(cfg);
    }
    if (!mounted) return;
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.isEditing ? '编辑 API 模型' : '添加 API 模型'),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: '显示名称 *')),
          TextField(
            controller: _baseUrl,
            decoration: const InputDecoration(
              labelText: 'Base URL *',
              hintText: 'https://api.openai.com/v1 或 http://127.0.0.1:8080/v1',
            ),
          ),
          TextField(
            controller: _apiKey,
            decoration: const InputDecoration(
              labelText: 'API Key',
              hintText: '可留空（本地服务）',
            ),
            obscureText: true,
          ),
          TextField(
            controller: _model,
            decoration: const InputDecoration(
              labelText: '模型名 *',
              hintText: 'gpt-4o / qwen2.5-7b-instruct',
            ),
          ),
          TextField(
            controller: _temp,
            keyboardType: TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'temperature（留空=0.7）'),
          ),
          TextField(
            controller: _maxTokens,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'max_tokens（留空=1024）'),
          ),
          TextField(
            controller: _contextWindow,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: '上下文窗口（留空=自动探测）',
              hintText: '顶部上下文占用百分比的分母；自动从 /v1/models 读取 n_ctx',
            ),
          ),
          SwitchListTile(
            title: const Text('支持视觉（图片理解）'),
            subtitle: const Text('开启后，带图消息会以 base64 图片发送给该 API'),
            value: _visionCapable,
            onChanged: (v) => setState(() => _visionCapable = v),
          ),
          // ── 思考强度（每条 API 配置独立，避免"全局一个开关配错某些端点"）──
          const SizedBox(height: 4),
          const Text('思考强度（该端点）',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          Wrap(
            spacing: 6,
            children: [
              for (final e in ThinkingEffort.values)
                ChoiceChip(
                  label: Text(thinkingEffortLabel(e)),
                  selected: _thinkingEffort == e,
                  onSelected: (_) => setState(() => _thinkingEffort = e),
                ),
            ],
          ),
          Row(
            children: [
              const Text('参数族', style: TextStyle(fontSize: 12)),
              const SizedBox(width: 8),
              DropdownButton<ThinkingFamily?>(
                value: _thinkingFamily,
                isDense: true,
                underline: const SizedBox.shrink(),
                items: [
                  const DropdownMenuItem<ThinkingFamily?>(
                      value: null,
                      child: Text('自动探测', style: TextStyle(fontSize: 12))),
                  for (final f in ThinkingFamily.values)
                    DropdownMenuItem<ThinkingFamily?>(
                      value: f,
                      child: Text(thinkingFamilyLabel(f),
                          style: const TextStyle(fontSize: 12)),
                    ),
                ],
                onChanged: (v) => setState(() => _thinkingFamily = v),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              '各家字段不同（reasoning_effort / thinking budget / '
              'chat_template_kwargs…），默认按模型名与端点自动选族；判错时这里手工钉死。'
              '端点不认该字段会自动去掉重发，不会把请求打死。'
              '调「高」= 允许更长思考，请同步把「思考字数上限」调大，否则会被守卫按不思考重试。',
              style: TextStyle(fontSize: 11, color: Colors.grey[600]),
            ),
          ),
          const SizedBox(height: 12),
          if (_testResult != null)
            Text(
              _testResult!,
              style: TextStyle(
                color: _testResult!.startsWith('✅') ? Colors.green : Colors.red,
              ),
            ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _testing ? null : _test,
                  icon: const Icon(Icons.wifi_tethering, size: 16),
                  label: Text(_testing ? '测试中…' : '测试连接'),
                ),
              ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _save, child: const Text('保存')),
      ],
    );
  }
}

