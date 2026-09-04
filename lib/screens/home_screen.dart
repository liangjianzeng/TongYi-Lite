import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart' show openAppSettings;

import '../providers/index.dart' show chatNotifierProvider, isGeneratingProvider, messagesProvider, conversationsProvider, currentModelIdProvider, kLocalVisionSupported;
import '../providers/model_provider.dart';
import '../providers/settings_provider.dart' show settingsProvider;
import '../services/inference_service.dart';
import '../providers/shared_providers.dart';
import '../models/conversation.dart';
import '../services/settings_service.dart';
import '../services/storage_permission_service.dart';
import '../widgets/chat_bubble.dart';
import 'settings_screen.dart';

/// App-lifetime guard: 启动自动加载默认模型只执行一次。
/// 放在库作用域，避免首页路由重建时重复触发（与设置页 `_appLaunchScanDone` 同风格）。
bool _autoLoadDefaultDone = false;

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  final _scrollController = ScrollController();
  final _textController = TextEditingController();
  String _currentConversationId = '';
  bool _initiallyLoaded = false;
  // When true, the view auto-scrolls to the newest message (bottom of the
  // list). Disabled once the user scrolls up to read history.
  bool _followStream = true;

  // Image picker state
  String? _selectedImagePath;
  final ImagePicker _picker = ImagePicker();

  // 语音拾音（按住说话）状态 —— 用 ValueNotifier 而非 setState 驱动，避免
  // 录音中重建 GestureDetector 导致「松手」手势丢失（此前重建会杀掉 onLongPressEnd）。
  final ValueNotifier<bool> _recordingNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<int> _recordingSecondsNotifier = ValueNotifier<int>(0);
  Timer? _recordingTimer;

  // 会话批量选择状态
  bool _conversationSelectionMode = false;
  final Set<String> _selectedConversations = {};

  // GPU/CPU 占用率监控（模型状态栏底部双色线）
  Timer? _sampleTimer;
  double _gpuUsage = 0.0;
  double _cpuUsage = 0.0;
  /// 当前采样模式：-1=停止，0=仅推理时采样（500ms），N>0=周期性采样（N 秒）。
  int _samplingMode = -1;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _initStoragePermission();
    _initConversation();
    _initAutoLoadDefaultModel();
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _textController.dispose();
    _recordingTimer?.cancel();
    _recordingTimer = null;
    _recordingNotifier.dispose();
    _recordingSecondsNotifier.dispose();
    _stopResourceSampling();
    super.dispose();
  }

  /// Track whether the user is near the bottom of the list (where the newest
  /// message lives) so we only auto-scroll while they're following the
  /// conversation, not when they've scrolled up to read history.
  void _onScroll() {
    if (!_scrollController.hasClients) return;
    // While a reply is streaming in, always keep following the bottom. The
    // auto-scroll animation (animateTo) fires scroll notifications mid-flight;
    // if we let those intermediate positions flip _followStream off, the
    // following stops and the incoming assistant message piles up off-screen.
    // So during generation we pin _followStream = true and ignore position.
    if (ref.read(isGeneratingProvider)) {
      if (!_followStream) setState(() => _followStream = true);
      return;
    }
    final pos = _scrollController.position;
    final nearBottom = pos.pixels >= pos.maxScrollExtent - 60;
    if (nearBottom != _followStream) {
      setState(() => _followStream = nearBottom);
    }
  }

  Future<void> _initStoragePermission() async {
    // 延迟一点时间显示权限对话框，避免阻塞启动
    Future.delayed(const Duration(milliseconds: 500), () async {
      await StoragePermissionService.checkAndRequestIfNeeded(context);
    });
  }

  Future<void> _initConversation() async {
    final notifier = ref.read(conversationsProvider.notifier);
    // Ensure the list is loaded from storage before deciding whether to seed.
    await notifier.ensureLoaded();
    var conversations = ref.read(conversationsProvider);
    if (conversations.isEmpty) {
      await notifier.create();
      conversations = ref.read(conversationsProvider);
    }
    setState(() {
      _currentConversationId = conversations.first.id;
      _initiallyLoaded = true;
    });
  }

  /// 启动自动加载「默认模型」：用户已在模型管理页勾选某个已缓存模型为默认，
  /// 每次进入首页时自动把该模型加载进内存。文件缺失/加载失败时静默跳过，
  /// 不影响首页正常使用。每个 APP 进程仅执行一次。
  Future<void> _initAutoLoadDefaultModel() async {
    if (_autoLoadDefaultDone) return;
    _autoLoadDefaultDone = true;

    // 直接读持久化设置，避免 settingsProvider 异步 _load 未完成时读到默认 null。
    final settings = await SettingsService().load();
    final defaultId = settings.defaultModelId;
    if (defaultId == null || defaultId.isEmpty || !mounted) return;

    final manager = ref.read(modelManagerProvider.notifier);
    if (manager.isBusy || manager.isLoadedState) return;

    final cached = await manager.isModelCached(defaultId);
    if (!cached || !mounted) return;

    final ok = await manager.loadModel(defaultId);
    if (!mounted) return;
    if (ok) {
      // 同步当前模型 id，使聊天默认使用该模型。
      ref.read(currentModelIdProvider.notifier).state = defaultId;
      manager.appendInferenceLog('启动自动加载默认模型: $defaultId');
    }
  }

  /// Pick image from camera or gallery
  Future<void> _pickImage() async {
    if (_selectedImagePath != null) {
      // Clear selected image
      setState(() => _selectedImagePath = null);
      return;
    }

    final source = await showDialog<ImageSource>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('选择图片来源'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt),
              title: const Text('拍照'),
              onTap: () async {
                // Check camera permission before proceeding
                final hasPermission = await StoragePermissionService.requestCameraPermission();
                if (!hasPermission) {
                  Navigator.pop(ctx);
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('相机权限被拒绝，请在设置中授予')),
                    );
                  }
                  return;
                }
                Navigator.pop(ctx, ImageSource.camera);
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('相册'),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );

    if (source == null) return;

    try {
      // 端侧视觉：把用户选图先「下采样」再喂模型，而不是原图直喂。
      // 真机实测：1920px 大图进视觉塔 → 单张图产出 ~2717 个 image token，
      // 视觉编码内存飙到 2.6GB+，推理卡死（消息一直转圈无输出）后被系统杀掉。
      // 压到 768px 后 token 数骤减（~300+），编码内存/耗时都大幅下降。
      final XFile? image = await _picker.pickImage(
        source: source,
        maxWidth: 768,
        maxHeight: 768,
        imageQuality: 85,
      );

      if (image != null) {
        setState(() => _selectedImagePath = image.path);
        _warnIfImageDropped();
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('选择图片失败: $e')),
      );
    }
  }

  /// 选图后提示：若当前实际路线不支持视觉，图片仅展示、不会发给模型。
  /// 仅为提示，不阻止发送；真正的强制门禁在 [ChatNotifier.sendMessage]。
  void _warnIfImageDropped() {
    if (!mounted) return;
    final settings = ref.read(settingsProvider);
    final activeApi = settings.activeApiModel();
    final hasLocalLoaded = ref.read(modelManagerProvider).isLoaded;
    final hasDefault = settings.defaultModelId != null;

    // 与 sendMessage 一致的路由判断：无本地意图且激活了 API → 走 API；
    // 否则 local-first（本地当前原生视觉未支持，一律不送图）。
    final useApi = activeApi != null && !hasLocalLoaded && !hasDefault;
    final visionCapable = useApi
        ? activeApi.visionCapable
        : kLocalVisionSupported; // 本地路线：原生视觉未支持 → false

    if (!visionCapable) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('⚠️ 当前模型不支持视觉，图片仅展示、不会发送给模型')),
      );
    }
  }

  // ------------------------------------------------------------------------
  // 语音拾音（按住说话 → 松手自动发送）
  // ------------------------------------------------------------------------

  /// 按住麦克风开始拾音。返回是否真正开始（模型支持语音且权限已授予）。
  Future<bool> _startRecording() async {
    // 当前模型必须支持语音（mmproj 带音频编码器）。
    final inference = ref.read(inferenceServiceProvider);
    final supportsAudio = await inference.supportsAudio();
    if (!supportsAudio) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('⚠️ 当前模型不支持语音理解，请加载 Gemma 4 E2B 模型')),
        );
      }
      return false;
    }
    // 麦克风权限（RECORD_AUDIO）。拒绝时给出「前往设置」引导，无需重装。
    final hasMic = await StoragePermissionService.requestMicrophonePermission();
    if (!hasMic) {
      if (mounted) _showMicPermissionDialog();
      return false;
    }
    final ok = await inference.startRecording();
    if (!ok) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('麦克风启动失败')),
        );
      }
      return false;
    }
    // 用 ValueNotifier 驱动 UI，不 setState —— 避免重建 GestureDetector 使松手失效。
    _recordingNotifier.value = true;
    _recordingSecondsNotifier.value = 0;
    _recordingTimer?.cancel();
    _recordingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _recordingSecondsNotifier.value++;
    });
    return true;
  }

  /// 松手/取消停止拾音。send=true 时若录音有效则自动作为语音消息发送。
  Future<void> _stopRecording({bool send = true}) async {
    if (!_recordingNotifier.value) return;
    _recordingTimer?.cancel();
    _recordingTimer = null;
    _recordingNotifier.value = false;

    final inference = ref.read(inferenceServiceProvider);
    final audioPath = await inference.stopRecording();
    if (audioPath == null || audioPath.isEmpty) {
      if (send && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('录音过短，已放弃')),
        );
      }
      return;
    }
    if (send && mounted) {
      // 松手自动发送：附带当前已输入的文字。
      await _sendMessage(audioPath: audioPath);
    }
  }

  /// 麦克风权限被拒：引导去系统设置授权（无需重装 APK）。
  void _showMicPermissionDialog() {
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('需要麦克风权限'),
        content: const Text(
          '语音输入需要「麦克风」权限。\n\n'
          '不需要重新安装：点击「前往设置」打开本应用权限页，把「麦克风」打开即可。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          ElevatedButton.icon(
            onPressed: () async {
              Navigator.pop(ctx);
              await openAppSettings();
            },
            icon: const Icon(Icons.settings),
            label: const Text('前往设置'),
          ),
        ],
      ),
    );
  }

  /// Send message with optional image / audio
  Future<void> _sendMessage({String? audioPath}) async {
    final text = _textController.text.trim();
    final imagePath = _selectedImagePath;

    // 语音消息可仅带音频（无文字）；普通文本/图片必须有内容。
    if (text.isEmpty && imagePath == null && audioPath == null) return;
    // 语音消息若附带文字则一并发送；否则提示为空文本（模型仍收到音频）。
    if (audioPath != null && text.isEmpty) {
      // 允许：仅语音，无文字。
    }

    // Collapse the keyboard immediately when sending so the chat area expands
    // to full screen while the reply streams in (don't wait for the reply).
    FocusScope.of(context).unfocus();

    final notifier = ref.read(chatNotifierProvider.notifier);
    // Turn on "follow the conversation" the instant we send. _sendMessage
    // awaits the full generation, so if we only enabled following afterwards
    // the streamed reply would scroll into view only once it finished. This
    // also covers the case where the user had scrolled up to read history
    // right before hitting send.
    _followStream = true;
    // Clear the input box immediately: the message is already composed in
    // `text` and is about to be dispatched to the model. Keeping the text in
    // the box until the whole reply finishes is confusing — it should empty
    // the moment the message is sent. 语音消息同样清空输入框（文字已随语音发送）。
    _textController.clear();
    setState(() => _selectedImagePath = null);
    try {
      await notifier.sendMessage(_currentConversationId, text,
          imagePath: imagePath, audioPath: audioPath);
    } catch (e) {
      // The send failed before leaving the client — restore the input so the
      // user can retry. (If it failed mid-generation the message is already
      // persisted and shown in the chat, so no restore needed there.)
      _textController.text = text;
      if (imagePath != null) setState(() => _selectedImagePath = imagePath);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('发送失败: $e', style: const TextStyle(color: Colors.white))),
      );
      return;
    }

    // Safety-net re-anchor once the reply is fully generated. Following was
    // already active during streaming (set true at send time, pinned while
    // isGenerating). This guarantees the final message is in view even if the
    // last streamed chunk arrived between two 500ms list refreshes.
    Future.delayed(const Duration(milliseconds: 100), () {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  /// Stop the in-flight reply. Native side sets should_stop, the completion
  /// loop returns promptly, the token stream closes and isGenerating flips
  /// back to false (so the button reverts to send mode automatically).
  Future<void> _stopGeneration() async {
    try {
      await ref.read(chatNotifierProvider.notifier).stopGeneration();
    } catch (e) {
      debugPrint('[HomeScreen] stopGeneration failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final isGenerating = ref.watch(isGeneratingProvider);
    final modelState = ref.watch(modelManagerProvider);

    // 每次 build 同步采样 Timer（幂等）：按监控开关/采样周期启停。
    _syncResourceSampling(isGenerating);

    return Scaffold(
      drawer: _buildConversationDrawer(),
      appBar: AppBar(
        // 紧凑标题栏：44px（默认 56），给主屏幕更多呈现空间。
        toolbarHeight: 44,
        title: const Text(
          'TongYi-Lite',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
        ),
        centerTitle: true,
        leading: Builder(
          builder: (ctx) => IconButton(
            icon: const Icon(Icons.forum_outlined),
            tooltip: '会话',
            onPressed: () => Scaffold.of(ctx).openDrawer(),
          ),
        ),
        actions: [
          _buildModelStatusChip(modelState, isGenerating),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: '设置',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SettingsScreen()),
              );
            },
          ),
        ],
      ),
      body: Column(
        children: [
          // ---- Inline model status (only shows loading/unloading/error progress) ----
          _buildInlineProgress(modelState, isGenerating),
          // ---- GPU/CPU 占用率监控条（蓝=GPU、紫=CPU）----
          _buildResourceMonitor(),

          Expanded(
            child: _initiallyLoaded
                ? _buildMessagesList()
                : const Center(child: CircularProgressIndicator()),
          ),

          // Image preview (if selected)
          if (_selectedImagePath != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Stack(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.file(
                      File(_selectedImagePath!),
                      height: 100,
                      fit: BoxFit.cover,
                    ),
                  ),
                  Positioned(
                    top: 4,
                    right: 4,
                    child: Material(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(12),
                      child: IconButton(
                        icon: const Icon(Icons.close, color: Colors.white, size: 18),
                        onPressed: () => setState(() => _selectedImagePath = null),
                      ),
                    ),
                  ),
                ],
              ),
            ),

          _buildInputBar(isGenerating),
        ],
      ),
    );
  }

  // =========================================================================
  // Model status chip — compact indicator in AppBar leading area (left of title)
  // Tapping opens a bottom sheet with model name, unload / reload actions
  // =========================================================================

  Widget _buildModelStatusChip(ModelState ms, bool isGenerating) {
    final color = _colorFor(ms.phaseColor);

    // Idle + not generating → no chip needed (leading returns null-like empty widget)
    if (ms.phase == ModelLifecyclePhase.idle && !isGenerating) {
      return const SizedBox.shrink();
    }

    Widget label;
    IconData chipIcon;
    switch (ms.phase) {
      case ModelLifecyclePhase.loading:
        chipIcon = Icons.sync_alt;
        label = const Text('加载中…', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500));
        break;
      case ModelLifecyclePhase.loaded:
        chipIcon = isGenerating ? Icons.auto_awesome : Icons.check_circle;
        label = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isGenerating) _buildPulsingDot(),
            const SizedBox(width: 4),
            Text(
              ms.modelName ?? (ms.modelId ?? '模型就绪'),
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: color),
            ),
          ],
        );
        break;
      case ModelLifecyclePhase.unloading:
        chipIcon = Icons.sync_disabled;
        label = const Text('卸载中…', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500));
        break;
      case ModelLifecyclePhase.error:
        chipIcon = Icons.error_outline;
        label = const Text('加载失败', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500));
        break;
      case ModelLifecyclePhase.idle:
        chipIcon = Icons.memory_outlined;
        label = const Text('未加载', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500));
        break;
    }

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => _showModelStatusPopup(ms, isGenerating),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(chipIcon, size: 16, color: color),
              const SizedBox(width: 4),
              label,
            ],
          ),
        ),
      ),
    );
  }

  void _showModelStatusPopup(ModelState ms, bool isGenerating) {
    final notifier = ref.read(modelManagerProvider.notifier);
    // Resolve the display name consistently with the chip: loaded modelName
    // (catalog, already cleaned) → modelId → fallback. Avoids "未知模型".
    final modelName = ms.modelName ?? (ms.modelId ?? '未知模型');

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      // Sheet now carries a memory panel + logs + buttons; without
      // isScrollControlled the default 9/16-screen cap clips the content.
      isScrollControlled: true,
      builder: (ctx) => _ModelStatusSheet(
        phase: ms.phase,
        modelName: modelName,
        errorMessage: ms.errorMessage,
        logs: ms.loadingLogs,
        isGenerating: isGenerating,
        ref: ref,
        onUnload: () async {
          Navigator.pop(ctx);
          final ok = await notifier.unloadModel();
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(ok ? '✅ 已卸载模型，已释放内存' : '❌ 卸载失败，请重试'),
              backgroundColor: ok ? Colors.green : Colors.red,
              duration: const Duration(seconds: 2),
            ),
          );
        },
        onLoad: () async {
          final id = ms.modelId;
          if (id != null) {
            Navigator.pop(ctx);
            // 若正在推理，先停止生成，避免卸载/重载时原生引擎崩溃（红屏）。
            if (ref.read(isGeneratingProvider)) {
              try {
                await ref.read(chatNotifierProvider.notifier).stopGeneration();
              } catch (_) {}
              await Future.delayed(const Duration(milliseconds: 300));
            }
            await notifier.loadModel(id);
          }
        },
        onGoToSettings: () {
          Navigator.pop(ctx);
          Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen()));
        },
      ),
    );
  }

  /// Thin progress strip shown below the app bar only during loading / unloading / error.
  /// Hidden when idle and not generating — no space wasted.
  Widget _buildInlineProgress(ModelState ms, bool isGenerating) {
    // Only show during loading / unloading / error — idle and loaded states
    // are handled by the AppBar chip (no space wasted on chat area).
    if (ms.phase == ModelLifecyclePhase.idle || ms.phase == ModelLifecyclePhase.loaded) {
      return const SizedBox.shrink();
    }

    final color = _colorFor(ms.phaseColor);
    final generating = isGenerating ? ' · 思考中…' : '';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      color: color.withValues(alpha: 0.10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              if (ms.phase == ModelLifecyclePhase.loading || ms.phase == ModelLifecyclePhase.unloading)
                SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: color)),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  ms.modelName != null && ms.modelName!.isNotEmpty
                      ? '${ms.modelName!}$generating'
                      : (isGenerating ? '推理中…' : '模型未加载'),
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
                ),
              ),
            ],
          ),
          // Loading log or error message shown below the status row
          if (ms.phase == ModelLifecyclePhase.loading && ms.latestLog != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                ms.latestLog!,
                style: TextStyle(fontSize: 11, color: Colors.blue.shade700),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          if (ms.phase == ModelLifecyclePhase.error && ms.errorMessage != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      ms.errorMessage!,
                      style: TextStyle(fontSize: 11, color: Colors.red.shade700),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton.icon(
                    onPressed: ms.modelId != null
                        ? () => ref.read(modelManagerProvider.notifier).loadModel(ms.modelId!)
                        : null,
                    icon: const Icon(Icons.refresh, size: 14),
                    label: const Text('重试', style: TextStyle(fontSize: 11)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  // =========================================================================
  // GPU/CPU 占用率监控条（模型状态栏底部，蓝=GPU / 紫=CPU，宽=屏宽）
  // =========================================================================

  /// 按当前设置同步采样 Timer（每次 build 调用，幂等）：
  /// - 监控关闭 → 停止采样；
  /// - 采样周期 >0 → 周期性采样（空闲也更新）；
  /// - 采样周期 =0 → 仅推理时采样（500ms，空闲不采样省电）。
  void _syncResourceSampling(bool isGenerating) {
    final settings = ref.read(settingsProvider);
    if (!settings.showResourceMonitor) {
      _stopResourceSampling();
      return;
    }
    final interval = settings.resourceSampleIntervalSec;
    if (interval > 0) {
      if (_samplingMode != interval) {
        _stopResourceSampling();
        _sampleTimer = Timer.periodic(Duration(seconds: interval),
            (_) => _sampleResourceOnce());
        _samplingMode = interval;
      }
    } else {
      final want = isGenerating;
      if (want && _samplingMode != 0) {
        _stopResourceSampling();
        _sampleTimer = Timer.periodic(const Duration(milliseconds: 500),
            (_) => _sampleResourceOnce());
        _samplingMode = 0;
      } else if (!want && _samplingMode == 0) {
        _stopResourceSampling();
      }
    }
  }

  void _stopResourceSampling() {
    _sampleTimer?.cancel();
    _sampleTimer = null;
    _samplingMode = -1;
  }

  Future<void> _sampleResourceOnce() async {
    final r = await InferenceService().getResourceUsage();
    if (!mounted) return;
    setState(() {
      _gpuUsage = r.gpu ?? 0.0;
      _cpuUsage = r.cpu;
    });
  }

  /// 双色线监控条：蓝=GPU、紫=CPU，各占满屏宽，宽度 = 占用率%。
  /// 高度 4px（紧凑，不挤占聊天区）。
  Widget _buildResourceMonitor() {
    final settings = ref.watch(settingsProvider);
    if (!settings.showResourceMonitor) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      height: 4,
      color: const Color(0x11000000),
      padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 1),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _buildMonitorLine(color: const Color(0xFF2196F3), usage: _gpuUsage),
          const SizedBox(height: 1),
          _buildMonitorLine(color: const Color(0xFF9C27B0), usage: _cpuUsage),
        ],
      ),
    );
  }

  Widget _buildMonitorLine({required Color color, required double usage}) {
    return LayoutBuilder(builder: (context, constraints) {
      final maxW = constraints.maxWidth;
      final w = maxW * (usage / 100).clamp(0.0, 1.0);
      return Stack(
        children: [
          Container(height: 1, width: maxW, color: color.withValues(alpha: 0.15)),
          Container(height: 1, width: w, color: color),
        ],
      );
    });
  }

  Widget _buildPulsingDot() {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.3, end: 1.0),
      duration: const Duration(milliseconds: 800),
      curve: Curves.easeInOut,
      builder: (context, value, _) => Container(
        width: 12, height: 12,
        decoration: BoxDecoration(
          color: Colors.orange.shade400.withValues(alpha: value),
          shape: BoxShape.circle,
        ),
      ),
    );
  }

  Color _colorFor(String name) {
    switch (name) {
      case 'grey': return Colors.grey;
      case 'blue': return Colors.blue;
      case 'green': return Colors.green;
      case 'orange': return Colors.orange;
      case 'red': return Colors.red;
      default: return Colors.grey;
    }
  }

  // =========================================================================
  // Chat UI
  // =========================================================================

  Widget _buildMessagesList() {
    final messagesAsync = ref.watch(messagesProvider(_currentConversationId));

    return messagesAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, stack) => Center(child: Text('Error: $err')),
      data: (messages) {
        if (messages.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.auto_awesome, size: 64, color: Colors.grey.shade400),
                const SizedBox(height: 16),
                Text(
                  '你好！我是 TongYi-Lite\n端到端离线的 AI 助手',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 16),
                ),
              ],
            ),
          );
        }

        // Keep the newest message in view: auto-scroll to the bottom whenever
        // messages change while the user is following the conversation. This
        // makes streaming replies follow in real time instead of requiring a
        // manual scroll-up to reveal the new content.
        if (messages.isNotEmpty && _followStream) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_followStream && _scrollController.hasClients) {
              _scrollController.animateTo(
                _scrollController.position.maxScrollExtent,
                duration: const Duration(milliseconds: 160),
                curve: Curves.easeOut,
              );
            }
          });
        }

        // 聊天顺序：自上而下 = 最早的在上、最新的在下（messages 即旧→新）。
        // 无 reverse，maxScrollExtent 即最底部（最新消息）。
        return ListView.builder(
          controller: _scrollController,
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: messages.length,
          itemBuilder: (context, index) {
            final msg = messages[index];
            return ChatBubble(
              role: msg.role.name,
              content: msg.content,
              timestamp: msg.timestamp,
              // Newest message is the last index (messages are ordered oldest→newest).
              isStreaming: msg.isStreaming && index == messages.length - 1,
              imagePath: msg.imagePath,
              audioPath: msg.audioPath,
              inferenceStats: msg.inferenceStats,
            );
          },
        );
      },
    );
  }

  Widget _buildInputBar(bool isGenerating) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 录音中：波形动画 + 计时 + 「松手发送」提示（独立 widget，不重建手势区）。
        _buildRecordingBanner(),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 4)],
          ),
          child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _textController,
              decoration: InputDecoration(
                hintText: '输入消息...',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide.none,
                ),
                filled: true,
                fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                suffixIcon: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: Icon(
                        _selectedImagePath != null ? Icons.check_circle : Icons.image,
                        color: _selectedImagePath != null ? Colors.green : null,
                      ),
                      tooltip: _selectedImagePath != null ? '已选图片，点击清除' : '添加图片',
                      onPressed: isGenerating ? null : _pickImage,
                    ),
                    // 语音拾音：按住说话 → 松手自动发送（模型原生理解音频）。
                    // 注意：不要再包 Tooltip —— Tooltip 自身用「长按」弹提示，会抢走
                    // 录音手势（此前表现为只弹「按住说话」、无任何录制效果）。
                    // 用 ValueNotifier 驱动图标颜色/波形，避免录音中重建本 GestureDetector。
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onLongPressStart: isGenerating
                          ? null
                          : (_) {
                              _startRecording();
                            },
                      onLongPressEnd: isGenerating
                          ? null
                          : (_) {
                              _stopRecording(send: true);
                            },
                      onLongPressCancel: () {
                        // 按住后滑出按钮/被打断 → 放弃并停止录音（不发送）。
                        if (_recordingNotifier.value) _stopRecording(send: false);
                      },
                      child: ValueListenableBuilder<bool>(
                        valueListenable: _recordingNotifier,
                        builder: (_, recording, __) => Padding(
                          padding: const EdgeInsets.all(10),
                          child: Icon(
                            recording ? Icons.mic : Icons.mic_none,
                            color: recording ? Colors.red : null,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              onSubmitted: (_) {
                // Ignore Enter while a reply is streaming — the send button
                // has switched to "stop" mode during generation.
                if (isGenerating) return;
                _sendMessage();
              },
              maxLines: null,
            ),
          ),
          const SizedBox(width: 8),
          FloatingActionButton(
            onPressed: isGenerating ? _stopGeneration : _sendMessage,
            mini: true,
            tooltip: isGenerating ? '停止回复' : '发送',
            child: isGenerating
                ? const Icon(Icons.stop, size: 24)
                : const Icon(Icons.send),
          ),
        ],
      ),
      ),
    ],
    );
  }

  /// 录音中的横幅：波形动画 + 计时 + 「松手发送」提示。
  Widget _buildRecordingBanner() {
    return ValueListenableBuilder<bool>(
      valueListenable: _recordingNotifier,
      builder: (_, recording, __) {
        if (!recording) return const SizedBox.shrink();
        return Material(
          color: Colors.red.shade50,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Row(
              children: [
                const _RecordingWave(color: Colors.red),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '正在聆听 · 松手发送',
                    style: TextStyle(color: Colors.red.shade700, fontSize: 13),
                  ),
                ),
                ValueListenableBuilder<int>(
                  valueListenable: _recordingSecondsNotifier,
                  builder: (_, seconds, __) => Text(
                    '${seconds}s',
                    style: TextStyle(
                      color: Colors.red.shade700,
                      fontWeight: FontWeight.bold,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // =========================================================================
  // Conversation drawer — compact entry for managing (new / switch / delete)
  // =========================================================================

  Widget _buildConversationDrawer() {
    final conversations = ref.watch(conversationsProvider);
    return Drawer(
      child: SafeArea(
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: Colors.grey.shade300)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.forum, size: 24),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text('会话', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  ),
                  // 批量选择开关：进入多选模式后，点按会话变为勾选而非切换。
                  IconButton(
                    icon: Icon(_conversationSelectionMode ? Icons.close : Icons.checklist),
                    tooltip: _conversationSelectionMode ? '退出批量选择' : '批量选择',
                    color: _conversationSelectionMode ? Theme.of(context).colorScheme.primary : null,
                    onPressed: () {
                      setState(() {
                        _conversationSelectionMode = !_conversationSelectionMode;
                        if (!_conversationSelectionMode) _selectedConversations.clear();
                      });
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.add),
                    tooltip: '新建对话',
                    onPressed: _newConversation,
                  ),
                ],
              ),
            ),
            Expanded(
              child: conversations.isEmpty
                  ? const Center(child: Text('暂无会话', style: TextStyle(color: Colors.grey)))
                  : ListView.separated(
                      itemCount: conversations.length,
                      separatorBuilder: (_i1, _i2) => Divider(height: 1, color: Colors.grey.shade200),
                      itemBuilder: (ctx, i) {
                        final c = conversations[i];
                        return _buildConversationTile(c, c.id == _currentConversationId);
                      },
                    ),
            ),
            // 批量选择底部操作栏
            if (_conversationSelectionMode) ...[
              const Divider(height: 1),
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Text('已选 ${_selectedConversations.length} 个'),
                      const Spacer(),
                      OutlinedButton.icon(
                        onPressed: _selectedConversations.isEmpty
                            ? null
                            : _confirmBulkDelete,
                        icon: const Icon(Icons.delete_outline, size: 18),
                        label: Text('删除选中(${_selectedConversations.length})'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.red.shade700,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildConversationTile(Conversation c, bool isCurrent) {
    final updated = _formatTime(c.updatedAt);
    // 批量选择模式下：勾选框 + 点按切换选中；隐藏单个删除按钮。
    final selectionMode = _conversationSelectionMode;
    final selected = _selectedConversations.contains(c.id);
    return ListTile(
      dense: true,
      selected: isCurrent && !selectionMode,
      leading: selectionMode
          ? Icon(
              selected ? Icons.check_circle : Icons.circle_outlined,
              color: selected ? Theme.of(context).colorScheme.primary : Colors.grey.shade400,
            )
          : Icon(
              isCurrent ? Icons.chat_bubble : Icons.chat_bubble_outline,
              size: 20,
              color: isCurrent ? Theme.of(context).colorScheme.primary : Colors.grey,
            ),
      title: Text(
        c.title.isEmpty ? '新对话' : c.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontWeight: isCurrent && !selectionMode ? FontWeight.w600 : FontWeight.normal),
      ),
      subtitle: Text('$updated · ${c.messageCount} 条', style: const TextStyle(fontSize: 12)),
      onTap: selectionMode
          ? () {
              setState(() {
                if (!_selectedConversations.remove(c.id)) {
                  _selectedConversations.add(c.id);
                }
              });
            }
          : () => _switchConversation(c.id),
      trailing: selectionMode
          ? null
          : IconButton(
              icon: const Icon(Icons.delete_outline, size: 20),
              tooltip: '删除',
              onPressed: () => _confirmDelete(c),
            ),
    );
  }

  /// Create a new conversation and switch to it.
  Future<void> _newConversation() async {
    final notifier = ref.read(conversationsProvider.notifier);
    await notifier.create();
    final convs = ref.read(conversationsProvider);
    if (convs.isNotEmpty) {
      setState(() {
        _currentConversationId = convs.first.id;
        _followStream = true;
        _selectedImagePath = null;
      });
    }
    if (Navigator.of(context).canPop()) Navigator.of(context).pop();
  }

  /// Switch to an existing conversation (no-op if already current).
  void _switchConversation(String id) {
    if (id != _currentConversationId) {
      setState(() {
        _currentConversationId = id;
        _followStream = true;
        _selectedImagePath = null;
      });
    }
    Navigator.of(context).pop();
  }

  Future<void> _confirmDelete(Conversation c) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除会话'),
        content: Text('确定删除「${c.title.isEmpty ? '新对话' : c.title}」吗？\n该会话的所有消息将被永久删除。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed == true) await _deleteConversation(c.id);
  }

  /// 批量删除：先弹确认框，再逐个删除选中的会话。
  Future<void> _confirmBulkDelete() async {
    final n = _selectedConversations.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除会话'),
        content: Text('确定删除选中的 $n 个会话吗？\n每个会话的所有消息将被永久删除。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final notifier = ref.read(conversationsProvider.notifier);
    for (final id in _selectedConversations.toList()) {
      await notifier.delete(id);
    }
    // 若删到了当前会话，回落到任一剩余会话或新建一个，避免聊天区为空。
    if (_selectedConversations.contains(_currentConversationId)) {
      final convs = ref.read(conversationsProvider);
      if (convs.isEmpty) {
        await notifier.create();
      }
      final list = ref.read(conversationsProvider);
      setState(() {
        _currentConversationId = list.isEmpty ? '' : list.first.id;
        _followStream = true;
        _selectedImagePath = null;
      });
    }
    setState(() {
      _selectedConversations.clear();
      _conversationSelectionMode = false;
    });
  }

  Future<void> _deleteConversation(String id) async {
    final notifier = ref.read(conversationsProvider.notifier);
    await notifier.delete(id);
    // If we just deleted the active conversation, fall back to another one or
    // create a fresh one so the chat view is never left empty.
    if (id == _currentConversationId) {
      var convs = ref.read(conversationsProvider);
      if (convs.isEmpty) {
        await notifier.create();
        convs = ref.read(conversationsProvider);
      }
      setState(() {
        _currentConversationId = convs.isEmpty ? '' : convs.first.id;
        _followStream = true;
        _selectedImagePath = null;
      });
    }
  }

  String _formatTime(DateTime t) {
    final now = DateTime.now();
    final diff = now.difference(t);
    if (diff.inDays == 0) {
      final h = t.hour.toString().padLeft(2, '0');
      final m = t.minute.toString().padLeft(2, '0');
      return '$h:$m';
    } else if (diff.inDays == 1) {
      return '昨天';
    } else if (diff.inDays < 7) {
      return '${diff.inDays} 天前';
    }
    return '${t.month}/${t.day}';
  }
}

// =========================================================================
// Model status bottom sheet widget (outside the State class)
// =========================================================================

/// Reusable bottom-sheet widget for model status details.
class _ModelStatusSheet extends StatelessWidget {
  final ModelLifecyclePhase phase;
  final String modelName;
  final String? errorMessage;
  final List<String> logs;
  final bool isGenerating;
  final VoidCallback onUnload;
  final VoidCallback onLoad;
  final VoidCallback onGoToSettings;
  final WidgetRef ref;

  const _ModelStatusSheet({
    required this.phase,
    required this.modelName,
    this.errorMessage,
    this.logs = const [],
    required this.isGenerating,
    required this.onUnload,
    required this.onLoad,
    required this.onGoToSettings,
    required this.ref,
  });

  @override
  Widget build(BuildContext context) {
    final color = _sheetColorFor(phase);
    return Container(
      margin: const EdgeInsets.only(top: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.85,
      ),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Handle bar
              Container(
                width: 40, height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(color: Colors.grey.shade400, borderRadius: BorderRadius.circular(2)),
              ),
              // Title + icon
              Row(
                children: [
                  Icon(_sheetIconFor(phase), size: 28, color: color),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          phase == ModelLifecyclePhase.loaded ? '模型已就绪' : _phaseLabelFor(phase),
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                        ),
                        if (phase == ModelLifecyclePhase.loaded || phase == ModelLifecyclePhase.error)
                          Text(
                            modelName,
                            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                      ],
                    ),
                  ),
                  if (isGenerating) _buildPulsingDotLarge(),
                ],
              ),
              _MemoryPanel(ref: ref),
              const SizedBox(height: 12),
              // Inference / loading logs (scrollable, latest entries at bottom)
              if (logs.isNotEmpty)
                Container(
                  width: double.infinity,
                  constraints: const BoxConstraints(maxHeight: 160),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.blue.shade50,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: ListView.builder(
                    itemCount: logs.length,
                    itemBuilder: (ctx, i) => Text(
                      logs[i],
                      style: TextStyle(fontSize: 12, color: Colors.blue.shade800),
                    ),
                  ),
                ),
              if (logs.isNotEmpty) const SizedBox(height: 12),
              // Error message
              if (errorMessage != null)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.red.shade50,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(errorMessage!, style: TextStyle(fontSize: 12, color: Colors.red.shade800)),
                ),
              if (errorMessage != null) const SizedBox(height: 12),
              // Actions
              if (phase == ModelLifecyclePhase.loaded && !isGenerating) ...[
                _sheetButton(context, label: '卸载模型', icon: Icons.close, color: Colors.red, onTap: onUnload),
                const SizedBox(height: 8),
              ],
              if (phase == ModelLifecyclePhase.error) ...[
                _sheetButton(context, label: '重试加载', icon: Icons.refresh, color: Colors.blue, onTap: onLoad),
                const SizedBox(height: 8),
              ],
              if (phase == ModelLifecyclePhase.idle) ...[
                _sheetButton(context, label: '去加载模型', icon: Icons.download, color: Colors.green, onTap: onGoToSettings),
                const SizedBox(height: 8),
              ],
              _sheetButton(context, label: '关闭', icon: null, color: null, onTap: () => Navigator.pop(context), isDefault: true),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sheetButton(BuildContext context, {
    required String label,
    IconData? icon,
    Color? color,
    required VoidCallback onTap,
    bool isDefault = false,
  }) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: onTap,
        style: ElevatedButton.styleFrom(
          backgroundColor: color ?? Theme.of(context).colorScheme.primaryContainer,
          foregroundColor: color == null ? null : Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
        icon: icon != null ? Icon(icon, size: 18) : null,
        label: Text(label),
      ),
    );
  }

  IconData _sheetIconFor(ModelLifecyclePhase phase) {
    switch (phase) {
      case ModelLifecyclePhase.idle: return Icons.memory_outlined;
      case ModelLifecyclePhase.loading: return Icons.sync_alt;
      case ModelLifecyclePhase.loaded: return Icons.check_circle;
      case ModelLifecyclePhase.unloading: return Icons.sync_disabled;
      case ModelLifecyclePhase.error: return Icons.error_outline;
    }
  }

  String _phaseLabelFor(ModelLifecyclePhase phase) {
    switch (phase) {
      case ModelLifecyclePhase.idle: return '未加载';
      case ModelLifecyclePhase.loading: return '加载中…';
      case ModelLifecyclePhase.loaded: return '已加载';
      case ModelLifecyclePhase.unloading: return '卸载中…';
      case ModelLifecyclePhase.error: return '加载失败';
    }
  }

  Color _sheetColorFor(ModelLifecyclePhase phase) {
    switch (phase) {
      case ModelLifecyclePhase.idle: return Colors.grey;
      case ModelLifecyclePhase.loading: return Colors.blue;
      case ModelLifecyclePhase.loaded: return Colors.green;
      case ModelLifecyclePhase.unloading: return Colors.orange;
      case ModelLifecyclePhase.error: return Colors.red;
    }
  }

  Widget _buildPulsingDotLarge() {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.3, end: 1.0),
      duration: const Duration(milliseconds: 800),
      curve: Curves.easeInOut,
      builder: (context, value, _) => Container(
        width: 14, height: 14,
        decoration: BoxDecoration(
          color: Colors.orange.shade400.withValues(alpha: value),
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

/// Live memory-usage panel shown inside the model-status sheet.
///
/// Polls [InferenceService.getMemoryInfo] every 2s so the user can watch
/// system RAM pressure and llama.cpp (in-process) memory while generating.
/// Colors: green = comfortable, orange = tight, red = critical.
class _MemoryPanel extends StatefulWidget {
  final WidgetRef ref;
  const _MemoryPanel({required this.ref});

  @override
  State<_MemoryPanel> createState() => _MemoryPanelState();
}

class _MemoryPanelState extends State<_MemoryPanel> {
  Map<String, int>? _mem;
  String? _error;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final m = await widget.ref.read(inferenceServiceProvider).getMemoryInfo();
      if (!mounted) return;
      setState(() {
        _mem = m;
        _error = m.isEmpty ? '原生端未返回内存数据' : null;
      });
    } catch (e) {
      // Surface the failure instead of spinning forever — a silent catch here
      // is exactly what hid the earlier type-cast bug.
      if (mounted && _mem == null) setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_mem == null || _mem!.isEmpty) {
      return Container(
        width: double.infinity,
        margin: const EdgeInsets.only(top: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.grey.shade100,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.grey.shade300),
        ),
        child: Row(
          children: [
            const SizedBox(
              width: 14, height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                _error == null ? '读取内存信息…' : '内存信息不可用：$_error',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      );
    }
    final sysTotal = _mem!['sysTotalMB'] ?? 0;
    final sysAvail = _mem!['sysAvailMB'] ?? 0;
    final sysUsed = _mem!['sysUsedMB'] ?? 0;
    final procRss = _mem!['procRssMB'] ?? 0;
    final modelMB = _mem!['modelMB'] ?? 0;
    final kvCache = _mem!['kvCacheMB'] ?? 0;
    final sysAvailPct = sysTotal > 0 ? sysAvail / sysTotal : 0.0;
    final procPct = sysTotal > 0 ? procRss / sysTotal : 0.0;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.memory, size: 16),
              const SizedBox(width: 6),
              Text('内存占用', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.grey.shade800)),
              const Spacer(),
              Text('可用 ${_gb(sysAvail)} GB', style: TextStyle(fontSize: 12, color: _pressureColor(sysAvailPct))),
            ],
          ),
          const SizedBox(height: 10),
          _memBar(
            label: '系统内存',
            usedMB: sysUsed,
            totalMB: sysTotal,
            pct: sysTotal > 0 ? sysUsed / sysTotal : 0,
            color: _pressureColor(sysAvailPct),
          ),
          const SizedBox(height: 8),
          _memBar(
            label: 'App (llama.cpp)',
            usedMB: procRss,
            totalMB: sysTotal,
            pct: procPct,
            color: _pressureColor(1 - procPct),
          ),
          const SizedBox(height: 10),
          // llama.cpp 自身的内存构成：模型权重 + KV 缓存
          Row(
            children: [
              Expanded(
                child: _memStat(
                  '模型权重',
                  modelMB > 0 ? '${_gb(modelMB)} GB' : '—',
                  modelMB > 0 ? Colors.indigo : Colors.grey,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _memStat(
                  'KV 缓存',
                  kvCache > 0 ? '${_gb(kvCache)} GB' : '—',
                  kvCache > 0 ? Colors.teal : Colors.grey,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'llama.cpp 合计: ${_gb(modelMB + kvCache)} GB',
                style: TextStyle(
                  fontSize: 12,
                  color: _pressureColor(sysTotal > 0 ? 1 - (modelMB + kvCache) / sysTotal : 1),
                ),
              ),
              Text('进程 RSS: ${_gb(procRss)} GB', style: const TextStyle(fontSize: 12, color: Colors.black87)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _memStat(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(fontSize: 11, color: color.withValues(alpha: 0.9))),
          const SizedBox(height: 2),
          Text(value, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: color)),
        ],
      ),
    );
  }

  Color _pressureColor(double availPct) {
    if (availPct >= 0.3) return Colors.green;
    if (availPct >= 0.1) return Colors.orange;
    return Colors.red;
  }

  String _gb(int mb) => (mb / 1024.0).toStringAsFixed(1);

  Widget _memBar({
    required String label,
    required int usedMB,
    required int totalMB,
    required double pct,
    required Color color,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: const TextStyle(fontSize: 12)),
            Text('${_gb(usedMB)} / ${_gb(totalMB)} GB', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
          ],
        ),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: pct.clamp(0.0, 1.0),
            minHeight: 9,
            valueColor: AlwaysStoppedAnimation(color),
            backgroundColor: Colors.grey.shade300,
          ),
        ),
      ],
    );
  }
}

