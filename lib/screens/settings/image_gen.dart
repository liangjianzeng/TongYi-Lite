part of '../settings_screen.dart';

// =========================================================================
// 图像生成（同尾网/局域网 Unsloth Studio）配置卡 —— 放在「API 接入」页：
// 与远程 API / 联网搜索同属外部服务配置。能力移植自汪柴 WangCai。
//
// 设计要点（与 WebSearchSettingsBody 同款纪律）：
// - 默认关：generate_image 工具不注册（模型看不见）；开一下才可用。
// - 地址出厂预置自建 tailnet 的 Tailscale serve（手机 Tailscale 连同尾网
//   即可跨网访问）；同局域网也可直填 http://<PC>:8888。
// - **模型是选择出来的，不是手填目录**（用户 2026-11-10 定案）：
//   「获取模型列表」从服务端 GET /v1/models 拉真实 id（优先
//   task=text-to-image），下拉直接选；服务端不可达时才走「手动输入」兜底。
// - 「测试连接」用输入框里的**草稿值**直接打 /api/health + /v1/models
//   （无需先保存），成功顺带把模型列表灌进下拉。
// =========================================================================

class ImageGenSettingsBody extends ConsumerStatefulWidget {
  const ImageGenSettingsBody();

  @override
  ConsumerState<ImageGenSettingsBody> createState() =>
      ImageGenSettingsBodyState();
}

class ImageGenSettingsBodyState extends ConsumerState<ImageGenSettingsBody> {
  final _url = TextEditingController();
  final _model = TextEditingController();
  final _apiKey = TextEditingController();

  final _urlFocus = FocusNode();
  final _modelFocus = FocusNode();
  final _apiKeyFocus = FocusNode();

  bool _revealKey = false;
  bool _testing = false;
  String? _testResult;
  bool _testOk = false;

  /// 服务端模型 id 列表（「获取模型列表」/「测试连接」成功后填充）。
  List<String> _serverModels = const [];
  bool _modelsLoading = false;
  String? _modelsError;

  /// 手动输入模型名模式（服务端不可达/想填自定义 id 时的兜底）。
  bool _manualModel = false;

  /// 提前捕获 notifier（provider 与应用同生命周期）：dispose（离开页面）时
  /// 还要落盘草稿，而那时不能再触碰 ref（web_search 同款）。
  SettingsNotifier? _liveNotifier;

  @override
  void initState() {
    super.initState();
    _liveNotifier = ref.read(settingsProvider.notifier);
    final n = _liveNotifier!;
    _saveOnBlur(_urlFocus, () => n.setImageGenBaseUrl(_url.text));
    _saveOnBlur(_modelFocus, () => n.setImageGenModel(_model.text));
    _saveOnBlur(_apiKeyFocus, () => n.setImageGenApiKey(_apiKey.text));
  }

  /// 焦点离开 [node] 时执行一次 [save]（web_search 同款离焦即存）。
  void _saveOnBlur(FocusNode node, void Function() save) {
    var hadFocus = false;
    node.addListener(() {
      if (hadFocus && !node.hasFocus && _liveNotifier != null) save();
      hadFocus = node.hasFocus;
    });
  }

  @override
  void dispose() {
    // 离页兜底保存（web_search 同款）：填完直接返回时焦点从未离开输入框，
    // 不在此落盘值就丢了。setter 幂等，与离焦保存重复触发无副作用。
    final n = _liveNotifier;
    if (n != null) {
      n.setImageGenBaseUrl(_url.text);
      n.setImageGenApiKey(_apiKey.text);
      if (_manualModel) n.setImageGenModel(_model.text);
    }
    _url.dispose();
    _model.dispose();
    _apiKey.dispose();
    _urlFocus.dispose();
    _modelFocus.dispose();
    _apiKeyFocus.dispose();
    super.dispose();
  }

  /// 设置异步加载：首帧空输入框，等值到位灌一次，绝不覆盖正在输入的内容。
  void _seed(TextEditingController c, String value) {
    if (c.text.isEmpty && value.isNotEmpty) c.text = value;
  }

