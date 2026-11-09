part of '../settings_screen.dart';

// =========================================================================
// 联网搜索（SearXNG）配置卡 —— 放在「API 接入」页：与远程 API 同属外部服务配置。
//
// 设计要点：
// - 地址由用户自己的部署决定，App **不预置任何实例**；未填时 web_search 会
//   明确回"未配置地址"的诊断，而不是拿 127.0.0.1 去连手机自己。
// - 「测试连接」用输入框里的**草稿值**直接发一次真实搜索（无需先保存），并把
//   provider 的分类诊断原样显示（HTTP 状态 / 超时 / 实例未开 format=json 等），
//   避免"红条指错方向"。
// =========================================================================

class WebSearchSettingsBody extends ConsumerStatefulWidget {
  const WebSearchSettingsBody();

  @override
  ConsumerState<WebSearchSettingsBody> createState() =>
      WebSearchSettingsBodyState();
}

class WebSearchSettingsBodyState extends ConsumerState<WebSearchSettingsBody> {
  final _url = TextEditingController();
  final _apiKey = TextEditingController();
  final _engines = TextEditingController();
  final _language = TextEditingController();
  final _maxResults = TextEditingController();
  final _timeoutSec = TextEditingController();

  /// 各文本框的 FocusNode：用于「离焦即自动保存」，
  /// 解决"填完值没按回车就丢了"的问题。
  final _urlFocus = FocusNode();
  final _apiKeyFocus = FocusNode();
  final _enginesFocus = FocusNode();
  final _languageFocus = FocusNode();
  final _maxResultsFocus = FocusNode();
  final _timeoutSecFocus = FocusNode();

  bool _revealKey = false;
  bool _testing = false;
  String? _testResult;
  bool _testOk = false;

  /// 提前捕获 notifier（provider 与应用同生命周期）：dispose（离开页面）时
  /// 还要落盘草稿，而那时不能再触碰 ref。
  SettingsNotifier? _liveNotifier;

  @override
  void initState() {
    super.initState();
    _liveNotifier = ref.read(settingsProvider.notifier);
    // 离焦即保存（SDK 3.27 的 TextField 既无 onBlur 也无 onFocusChange，
    // 用 FocusNode 监听实现；仅"由有焦点→失去焦点"时触发一次）。
    final n = _liveNotifier!;
    _saveOnBlur(_urlFocus, () => n.setWebSearchSearXngBaseUrl(_url.text));
    _saveOnBlur(_apiKeyFocus, () => n.setWebSearchSearXngApiKey(_apiKey.text));
    _saveOnBlur(
        _enginesFocus, () => n.setWebSearchSearXngEngines(_engines.text));
    _saveOnBlur(
        _languageFocus, () => n.setWebSearchSearXngLanguage(_language.text));
    _saveOnBlur(_maxResultsFocus, () => _saveMaxResults(_maxResults.text));
    _saveOnBlur(_timeoutSecFocus, () => _saveTimeoutSec(_timeoutSec.text));
  }

  /// 焦点离开 [node] 时执行一次 [save]（不依赖 ref，页面销毁路径也安全）。
  void _saveOnBlur(FocusNode node, void Function() save) {
    var hadFocus = false;
    node.addListener(() {
      if (hadFocus && !node.hasFocus && _liveNotifier != null) save();
      hadFocus = node.hasFocus;
    });
  }

  @override
  void dispose() {
    // 离页兜底保存：离焦保存只覆盖"焦点切换"场景；填完直接返回/切页时
    // 焦点从未离开过输入框，若不在此落盘，值就丢了（"配置不自动保存"的
    // 最后一个口子）。setter 幂等，与离焦保存重复触发无副作用。
    final n = _liveNotifier;
    if (n != null) {
      n.setWebSearchSearXngBaseUrl(_url.text);
      n.setWebSearchSearXngApiKey(_apiKey.text);
      n.setWebSearchSearXngEngines(_engines.text);
      n.setWebSearchSearXngLanguage(_language.text);
      final maxResults = int.tryParse(_maxResults.text.trim());
      if (maxResults != null) n.setWebSearchSearXngMaxResults(maxResults);
      final timeoutSec = int.tryParse(_timeoutSec.text.trim());
      if (timeoutSec != null) {
        n.setWebSearchSearXngTimeoutMs(timeoutSec * 1000);
      }
    }
    _url.dispose();
    _apiKey.dispose();
    _engines.dispose();
    _language.dispose();
    _maxResults.dispose();
    _timeoutSec.dispose();
    _urlFocus.dispose();
    _apiKeyFocus.dispose();
    _enginesFocus.dispose();
    _languageFocus.dispose();
    _maxResultsFocus.dispose();
    _timeoutSecFocus.dispose();
    super.dispose();
  }

