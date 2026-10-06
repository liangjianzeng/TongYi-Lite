import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import '../asr/hold_to_talk.dart';
import 'package:file_picker/file_picker.dart';
import 'package:permission_handler/permission_handler.dart'
    show openAppSettings;

import '../providers/index.dart'
    show
        chatNotifierProvider,
        runningTurnsProvider,
        agentPendingQuestionProvider,
        messagesProvider,
        conversationsProvider,
        currentModelIdProvider,
        kLocalVisionSupported;
import '../providers/model_provider.dart';
import '../providers/settings_provider.dart' show settingsProvider;
import '../services/attachment_service.dart'
    show kMaxAttachments, kSupportedExtensions;
import '../services/inference_service.dart';
import '../providers/shared_providers.dart';
import '../providers/context_usage_provider.dart'
    show contextUsageProvider;
import '../models/agent_persona.dart' show kStandardPersonaId;
import '../agent/goal/goal_store.dart'
    show GoalStore, GoalState, GoalStatus, PlanStepStatus;
import '../agent/builtin_tools/todo_tool.dart'
    show readTodoStore, renderTodoCardText;
import '../widgets/todo_card.dart';
import '../models/conversation.dart';
import '../services/settings_service.dart';
import '../services/storage_permission_service.dart';
import '../widgets/agent_workflow.dart';
import '../widgets/chat_bubble.dart';
import '../providers/agent_state_provider.dart'
    show agentUiStateProvider, AgentUiState, ToolActivityUi, ToolUiStatus;
