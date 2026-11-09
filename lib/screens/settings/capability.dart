part of '../settings_screen.dart';

// =========================================================================
// 「能力」Tab（2026-10-24 用户定案）：插件与技能是**智能体的能力扩展面**，
// 与「智能体 / 上下文压缩 / 人格」这些原生能力放在一起，按梯队管理 ——
// 不再塞进「开发者」（那个 Tab 是 Dev Agent / SSH 的地盘，能力开关藏在那儿没人找得到）。
//
// 三档梯队：
//   ① 原生能力（默认开启）：平台自带的开关，功能"突然没有了"第一个来这儿看；
//   ② 插件：启用 / 参数 / 方案档 / 诊断（启用后图标出现在聊天输入框那一行）；
//   ③ 技能（Skills）：提示词模板，智能体按「何时触发」自己取用。
// =========================================================================
class CapabilitySettingsBody extends ConsumerStatefulWidget {
  const CapabilitySettingsBody({this.controller});

  /// 跳回「智能体」Tab 细调时用（人格表单在那边；技能管理已内联本面板）。
  final TabController? controller;

  @override
  ConsumerState<CapabilitySettingsBody> createState() =>
      CapabilitySettingsBodyState();
}

class CapabilitySettingsBodyState
    extends ConsumerState<CapabilitySettingsBody> {
  void _gotoAgentTab() => widget.controller?.animateTo(3);
  // ================= 语音（Edge TTS 播报 + 端侧 ASR 输入）=================

  /// Edge TTS 音色列表（null = 拉取中；失败回退内置常用清单）。
  List<TtsVoiceInfo>? _ttsVoices;
  Future<bool>? _asrModelReady;

  Future<void> _loadTtsVoices() async {
    final voices = await EdgeTtsService.instance.listVoices();
    if (!mounted) return;
    setState(() => _ttsVoices = voices);
  }

  static String _signedPct(int v) => '${v >= 0 ? '+' : ''}$v%';
  static String _signedHz(int v) => '${v >= 0 ? '+' : ''}$v Hz';

  @override
  void initState() {
    super.initState();
    _loadTtsVoices();
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
                    // 音色下拉（拉取失败回退内置清单）。
                    // isExpanded=true：选中项占满行宽——方言音色全名很长
                    // （zh-CN-shaanxi-XiaoniNeural），不放开会把 suffixIcon
                    // 挤出界 → RenderFlex RIGHT OVERFLOWED 溢出条遮挡 UI
                    //（真机实锤 87px）。
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
                        // 分组头（不可点，value 用哨兵防与真实音色冲突）。
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
                              // 英文音色读不出中文（服务端返回空音频），
                              // 试听文本按音色语言选择。
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

  /// 音色列表里不存在当前设置值（拉取失败/下架）→ 返回 null 让下拉显示空，
  /// 但保存值不动，列表恢复后自动回显。
  String? _ttsVoiceInList(List<TtsVoiceInfo>? voices, String current) {
    if (voices == null) return current;
    for (final v in voices) {
      if (v.shortName == current) return current;
    }
    return null;
  }

  Future<void> _editAsrHotwords(SettingsNotifier notifier) async {
    final ctrl = TextEditingController(text: settings0HotwordCustom());
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

  String settings0HotwordCustom() =>
      // Riverpod 正规读口：notifier.state 对外 protected，读状态一律走 provider。
      ref.read(settingsProvider).asrHotwordCustom;

  /// 编辑某个热词分类的词表：预填生效词（默认 + 增 − 删），保存时算差量
  /// （增词 = 新表 − 默认表；删词 = 默认表 − 新表）持久化；「恢复默认」
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


  Widget _header(String title, String subtitle) {
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style:
                  const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
          Text(subtitle,
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
        ],
      ),
    );
  }

  Widget _card({required List<Widget> children}) => Card(
        margin: EdgeInsets.zero,
        child: Padding(
            padding: const EdgeInsets.all(4),
            child: Column(children: children)),
      );

  Widget _switchRow(String title, bool value,
      Future<void> Function(bool) onChanged, String subtitle) {
    return SwitchListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 10),
      title: Text(title, style: const TextStyle(fontSize: 13)),
      subtitle: Text(subtitle,
          style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
      value: value,
      onChanged: (v) => onChanged(v),
    );
  }

  Widget _infoRow(
      String title, String value, String subtitle, VoidCallback? onTap) {
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 10),
      title: Text(title, style: const TextStyle(fontSize: 13)),
      subtitle: Text(subtitle,
          style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(value, style: const TextStyle(fontSize: 12)),
          if (onTap != null) const Icon(Icons.chevron_right, size: 18),
        ],
      ),
      onTap: onTap,
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header('🟢 原生能力（默认开启）', '平台自带的能力。功能"突然没有了"，第一个来这儿看是不是被谁关了'),
          _card(children: [
            _switchRow('智能体模式', settings.agentEnabled, notifier.setAgentEnabled,
                '关掉就是纯聊天：没有工具、技能与人格'),
            _switchRow('上下文压缩', settings.agentCompactEnabled,
                notifier.setAgentCompactEnabled, '长对话自动压历史，免得一步就顶满上下文'),
            _switchRow('子代理（并行拆解）', settings.agentSubagentEnabled,
                notifier.setAgentSubagentEnabled, '把大任务拆给子代理并行跑'),
            _infoRow('人格（Persona）', '标准 + 自定义', '标准人格开箱即用；增删自定义人格在「智能体」Tab',
                _gotoAgentTab),
          ]),
          _header('🔊 语音播报（Edge TTS）',
              '回答气泡出现 🔊 播报按钮；联网免费接口，失败静默降级'),
          _buildTtsCard(settings, notifier),
          const SizedBox(height: 14),
          _header('🎙️ 语音输入（端侧识别）',
              'sherpa-onnx 流式 ASR；热词偏置提升术语识别'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                              // ---- 端侧语音输入（sherpa-onnx ASR）设置 ----
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
                                  style: TextStyle(
                                      fontSize: 12, color: Colors.grey.shade600)),
                              const SizedBox(height: 4),
                              Wrap(
                                spacing: 6,
                                runSpacing: 2,
                                children: [
                                  for (final cat in hotwordCategories)
                                    FilterChip(
                                      label: Text(cat.name,
                                          style: const TextStyle(fontSize: 11)),
                                      selected:
                                          settings.asrHotwordCategories.isEmpty ||
                                              settings.asrHotwordCategories
                                                  .contains(cat.id),
                                      onSelected: (sel) {
                                        final current =
                                            settings.asrHotwordCategories;
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
                                              : current
                                                  .where((e) => e != cat.id)
                                                  .toList();
                                        }
                                        notifier.setAsrHotwordCategories(next);
                                      },
                                    ),
                                ],
                              ),
                              // 词表查看/编辑：逐分类展开看实际热词内容，
                              // 点进编辑框可增删词（差量持久化）。
                              ExpansionTile(
                                tilePadding: EdgeInsets.zero,
                                childrenPadding: const EdgeInsets.only(bottom: 4),
                                title: Text('热词词表（查看 / 编辑）',
                                    style: const TextStyle(fontSize: 14)),
                                subtitle: Text(
                                    '${hotwordCategories.length} 个分类，共 '
                                    '${hotwordCategories.fold<int>(0, (n, c) => n + effectiveCategoryWords(c.id, settings.asrHotwordAdded, settings.asrHotwordRemoved).length)} 个生效词；点分类可增删词',
                                    style: const TextStyle(fontSize: 12)),
                                children: [
                                  for (final cat in hotwordCategories)
                                    ListTile(
                                      dense: true,
                                      contentPadding: EdgeInsets.zero,
                                      title: Text(cat.name,
                                          style: const TextStyle(fontSize: 13)),
                                      subtitle: Text(
                                          '${effectiveCategoryWords(cat.id, settings.asrHotwordAdded, settings.asrHotwordRemoved).length} 个词',
                                          style: const TextStyle(fontSize: 11)),
                                      trailing:
                                          const Icon(Icons.edit_outlined, size: 16),
                                      onTap: () =>
                                          _editAsrCategoryWords(cat, notifier),
                                    ),
                                ],
                              ),
                              ListTile(
                                contentPadding: EdgeInsets.zero,
                                dense: true,
                                leading: const Icon(Icons.edit_note, size: 20),
                                title: const Text('自定义热词',
                                    style: TextStyle(fontSize: 14)),
                                subtitle: Text(
                                    settings.asrHotwordCustom.trim().isEmpty
                                        ? '每行一个词（人名/产品名等，同音自动校正）'
                                        : settings.asrHotwordCustom
                                                .trim()
                                                .split('\n')
                                                .length
                                                .toString() +
                                            ' 个词',
                                    style: const TextStyle(fontSize: 12)),
                                trailing: const Icon(Icons.edit_outlined, size: 18),
                                onTap: () => _editAsrHotwords(notifier),
                              ),
                              // 模型管理：状态 + 下载/删除
                              FutureBuilder<bool>(
                                future: _asrModelReady ??=
                                    AsrModelManager.isReady(),
                                builder: (ctx, snap) {
                                  final ready = snap.data ?? false;
                                  return ListTile(
                                    contentPadding: EdgeInsets.zero,
                                    dense: true,
                                    leading: Icon(
                                      ready
                                          ? Icons.check_circle
                                          : Icons.download_outlined,
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
                                                    onPressed: () =>
                                                        Navigator.pop(ctx, false),
                                                    child: const Text('取消')),
                                                FilledButton(
                                                    onPressed: () =>
                                                        Navigator.pop(ctx, true),
                                                    child: const Text('删除')),
                                              ],
                                            ),
                                          );
                                          if (ok == true) {
                                            await AsrModelManager.deleteModel();
                                            if (context.mounted) {
                                              ScaffoldMessenger.of(context)
                                                  .showSnackBar(const SnackBar(
                                                      content: Text('识别模型已删除')));
                                            }
                                          }
                                        } else {
                                          await AsrModelGate.ensureModelReady(
                                              context);
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
          ),
          const SizedBox(height: 14),
          _header('🧩 插件（能力扩展）', '启用后图标出现在聊天输入框那一行；参数、方案档、诊断都进这个面板'),
          _card(children: const [
            PluginsEntryTile(pluginsDirHint: '文档/plugins/<插件名>/plugin.json'),
          ]),
          const SizedBox(height: 14),
          _header('⚡ 技能（Skills）',
              '提示词模板；管理动作就地完成，不再跳智能体面板'),
          _card(children: const [SkillsManagementBody()]),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