  /// 设置是异步加载的：首帧输入框还是空的，等值到位后灌进去一次。
  /// 只灌空字段——绝不覆盖用户正在输入的内容。
  void _seed(TextEditingController c, String value) {
    if (c.text.isEmpty && value.isNotEmpty) c.text = value;
  }

  SettingsNotifier get _notifier => ref.read(settingsProvider.notifier);

  String? get _draftKeyOrNull =>
      _apiKey.text.trim().isEmpty ? null : _apiKey.text.trim();

  /// 用输入框里的当前内容构造一个 provider 并搜索一次"测试"。
  /// 测试前先**保存草稿**（点测试通常代表"我配完了"），避免只点了测试、
  /// 没按回车/没离焦导致值丢失——这正是"配置后不自动保存"的常见场景。
  Future<void> _test() async {
    await _saveAllDrafts();
    setState(() {
      _testing = true;
      _testResult = null;
    });
    final provider = SearXNGSearchProvider(
      baseURL: _url.text.trim(),
      apiKey: _draftKeyOrNull,
      engines: _engines.text.trim().isEmpty ? null : _engines.text.trim(),
      language: _language.text.trim().isEmpty ? null : _language.text.trim(),
      maxResults: int.tryParse(_maxResults.text.trim()) ?? 8,
      timeout: Duration(
          seconds: int.tryParse(_timeoutSec.text.trim()) ??
              (InferenceSettings.kDefaultSearXngTimeoutMs ~/ 1000)),
    );
    final sw = Stopwatch()..start();
    String message;
    bool ok;
    try {
      final result = await provider.search('测试');
      ok = true;
      message = '连接成功：${result.sources.length} 条结果'
          '，用时 ${sw.elapsedMilliseconds} ms'
          '${result.truncated ? '（结果超过上限，已截断）' : ''}';
      if (result.sources.isEmpty) {
        message = '连接成功但 0 条结果（用时 ${sw.elapsedMilliseconds} ms）：'
            '多半是指定的引擎都没结果，清空引擎白名单试试';
      }
    } on WebSearchProviderError catch (e) {
      ok = false;
      message = e.kind == 'WEB_ABORTED'
          ? '${e.message}（已等 ${sw.elapsedMilliseconds} ms）'
          : e.message;
    } catch (e) {
      ok = false;
      message = '搜索失败：$e';
    } finally {
      provider.dispose();
    }
    if (!mounted) return;
    setState(() {
      _testing = false;
      _testOk = ok;
      _testResult = message;
    });
  }

  /// 数字项保存：notifier 会把值夹紧到合法区间，保存后把**真正生效的值**回写输入框，
  /// 避免"填了 300、实际生效 120"这种自己看不出来的偏差。
  /// 读生效值走 [SettingsNotifier.snapshot]：这些回调可能由离焦监听在页面
  /// 拆卸时触发，ref 已不可用，只能走捕获的 notifier 公开读口。
  Future<void> _saveMaxResults(String v) async {
    final n = _liveNotifier;
    if (n == null) return;
    await n.setWebSearchSearXngMaxResults(int.tryParse(v.trim()) ??
        n.snapshot.webSearchSearXngMaxResults);
    if (!mounted) return;
    _maxResults.text = '${n.snapshot.webSearchSearXngMaxResults}';
  }

  Future<void> _saveTimeoutSec(String v) async {
    final n = _liveNotifier;
    if (n == null) return;
    final currentSec = n.snapshot.webSearchSearXngTimeoutMs ~/ 1000;
    await n.setWebSearchSearXngTimeoutMs(
        (int.tryParse(v.trim()) ?? currentSec) * 1000);
    if (!mounted) return;
    _timeoutSec.text =
        '${(n.snapshot.webSearchSearXngTimeoutMs / 1000).round()}';
  }

