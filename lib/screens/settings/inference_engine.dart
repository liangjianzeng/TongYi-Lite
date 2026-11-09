part of '../settings_screen.dart';

class InferenceEngineSettingsBody extends ConsumerWidget {
  const InferenceEngineSettingsBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final modelState = ref.watch(modelManagerProvider);
    final gpuSettings = ref.watch(settingsProvider);
    final gpuNotifier = ref.read(settingsProvider.notifier);
    // 设备 SoC 信息：天玑（MediaTek）芯片不支持 OpenCL，禁用该后端并提示。
    final deviceInfo = ref.watch(deviceInfoProvider).valueOrNull ?? const {};
    final isDimensity = _isDimensitySoC(deviceInfo);
    // 天玑不支持 OpenCL：若此前选了 opencl 后端，自动切到 Vulkan。
    if (isDimensity && gpuSettings.gpuBackend == 'opencl') {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (gpuSettings.gpuBackend == 'opencl') {
          gpuNotifier.setGpuBackend('vulkan');
        }
      });
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ---- GPU 加速设置卡片 ----
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildToggleTitle(
                    '⚙️ GPU 加速',
                    gpuSettings.enableGpu,
                    gpuNotifier.setEnableGpu,
                  ),
                  const SizedBox(height: 10),
                  // 分段钮不带图标（图标+长英文 label 在窄面板必然断行成
                  // 「Ope nCL / Vulk an」，2026-10-25 真机截图定案），字号 12。
                  SegmentedButton<String>(
                    segments: [
                      const ButtonSegment(
                        value: 'auto',
                        label: Text('自动', style: TextStyle(fontSize: 12)),
                      ),
                      ButtonSegment(
                        value: 'opencl',
                        label: Text('OpenCL', style: TextStyle(fontSize: 12)),
                        enabled: !isDimensity,
                      ),
                      const ButtonSegment(
                        value: 'vulkan',
                        label: Text('Vulkan', style: TextStyle(fontSize: 12)),
                      ),
                    ],
                    selected: {gpuSettings.gpuBackend},
                    onSelectionChanged: gpuSettings.enableGpu
                        ? (sel) {
                            final v = sel.first;
                            if (v != gpuSettings.gpuBackend) {
                              gpuNotifier.setGpuBackend(v);
                            }
                          }
                        : null,
                    showSelectedIcon: false,
                    style: ButtonStyle(
                      visualDensity: VisualDensity.compact,
                      textStyle: WidgetStatePropertyAll(
                        TextStyle(fontSize: 12, color: Colors.grey.shade800),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    isDimensity
                        ? '当前设备为天玑（MediaTek）芯片：不支持 OpenCL，GPU 加速请优先使用 Vulkan'
                        : (gpuSettings.enableGpu
                            ? _gpuBackendHint(gpuSettings.gpuBackend)
                            : 'GPU 已关闭（纯 CPU）'),
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: Slider(
                          value: gpuSettings.gpuLayers.toDouble(),
                          min: 0,
                          max: 100,
                          divisions: 100,
                          label: '${gpuSettings.gpuLayers}',
                          onChanged: _gpuLayersEditable(gpuSettings)
                              ? (v) => gpuNotifier.setGpuLayers(v.round())
                              : null,
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 56,
                        child: Text(
                          '${gpuSettings.gpuLayers} 层',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontWeight: FontWeight.w500,
                            color: Colors.grey.shade500,
                          ),
                        ),
                      ),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      _gpuLayersHint(gpuSettings),
                      style:
                          TextStyle(fontSize: 12, color: Colors.grey.shade600),
                    ),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 10),

          // ---- 思考模式设置卡片 ----
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildToggleTitle(
                    '🧠 思考模式',
                    gpuSettings.enableThinking,
                    (v) {
                      gpuNotifier.setEnableThinking(v);
                      // 立即同步到原生层，无需重新加载模型。
                      ref.read(inferenceServiceProvider).setEnableThinking(v);
                    },
                    subtitle: '先输出推理过程再给结论；直接作答更快（仅思考型模型生效）',
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 10),

          // ---- MTP 加速全局开关卡片 ----
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildToggleTitle(
                    '🚀 MTP 加速（端侧推测解码）',
                    gpuSettings.enableMtpFeature,
                    gpuNotifier.setEnableMtpFeature,
                    subtitle: '默认关闭；开启后在模型卡片配置各模型 MTP（仅高端机按需开启）',
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 10),

          // ---- dspark 加速全局开关卡片 ----
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildToggleTitle(
                    '⚡ dspark 加速（整块投机解码）',
                    gpuSettings.enableDsparkFeature,
                    gpuNotifier.setEnableDsparkFeature,
                    subtitle: '默认关闭；开启后在模型卡片配置各模型 dspark（Q1_0 低比特模型收益有限）',
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 10),

          // ---- 上下文大小设置卡片 ----
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildSectionHeader('🧩 上下文大小（Context Size）', context),
                  const SizedBox(height: 4),
                  const Text(
                    '模型可记忆的对话长度上限，越大占用内存越多',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: Slider(
                          value: gpuSettings.contextSize.toDouble(),
                          min: 1024,
                          max: 65536,
                          divisions: 63,
                          // k 级显示（1k 步进恒整 k），不再显示裸数值。
                          label: '${gpuSettings.contextSize ~/ 1024}k',
                          onChanged: (v) =>
                              gpuNotifier.setContextSize(v.round()),
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 78,
                        child: Text(
                          '${gpuSettings.contextSize ~/ 1024}k token',
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontWeight: FontWeight.w500),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 10),

          // ---- 推理引擎扩展设置卡片（视觉投影器 / 资源监控）----
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildSectionHeader('🧠 推理引擎扩展', context),
                  const SizedBox(height: 12),
                  _buildToggleTitle(
                    '🖼️ 默认加载视觉投影器',
                    gpuSettings.autoLoadMmproj,
                    gpuNotifier.setAutoLoadMmproj,
                    subtitle: '针对有投影器（mmproj）的视觉模型；关闭后仅文本推理',
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 10),

          // ---- GPU 推理防闪纹卡片（2026-10-07 小米13 定案）----
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildToggleTitle(
                    '🖥️ GPU 推理时限制刷新率（防闪纹）',
                    gpuSettings.inferenceLimitRefreshRate,
                    gpuNotifier.setInferenceLimitRefreshRate,
                    subtitle: '模型加载/prefill 的瞬时显存带宽会挤占显示供帧'
                        '（Adreno 闪条纹），期间自动锁 60Hz、回合结束恢复 120Hz。'
                        'CPU 后端无此现象不受影响',
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 10),

          // ---- GPU 稳定性调优（2026-10-07 小米13 GPU fault 定案）----
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('⚙️ GPU 稳定性调优（防 GPU fault）',
                      style: const TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 14)),
                  const SizedBox(height: 4),
                  Text(
                    'Adreno 持续满血计算可能触发 GPU 挂死'
                    '（屏幕随机彩色乱码，Vulkan 档可升级为闪退）。',
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                  ),
                  const Divider(height: 20),
                  _buildSliderRow(
                    label: 'prefill 宽度（n_ubatch）',
                    value: gpuSettings.gpuNUbatch,
                    min: 0,
                    max: 512,
                    divisions: 16,
                    display: gpuSettings.gpuNUbatch == 0
                        ? '自动'
                        : '${gpuSettings.gpuNUbatch}',
                    onChanged: gpuNotifier.setGpuNUbatch,
                    hint: '0=自动（统一 512，split-MoE 按 bank 自动收敛）；调小拆'
                        '单次计算 burst 缓解 GPU 挂死，prefill 变慢。32 的倍数步'
                        '进，改后重新加载模型生效',
                  ),
                  _buildToggleTitle(
                    'Vulkan 禁用 subgroup',
                    gpuSettings.vkNoSubgroup,
                    gpuNotifier.setVkNoSubgroup,
                    subtitle: 'turnip GPU 挂死嫌疑源之一，开启可能更稳但略降速；'
                        '重启 app 后生效',
                  ),
                  _buildToggleTitle(
                    '🧩 智能 MoE 加载',
                    gpuSettings.smartMoeEnabled,
                    gpuNotifier.setSmartMoeEnabled,
                    subtitle: '超大 MoE 模型（拆分专家版）：dense 权重常驻内存，'
                        '路由专家按需流式读入专家窗口。关闭则整包全加载'
                        '（内存不足的大模型会失败）。改后重新加载模型生效',
                  ),
                  const Divider(height: 24),
                  // 热专家 bank：默认按机型 MemAvailable 自动分档（12G/16G
                  // 机型预算不同）；手动覆写走通配键 '*'，滑条固定槽数。
                  _buildToggleTitle(
                    '专家池手动覆写',
                    gpuSettings.moeBankOverrideByModel['*'] != null,
                    (v) => gpuNotifier.setMoeBankOverride('*', v ? 16 : null),
                    subtitle: '热专家常驻槽数（8–64）。默认自动分档：按机型可用内存 '
                        '− 系统保留 − KV − 草稿 − 视觉 的预算÷单专家体积；16G 机型'
                        '自动多驻留专家、少换入。开启后按滑条固定。改后重新加载模型生效',
                  ),
                  if (gpuSettings.moeBankOverrideByModel['*'] != null)
                    _buildSliderRow(
                      label: '专家池槽数',
                      value: gpuSettings.moeBankOverrideByModel['*']!,
                      min: 8,
                      max: 64,
                      divisions: 14,
                      display: '${gpuSettings.moeBankOverrideByModel['*']}',
                      onChanged: (v) => gpuNotifier.setMoeBankOverride('*', v),
                      hint: '槽数 × 单专家体积 = 常驻内存；过大挤占 KV/视觉，'
                          '过小换入频繁。参考自动值（推理日志「智能 MoE 加载」行）',
                    ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 10),

          // ---- OOM 内存守卫设置卡片 ----
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildToggleTitle(
                    '🛡️ OOM 内存守卫',
                    gpuSettings.oomGuardEnabled,
                    gpuNotifier.setOomGuardEnabled,
                    subtitle: gpuSettings.oomGuardEnabled
                        ? '加载前预检内存余量，超出则拒绝加载，防止整机硬死机'
                        : '⚠️ 已关闭：超大模型可强行加载，内存不足时可能整机死机重启',
                  ),
                  // 余量滑条仅守卫开启时可调；关闭时置灰直观反映「不生效」。
                  Opacity(
                    opacity: gpuSettings.oomGuardEnabled ? 1.0 : 0.45,
                    child: IgnorePointer(
                      ignoring: !gpuSettings.oomGuardEnabled,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Divider(height: 24),
                          _buildHeadroomSlider(
                            label: '预检余量',
                            value: gpuSettings.oomPreHeadroomMb,
                            onChanged: gpuNotifier.setOomPreHeadroomMb,
                            hint: '加载前可用内存需超出模型体积至少该余量，否则拒绝加载；'
                                '调小更容易放过极限大模型，调大更保守',
                          ),
                          _buildHeadroomSlider(
                            label: '加载后余量',
                            value: gpuSettings.oomPostHeadroomMb,
                            onChanged: gpuNotifier.setOomPostHeadroomMb,
                            hint: '加载完成后 KV 缓存/图计算缓冲的内存预算 = '
                                '可用内存 − 该余量；调小给上下文更大空间，调大更保守',
                          ),
                        ],
                      ),
                    ),
                  ),
                  Text(
                    '默认 768 / 1536 MB（与原生层一致）。修改后下次加载模型生效',
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 10),

          // ---- KV 缓存精度卡片（手机必须量化：默认 Q4） ----
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '🧮 KV 缓存精度',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(
                        value: 'q4_0',
                        // 标签留短（"默认"已由下方灰字说明），否则 SegmentedButton
                        // 三段"图标+文字"在同一 Row，最宽段把整行撑爆→窄屏(830)裁切显示不全。
                        label: Text('Q4'),
                        icon: Icon(Icons.compress, size: 16),
                      ),
                      ButtonSegment(
                        value: 'q8_0',
                        label: Text('Q8'),
                        icon: Icon(Icons.balance, size: 16),
                      ),
                      ButtonSegment(
                        value: 'f16',
                        label: Text('F16'),
                        icon: Icon(Icons.speed, size: 16),
                      ),
                    ],
                    selected: {gpuSettings.kvCacheType},
                    onSelectionChanged: (sel) {
                      final v = sel.first;
                      if (v != gpuSettings.kvCacheType) {
                        gpuNotifier.setKvCacheType(v);
                      }
                    },
                    showSelectedIcon: false,
                    style: ButtonStyle(
                      visualDensity: VisualDensity.compact,
                      textStyle: WidgetStatePropertyAll(
                        TextStyle(fontSize: 12, color: Colors.grey.shade800),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '端侧内存有限，KV 缓存默认 Q4 量化（所有本地模型生效）；'
                    'Q8 精度更高、更占内存。仅量化 K 部分，V 保持 F16'
                    '（V 量化需开启下方 flash-attn）。'
                    'F16 不量化：混合架构（GDN+注意力，如 Ling）GPU 卸载时'
                    'Q4 K 会把注意力链踢回 CPU，选 F16 恢复全 GPU 路径。'
                    '修改后重新加载模型生效',
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 10),

          // ---- flash attention 卡片（P1：实验性，默认关） ----
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '⚡ Flash Attention（实验性）',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(
                        value: false,
                        label: Text('关（默认）'),
                        icon: Icon(Icons.shield_outlined, size: 16),
                      ),
                      ButtonSegment(
                        value: true,
                        label: Text('开'),
                        icon: Icon(Icons.flash_on, size: 16),
                      ),
                    ],
                    selected: {gpuSettings.flashAttn},
                    onSelectionChanged: (sel) {
                      final v = sel.first;
                      if (v != gpuSettings.flashAttn) {
                        gpuNotifier.setFlashAttn(v);
                      }
                    },
                    showSelectedIcon: false,
                    style: ButtonStyle(
                      visualDensity: VisualDensity.compact,
                      textStyle: WidgetStatePropertyAll(
                        TextStyle(fontSize: 12, color: Colors.grey.shade800),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '开启后 attention 走 FA 内核，长上下文 prefill/decode 显存'
                    '与速度收益明显；V 缓存跟随 K 一起量化（省一半 KV 内存）。'
                    'hybrid（recurrent 层）架构会自动保持关闭。历史上该开关'
                    '在 KV 复用路径上出过乱码，开启后请先做一次多轮对话测试。'
                    '修改后重新加载模型生效',
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 10),

          // ---- 引擎状态卡片 ----
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildSectionHeader('🧠 推理引擎状态', context),
                  const SizedBox(height: 12),

                  // Status row
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('当前状态:',
                          style: TextStyle(
                              fontSize: 14, color: Colors.grey.shade700)),
                      _buildLifecycleChipFromState(modelState),
                    ],
                  ),

                  if (modelState.modelName != null &&
                      modelState.modelName!.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('当前模型:',
                            style: TextStyle(
                                fontSize: 14, color: Colors.grey.shade700)),
                        Text(modelState.modelName!,
                            style:
                                const TextStyle(fontWeight: FontWeight.w500)),
                      ],
                    ),
                  ],

                  if (modelState.errorMessage != null &&
                      modelState.errorMessage!.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('错误:',
                            style: TextStyle(fontSize: 14, color: Colors.red)),
                        Expanded(
                          child: Text(
                            modelState.errorMessage!,
                            style: const TextStyle(
                                fontSize: 12, color: Colors.red),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),

          const SizedBox(height: 10),

          // ---- 操作按钮 ----
          _buildSectionHeader('⚡ 快捷操作', context),
          const SizedBox(height: 8),

          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const InferenceLogScreen()),
                    );
                  },
                  icon: const Icon(Icons.terminal),
                  label: const Text('查看推理日志'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: modelState.isLoaded
                      ? () => unloadModelAndNotify(
                          ref, context, modelState.modelName ?? '当前模型')
                      : null,
                  icon: const Icon(Icons.close),
                  label: const Text('卸载模型'),
                  style: OutlinedButton.styleFrom(
                    backgroundColor: Colors.red.shade700,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                ),
              ),
            ],
          ),

          if (modelState.isError && modelState.modelId != null) ...[
            const SizedBox(height: 8),
            ElevatedButton.icon(
              onPressed: () async {
                await ref
                    .read(modelManagerProvider.notifier)
                    .loadModel(modelState.modelId!);
              },
              icon: const Icon(Icons.refresh),
              label: const Text('重试加载'),
            ),
          ],

          const SizedBox(height: 24),

          // ---- 最近日志摘要 ----
          Row(
            children: [
              Expanded(child: _buildSectionHeader('📋 最近日志', context)),
              IconButton(
                icon: const Icon(Icons.copy, size: 18),
                tooltip: '复制全部日志',
                onPressed: () => _copyInferenceLogs(context, ref),
              ),
            ],
          ),
          const SizedBox(height: 4),

          RecentLogsWidget(),
        ],
      ),
    );
  }

  Widget _buildLifecycleChipFromState(ModelState modelState) {
    Color color;
    String label;
    switch (modelState.phase) {
      case ModelLifecyclePhase.idle:
        color = Colors.grey;
        label = '未加载';
        break;
      case ModelLifecyclePhase.loading:
        color = Colors.blue;
        label = '加载中...';
        break;
      case ModelLifecyclePhase.loaded:
        color = Colors.green;
        label = '已加载';
        break;
      case ModelLifecyclePhase.unloading:
        color = Colors.orange;
        label = '卸载中...';
        break;
      case ModelLifecyclePhase.error:
        color = Colors.red;
        label = '错误';
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(label, style: TextStyle(color: color, fontSize: 13)),
    );
  }

  // ---- GPU 后端辅助 ----

  /// OOM 余量滑条行：标签 + 当前值（MB）+ 滑条（0~4096，步进 64）+ 说明。
  Widget _buildHeadroomSlider({
    required String label,
    required int value,
    required ValueChanged<int> onChanged,
    required String hint,
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
              SizedBox(
                width: 88,
                child: Text(
                  '$value MB',
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w500),
                ),
              ),
            ],
          ),
          SizedBox(
            height: 34,
            child: Slider(
              value: value.clamp(0, 4096).toDouble(),
              min: 0,
              max: 4096,
              divisions: 64,
              label: '$value MB',
              onChanged: (v) => onChanged((v / 64).round() * 64),
            ),
          ),
          Text(hint,
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
        ],
      ),
    );
  }

  /// 判断是否为 MediaTek 天玑（Dimensity）SoC。
  /// 依据：Build.SOC_MANUFACTURER == "MediaTek"（API 31+），
  /// 或硬件/主板名含 MTK 平台代号（mtxxxx / MTxxxx）。
  static bool _isDimensitySoC(Map<String, String> info) {
    final socMfg = (info['socManufacturer'] ?? '').toLowerCase();
    if (socMfg.contains('mediatek')) return true;
    final hardware = (info['hardware'] ?? '').toLowerCase();
    final board = (info['board'] ?? '').toLowerCase();
    final socModel = (info['socModel'] ?? '').toLowerCase();
    if (hardware.startsWith('mt') || board.startsWith('mt')) return true;
    if (socModel.startsWith('mt')) return true;
    // 平台代号回退：常见天玑平台代号（部分机型 hardware 为 "mt6877" 等）
    if (RegExp(r'^mt\d{4,5}$').hasMatch(hardware)) return true;
    if (RegExp(r'^mt\d{4,5}$').hasMatch(board)) return true;
    return false;
  }

  String _gpuBackendHint(String backend) {
    switch (backend) {
      case 'opencl':
        return 'OpenCL：推荐后端';
      case 'vulkan':
        return 'Vulkan';
      case 'cpu':
        return 'CPU：纯 CPU 后端';
      default:
        return '自动：优先 OpenCL，无 GPU 时回落 CPU';
    }
  }

  /// 一键复制全部推理日志（最近日志摘要与日志页共用语义：全量拼接换行）。
  void _copyInferenceLogs(BuildContext context, WidgetRef ref) {
    final logs = ref.read(modelManagerProvider.notifier).loadingLogs;
    if (logs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('暂无日志可复制')),
      );
      return;
    }
    Clipboard.setData(ClipboardData(text: logs.join('\n')));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已复制 ${logs.length} 条日志')),
    );
  }

  bool _gpuLayersEditable(InferenceSettings s) {
    if (!s.enableGpu) return false;
    // CPU 无意义；其余后端（opencl/auto）允许调层数，Vulkan 暂不可调。
    return s.gpuBackend == 'opencl' || s.gpuBackend == 'auto';
  }

  String _gpuLayersHint(InferenceSettings s) {
    if (!s.enableGpu) return 'GPU 已关闭（纯 CPU）';
    if (_gpuLayersEditable(s)) {
      return '0 = 纯 CPU，越大卸载越多（全量 = 999）';
    }
    if (s.gpuBackend == 'vulkan') {
      return 'Vulkan 暂不可调层数';
    }
    return '当前后端固定，层数不可调';
  }
}