  SettingsNotifier get _notifier => ref.read(settingsProvider.notifier);

  /// 用输入框草稿构造配置（enabled 强制 true：测试是"验地址和密钥"，
  /// 不该被总开关状态拦住）。模型名不参与测试，取当前设置值即可。
  ImageGenConfig _draftConfig() => ImageGenConfig(
        enabled: true,
        baseUrl: _url.text,
        model: _liveNotifier?.snapshot.imageGenModel ??
            kImageGenDefaultModel,
        defaultSize: _liveNotifier?.snapshot.imageGenDefaultSize ??
            '1024x1024',
        apiKey: _apiKey.text,
      );

  /// 测试连接前先保存草稿（点测试通常代表"我配完了"，web_search 同款）。
  Future<void> _test() async {
    final n = _notifier;
    await n.setImageGenBaseUrl(_url.text);
    await n.setImageGenApiKey(_apiKey.text);
    setState(() {
      _testing = true;
      _testResult = null;
    });
    final health = await ImageGenService.instance.checkHealth(_draftConfig());
    if (!mounted) return;
    setState(() {
      _testing = false;
      _testOk = health.ok;
      _testResult = health.message;
      // 测试成功顺带灌模型列表——「测试连接」即完成一次模型选择准备。
      if (health.models.isNotEmpty) {
        _serverModels = health.models;
        _modelsError = null;
      }
    });
  }

  /// 从服务端拉模型 id 列表（下拉选项来源）。失败摆红字，不抛。
  Future<void> _refreshModels() async {
    await _notifier.setImageGenBaseUrl(_url.text);
    await _notifier.setImageGenApiKey(_apiKey.text);
    setState(() {
      _modelsLoading = true;
      _modelsError = null;
    });
    try {
      final models =
          await ImageGenService.instance.listModels(_draftConfig());
      if (!mounted) return;
      setState(() {
        _modelsLoading = false;
        _serverModels = models;
      });
    } on ImageGenException catch (e) {
      if (!mounted) return;
      setState(() {
        _modelsLoading = false;
        _modelsError = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _modelsLoading = false;
        _modelsError = '拉取失败：$e';
      });
    }
  }

  /// 模型下拉选项：服务端列表 ∪ 当前设置值（列表未拉/值不在列表时可见可选）。
  List<String> _modelOptions(String current) {
    final seen = <String>{};
    final out = <String>[];
    for (final m in [..._serverModels, current]) {
      final t = m.trim();
      if (t.isNotEmpty && seen.add(t)) out.add(t);
    }
    return out;
  }

