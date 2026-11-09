part of '../settings_screen.dart';

/// 语音基础配置合体（2026-10-25 从「能力与实验」面板抽出）：
/// 🔊 Edge TTS 播报 + 🎙️ 端侧 ASR 输入。挂在左栏「更多（基础配置）」面板
/// 直陈——这两块是基础配置不是能力扩展，且能力面板里其余小节
/// （原生能力开关=智能体面板、插件/技能=各自面板）全是重复入口，
/// 整个「能力与实验」面板从此不再从左栏可达。
class VoiceSettingsBody extends ConsumerStatefulWidget {
  const VoiceSettingsBody({super.key});

  @override
  ConsumerState<VoiceSettingsBody> createState() => _VoiceSettingsBodyState();
}

class _VoiceSettingsBodyState extends ConsumerState<VoiceSettingsBody> {
  /// Edge TTS 音色列表（null = 拉取中；失败回退内置常用清单）。
  List<TtsVoiceInfo>? _ttsVoices;
  Future<bool>? _asrModelReady;

  @override
  void initState() {
    super.initState();
    _loadTtsVoices();
  }

  Future<void> _loadTtsVoices() async {
    final voices = await EdgeTtsService.instance.listVoices();
    if (!mounted) return;
    setState(() => _ttsVoices = voices);
  }