import '../models/chat_message.dart' show ChatMessage;
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

  /// ask_user_question 自由回答输入框（随提问卡片创建/销毁复用）。
  final _questionController = TextEditingController();
  String _currentConversationId = '';
  bool _initiallyLoaded = false;
  // When true, the view auto-scrolls to the newest message (bottom of the
  // list). Disabled once the user scrolls up to read history.
  bool _followStream = true;

  // Image picker state
  final List<String> _selectedImagePaths = [];

  /// 智能体附件（≤5 个，WP-A）。
  final List<String> _selectedFilePaths = [];
  final ImagePicker _picker = ImagePicker();

  // 语音拾音（按住说话）状态 —— 用 ValueNotifier 而非 setState 驱动，避免
  // 录音中重建 GestureDetector 导致「松手」手势丢失（此前重建会杀掉 onLongPressEnd）。
  // 端侧 ASR（sherpa-onnx，DSH-Phone 方案）：按住说话会话句柄。
  HoldToTalkSession? _voiceSession;
  Offset? _voiceLongPressPos;

  // 附件面板的暂存选择（bottom sheet 回调里不能直接 await pick，
  // 先落字段、pop 后统一分发）。
  // 会话批量选择状态
  bool _conversationSelectionMode = false;
  final Set<String> _selectedConversations = {};

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
    _conversationSearchCtrl.dispose();
    _questionController.dispose();

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
    if (ref.read(runningTurnsProvider)[_currentConversationId] ?? false) {
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
    // 占用快照是内存态（重启即丢）：启动时按本地历史估算回填，圈圈立即可见。
    unawaited(ref
        .read(chatNotifierProvider.notifier)
        .refreshUsageEstimate(_currentConversationId));
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

    // 直接进首页后，本页自动加载可能先于启动门控的 InferenceService.initialize()
    // 完成；llama_backend_init 幂等（多次调用无副作用），先确保原生引擎就绪。
    try {
      await InferenceService().initialize();
    } catch (e) {
      debugPrint('[Home] InferenceService init failed, skipping auto-load: $e');
      return;
    }

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

  /// Pick image from camera or gallery（多图，≤10）。
  /// [source] 为空时弹选择对话框（拍照/相册）；已指定则直接走对应来源。
  Future<void> _pickImage([ImageSource? source]) async {
    source ??= await showDialog<ImageSource>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('选择图片来源（最多 10 张）'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt),
              title: const Text('拍照'),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('相册（可多选）'),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );

    if (source == null) return;

    // 相机需要权限（无论从哪个入口进入都先检查）。
    if (source == ImageSource.camera) {
      final hasPermission =
          await StoragePermissionService.requestCameraPermission();
      if (!hasPermission) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('相机权限被拒绝，请在设置中授予')),
          );
        }
        return;
      }
    }

    try {
      // 端侧视觉：把用户选图先「下采样」再喂模型，而不是原图直喂。
      // 真机实测：1920px 大图进视觉塔 → 单张图产出 ~2717 个 image token，
      // 视觉编码内存飙到 2.6GB+，推理卡死（消息一直转圈无输出）后被系统杀掉。
      // 压到 768px 后 token 数骤减（~300+），编码内存/耗时都大幅下降。
      if (source == ImageSource.gallery) {
        final images = await _picker.pickMultiImage(
          maxWidth: 768,
          maxHeight: 768,
          imageQuality: 85,
        );
        if (images.isEmpty) return;
        setState(() {
          for (final image in images) {
            if (_selectedImagePaths.length >= 10) break;
            _selectedImagePaths.add(image.path);
          }
        });
      } else {
        final XFile? image = await _picker.pickImage(
          source: source,
          maxWidth: 768,
          maxHeight: 768,
          imageQuality: 85,
        );
        if (image != null) {
          setState(() {
            if (_selectedImagePaths.length < 10) {
              _selectedImagePaths.add(image.path);
            }
          });
        }
      }
      if (_selectedImagePaths.length == 10 && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('最多 10 张，超出的未添加')),
        );
      }
      _warnIfImageDropped();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('选择图片失败: $e')),
      );
    }
  }

  /// 智能体附件选择（WP-A）：≤5 个，白名单办公/文本格式。
  Future<void> _pickAttachmentFiles() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions:
          kSupportedExtensions.map((e) => e.replaceFirst('.', '')).toList(),
    );
    if (result == null || result.files.isEmpty) return;
    setState(() {
      for (final f in result.files) {
        if (_selectedFilePaths.length >= kMaxAttachments) break;
        final path = f.path;
        if (path != null && !_selectedFilePaths.contains(path)) {
          _selectedFilePaths.add(path);
        }
      }
    });
    if (mounted && result.files.length > kMaxAttachments) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('最多 $kMaxAttachments 个文件，超出的未添加')),
      );
    }
  }

  /// 统一附件入口：图片（拍照/相册）与文件附件（智能体模式）合并为一个
  /// 「+」按钮，点按弹出选择面板——替代此前输入框右侧「图片」+ 前置
  /// 「附件」两个独立按钮，收窄消息发送区。
  ///
  /// ⚠️ 此前实现把 `showModalBottomSheet<void>` 的返回值丢弃、靠一个从未
  /// 赋值的暂存字段分发 → 选完什么都不会发生（"附件/拍照上传全坏"根因）。
  /// 现改为直接消费面板返回的 [_AttachSource]。
  Future<void> _showAttachSheet() async {
    final agentOn = ref.read(settingsProvider).agentEnabled;
    final theme = Theme.of(context);
    final source = await showModalBottomSheet<_AttachSource>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 拖拽把手 + 标题
                Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 10),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.outlineVariant,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(left: 12, bottom: 6),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text('添加附件',
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w600)),
                  ),
                ),
                _AttachOption(
                  icon: Icons.photo_camera_outlined,
                  tint: Colors.blue,
                  title: '拍照',
                  subtitle: '拍摄一张照片发送（≤10 张）',
                  onTap: () => Navigator.pop(ctx, _AttachSource.camera),
                ),
                _AttachOption(
                  icon: Icons.photo_library_outlined,
                  tint: Colors.green,
                  title: '从相册选择',
                  subtitle: '可多选图片，一次最多 10 张',
                  onTap: () => Navigator.pop(ctx, _AttachSource.gallery),
                ),
                if (agentOn)
                  _AttachOption(
                    icon: Icons.attach_file,
                    tint: Colors.deepOrange,
                    title: '文件',
                    subtitle:
                        '智能体附件（≤$kMaxAttachments 个）：docx / xlsx / pptx / txt / md / csv 等',
                    onTap: () => Navigator.pop(ctx, _AttachSource.file),
                  ),
                const SizedBox(height: 4),
              ],
            ),
          ),
        ),
      ),
    );
    if (!mounted || source == null) return;
    switch (source) {
      case _AttachSource.camera:
        await _pickImage(ImageSource.camera);
        break;
      case _AttachSource.gallery:
        await _pickImage(ImageSource.gallery);
        break;
      case _AttachSource.file:
        await _pickAttachmentFiles();
        break;
      case _AttachSource.none:
        break;
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
  // ---- 端侧语音接入（sherpa-onnx 流式 ASR，DSH-Phone 方案）----
  // 放弃「录音文件喂 LLM」的语音方案：长按说话 → 端侧实时转写 → 文本直接
  // 发送。模型 ~160MB 首次使用时经 AsrModelGate 下载（hf-mirror 断点续传）。

  Future<void> _onVoiceLongPressStart(BuildContext ctx, Offset pos) async {
    if (_voiceSession != null) return;
    try {
      debugPrint('[Voice] long-press: requesting mic permission');
      final hasMic =
          await StoragePermissionService.requestMicrophonePermission();
      if (!hasMic) {
        debugPrint('[Voice] mic permission denied');
        if (mounted) _showMicPermissionDialog();
        return;
      }
      debugPrint('[Voice] mic ok; checking ASR model');
      final ready = await AsrModelGate.ensureModelReady(ctx);
      if (!ready) {
        debugPrint('[Voice] ASR model not ready (用户取消/下载失败)');
        if (mounted) {
          ScaffoldMessenger.of(this.context).showSnackBar(const SnackBar(
              content: Text('语音模型未就绪（下载未完成或已取消），'
                  '再次长按可重新下载/继续断点')));
        }
        return;
      }
      debugPrint('[Voice] model ready; starting hold session');
      final session = HoldToTalkSession();
      _voiceSession = session;
      _voiceLongPressPos = pos;
      final ok = await session.start(this.context);
      if (!ok) {
        _voiceSession = null;
        debugPrint('[Voice] session start failed');
        if (mounted) {
          ScaffoldMessenger.of(this.context).showSnackBar(
              const SnackBar(content: Text('语音引擎启动失败，请重试')));
        }
      }
    } catch (e) {
      _voiceSession = null;
      debugPrint('[Voice] long-press start error: $e');
      if (mounted) {
        ScaffoldMessenger.of(this.context).showSnackBar(
            SnackBar(content: Text('语音启动异常：$e')));
      }
    }
  }

  void _onVoiceLongPressMoveUpdate(Offset pos) {
    final session = _voiceSession;
    final start = _voiceLongPressPos;
    if (session == null || start == null) return;
    session.cancelMode.value = (pos.dy - start.dy) < -HoldToTalkSession.cancelSlop;
  }

  Future<void> _onVoiceLongPressEnd() async {
    final session = _voiceSession;
    if (session == null) return;
    _voiceSession = null;
    _voiceLongPressPos = null;
    final cancelled = session.cancelMode.value;
    final text = await session.end(cancelled: cancelled);
    if (!mounted) return;
    if (text.isEmpty) {
      if (!cancelled) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('未识别到内容，请重试')));
      }
      return;
    }
    // 识别文本直接发送（附加输入框已有文字，语音即完整消息）。
    final existing = _textController.text.trim();
    _textController.text = existing.isEmpty ? text : '$existing $text';
    _textController.selection = TextSelection.fromPosition(
        TextPosition(offset: _textController.text.length));
    await _sendMessage();
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

  /// Send message with optional images / attachments / audio
  Future<void> _sendMessage() async {
    final text = _textController.text.trim();
    final imagePaths = List<String>.from(_selectedImagePaths);
    final attachmentPaths = List<String>.from(_selectedFilePaths);
    if (text.isEmpty && imagePaths.isEmpty) return;

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
    _drafts.remove(_currentConversationId);
    setState(() {
      _selectedImagePaths.clear();
      _selectedFilePaths.clear();
    });
    try {
      await notifier.sendMessage(_currentConversationId, text,
          imagePath: imagePaths.isNotEmpty ? imagePaths.first : null,
          imagePaths: imagePaths,
          attachmentPaths: attachmentPaths);
    } catch (e) {
      // The send failed before leaving the client — restore the input so the
      // user can retry. (If it failed mid-generation the message is already
      // persisted and shown in the chat, so no restore needed there.)
      _textController.text = text;
      setState(() {
        _selectedImagePaths
          ..clear()
          ..addAll(imagePaths);
        _selectedFilePaths
          ..clear()
          ..addAll(attachmentPaths);
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content:
                Text('发送失败: $e', style: const TextStyle(color: Colors.white))),
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
      // 只停当前会话的回合（其他会话的并发回合不受影响）。
      await ref
          .read(chatNotifierProvider.notifier)
          .stopGeneration(conversationId: _currentConversationId);
    } catch (e) {
      debugPrint('[HomeScreen] stopGeneration failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    // 生成态按「当前会话」判定：多会话并发时，别的会话在跑不影响本会话
    // 的发送按钮（本会话自己在跑才显示停止键）。
    final isGenerating =
        ref.watch(runningTurnsProvider)[_currentConversationId] ?? false;
    final modelState = ref.watch(modelManagerProvider);

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
            onPressed: () {
              _invalidateSnippets();
              Scaffold.of(ctx).openDrawer();
            },
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
        // 顶部状态栏最下方：叠一条蓝色上下文占用细线（零额外布局空间）。
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(3),
          child: _buildContextUsageBar(modelState, isGenerating),
        ),
      ),
      body: Column(
        children: [
          // ---- Inline model status (only shows loading/unloading/error progress) ----
          _buildInlineProgress(modelState, isGenerating),

          Expanded(
            child: _initiallyLoaded
                ? _buildMessagesList()
                : const Center(child: CircularProgressIndicator()),
          ),

          // 附件预览已并入 composer 卡片（chips 行，可单个删除）。
          _buildInputBar(isGenerating, modelState),
        ],
      ),
    );
  }

  String _fileNameOf(String path) {
    final i = path.lastIndexOf('/');
    return i == -1 ? path : path.substring(i + 1);
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
        label = const Text('加载中…',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500));
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
              style: TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w500, color: color),
            ),
          ],
        );
        break;
      case ModelLifecyclePhase.unloading:
        chipIcon = Icons.sync_disabled;
        label = const Text('卸载中…',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500));
        break;
      case ModelLifecyclePhase.error:
        chipIcon = Icons.error_outline;
        label = const Text('加载失败',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500));
        break;
      case ModelLifecyclePhase.idle:
        chipIcon = Icons.memory_outlined;
        label = const Text('未加载',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500));
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
            // 若正在推理，先停止生成（全部回合，模型即将重载），
            // 避免卸载/重载时原生引擎崩溃（红屏）。
            if (ref.read(runningTurnsProvider).isNotEmpty) {
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
          Navigator.push(context,
              MaterialPageRoute(builder: (_) => const SettingsScreen()));
        },
      ),
    );
  }

  /// Thin progress strip shown below the app bar only during loading / unloading / error.
  /// Hidden when idle and not generating — no space wasted.
  Widget _buildInlineProgress(ModelState ms, bool isGenerating) {
    // Only show during loading / unloading / error — idle and loaded states
    // are handled by the AppBar chip (no space wasted on chat area).
    if (ms.phase == ModelLifecyclePhase.idle ||
        ms.phase == ModelLifecyclePhase.loaded) {
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
              if (ms.phase == ModelLifecyclePhase.loading ||
                  ms.phase == ModelLifecyclePhase.unloading)
                SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: color)),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  ms.modelName != null && ms.modelName!.isNotEmpty
                      ? '${ms.modelName!}$generating'
                      : (isGenerating ? '推理中…' : '模型未加载'),
                  style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w500),
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
                      style:
                          TextStyle(fontSize: 11, color: Colors.red.shade700),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton.icon(
                    onPressed: ms.modelId != null
                        ? () => ref
                            .read(modelManagerProvider.notifier)
                            .loadModel(ms.modelId!)
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

  /// 顶部状态栏最下方的上下文占用细线（叠在 AppBar 底部，不额外占用布局
  /// 空间）。纯展示：查询/手动压缩入口在输入框左侧的圆形占用圈。
  ///
  /// API 接入：宽度 = prompt_tokens / n_ctx（usage + /v1/models 实测槽位）。
  /// 本地模型：宽度 = KV 缓存已占用位置（kv_used）/ 上下文窗口（kv_ctx）。
  Widget _buildContextUsageBar(ModelState ms, bool isGenerating) {
    final settings = ref.watch(settingsProvider);
    final activeApi = settings.activeApiModel();
    final hasLocalLoaded = ms.isLoaded;
    final hasDefault = settings.defaultModelId != null;
    // 细条显示条件（本地或 API 任一可用即显示）：
    // - 智能体显式 API 驱动（agentModelSource=api）→ 恒走 API；
    // - 普通聊天：无本地意图（未加载本地模型 且 无默认勾选）且激活了 API → API；
    // - 本地模型（已加载 或 勾选默认）→ 显示 KV 缓存占比。
    final isAgentApi = settings.agentModelSource == 'api' && activeApi != null;
    final isPlainApi = activeApi != null && !hasLocalLoaded && !hasDefault;
    final isLocal = hasLocalLoaded || hasDefault;
    if (!isAgentApi && !isPlainApi && !isLocal) return const SizedBox.shrink();

    final usage = ref.watch(contextUsageProvider)[_currentConversationId];
    final fraction = usage?.fraction ?? 0.0;
    // 阈值语义：≥85% 红（撞墙在即，应压缩/换会话）、≥60% 橙（留意）、蓝（健康）。
    final barColor = fraction >= 0.85
        ? const Color(0xFFE53935)
        : fraction >= 0.60
            ? const Color(0xFFFB8C00)
            : const Color(0xFF2196F3);

    return SizedBox(
      height: 3,
      width: MediaQuery.of(context).size.width,
      child: Stack(
        children: [
          // 极浅底色线（全宽）：让用户看到细线槽位存在，占用为 0 时也可见。
          const Positioned.fill(
            child: ColoredBox(color: Color(0x14000000)),
          ),
          // 占用细线：宽度 = 占用比例 × 屏幕宽，颜色按阈值分档。
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: MediaQuery.of(context).size.width * fraction,
            child: ColoredBox(color: barColor),
          ),
        ],
      ),
    );
  }

  /// 手动压缩确认 + 执行：回合执行中拒绝（与活动回合的会话日志竞争）；
  /// 完成后 SnackBar 反馈（清理条数 0 = 没有可压缩的旧工具记录）。
  Future<void> _confirmManualCompact() async {
    final running =
        ref.read(runningTurnsProvider)[_currentConversationId] ?? false;
    if (running) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('回合执行中，结束后再压缩')),
      );
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('手动压缩上下文'),
        content: const Text(
          '把较早轮次的工具结果从会话上下文中清出（保留最近一轮的工具记录'
          '与全部对话文本，'
          '存一条摘要供模型回看）。聊天记录显示不受影响。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('压缩'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final (envelopes, chars) = await ref
        .read(chatNotifierProvider.notifier)
        .manualCompact(_currentConversationId);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(envelopes == 0
            ? '没有可压缩的旧工具记录'
            : '已压缩：清理 $envelopes 条工具记录，摘要 $chars 字'),
      ),
    );
  }

  /// 上下文 / KV 占用详情面板（输入框占用圈点开）：当前会话占用数字与来源、全部
  /// 会话快照、最近压缩记录（来自推理日志）、阈值图例。
  void _showContextUsageSheet() {
    final usageMap = ref.read(contextUsageProvider);
    final modelState = ref.read(modelManagerProvider);
    final settings = ref.read(settingsProvider);
    final activeApi = settings.activeApiModel();
    final engineName = modelState.isLoaded
        ? (modelState.modelName ?? modelState.modelId ?? '本地模型')
        : (activeApi != null ? activeApi.name : null);

    // 压缩记录：推理日志里带「上下文压缩」前缀的行（chat_provider 落档），
    // 最近 8 条倒序。
    final compactionLines = modelState.loadingLogs
        .where((l) => l.contains('上下文压缩'))
        .toList()
        .reversed
        .take(8)
        .toList();

    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        final theme = Theme.of(sheetContext);
        final current = usageMap[_currentConversationId];
        final fraction = current?.fraction ?? 0.0;
        final barColor = fraction >= 0.85
            ? const Color(0xFFE53935)
            : fraction >= 0.60
                ? const Color(0xFFFB8C00)
                : const Color(0xFF2196F3);
        final others = usageMap.entries
            .where((e) => e.key != _currentConversationId && e.value.hasData)
            .toList();

        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('上下文占用', style: theme.textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(
                  engineName == null ? '当前无激活引擎' : '引擎：$engineName',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 12),
                if (current == null || !current.hasData)
                  Text(
                    '当前会话暂无占用数据——发一条消息（或跑一轮智能体）后，'
                    '占用会在每轮响应后更新。',
                    style: theme.textTheme.bodyMedium,
                  )
                else ...[
                  // 大号占用数字 + 进度条。
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(
                        '${(fraction * 100).toStringAsFixed(1)}%',
                        style: theme.textTheme.headlineMedium?.copyWith(
                          color: barColor,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '${_fmtTokens(current.usedTokens)} / '
                          '${_fmtTokens(current.windowTokens)} tokens'
                          '（${current.windowSource}）',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: SizedBox(
                      height: 8,
                      child: LinearProgressIndicator(
                        value: fraction,
                        backgroundColor:
                            barColor.withValues(alpha: 0.15),
                        valueColor: AlwaysStoppedAnimation(barColor),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                Text(
                  '颜色阈值：蓝 <60% · 橙 ≥60%（留意）· 红 ≥85%（建议压缩或换会话）',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),
                // 手动压缩：存储级清理旧工具轮信封（持久，区别于回合内压缩）。
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.compress, size: 18),
                    label: const Text('手动压缩上下文'),
                    onPressed: () {
                      Navigator.pop(sheetContext);
                      _confirmManualCompact();
                    },
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '清理较早轮次的工具结果（保留最近一轮的工具记录与全部对话文本），'
                  '存一条摘要供模型回看——下一轮请求立即瘦身。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                if (others.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text('其它会话快照',
                      style: theme.textTheme.titleSmall),
                  const SizedBox(height: 4),
                  for (final e in others)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text(
                        '· ${_fmtTokens(e.value.usedTokens)} / '
                        '${_fmtTokens(e.value.windowTokens)}'
                        '（${(e.value.fraction! * 100).toStringAsFixed(0)}%）',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                ],
                if (compactionLines.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text('最近压缩记录', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 4),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest
                          .withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final line in compactionLines)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 1),
                            child: Text(
                              line,
                              style: theme.textTheme.bodySmall?.copyWith(
                                fontFamily: 'monospace',
                                fontSize: 11,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  /// token 数格式化：1234 → 1.2k，1234567 → 1.23M，其余原样。
  static String _fmtTokens(int? tokens) {
    if (tokens == null) return '?';
    if (tokens >= 1000000) {
      return '${(tokens / 1000000).toStringAsFixed(2)}M';
    }
    if (tokens >= 1000) {
      return '${(tokens / 1000).toStringAsFixed(1)}k';
    }
    return '$tokens';
  }

  Widget _buildPulsingDot() {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.3, end: 1.0),
      duration: const Duration(milliseconds: 800),
      curve: Curves.easeInOut,
      builder: (context, value, _) => Container(
        width: 12,
        height: 12,
        decoration: BoxDecoration(
          color: Colors.orange.shade400.withValues(alpha: value),
          shape: BoxShape.circle,
        ),
      ),
    );
  }

  Color _colorFor(String name) {
    switch (name) {
      case 'grey':
        return Colors.grey;
      case 'blue':
        return Colors.blue;
      case 'green':
        return Colors.green;
      case 'orange':
        return Colors.orange;
      case 'red':
        return Colors.red;
      default:
        return Colors.grey;
    }
  }

  // =========================================================================
  // Chat UI
  // =========================================================================

  Widget _buildMessagesList() {
    // 多会话并发：live 回合 UI 状态按当前会话取自己的快照（事件流不串台）。
    final uiState = ref.watch(agentUiStateProvider)[_currentConversationId] ??
        const AgentUiState();
    // 普通聊天（非智能体回合）也要让最后一组进入 live 态：
    // 空答案气泡才会显示唯一的「思考中…」占位、流式光标才会出现。
    final generating =
        ref.watch(runningTurnsProvider)[_currentConversationId] ?? false;
    final messagesAsync = ref.watch(messagesProvider(_currentConversationId));

    return messagesAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, stack) => Center(child: Text('Error: $err')),
      data: (rawMessages) {
        if (rawMessages.isEmpty) {
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
        if (rawMessages.isNotEmpty && _followStream) {
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
        //
        // 内嵌工作流：把流重排为 [user | 智能体回合块]。回合块 =
        // [工具步骤… → 最终回答]；运行中步骤取事件流实时数据，历史步骤
        // 解析自存储 🔧 活动消息（groupMessages / parsedToolActivities）。
        final units = groupMessages(rawMessages);
        // 对话区文字整体缩放（设置→智能体→对话文字大小，0.7~1.3）。
        final textScale = ref.watch(settingsProvider).chatTextScale;
        return MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: ListView.builder(
            controller: _scrollController,
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: units.length,
            itemBuilder: (context, index) {
              final unit = units[index];
              final isLiveTurn =
                  (uiState.running || generating) && index == units.length - 1;
              return switch (unit) {
                UserUnit(:final message) => ChatBubble(
                    role: message.role.name,
                    content: message.content,
                    timestamp: message.timestamp,
                    isStreaming:
                        message.isStreaming && index == units.length - 1,
                    imagePath: message.imagePath,
                    imagePaths: message.imagePaths,
                    attachments: message.attachments,
                    audioPath: message.audioPath,
                    inferenceStats: message.inferenceStats,
                  ),
                TurnUnit(:final tools, :final answer, :final thinking) =>
                  AgentTurnBlock(
                    isLive: isLiveTurn,
                    steps: _stepsFor(uiState, tools, isLiveTurn),
                    answer: answer,
                    ui: uiState,
                    thinking: thinking,
                  ),
              };
            },
          ),
        );
      },
    );
  }

  /// 回合步骤：live **智能体**回合用事件流实时数据（参数/结果/状态实时更新）；
  /// 其余（历史回合 / 普通聊天生成中）解析存储 🔧 活动消息。
  /// 普通聊天生成中绝不借用事件流——那是上一智能体回合的残留卡片，
  /// 借了就会在简单对话下面凭空多出一排工具卡。
  List<ToolActivityUi> _stepsFor(
      AgentUiState ui, List<ChatMessage> tools, bool isLiveTurn) {
    if (isLiveTurn && ui.running) return ui.tools;
    return parsedToolActivities(tools);
  }

  /// 计划模式文本前缀（P3 模式行「计划」chip 切换；/plan 由 chat_provider 消费）。
  static const String _planPrefix = '/plan ';

  /// 会话草稿（P3）：convId → 未发送文字，切换会话不打字仍在。
  final Map<String, String> _drafts = {};

  /// 计划存储（P1 计划实体化；与 chat_provider 同目录 goals/）。
  GoalStore? _planStoreCache;
  Future<GoalStore> _planStore() async {
    _planStoreCache ??= GoalStore(
        baseDir:
            '${(await getApplicationSupportDirectory()).path}/goals');
    return _planStoreCache!;
  }

  /// 输入区（标准智能体 composer 形态重构，2026-10-05）：
  ///
  /// [生成中状态细条]
  /// ┌─ composer 卡片（圆角 24）────────────────────┐
  /// │ 附件 chips 行（缩略图/文件名，× 单个删除）        │
  /// │ TextField 多行（hint 随状态变化）               │
  /// │ [+] [🤖智能体][🎭人格][📋计划][模型]   (🎤/➤/⏹) │
  /// └────────────────────────────────────────────┘
  ///
  /// 发送键**位置语义复用**（单键四态，替代双 FAB 并排）：
  /// 空闲空输入=🎤（长按说话）/ 空闲有文字=➤ / 生成中空输入=⏹停止 /
  /// 生成中有文字=➤（插话，不打断）。停止另有状态细条右侧文字按钮兜底。
  Widget _buildInputBar(bool isGenerating, ModelState ms) {
    final settings = ref.watch(settingsProvider);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // ask_user_question 待回答卡片（P2-B2）：智能体提问挂起等待时显示。
        _buildPendingQuestionCard(),
        // 生成中状态细条：执行进度一眼可见 + 停止兜底入口。
        _buildTurnStatusStrip(isGenerating),
        Container(
          margin: const EdgeInsets.fromLTRB(8, 4, 8, 8),
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(24),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 附件 chips 行（选中才出现，单个可删）。
              _buildAttachmentChips(),
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: _textController,
                builder: (_, value, __) => TextField(
                  controller: _textController,
                  textInputAction: TextInputAction.newline,
                  decoration: InputDecoration(
                    hintText: _inputHintFor(isGenerating, value.text),
                    hintStyle: const TextStyle(fontSize: 14),
                    border: InputBorder.none,
                    filled: false,
                    isDense: true,
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                  ),
                  onSubmitted: (_) {
                    // 生成中：Enter = 插话转向（steer，不打断执行）。
                    if (isGenerating) {
                      _steerMessage();
                      return;
                    }
                    _sendMessage();
                  },
                  maxLines: 6,
                  minLines: 1,
                ),
              ),
              const SizedBox(height: 2),
              Row(
                children: [
                  // 统一附件入口：徽标 = 已选总数（明细在上面的 chips 行）。
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: Badge(
                      isLabelVisible: _selectedImagePaths.isNotEmpty ||
                          _selectedFilePaths.isNotEmpty,
                      label: Text(
                          '${_selectedImagePaths.length + _selectedFilePaths.length}'),
                      child: const Icon(Icons.add, size: 22),
                    ),
                    tooltip: '添加图片 / 文件',
                    constraints:
                        const BoxConstraints(minWidth: 36, minHeight: 36),
                    padding: EdgeInsets.zero,
                    onPressed: _showAttachSheet,
                  ),
                  const SizedBox(width: 2),
                  // 模式 chips 行：智能体 / 人格 / 计划 / 模型（可横滚）。
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          _buildContextUsageRing(),
                          _buildAgentToggleChip(settings),
                          _buildPersonaChip(settings),
                          _buildPlanModeChip(),
                          _buildModelChip(ms, isGenerating),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  _buildComposerKey(isGenerating),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 输入框左侧的圆形上下文占用圈（传统进度环形态）：
  /// 环 = 占用比例（阈值配色与顶部细条一致），环心 = 百分比数字；
  /// 无数据时灰环显示「—」。点按 → 上下文详情面板（数字/来源/压缩记录/
  /// 手动压缩）。智能体回合执行中禁用点按（防误触打断注意力）。
  Widget _buildContextUsageRing() {
    final usage = ref.watch(contextUsageProvider)[_currentConversationId];
    final fraction = usage?.fraction;
    final hasData = fraction != null;
    final color = !hasData
        ? Colors.grey.shade400
        : fraction >= 0.85
            ? const Color(0xFFE53935)
            : fraction >= 0.60
                ? const Color(0xFFFB8C00)
                : const Color(0xFF2196F3);
    return Tooltip(
      message: '上下文占用详情 / 手动压缩',
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: _showContextUsageSheet,
        child: SizedBox(
          width: 36,
          height: 36,
          child: Stack(
            alignment: Alignment.center,
            children: [
              SizedBox(
                width: 26,
                height: 26,
                child: CircularProgressIndicator(
                  value: hasData ? fraction.clamp(0.02, 1.0) : 0.0,
                  strokeWidth: 2.6,
                  strokeCap: StrokeCap.round,
                  color: color,
                  backgroundColor: color.withValues(alpha: 0.18),
                ),
              ),
              Text(
                hasData ? '${(fraction * 100).toStringAsFixed(0)}%' : '—',
                style: TextStyle(
                  fontSize: 9,
                  height: 1.0,
                  fontWeight: FontWeight.w700,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 输入 hint 随状态：计划模式 / 生成中插话 / 普通输入。
  String _inputHintFor(bool isGenerating, String text) {    if (text.startsWith(_planPrefix)) return '计划模式：先规划后执行…';
    if (isGenerating) return '插话给执行中的智能体…（不打断）';
    return '输入消息…';
  }

  /// 生成中状态细条：「● 执行中 · N 个工具 · 当前工具」+ 右侧停止文字按钮。
  /// 普通聊天生成中只显示「生成中」。停止 = 兜底入口（主键位在空输入时也是停止）。
  Widget _buildTurnStatusStrip(bool isGenerating) {
    if (!isGenerating) return const SizedBox.shrink();
    final ui = ref.watch(agentUiStateProvider)[_currentConversationId] ??
        const AgentUiState();
    final executing = ui.tools
        .where((t) => t.status == ToolUiStatus.executing)
        .toList()
        .lastOrNull
        ?.name;
    final label = ui.tools.isEmpty
        ? '生成中…'
        : (executing != null
            ? '执行中 · ${ui.tools.length} 个工具 · $executing'
            : '执行中 · ${ui.tools.length} 个工具');
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 8, 0),
      child: Row(
        children: [
          _buildPulsingDot(),
          const SizedBox(width: 6),
          Expanded(
            child: Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 12, color: Theme.of(context).colorScheme.primary)),
          ),
          TextButton(
            style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8)),
            onPressed: _stopGeneration,
            child: const Text('停止', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  /// 附件 chips 行：图片 = 40px 缩略图、文件 = 文件名 chip，各带 × 删除。
  Widget _buildAttachmentChips() {
    if (_selectedImagePaths.isEmpty && _selectedFilePaths.isEmpty) {
      return const SizedBox.shrink();
    }
    return Container(
      margin: const EdgeInsets.only(top: 4),
      height: 52,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          for (var i = 0; i < _selectedImagePaths.length; i++)
            _removableChip(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.file(
                  File(_selectedImagePaths[i]),
                  width: 44,
                  height: 44,
                  fit: BoxFit.cover,
                ),
              ),
              onRemove: () => setState(() => _selectedImagePaths.removeAt(i)),
            ),
          for (var i = 0; i < _selectedFilePaths.length; i++)
            _removableChip(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.description, size: 18),
                    const SizedBox(width: 4),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 90),
                      child: Text(
                        _fileNameOf(_selectedFilePaths[i]),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11),
                      ),
                    ),
                  ],
                ),
              ),
              onRemove: () => setState(() => _selectedFilePaths.removeAt(i)),
            ),
        ],
      ),
    );
  }

  /// 可删除 chip 容器：右上角小 ×（44px 基座内 16px 触点扩展到 20）。
  Widget _removableChip({required Widget child, required VoidCallback onRemove}) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          child,
          Positioned(
            top: -4,
            right: -4,
            child: GestureDetector(
              onTap: onRemove,
              child: Container(
                width: 20,
                height: 20,
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.white, width: 1),
                ),
                child: const Icon(Icons.close, color: Colors.white, size: 13),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---- P3 模式 chips（composer 底部动作行，轻量 11px 字号）----

  /// 纯图标模式键（用户定案：图标即可，去文字防拥挤）。32px 圆角方，
  /// active 高亮；语义靠 Tooltip。低视力/新用户长按即见说明。
  Widget _composerChip({
    required IconData icon,
    required VoidCallback onTap,
    bool active = false,
    required String tooltip,
    Color? iconColor,
  }) {
    final tint = active
        ? Theme.of(context).colorScheme.primary
        : (iconColor ?? Theme.of(context).colorScheme.outline);
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Tooltip(
        message: tooltip,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Container(
            width: 32,
            height: 30,
            decoration: BoxDecoration(
              color: active
                  ? Theme.of(context).colorScheme.primaryContainer
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: active
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context)
                        .colorScheme
                        .outline
                        .withValues(alpha: 0.35),
              ),
            ),
            child: Icon(icon, size: 17, color: tint),
          ),
        ),
      ),
    );
  }

  /// 智能体总开关 chip（开 = 高亮；点按切换，设置同步持久化）。
  Widget _buildAgentToggleChip(InferenceSettings settings) {
    final on = settings.agentEnabled;
    return _composerChip(
      active: on,
      tooltip: on ? '智能体模式：开（点按关闭）' : '智能体模式：关（点按开启）',
      onTap: () => ref
          .read(settingsProvider.notifier)
          .setAgentEnabled(!on),
      icon: Icons.smart_toy_outlined,
    );
  }

  /// 人格 chip：显示当前人格（标准/自定义名），点按弹底部选择。
  Widget _buildPersonaChip(InferenceSettings settings) {
    final persona = settings.activePersona();
    return _composerChip(
      tooltip: '切换人格',
      onTap: () => _showPersonaPicker(settings),
      icon: Icons.theater_comedy,
      active: persona != null,
      iconColor: persona != null ? Colors.deepPurple : null,
    );
  }

  /// 人格快速选择（底部弹层：标准 + 自定义），选择即持久化。
  void _showPersonaPicker(InferenceSettings settings) {
    final notifier = ref.read(settingsProvider.notifier);
    final activeId = settings.activePersonaId;
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('切换人格',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.person_outline, size: 20),
              title: const Text('标准', style: TextStyle(fontSize: 14)),
              trailing: activeId == kStandardPersonaId
                  ? const Icon(Icons.check, size: 18)
                  : null,
              onTap: () {
                notifier.setActivePersona(kStandardPersonaId);
                Navigator.pop(ctx);
              },
            ),
            for (final p in settings.agentPersonas)
              ListTile(
                dense: true,
                leading: const Icon(Icons.theater_comedy, size: 20),
                title: Text(p.name, style: const TextStyle(fontSize: 14)),
                subtitle: p.prompt.isEmpty
                    ? null
                    : Text(p.prompt,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11)),
                trailing: activeId == p.id
                    ? const Icon(Icons.check, size: 18)
                    : null,
                onTap: () {
                  notifier.setActivePersona(p.id);
                  Navigator.pop(ctx);
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// 计划 chip：点按打开**计划面板**（查看/更新步骤状态/放弃/重新规划），
  /// 激活 = 输入框带 /plan 前缀或存在活跃计划（存在活跃计划时恒高亮）。
  Widget _buildPlanModeChip() {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: _textController,
      builder: (_, value, __) {
        final active = value.text.startsWith(_planPrefix) || _hasActivePlan;
        return _composerChip(
          active: active,
          tooltip: '计划：查看进度 / 手动更新状态 / 重新规划',
          onTap: _showPlanPanel,
          icon: Icons.checklist,
        );
      },
    );
  }

  /// 是否存在活跃计划（打开面板/切会话时刷新；驱动 chip 高亮）。
  bool _hasActivePlan = false;

  Future<void> _refreshActivePlanFlag() async {
    final plan = await (await _planStore()).load(_currentConversationId);
    if (mounted && _hasActivePlan != (plan != null)) {
      setState(() => _hasActivePlan = plan != null);
    }
  }

  /// 计划面板（bottom sheet）：无计划 = 说明 + 一键生成入口；
  /// 有计划 = 目标 + 步骤状态列表（点按改状态）+ 放弃/重新规划。
  Future<void> _showPlanPanel() async {
    final store = await _planStore();
    if (!mounted) return;
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _PlanPanelSheet(
        store: store,
        conversationId: _currentConversationId,
        onRegenerate: () {
          final text = _textController.text;
          if (!text.startsWith(_planPrefix)) {
            _textController.text = '$_planPrefix${text.trimLeft()}';
            _textController.selection = TextSelection.fromPosition(
                TextPosition(offset: _textController.text.length));
          }
          FocusScope.of(this.context).requestFocus(FocusNode());
        },
        onChanged: () => _refreshActivePlanFlag(),
      ),
    );
    _refreshActivePlanFlag();
  }

  /// 模型 chip：API 档显示 API 配置名，本地档显示当前模型；点按开模型状态弹层。
  Widget _buildModelChip(ModelState ms, bool isGenerating) {
    final settings = ref.watch(settingsProvider);
    final label = settings.agentEnabled && settings.agentModelSource == 'api'
        ? (settings.activeApiModel()?.name ?? 'API')
        : (ms.modelName ?? ms.modelId ?? '本地模型');
    return _composerChip(
      onTap: () => _showModelStatusPopup(ms, isGenerating),
      icon: Icons.memory,
      iconColor: Colors.teal,
      tooltip: '当前驱动模型：$label',
    );
  }

  /// ask_user_question 待回答卡片：问题 + 候选项 + 自由回答 + 跳过。
  /// 回答经 [ChatNotifier.answerPendingQuestion] 完成挂起的工具调用。
  Widget _buildPendingQuestionCard() {
    final pending =
        ref.watch(agentPendingQuestionProvider)[_currentConversationId];
    if (pending == null) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(Icons.help_outline,
                  size: 16, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 6),
              Text('智能体提问 · 回合等待中',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Theme.of(context).colorScheme.primary)),
            ],
          ),
          const SizedBox(height: 8),
          Text(pending.question, style: const TextStyle(fontSize: 14)),
          if (pending.options.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final option in pending.options)
                  ActionChip(
                    label: Text(option, style: const TextStyle(fontSize: 12)),
                    onPressed: () => ref
                        .read(chatNotifierProvider.notifier)
                        .answerPendingQuestion(_currentConversationId, option),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _questionController,
                  style: const TextStyle(fontSize: 13),
                  decoration: const InputDecoration(
                    hintText: '输入你的回答…',
                    isDense: true,
                    border: OutlineInputBorder(),
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  ),
                  onSubmitted: (value) {
                    if (value.trim().isEmpty) return;
                    ref
                        .read(chatNotifierProvider.notifier)
                        .answerPendingQuestion(_currentConversationId, value);
                    _questionController.clear();
                  },
                ),
              ),
              IconButton(
                icon: const Icon(Icons.send, size: 20),
                tooltip: '回答',
                onPressed: () {
                  final value = _questionController.text.trim();
                  if (value.isEmpty) return;
                  ref
                      .read(chatNotifierProvider.notifier)
                      .answerPendingQuestion(_currentConversationId, value);
                  _questionController.clear();
                },
              ),
              TextButton(
                onPressed: () => ref
                    .read(chatNotifierProvider.notifier)
                    .answerPendingQuestion(_currentConversationId, null),
                child: const Text('跳过', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// composer 主键（位置语义复用，单键四态——标准智能体形态）：
  /// - 空闲 + 空输入：🎤 长按说话（短按 = 直接发送语音的替代：点按后录音横幅出现，再点发送）；
  /// - 空闲 + 有文字：➤ 发送（含图片/附件）；
  /// - 生成中 + 空输入：⏹ 停止；
  /// - 生成中 + 有文字：➤ 插话（steer，不打断执行；附件不随插话发送）。
  /// 停止另有生成中状态细条右侧「停止」文字按钮兜底（永远两处可达）。
  Widget _buildComposerKey(bool isGenerating) {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: _textController,
      builder: (_, value, __) {
        final hasText = value.text.trim().isNotEmpty;
        // 生成中：空输入 = 停止；有文字 = 插话发送。
        if (isGenerating) {
          return _roundKey(
            icon: hasText ? Icons.arrow_upward : Icons.stop,
            color: hasText
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).colorScheme.error,
            tooltip: hasText ? '插话发送（不打断执行）' : '停止回复',
            onTap: hasText ? _steerMessage : _stopGeneration,
          );
        }
        // 空闲：有文字 = 发送；空输入 = 麦克风（长按说话，保留原手势语义）。
        if (hasText) {
          return _roundKey(
            icon: Icons.arrow_upward,
            color: Theme.of(context).colorScheme.primary,
            tooltip: '发送',
            onTap: _sendMessage,
          );
        }
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onLongPressStart: (d) =>
              _onVoiceLongPressStart(context, d.globalPosition),
          onLongPressMoveUpdate: (d) =>
              _onVoiceLongPressMoveUpdate(d.globalPosition),
          onLongPressEnd: (_) => _onVoiceLongPressEnd(),
          onLongPressCancel: () => _onVoiceLongPressEnd(),
          child: _roundKey(
            icon: Icons.mic,
            color: Theme.of(context).colorScheme.primary,
            tooltip: null,
            onTap: () {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                  content: Text('按住 🎤 说话，松手即发送（上滑取消）')));
            },
          ),
        );
      },
    );
  }

  /// 40px 圆形实心主键（composer 卡片内嵌，替代 FAB 的悬浮阴影）。
  /// [tooltip] 传 null = 不包 Tooltip——Tooltip 默认带长按手势识别器，
  /// 会赢过外层 GestureDetector 的长按（麦克风长按说话被它抢走的实锤，07:1x）。
  Widget _roundKey({
    required IconData icon,
    required Color color,
    String? tooltip,
    VoidCallback? onTap,
  }) {
    final key = Material(
      color: color,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: SizedBox(
          width: 40,
          height: 40,
          child: Icon(icon, size: 22, color: Colors.white),
        ),
      ),
    );
    if (tooltip == null) return key;
    return Tooltip(message: tooltip, child: key);
  }

  /// 回合中插话（steer）：不打断执行，文字注入运行中回合的下一个 step。
  /// 附件/图片不随插话发送——保留在输入区，随下一条正式消息发送。
  Future<void> _steerMessage() async {
    final text = _textController.text.trim();
    if (text.isEmpty) return;
    if (_selectedImagePaths.isNotEmpty || _selectedFilePaths.isNotEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('插话仅发送文字；已选附件将随下一条消息发送',
                style: TextStyle(color: Colors.white))));
      }
    }
    _textController.clear();
    FocusScope.of(context).unfocus();
    _followStream = true;
    try {
      await ref
          .read(chatNotifierProvider.notifier)
          .steerTurn(_currentConversationId, text);
    } catch (e) {
      _textController.text = text;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content:
                Text('插话失败: $e', style: const TextStyle(color: Colors.white))),
      );
    }
  }

  /// 录音中的横幅：波形动画 + 计时 + 「松手发送」提示。
  // =========================================================================
  // Conversation drawer — compact entry for managing (new / switch / delete)
  // =========================================================================

  // ---- P2 会话抽屉重构：搜索 / 分组 / 摘要 / 状态徽标 / 行内操作 ----

  final TextEditingController _conversationSearchCtrl =
      TextEditingController();
  String _conversationSearchQuery = '';

  /// 各会话最后一条消息摘要（一次批量 SQL；打开抽屉时失效重取）。
  Future<Map<String, String>>? _snippetsFuture;

  void _invalidateSnippets() => _snippetsFuture = null;

  Widget _buildConversationDrawer() {
    final conversations = ref.watch(conversationsProvider);
    final settings = ref.watch(settingsProvider);
    final pinned = settings.pinnedConversationIds.toSet();
    return Drawer(
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
              child: Row(children: [
                // 最常用操作给最大触点：新建 = 主按钮。
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _newConversation,
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('新对话'),
                  ),
                ),
                // 批量选择开关：进入多选模式后，点按会话变为勾选而非切换。
                IconButton(
                  icon: Icon(_conversationSelectionMode
                      ? Icons.close
                      : Icons.checklist),
                  tooltip:
                      _conversationSelectionMode ? '退出批量选择' : '批量选择',
                  color: _conversationSelectionMode
                      ? Theme.of(context).colorScheme.primary
                      : null,
                  onPressed: () {
                    setState(() {
                      _conversationSelectionMode =
                          !_conversationSelectionMode;
                      if (!_conversationSelectionMode) {
                        _selectedConversations.clear();
                      }
                    });
                  },
                ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
              child: TextField(
                controller: _conversationSearchCtrl,
                onChanged: (v) => setState(() => _conversationSearchQuery = v),
                decoration: InputDecoration(
                  hintText: '搜索会话…',
                  isDense: true,
                  prefixIcon: const Icon(Icons.search, size: 18),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10)),
                  contentPadding: const EdgeInsets.symmetric(vertical: 8),
                ),
              ),
            ),
            Expanded(
              child: conversations.isEmpty
                  ? const Center(
                      child: Text('暂无会话',
                          style: TextStyle(color: Colors.grey)))
                  : FutureBuilder<Map<String, String>>(
                      future: _snippetsFuture ??=
                          ref.read(storageServiceProvider)
                              .lastMessageSnippets(),
                      builder: (ctx, snap) {
                        final snippets = snap.data ?? const {};
                        return _buildConversationList(
                            conversations, pinned, snippets);
                      },
                    ),
            ),
            // 批量选择底部操作栏
            if (_conversationSelectionMode) ...[
              const Divider(height: 1),
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(children: [
                    Text('已选 ${_selectedConversations.length} 个'),
                    const Spacer(),
                    OutlinedButton.icon(
                      onPressed: _selectedConversations.isEmpty
                          ? null
                          : _confirmBulkDelete,
                      icon: const Icon(Icons.delete_outline, size: 18),
                      label:
                          Text('删除选中(${_selectedConversations.length})'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.red.shade700,
                        padding:
                            const EdgeInsets.symmetric(horizontal: 12),
                      ),
                    ),
                  ]),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 按查询过滤 + 分组：置顶 / 今天 / 昨天 / 7 天内 / 更早。
  List<MapEntry<String, List<Conversation>>> _groupConversations(
    List<Conversation> conversations,
    Set<String> pinned,
  ) {
    final q = _conversationSearchQuery.trim().toLowerCase();
    final filtered = q.isEmpty
        ? conversations
        : conversations
            .where((c) => c.title.toLowerCase().contains(q))
            .toList();
    final now = DateTime.now();
    final startToday = DateTime(now.year, now.month, now.day);
    final startYesterday = startToday.subtract(const Duration(days: 1));
    final startWeek = startToday.subtract(const Duration(days: 7));
    final groups = <String, List<Conversation>>{
      '置顶': [],
      '今天': [],
      '昨天': [],
      '7 天内': [],
      '更早': [],
    };
    for (final c in filtered) {
      if (pinned.contains(c.id)) {
        groups['置顶']!.add(c);
      } else if (!c.updatedAt.isBefore(startToday)) {
        groups['今天']!.add(c);
      } else if (!c.updatedAt.isBefore(startYesterday)) {
        groups['昨天']!.add(c);
      } else if (!c.updatedAt.isBefore(startWeek)) {
        groups['7 天内']!.add(c);
      } else {
        groups['更早']!.add(c);
      }
    }
    return [
      for (final e in groups.entries)
        if (e.value.isNotEmpty) MapEntry(e.key, e.value),
    ];
  }

  Widget _buildConversationList(
    List<Conversation> conversations,
    Set<String> pinned,
    Map<String, String> snippets,
  ) {
    final groups = _groupConversations(conversations, pinned);
    return ListView.builder(
      itemCount: groups.length,
      itemBuilder: (ctx, gi) {
        final g = groups[gi];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
              child: Text(g.key,
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Colors.grey.shade600)),
            ),
            for (final c in g.value)
              _buildConversationTile(c, c.id == _currentConversationId,
                  pinned.contains(c.id), snippets[c.id] ?? ''),
          ],
        );
      },
    );
  }

  Widget _buildConversationTile(
      Conversation c, bool isCurrent, bool isPinned, String snippet) {
    final updated = _formatTime(c.updatedAt);
    // 批量选择模式下：勾选框 + 点按切换选中；隐藏单个操作菜单。
    final selectionMode = _conversationSelectionMode;
    final selected = _selectedConversations.contains(c.id);
    final running = ref.watch(runningTurnsProvider)[c.id] ?? false;
    return ListTile(
      dense: true,
      selected: isCurrent && !selectionMode,
      leading: selectionMode
          ? Icon(
              selected ? Icons.check_circle : Icons.circle_outlined,
              color: selected
                  ? Theme.of(context).colorScheme.primary
                  : Colors.grey.shade400,
            )
          : running
              ? const Icon(Icons.autorenew,
                  size: 20, color: Colors.orange)
              : Icon(
                  isCurrent ? Icons.chat_bubble : Icons.chat_bubble_outline,
                  size: 20,
                  color: isCurrent
                      ? Theme.of(context).colorScheme.primary
                      : Colors.grey,
                ),
      title: Row(children: [
        if (isPinned) ...[
          Icon(Icons.push_pin, size: 12, color: Colors.grey.shade500),
          const SizedBox(width: 4),
        ],
        Flexible(
          child: Text(c.title.isEmpty ? '新对话' : c.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontWeight: isCurrent && !selectionMode
                      ? FontWeight.w600
                      : FontWeight.normal)),
        ),
        if (isCurrent && _hasActivePlan) ...[
          const SizedBox(width: 4),
          const Text('📋', style: TextStyle(fontSize: 11)),
        ],
      ]),
      subtitle: Text(
        snippet.isEmpty ? '$updated · ${c.messageCount} 条' : snippet,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
            fontSize: 12,
            color: snippet.isEmpty ? Colors.grey : Colors.grey.shade600),
      ),
      onTap: selectionMode
          ? () {
              setState(() {
                if (!_selectedConversations.remove(c.id)) {
                  _selectedConversations.add(c.id);
                }
              });
            }
          : () => _switchConversation(c.id),
      onLongPress: selectionMode
          ? null
          : () {
              // 长按 = 进入批量选择并选中（保留原批量能力入口）。
              setState(() {
                _conversationSelectionMode = true;
                _selectedConversations.add(c.id);
              });
            },
      trailing: selectionMode
          ? null
          : PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert, size: 18),
              onSelected: (action) {
                switch (action) {
                  case 'pin':
                    ref
                        .read(settingsProvider.notifier)
                        .togglePinnedConversation(c.id);
                    break;
                  case 'rename':
                    _renameConversation(c);
                    break;
                  case 'delete':
                    _confirmDelete(c);
                    break;
                }
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                    value: 'pin',
                    child: Text(isPinned ? '取消置顶' : '置顶')),
                const PopupMenuItem(
                    value: 'rename', child: Text('重命名')),
                const PopupMenuItem(
                    value: 'delete',
                    child: Text('删除',
                        style: TextStyle(color: Colors.red))),
              ],
            ),
    );
  }

  /// 重命名会话：对话框输入 → 更新存储 + provider（P2 抽屉行内操作）。
  Future<void> _renameConversation(Conversation c) async {
    final ctrl = TextEditingController(text: c.title);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名会话'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration:
              const InputDecoration(border: OutlineInputBorder()),
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
    if (ok != true) return;
    final title = ctrl.text.trim();
    if (title.isEmpty) return;
    await ref
        .read(storageServiceProvider)
        .updateConversation(id: c.id, title: title);
    if (!mounted) return;
    ref.read(conversationsProvider.notifier).update(Conversation(
          id: c.id,
          title: title,
          modelId: c.modelId,
          messageCount: c.messageCount,
          createdAt: c.createdAt,
          updatedAt: DateTime.now(),
        ));
  }

  /// Create a new conversation and switch to it.
  Future<void> _newConversation() async {
    final notifier = ref.read(conversationsProvider.notifier);
    await notifier.create();
    final convs = ref.read(conversationsProvider);
    if (convs.isNotEmpty) {
      _saveDraft();
      setState(() {
        _currentConversationId = convs.first.id;
        _followStream = true;
        _selectedImagePaths.clear();
        _selectedFilePaths.clear();
      });
      _restoreDraft();
    }
    if (Navigator.of(context).canPop()) Navigator.of(context).pop();
  }

  /// 会话草稿（P3）：保存当前未发送文字；发送/清空时删除对应草稿。
  void _saveDraft() {
    final t = _textController.text;
    if (t.isEmpty) {
      _drafts.remove(_currentConversationId);
    } else {
      _drafts[_currentConversationId] = t;
    }
  }

  /// 恢复目标会话的草稿（无草稿则清空输入框）。
  void _restoreDraft() {
    _textController.text = _drafts[_currentConversationId] ?? '';
    _textController.selection = TextSelection.fromPosition(
        TextPosition(offset: _textController.text.length));
    _refreshActivePlanFlag();
  }

  /// Switch to an existing conversation (no-op if already current).
  void _switchConversation(String id) {
    if (id != _currentConversationId) {
      _saveDraft();
      setState(() {
        _currentConversationId = id;
        _followStream = true;
        _selectedImagePaths.clear();
        _selectedFilePaths.clear();
      });
      _restoreDraft();
      // 切会话：该会话无快照（如重启后首次切入）→ 估算回填。
      unawaited(ref
          .read(chatNotifierProvider.notifier)
          .refreshUsageEstimate(id));
    }
    Navigator.of(context).pop();
  }

  Future<void> _confirmDelete(Conversation c) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除会话'),
        content: Text(
            '确定删除「${c.title.isEmpty ? '新对话' : c.title}」吗？\n该会话的所有消息将被永久删除。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
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
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
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
        _selectedImagePaths.clear();
        _selectedFilePaths.clear();
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
      _saveDraft();
      setState(() {
        _currentConversationId = convs.isEmpty ? '' : convs.first.id;
        _followStream = true;
        _selectedImagePaths.clear();
        _selectedFilePaths.clear();
      });
      _restoreDraft();
    }
  }

  String _formatTime(DateTime t) {
    final now = DateTime.now();
    final hhmm =
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    final day = DateTime(t.year, t.month, t.day);
    final today = DateTime(now.year, now.month, now.day);
    final diff = today.difference(day).inDays;
    if (diff == 0) return '今天 $hhmm';
    if (diff == 1) return '昨天 $hhmm';
    if (t.year == now.year) return '${t.month}/${t.day} $hhmm';
    return '${t.year}/${t.month}/${t.day} $hhmm';
  }
}