  /// 顺序保存所有文本框的当前草稿值（测试连接前调用）。
  /// 逐个 await（setter 内部读 state 再写 controller），避免并发竞态。
  /// 每个 setter 都会 _persist（原子写 + 热更新 provider），重复调用幂等。
  Future<void> _saveAllDrafts() async {
    await _notifier.setWebSearchSearXngBaseUrl(_url.text);
    await _notifier.setWebSearchSearXngApiKey(_apiKey.text);
    await _notifier.setWebSearchSearXngEngines(_engines.text);
    await _notifier.setWebSearchSearXngLanguage(_language.text);
    await _saveMaxResults(_maxResults.text);
    await _saveTimeoutSec(_timeoutSec.text);
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    _seed(_url, settings.webSearchSearXngBaseUrl);
    _seed(_apiKey, settings.webSearchSearXngApiKey ?? '');
    _seed(_engines, settings.webSearchSearXngEngines ?? '');
    _seed(_language, settings.webSearchSearXngLanguage ?? '');
    _seed(_maxResults, '${settings.webSearchSearXngMaxResults}');
    _seed(
        _timeoutSec, '${(settings.webSearchSearXngTimeoutMs / 1000).round()}');

    final url = _url.text.trim();
    final notConfigured = url.isEmpty;
    // http 明文 + 填了密钥 = Bearer key 明文过网（回环地址除外）。
    final isHttp = url.toLowerCase().startsWith('http://');
    final host = url.isEmpty ? '' : (Uri.tryParse(url)?.host ?? '');
    final isLoopbackHost =
        host == '127.0.0.1' || host == 'localhost' || host == '::1';
    final insecureKey = !notConfigured &&
        isHttp &&
        !isLoopbackHost &&
        _apiKey.text.trim().isNotEmpty;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSectionHeader('🌐 联网搜索', context),
            const SizedBox(height: 4),
            Text(
              '为智能体提供 web_search 联网搜索。「端侧直连引擎」开关打开时'
              '优先级最高（忽略下方 SearXNG 地址）；关闭后用你的 SearXNG 实例'
              '（需手机能直接访问，局域网 IP 或 Tailscale 地址均可）。',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('启用联网搜索', style: TextStyle(fontSize: 14)),
              subtitle: const Text(
                  '开启后模型可用 web_search / get_weather；关闭则这两个工具不可见',
                  style: TextStyle(fontSize: 12)),
              value: settings.webSearchEnabled,
              onChanged: (v) => _notifier.setWebSearchEnabled(v),
            ),
            // ---- SearXNG 实例配置（直连引擎开关打开时优先级更高）----
            const SizedBox(height: 8),
            TextField(
              controller: _url,
              keyboardType: TextInputType.url,
              focusNode: _urlFocus,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'SearXNG 地址',
                hintText: 'http://192.168.1.20:8080',
                helperText: '离焦或按回车自动保存；路径会自动补 /search，只填主机和端口即可',
                helperMaxLines: 2,
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onSubmitted: (v) => _notifier.setWebSearchSearXngBaseUrl(v),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _apiKey,
              focusNode: _apiKeyFocus,
              obscureText: !_revealKey,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: 'API Key（可选）',
                helperText: '仅私有实例需要；以 Bearer 发送',
                border: const OutlineInputBorder(),
                isDense: true,
                suffixIcon: IconButton(
                  icon: Icon(
                      _revealKey ? Icons.visibility_off : Icons.visibility,
                      size: 18),
                  onPressed: () => setState(() => _revealKey = !_revealKey),
                ),
              ),
              onSubmitted: (v) => _notifier.setWebSearchSearXngApiKey(v),
            ),
            if (insecureKey) ...[
              const SizedBox(height: 6),
              Text(
                '⚠️ 当前用 http 明文传输，API Key 会明文过网；建议改用 https 或走 Tailscale。',
                style: TextStyle(fontSize: 12, color: Colors.orange.shade800),
              ),
            ],
            const SizedBox(height: 12),
            TextField(
              controller: _engines,
              focusNode: _enginesFocus,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: '引擎白名单（可选）',
                hintText: '如 bing,sogou',
                helperText: '留空 = 用实例的全部引擎。实例上若有连不通的引擎，'
                    '搜索会一直等到超时（实测可从 20 秒级降到 2~3 秒）',
                helperMaxLines: 3,
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onSubmitted: (v) => _notifier.setWebSearchSearXngEngines(v),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _language,
              focusNode: _languageFocus,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: '搜索语言（可选）',
                hintText: '如 zh-CN，留空 = 不指定',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onSubmitted: (v) => _notifier.setWebSearchSearXngLanguage(v),
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
            // ---- 条数 / 超时设置 ----
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _maxResults,
                    focusNode: _maxResultsFocus,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '最多条数',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onSubmitted: _saveMaxResults,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _timeoutSec,
                    focusNode: _timeoutSecFocus,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '超时（秒）',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onSubmitted: _saveTimeoutSec,
                  ),
                ),
              ],
            ),
            if (notConfigured) ...[
              const SizedBox(height: 6),
              Text(
                '尚未填写地址：联网搜索将使用端侧直连引擎（下方可开关选择）。'
                '填好地址点「测试连接」可改用 SearXNG 实例。',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
              ),
            ],
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
            // ---- 端侧直连引擎（SearXNG 地址为空时生效）----
            _buildDirectEngineSection(context, notConfigured, settings),
          ],
        ),
      ),
    );
  }

  /// 端侧直连引擎配置：引擎开关（按风险分档）+ 每 10 分钟窗口请求预算。
  /// 「细水长流」管控：高风险引擎（搜狗/百度/夸克，风控激进）默认每窗口
  /// 发 4 次；预算耗尽自动跳过，窗口到期恢复；引擎被反爬拦截时熔断冷却
  /// 并自动换 Cookie/UA 身份重试（2026-10-02 放宽：次数 2→4、冷却缩短）。
  Widget _buildDirectEngineSection(
      BuildContext context, bool notConfigured, InferenceSettings settings) {
    const engineLabels = {
      'bing_cn': '必应 CN',
      'so360': '360 搜索',
      'chinaso': '中国搜索',
      'sogou': '搜狗（高风险）',
      'baidu': '百度（高风险）',
      'quark': '夸克（高风险）',
    };
    final enabled = settings.webSearchDirectEngines;
    Widget budgetSlider({
      required String label,
      required String hint,
      required int value,
      required int min,
      required int max,
      required ValueChanged<int> onChanged,
    }) =>
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: const TextStyle(fontSize: 12)),
            SizedBox(
              height: 34,
              child: Slider(
                value: value.toDouble(),
                min: min.toDouble(),
                max: max.toDouble(),
                divisions: max - min,
                label: '$value 次',
                onChanged: (v) => onChanged(v.round()),
              ),
            ),
            Text(hint,
                style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
          ],
        );
    final directOn = settings.webSearchDirectEnabled;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 14),
        _buildSectionHeader('⚡ 端侧直连引擎', context),
        const SizedBox(height: 2),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text('端侧直连引擎（优先级最高）', style: TextStyle(fontSize: 14)),
          subtitle: Text(
            directOn ? '已启用：优先用端侧直连，忽略上方 SearXNG 地址' : '已关闭：使用上方配置的 SearXNG 实例',
            style: const TextStyle(fontSize: 12),
          ),
          value: directOn,
          onChanged: (v) => _notifier.setWebSearchDirectEnabled(v),
        ),
        // 总开关关闭时子设置整体置灰不可点（对齐 agentEnabled 的置灰模式）。
        Opacity(
          opacity: directOn ? 1.0 : 0.45,
          child: IgnorePointer(
            ignoring: !directOn,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  notConfigured
                      ? '高风险引擎每窗口请求数少、被拦自动冷却换身份，'
                          '保证长期可用。'
                      : '当前被 SearXNG 地址覆盖（直连开关打开才生效）。',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
                const SizedBox(height: 4),
                for (final entry in engineLabels.entries)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    visualDensity: VisualDensity.compact,
                    title:
                        Text(entry.value, style: const TextStyle(fontSize: 14)),
                    value: enabled.contains(entry.key),
                    onChanged: (v) =>
                        _notifier.setWebSearchDirectEngineEnabled(entry.key, v),
                  ),
                const SizedBox(height: 4),
                budgetSlider(
                  label: '低风险引擎每 10 分钟搜索上限'
                      '（必应/360/中国搜索，当前 ${settings.webSearchDirectLowRiskPerWindow} 次）',
                  hint: '容忍度高，可适当放宽；预算用于控制连续任务的请求节奏',
                  value: settings.webSearchDirectLowRiskPerWindow,
                  min: 1,
                  max: 20,
                  onChanged: (v) =>
                      _notifier.setWebSearchDirectLowRiskPerWindow(v),
                ),
                const SizedBox(height: 4),
                budgetSlider(
                  label: '高风险引擎每 10 分钟搜索上限'
                      '（搜狗/百度/夸克，当前 ${settings.webSearchDirectHighRiskPerWindow} 次）',
                  hint: '风控激进，默认 4 次"细水长流"——偶尔贡献高质量结果，'
                      '避免连续请求被判定机器行为而封禁',
                  value: settings.webSearchDirectHighRiskPerWindow,
                  min: 1,
                  max: 6,
                  onChanged: (v) =>
                      _notifier.setWebSearchDirectHighRiskPerWindow(v),
                ),
                if (enabled.isEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    '⚠️ 所有直连引擎均已关闭：端侧直连不可用。',
                    style:
                        TextStyle(fontSize: 12, color: Colors.orange.shade800),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