  static String _signedPct(int v) => '${v >= 0 ? '+' : ''}$v%';
  static String _signedHz(int v) => '${v >= 0 ? '+' : ''}$v Hz';

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildTtsCard(settings, notifier),
        const SizedBox(height: 10),
        _buildAsrCard(settings, notifier),
      ],
    );
  }

  Widget _buildTtsCard(InferenceSettings settings, SettingsNotifier notifier) {
    final voices = _ttsVoices;
    final groups = groupTtsVoices(voices ?? kFallbackVoices);
    final tts = EdgeTtsService.instance;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildToggleTitle(
              '🔊 语音播报（Edge TTS）',
              settings.edgeTtsEnabled,
              notifier.setEdgeTtsEnabled,
              subtitle: '开 = 回答气泡出现 🔊 播报按钮；需联网（免费在线接口，'
                  '微软侧随时可能调整，失败会静默降级不打断聊天）',
            ),
            const SizedBox(height: 8),
            // 子设置：总开关关闭时置灰。
            Opacity(
              opacity: settings.edgeTtsEnabled ? 1.0 : 0.45,
              child: IgnorePointer(
                ignoring: !settings.edgeTtsEnabled,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildToggleTitle(
                      '回复后自动播报',
                      settings.edgeTtsAutoSpeak,
                      notifier.setEdgeTtsAutoSpeak,
                    ),
                    const SizedBox(height: 8),
                    // isExpanded=true：方言音色全名很长，不放开会溢出（真机实锤）。
                    DropdownButtonFormField<String>(
                      value: _ttsVoiceInList(voices, settings.edgeTtsVoice),
                      isExpanded: true,
                      decoration: InputDecoration(
                        labelText: '音色',
                        border: const OutlineInputBorder(),
                        isDense: true,
                        suffixIcon: voices == null
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: Padding(
                                  padding: EdgeInsets.all(8),
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2),
                                ),
                              )
                            : IconButton(
                                icon: const Icon(Icons.refresh, size: 18),
                                onPressed: () {
                                  setState(() => _ttsVoices = null);
                                  _loadTtsVoices();
                                },
                              ),
                      ),
                      items: [
                        for (var i = 0; i < groups.length; i++) ...[
                          DropdownMenuItem<String>(
                            enabled: false,
                            value: '◆group$i',
                            child: Text(
                              '── ${groups[i].title} ──',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                            ),
                          ),
                          for (final v in groups[i].voices)
                            DropdownMenuItem(
                              value: v.shortName,
                              child: Text('${v.localName} · ${v.shortName}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 13)),
                            ),
                        ],
                      ],
                      onChanged: (v) {
                        if (v != null) notifier.setEdgeTtsVoice(v);
                      },
                    ),
                    const SizedBox(height: 8),
                    _buildSliderRow(
                      label: '语速',
                      value: settings.edgeTtsRate,
                      min: -50,
                      max: 100,
                      divisions: 30,
                      display: _signedPct(settings.edgeTtsRate),
                      onChanged: notifier.setEdgeTtsRate,
                    ),
                    _buildSliderRow(
                      label: '音调',
                      value: settings.edgeTtsPitch,
                      min: -50,
                      max: 50,
                      divisions: 20,
                      display: _signedHz(settings.edgeTtsPitch),
                      onChanged: notifier.setEdgeTtsPitch,
                    ),
                    _buildSliderRow(
                      label: '音量',
                      value: settings.edgeTtsVolume,
                      min: -50,
                      max: 50,
                      divisions: 20,
                      display: _signedPct(settings.edgeTtsVolume),
                      onChanged: notifier.setEdgeTtsVolume,
                    ),
                    const SizedBox(height: 4),
                    // 试听：播报中显示停止。
                    ValueListenableBuilder<String?>(
                      valueListenable: tts.playingKey,
                      builder: (context, playing, _) {
                        final isPreview = playing == 'preview';
                        return OutlinedButton.icon(
                          icon: Icon(
                            isPreview ? Icons.stop : Icons.volume_up,
                            size: 18,
                          ),
                          label: Text(isPreview ? '停止' : '试听'),
                          onPressed: () async {
                            if (isPreview) {
                              await tts.stop();
                              return;
                            }
                            final ok = await tts.speak(
                              // 英文音色读不出中文，试听文本按音色语言选择。
                              settings.edgeTtsVoice.startsWith('en-')
                                  ? 'Hello, this is the TongYi-Lite voice '
                                      'preview. Rate ${_signedPct(settings.edgeTtsRate)}.'
                                  : '你好，这是 TongYi-Lite 的语音播报效果。'
                                      '当前语速${_signedPct(settings.edgeTtsRate)}，'
                                      '音色${settings.edgeTtsVoice}。',
                              key: 'preview',
                              voice: settings.edgeTtsVoice,
                              rate: settings.edgeTtsRate,
                              pitch: settings.edgeTtsPitch,
                              volume: settings.edgeTtsVolume,
                            );
                            if (ok || !mounted) return;
                            final err = tts.lastError;
                            if (err == null) return;
                            ScaffoldMessenger.of(context)
                              ..hideCurrentSnackBar()
                              ..showSnackBar(SnackBar(
                                content: Text('🔊 试听失败：$err'),
                                duration: const Duration(seconds: 4),
                              ));
                          },
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 音色列表里不存在当前设置值（拉取失败/下架）→ 下拉显示空，保存值不动。
  String? _ttsVoiceInList(List<TtsVoiceInfo>? voices, String current) {
    if (voices == null) return current;
    for (final v in voices) {
      if (v.shortName == current) return current;
    }
    return null;
  }

  Widget _buildAsrCard(InferenceSettings settings, SettingsNotifier notifier) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSectionHeader('🎙️ 语音输入（端侧识别）', context),
            _buildToggleTitle(
              '增强识别模式',
              settings.asrEnhancedMode,
              notifier.setAsrEnhancedMode,
              subtitle: 'beam search + 热词偏置：识别更准，首字延迟略增'
                  '（默认标准档 = greedy 流式）',
            ),
            const SizedBox(height: 4),
            Text('热词分类（未选 = 全部启用；提升术语识别准确率）',
                style:
                    TextStyle(fontSize: 12, color: Colors.grey.shade600)),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 2,
              children: [
                for (final cat in hotwordCategories)
                  FilterChip(
                    label:
                        Text(cat.name, style: const TextStyle(fontSize: 11)),
                    selected: settings.asrHotwordCategories.isEmpty ||
                        settings.asrHotwordCategories.contains(cat.id),
                    onSelected: (sel) {
                      final current = settings.asrHotwordCategories;
                      // 空 = 全部启用语义：首次取消某个分类时，
                      // 先把其他全部分类写进启用集。
                      List<String> next;
                      if (current.isEmpty) {
                        next = sel
                            ? current
                            : [
                                for (final c in hotwordCategories)
                                  if (c.id != cat.id) c.id
                              ];
                      } else {
                        next = sel
                            ? [...current, cat.id]
                            : current.where((e) => e != cat.id).toList();
                      }
                      notifier.setAsrHotwordCategories(next);
                    },
                  ),
              ],
            ),
            // 词表查看/编辑：逐分类展开看实际热词内容（差量持久化）。
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(bottom: 4),
              title: Text('热词词表（查看 / 编辑）',
                  style: const TextStyle(fontSize: 14)),
              subtitle: Text(
                  '${hotwordCategories.length} 个分类，共 '
                  '${hotwordCategories.fold<int>(0, (n, c) => n + effectiveCategoryWords(c.id, settings.asrHotwordAdded, settings.asrHotwordRemoved).length)} 个生效词；点分类可增删词',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12)),
              children: [
                for (final cat in hotwordCategories)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title:
                        Text(cat.name, style: const TextStyle(fontSize: 13)),
                    subtitle: Text(
                        '${effectiveCategoryWords(cat.id, settings.asrHotwordAdded, settings.asrHotwordRemoved).length} 个词',
                        style: const TextStyle(fontSize: 11)),
                    trailing: const Icon(Icons.edit_outlined, size: 16),
                    onTap: () => _editAsrCategoryWords(cat, notifier),
                  ),
              ],
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: const Icon(Icons.edit_note, size: 20),
              title:
                  const Text('自定义热词', style: TextStyle(fontSize: 14)),
              subtitle: Text(
                  settings.asrHotwordCustom.trim().isEmpty
                      ? '每行一个词（人名/产品名等，同音自动校正）'
                      : settings.asrHotwordCustom.trim().split('\n').length
                              .toString() +
                          ' 个词',
                  style: const TextStyle(fontSize: 12)),
              trailing: const Icon(Icons.edit_outlined, size: 18),
              onTap: () => _editAsrHotwords(notifier),
            ),
            // 模型管理：状态 + 下载/删除
            FutureBuilder<bool>(
              future: _asrModelReady ??= AsrModelManager.isReady(),
              builder: (ctx, snap) {
                final ready = snap.data ?? false;
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  leading: Icon(
                    ready ? Icons.check_circle : Icons.download_outlined,
                    size: 20,
                    color: ready ? Colors.green : Colors.orange,
                  ),
                  title: Text(ready ? '识别模型：已就绪' : '识别模型：未下载',
                      style: const TextStyle(fontSize: 14)),
                  subtitle: const Text(
                      'sherpa-onnx 流式中文模型（约 160MB，'
                      '首次语音时自动下载，支持断点续传）',
                      style: TextStyle(fontSize: 12)),
                  trailing: TextButton(
                    onPressed: () async {
                      if (ready) {
                        final ok = await showDialog<bool>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: const Text('删除识别模型？'),
                            content: const Text('删除后语音输入不可用，'
                                '再次长按说话会重新下载。'),
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
                        if (ok == true) {
                          await AsrModelManager.deleteModel();
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('识别模型已删除')));
                          }
                        }
                      } else {
                        await AsrModelGate.ensureModelReady(context);
                      }
                      if (context.mounted) {
                        setState(() => _asrModelReady = null);
                      }
                    },
                    child: Text(ready ? '删除' : '下载',
                        style: const TextStyle(fontSize: 12)),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _editAsrHotwords(SettingsNotifier notifier) async {
    // 读状态走 ref.read(provider)（notifier.state 越权，见 Riverpod 正规用法）。
    final ctrl = TextEditingController(
        text: ref.read(settingsProvider).asrHotwordCustom);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('自定义热词'),
        content: TextField(
          controller: ctrl,
          maxLines: 8,
          minLines: 4,
          decoration: const InputDecoration(
            hintText: '每行一个词，例如：\n彤 Yi\nTongYi-Lite\nsherpa',
            border: OutlineInputBorder(),
          ),
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
    if (ok == true) {
      await notifier.setAsrHotwordCustom(ctrl.text);
      if (mounted) setState(() {});
    }
  }

  /// 编辑某个热词分类的词表：预填生效词，保存时算差量持久化；「恢复默认」
  /// 清空该分类差量。
  Future<void> _editAsrCategoryWords(
      HotwordCategory cat, SettingsNotifier notifier) async {
    final defaults = defaultCategoryWords(cat.id);
    final settings = ref.read(settingsProvider);
    final effective = effectiveCategoryWords(
        cat.id, settings.asrHotwordAdded, settings.asrHotwordRemoved);
    final ctrl = TextEditingController(text: effective.join('\n'));
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('热词：${cat.name}'),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                  '内置 ${defaults.length} 个词，当前生效 '
                  '${effective.length} 个。一行一个词：新增行 = 加词，'
                  '删掉行 = 从该分类移除。',
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
              const SizedBox(height: 8),
              TextField(
                controller: ctrl,
                maxLines: 12,
                minLines: 8,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => ctrl.text = defaults.join('\n'),
            child: const Text('恢复默认'),
          ),
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('保存')),
        ],
      ),
    );
    if (ok != true) return;
    final d = diffCategoryWords(cat.id, ctrl.text.split('\n'));
    await notifier.setAsrHotwordCategoryEdit(cat.id, d.added, d.removed);
    if (mounted) setState(() {});
  }
}