/// 智能体设置 Tab（v0.2.1 全新引擎对齐）。
///
/// 设计原则：
/// 1. **能力驱动展示**：特性块查询驱动模型的能力快照，不支持则置灰说明；
/// 2. **只保留新引擎真实消费的旋钮**：每项设置都映射到引擎消费点；
/// 3. 旧键不动，新键安全默认，旧配置无损迁移。
/// C3 执行质量观测卡：读取 ApplicationSupport/metrics/turn_metrics.jsonl
/// 最近 200 回合聚合（失败码分布/步数/重复率/撞限），给"智能体笨在哪一段"
/// 一个可见的落点——数据早已落盘，此前只差消费端。
class _ExecutionQualityCard extends StatefulWidget {
  @override
  State<_ExecutionQualityCard> createState() => _ExecutionQualityCardState();
}

class _ExecutionQualityCardState extends State<_ExecutionQualityCard> {
  Map<String, dynamic>? _agg;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final base = await getApplicationSupportDirectory();
      final agg = await TurnMetricsStore.aggregateFromDisk(
          '${base.path}/metrics');
      if (!mounted) return;
      setState(() => _agg = agg);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    }
  }

  String _fmtReasons(Map<String, dynamic> reasons) {
    if (reasons.isEmpty) return '无';
    final entries = reasons.entries.toList()
      ..sort((a, b) => (b.value as int).compareTo(a.value as int));
    return entries.map((e) => '${e.key}×${e.value}').join('、');
  }

  String _fmtFailures(Map<String, dynamic> codes) {
    if (codes.isEmpty) return '无';
    final entries = codes.entries.toList()
      ..sort((a, b) => (b.value as int).compareTo(a.value as int));
    return entries
        .take(3)
        .map((e) => '${e.key}×${e.value}')
        .join('、');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: _buildSectionHeader('📊 执行质量（最近回合）', context)),
                InkWell(
                  onTap: _load,
                  child: const Icon(Icons.refresh, size: 18),
                ),
              ],
            ),
            if (_error != null)
              Text('读取失败：$_error',
                  style: const TextStyle(fontSize: 12, color: Colors.red)),
            if (_agg == null && _error == null)
              const Padding(
                padding: EdgeInsets.all(8),
                child: SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(strokeWidth: 2)),
              )
            else if (_agg != null) ...[
              if ((_agg!['turns'] as int?) == 0)
                Text('暂无数据（跑几回合智能体后这里会聚合）',
                    style: TextStyle(
                        fontSize: 12, color: theme.colorScheme.onSurfaceVariant))
              else ...[
                Text(
                  '回合 ${_agg!['turns']} | 平均步数 '
                  '${((_agg!['avgSteps'] as num?) ?? 0).toStringAsFixed(1)} | '
                  '平均耗时 '
                  '${(((_agg!['avgDurationMs'] as num?) ?? 0) / 1000).toStringAsFixed(1)}s',
                  style: const TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 4),
                Text(
                  '结局分布：${_fmtReasons((_agg!['endReasons'] as Map?)?.cast<String, dynamic>() ?? const {})}',
                  style: const TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 4),
                Text(
                  '工具 ${_agg!['toolCalls']} 次（重复 '
                  '${_agg!['duplicateToolCalls']} / 提醒 '
                  '${_agg!['repeatReminders']}）| LLM 重试 ${_agg!['llmRetries']}',
                  style: const TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 4),
                Text(
                  '失败码 TOP：${_fmtFailures((_agg!['failureCodes'] as Map?)?.cast<String, dynamic>() ?? const {})}',
                  style: const TextStyle(fontSize: 12),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