/// 统一附件面板的选项（拍照 / 相册 / 文件）。
enum _AttachSource { none, camera, gallery, file }

/// 附件面板的单行选项：着色圆角图标 + 标题 + 副标题，整行水波纹点按。
class _AttachOption extends StatelessWidget {
  final IconData icon;
  final Color tint;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _AttachOption({
    required this.icon,
    required this.tint,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: tint.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, size: 22, color: tint),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: const TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 1),
                      Text(subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 11,
                              color: theme.colorScheme.onSurfaceVariant)),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right,
                    size: 18, color: theme.colorScheme.onSurfaceVariant),
              ],
            ),
          ),
        ),
      ),
    );
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
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                    color: Colors.grey.shade400,
                    borderRadius: BorderRadius.circular(2)),
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
                          phase == ModelLifecyclePhase.loaded
                              ? '模型已就绪'
                              : _phaseLabelFor(phase),
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.bold),
                        ),
                        if (phase == ModelLifecyclePhase.loaded ||
                            phase == ModelLifecyclePhase.error)
                          Text(
                            modelName,
                            style: TextStyle(
                                fontSize: 12, color: Colors.grey.shade600),
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
                      style:
                          TextStyle(fontSize: 12, color: Colors.blue.shade800),
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
                  child: Text(errorMessage!,
                      style:
                          TextStyle(fontSize: 12, color: Colors.red.shade800)),
                ),
              if (errorMessage != null) const SizedBox(height: 12),
              // Actions
              if (phase == ModelLifecyclePhase.loaded && !isGenerating) ...[
                _sheetButton(context,
                    label: '卸载模型',
                    icon: Icons.close,
                    color: Colors.red,
                    onTap: onUnload),
                const SizedBox(height: 8),
              ],
              if (phase == ModelLifecyclePhase.error) ...[
                _sheetButton(context,
                    label: '重试加载',
                    icon: Icons.refresh,
                    color: Colors.blue,
                    onTap: onLoad),
                const SizedBox(height: 8),
              ],
              if (phase == ModelLifecyclePhase.idle) ...[
                _sheetButton(context,
                    label: '去加载模型',
                    icon: Icons.download,
                    color: Colors.green,
                    onTap: onGoToSettings),
                const SizedBox(height: 8),
              ],
              _sheetButton(context,
                  label: '关闭',
                  icon: null,
                  color: null,
                  onTap: () => Navigator.pop(context),
                  isDefault: true),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sheetButton(
    BuildContext context, {
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
          backgroundColor:
              color ?? Theme.of(context).colorScheme.primaryContainer,
          foregroundColor: color == null ? null : Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 12),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
        icon: icon != null ? Icon(icon, size: 18) : null,
        label: Text(label),
      ),
    );
  }

  IconData _sheetIconFor(ModelLifecyclePhase phase) {
    switch (phase) {
      case ModelLifecyclePhase.idle:
        return Icons.memory_outlined;
      case ModelLifecyclePhase.loading:
        return Icons.sync_alt;
      case ModelLifecyclePhase.loaded:
        return Icons.check_circle;
      case ModelLifecyclePhase.unloading:
        return Icons.sync_disabled;
      case ModelLifecyclePhase.error:
        return Icons.error_outline;
    }
  }

  String _phaseLabelFor(ModelLifecyclePhase phase) {
    switch (phase) {
      case ModelLifecyclePhase.idle:
        return '未加载';
      case ModelLifecyclePhase.loading:
        return '加载中…';
      case ModelLifecyclePhase.loaded:
        return '已加载';
      case ModelLifecyclePhase.unloading:
        return '卸载中…';
      case ModelLifecyclePhase.error:
        return '加载失败';
    }
  }

  Color _sheetColorFor(ModelLifecyclePhase phase) {
    switch (phase) {
      case ModelLifecyclePhase.idle:
        return Colors.grey;
      case ModelLifecyclePhase.loading:
        return Colors.blue;
      case ModelLifecyclePhase.loaded:
        return Colors.green;
      case ModelLifecyclePhase.unloading:
        return Colors.orange;
      case ModelLifecyclePhase.error:
        return Colors.red;
    }
  }

  Widget _buildPulsingDotLarge() {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.3, end: 1.0),
      duration: const Duration(milliseconds: 800),
      curve: Curves.easeInOut,
      builder: (context, value, _) => Container(
        width: 14,
        height: 14,
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
              width: 14,
              height: 14,
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
              Text('内存占用',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Colors.grey.shade800)),
              const Spacer(),
              Text('可用 ${_gb(sysAvail)} GB',
                  style: TextStyle(
                      fontSize: 12, color: _pressureColor(sysAvailPct))),
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
                  color: _pressureColor(
                      sysTotal > 0 ? 1 - (modelMB + kvCache) / sysTotal : 1),
                ),
              ),
              Text('进程 RSS: ${_gb(procRss)} GB',
                  style: const TextStyle(fontSize: 12, color: Colors.black87)),
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
          Text(label,
              style:
                  TextStyle(fontSize: 11, color: color.withValues(alpha: 0.9))),
          const SizedBox(height: 2),
          Text(value,
              style: TextStyle(
                  fontSize: 14, fontWeight: FontWeight.w700, color: color)),
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
            Text('${_gb(usedMB)} / ${_gb(totalMB)} GB',
                style:
                    const TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
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

class _PlanPanelSheet extends StatefulWidget {
  final GoalStore store;
  final String conversationId;
  final VoidCallback onRegenerate;
  final VoidCallback onChanged;

  const _PlanPanelSheet({
    required this.store,
    required this.conversationId,
    required this.onRegenerate,
    required this.onChanged,
  });

  @override
  State<_PlanPanelSheet> createState() => _PlanPanelSheetState();
}

class _PlanPanelSheetState extends State<_PlanPanelSheet> {
  GoalState? _plan;
  List<Map<String, String>> _todos = const [];
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final plan = await widget.store.load(widget.conversationId);
    // 任务清单（todo_write 按会话落盘）：只看**当前会话**的清单（todo v3
    // 按会话隔离——旧全局单文件会在任何会话显示同一份清单，已废弃）。
    List<Map<String, String>> todos = const [];
    try {
      todos = await readTodoStore(widget.conversationId);
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _plan = plan;
      _todos = todos;
      _loaded = true;
    });
  }

  Future<void> _setStep(int index, PlanStepStatus status) async {
    final err = await widget.store.updateStep(widget.conversationId,
        stepIndex: index, status: status);
    if (err == null) {
      widget.onChanged();
      await _reload();
    }
  }

  Future<void> _finishPlan(GoalStatus status) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(status == GoalStatus.cancelled ? '放弃计划？' : '重新规划？'),
        content: const Text('当前计划将被清除，执行中的无人值守续跑随之停止。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('确认')),
        ],
      ),
    );
    if (ok != true) return;
    await widget.store.finish(widget.conversationId, status);
    widget.onChanged();
    if (!mounted) return;
    Navigator.pop(context);
    if (status == GoalStatus.cancelled) widget.onRegenerate();
  }

  @override
  Widget build(BuildContext context) {
    final plan = _plan;
    return SafeArea(
      child: Container(
        constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.7),
        padding: const EdgeInsets.all(16),
        child: !_loaded
            ? const Center(child: CircularProgressIndicator())
            : plan == null
                ? _buildEmpty(context)
                : _buildPlan(context, plan),
      ),
    );
  }

  /// 任务清单区（todo_write 的全局清单；空则不显示）。与对话内活卡同组件。
  Widget _buildTodosSection(BuildContext context) {
    if (_todos.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: TodoChecklistCard(content: renderTodoCardText(_todos)),
    );
  }

  Widget _buildEmpty(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('📋 计划',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        const Text(
            '当前会话没有活跃计划。发送「/plan <任务>」，智能体调研后提交计划，'
            '你批准后自动执行，进度在这里回看。',
            style: TextStyle(fontSize: 13, height: 1.5)),
        _buildTodosSection(context),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: () {
              Navigator.pop(context);
              widget.onRegenerate();
            },
            icon: const Icon(Icons.auto_fix_high, size: 18),
            label: const Text('生成计划（填入 /plan 到输入框）'),
          ),
        ),
      ],
    );
  }

  Widget _buildPlan(BuildContext context, GoalState plan) {
    final statusText = switch (plan.status) {
      GoalStatus.active => '执行中（续跑 ${plan.rounds}/${plan.maxRounds} 轮）',
      GoalStatus.done => '已完成',
      GoalStatus.cancelled => '已取消',
      GoalStatus.expired => '轮数耗尽',
    };
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          const Text('📋 计划',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(width: 8),
          Flexible(
            child: Text(plan.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14)),
          ),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: plan.status == GoalStatus.active
                  ? Theme.of(context).colorScheme.primaryContainer
                  : Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(statusText, style: const TextStyle(fontSize: 11)),
          ),
        ]),
        const SizedBox(height: 8),
        if (plan.steps.isEmpty) ...[
          Text(plan.goal,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, height: 1.4)),
          const SizedBox(height: 6),
          const Text('（纯文本目标：无结构化步骤；重新规划可生成带步骤的计划）',
              style: TextStyle(fontSize: 11, color: Colors.grey)),
        ] else ...[
          Text('目标：${plan.goal}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
          const SizedBox(height: 6),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (var i = 0; i < plan.steps.length; i++)
                  _stepTile(context, plan, i),
              ],
            ),
          ),
          Text('已完成 ${plan.doneCount}/${plan.steps.length} · 点按改状态',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
        ],
        _buildTodosSection(context),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () => _finishPlan(GoalStatus.cancelled),
              icon: const Icon(Icons.delete_outline, size: 16),
              label: const Text('放弃计划'),
              style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.red.shade700),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: FilledButton.tonalIcon(
              onPressed: () => _finishPlan(GoalStatus.expired),
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('重新规划'),
            ),
          ),
        ]),
      ],
    );
  }

  /// 步骤行：点按循环 pending→running→done→pending；菜单可指定/置失败。
  Widget _stepTile(BuildContext context, GoalState plan, int i) {
    final step = plan.steps[i];
    final isCurrent = plan.currentStepIndex == i;
    final (icon, color) = switch (step.status) {
      PlanStepStatus.pending => (Icons.radio_button_unchecked, Colors.grey),
      PlanStepStatus.running => (Icons.autorenew, Colors.orange),
      PlanStepStatus.done => (Icons.check_circle, Colors.green),
      PlanStepStatus.failed => (Icons.cancel, Colors.red),
    };
    return ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      tileColor: isCurrent
          ? Theme.of(context)
              .colorScheme
              .primaryContainer
              .withValues(alpha: 0.4)
          : null,
      leading: Icon(icon, size: 20, color: color),
      title: Text('${i + 1}. ${step.title}',
          style: TextStyle(
              fontSize: 13,
              decoration: step.status == PlanStepStatus.done
                  ? TextDecoration.lineThrough
                  : null)),
      subtitle: step.detail.isEmpty
          ? null
          : Text(step.detail,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11)),
      trailing: PopupMenuButton<PlanStepStatus>(
        icon: const Icon(Icons.more_vert, size: 18),
        onSelected: (s) => _setStep(i + 1, s),
        itemBuilder: (_) => const [
          PopupMenuItem(value: PlanStepStatus.pending, child: Text('置为待做')),
          PopupMenuItem(value: PlanStepStatus.running, child: Text('置为执行中')),
          PopupMenuItem(value: PlanStepStatus.done, child: Text('置为完成')),
          PopupMenuItem(value: PlanStepStatus.failed, child: Text('标记失败')),
        ],
      ),
      onTap: () {
        // 循环：pending → running → done → pending
        final next = switch (step.status) {
          PlanStepStatus.pending => PlanStepStatus.running,
          PlanStepStatus.running => PlanStepStatus.done,
          _ => PlanStepStatus.pending,
        };
        _setStep(i + 1, next);
      },
    );
  }
}
