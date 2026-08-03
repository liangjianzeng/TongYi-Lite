import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../providers/index.dart' show chatNotifierProvider, isGeneratingProvider, messagesProvider, storageServiceProvider;
import '../providers/model_provider.dart';
import '../services/storage_permission_service.dart';
import '../widgets/chat_bubble.dart';
import 'settings_screen.dart';

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

  // Image picker state
  String? _selectedImagePath;
  final ImagePicker _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    _initStoragePermission();
    _initConversation();
  }

  Future<void> _initStoragePermission() async {
    // 延迟一点时间显示权限对话框，避免阻塞启动
    Future.delayed(const Duration(milliseconds: 500), () async {
      await StoragePermissionService.checkAndRequestIfNeeded(context);
    });
  }

  Future<void> _initConversation() async {
    final storage = ref.read(storageServiceProvider);
    final conversations = await storage.getAllConversations();
    if (conversations.isEmpty) {
      final conv = await storage.createConversation(title: '新对话');
      setState(() {
        _currentConversationId = conv.id;
      });
    } else {
      setState(() {
        _currentConversationId = conversations.first.id;
      });
    }
    _initiallyLoaded = true;
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
      final XFile? image = await _picker.pickImage(
        source: source,
        maxWidth: 1920,
        maxHeight: 1920,
        imageQuality: 85,
      );

      if (image != null) {
        setState(() => _selectedImagePath = image.path);
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('选择图片失败: $e')),
      );
    }
  }

  /// Send message with optional image
  Future<void> _sendMessage() async {
    final text = _textController.text.trim();
    final imagePath = _selectedImagePath;

    if (text.isEmpty && imagePath == null) return;

    final notifier = ref.read(chatNotifierProvider.notifier);
    try {
      await notifier.sendMessage(_currentConversationId, text, imagePath: imagePath);
    } catch (e) {
      // Show error feedback — don't clear input so user can retry.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('发送失败: $e', style: const TextStyle(color: Colors.white))),
      );
      return;
    }

    // Only clear after successful send.
    _textController.clear();
    setState(() => _selectedImagePath = null);

    // Scroll to top (newest message) — ListView is reverse so maxScrollExtent=0 at the top.
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

  @override
  Widget build(BuildContext context) {
    final isGenerating = ref.watch(isGeneratingProvider);
    final modelState = ref.watch(modelManagerProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('TongYi-Lite'),
        centerTitle: true,
        leading: _buildModelStatusChip(modelState, isGenerating),
        actions: [
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
            Text('模型就绪', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: color)),
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
    final modelName = ms.modelName ?? '未知模型';

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _ModelStatusSheet(
        phase: ms.phase,
        modelName: modelName,
        errorMessage: ms.errorMessage,
        latestLog: ms.latestLog,
        isGenerating: isGenerating,
        onUnload: () async {
          Navigator.pop(ctx);
          await notifier.unloadModel();
        },
        onLoad: () async {
          final id = ms.modelId;
          if (id != null) {
            Navigator.pop(ctx);
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

        return ListView.builder(
          controller: _scrollController,
          padding: const EdgeInsets.symmetric(vertical: 8),
          reverse: true,
          itemCount: messages.length,
          itemBuilder: (context, index) {
            final msg = messages[index];
            return ChatBubble(
              role: msg.role.name,
              content: msg.content,
              timestamp: msg.timestamp,
              isStreaming: msg.isStreaming && index == 0,
              imagePath: msg.imagePath,
            );
          },
        );
      },
    );
  }

  Widget _buildInputBar(bool isGenerating) {
    return Container(
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
                    IconButton(
                      icon: const Icon(Icons.mic),
                      tooltip: '语音',
                      onPressed: isGenerating ? null : () {
                        // TODO: Speech input
                      },
                    ),
                  ],
                ),
              ),
              onSubmitted: (_) => _sendMessage(),
              maxLines: null,
            ),
          ),
          const SizedBox(width: 8),
          FloatingActionButton(
            onPressed: isGenerating ? null : _sendMessage,
            mini: true,
            child: isGenerating
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.send),
          ),
        ],
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
  final String? latestLog;
  final bool isGenerating;
  final VoidCallback onUnload;
  final VoidCallback onLoad;
  final VoidCallback onGoToSettings;

  const _ModelStatusSheet({
    required this.phase,
    required this.modelName,
    this.errorMessage,
    this.latestLog,
    required this.isGenerating,
    required this.onUnload,
    required this.onLoad,
    required this.onGoToSettings,
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
      child: SafeArea(
        child: Padding(
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
              const SizedBox(height: 12),
              // Progress log
              if (latestLog != null)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.blue.shade50,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(latestLog!, style: TextStyle(fontSize: 12, color: Colors.blue.shade800)),
                ),
              if (latestLog != null) const SizedBox(height: 12),
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