  Widget _buildModelPicker(InferenceSettings settings) {
    final current = settings.imageGenModel.trim();
    if (_manualModel) {
      // 手动输入兜底：填完按 ✓ 回下拉模式（值已在离焦/回车时落库）。
      return Row(
        children: [
          Expanded(
            child: TextField(
              controller: _model,
              focusNode: _modelFocus,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: '模型名（手动）',
                hintText: 'qwen-image-2.1-turbo-Q5_K_M',
                helperText: '与「测试连接」同口径；下拉不可用时才用这里',
                helperMaxLines: 1,
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onSubmitted: (v) => _notifier.setImageGenModel(v),
            ),
          ),
          IconButton(
            tooltip: '完成（回下拉选择）',
            icon: const Icon(Icons.check, size: 20),
            onPressed: () {
              _notifier.setImageGenModel(_model.text);
              setState(() => _manualModel = false);
            },
          ),
        ],
      );
    }
    final options = _modelOptions(current);
    return Row(
      children: [
        Expanded(
          child: DropdownButtonFormField<String>(
            value: options.isEmpty ? null : (options.contains(current) ? current : options.first),
            isDense: true,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: '模型',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            items: [
              for (final m in options)
                DropdownMenuItem(value: m, child: Text(m, overflow: TextOverflow.ellipsis)),
            ],
            onChanged: (v) {
              if (v != null && v.isNotEmpty) _notifier.setImageGenModel(v);
            },
          ),
        ),
        IconButton(
          tooltip: _serverModels.isEmpty ? '获取模型列表' : '刷新模型列表',
          icon: _modelsLoading
              ? const SizedBox(
                  width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.refresh, size: 20),
          onPressed: _modelsLoading ? null : _refreshModels,
        ),
        IconButton(
          tooltip: '手动输入',
          icon: const Icon(Icons.edit_outlined, size: 20),
          onPressed: () {
            _model.text = current;
            setState(() => _manualModel = true);
          },
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    _seed(_url, settings.imageGenBaseUrl);
    _seed(_model, settings.imageGenModel);
    _seed(_apiKey, settings.imageGenApiKey);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSectionHeader('🎨 图像生成', context),
            const SizedBox(height: 4),
            Text(
              '智能体可用 generate_image 调 Unsloth Studio（Qwen-Image）出图，'
              '成图直接出现在聊天区。默认走 Tailscale：手机连上同尾网即可跨网'
              '使用（同局域网也可直接填 http://<PC>:8888）。',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('启用图像生成', style: TextStyle(fontSize: 14)),
              subtitle: const Text(
                  '开启后模型可用 generate_image；关闭则该工具不可见',
                  style: TextStyle(fontSize: 12)),
              value: settings.imageGenEnabled,
              onChanged: (v) => _notifier.setImageGenEnabled(v),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _url,
              keyboardType: TextInputType.url,
              focusNode: _urlFocus,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: '服务地址',
                hintText: 'https://<机器>.<tailnet>.ts.net:8888',
                helperText: '离焦或按回车自动保存；默认已预置自建 Tailscale serve '
                    '地址；留空 = 未配置（工具报"未配置服务地址"）',
                helperMaxLines: 2,
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onSubmitted: (v) => _notifier.setImageGenBaseUrl(v),
            ),
            const SizedBox(height: 12),
            _buildModelPicker(settings),
            if (_modelsError != null) ...[
              const SizedBox(height: 4),
              Text(
                '❌ $_modelsError（可点 ✎ 手动输入模型名）',
                style: TextStyle(fontSize: 12, color: Colors.red.shade600),
              ),
            ],
            const SizedBox(height: 12),
            TextField(
              controller: _apiKey,
              focusNode: _apiKeyFocus,
              obscureText: !_revealKey,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: 'API Key（可选）',
                helperText: '以 Bearer 发送；无鉴权的实例留空',
                border: const OutlineInputBorder(),
                isDense: true,
                suffixIcon: IconButton(
                  icon: Icon(
                      _revealKey ? Icons.visibility_off : Icons.visibility,
                      size: 18),
                  onPressed: () => setState(() => _revealKey = !_revealKey),
                ),
              ),
              onSubmitted: (v) => _notifier.setImageGenApiKey(v),
            ),
            const SizedBox(height: 12),
            // 默认尺寸档位（工具不传 size 时用这个；工具传 size 以工具为准）。
            Row(
              children: [
                const Text('默认尺寸', style: TextStyle(fontSize: 13)),
                const SizedBox(width: 10),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: kImageGenSizes.contains(settings.imageGenDefaultSize)
                        ? settings.imageGenDefaultSize
                        : '1024x1024',
                    isDense: true,
                    decoration: const InputDecoration(
                        border: OutlineInputBorder(), isDense: true),
                    items: [
                      for (final s in kImageGenSizes)
                        DropdownMenuItem(value: s, child: Text(s)),
                    ],
                    onChanged: (v) {
                      if (v != null) _notifier.setImageGenDefaultSize(v);
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
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
            if (_testResult != null) ...[
              const SizedBox(height: 8),
              Text(
                '${_testOk ? '✅' : '❌'} $_testResult',
                style: TextStyle(
                  fontSize: 12,
                  color: _testOk ? Colors.green : Colors.red,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