/// 录音中的波形动画：几根竖条按相位起伏，提示用户正在拾音。
class _RecordingWave extends StatefulWidget {
  final Color color;
  const _RecordingWave({required this.color});

  @override
  State<_RecordingWave> createState() => _RecordingWaveState();
}

class _RecordingWaveState extends State<_RecordingWave>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  static const int _barCount = 5;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (_, __) {
        return SizedBox(
          height: 22,
          width: 24,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: List.generate(_barCount, (i) {
              final phase = (_controller.value + i * 0.18) % 1.0;
              // 相位正弦映射到 0.25~1.0 的高度比例，形成起伏。
              final h = 0.25 + 0.75 * (0.5 - 0.5 * _cos(phase * 6.2832));
              return Container(
                width: 3,
                height: 22 * h,
                margin: const EdgeInsets.symmetric(horizontal: 1),
                decoration: BoxDecoration(
                  color: widget.color,
                  borderRadius: BorderRadius.circular(2),
                ),
              );
            }),
          ),
        );
      },
    );
  }

  double _cos(double x) {
    // 极简余弦：1 - 2x² (x∈[0,1]) 的近似即可，动画视觉足够。
    final v = x - (x * x * x) / 6.0 + (x * x * x * x * x) / 120.0;
    return v;
  }
}
