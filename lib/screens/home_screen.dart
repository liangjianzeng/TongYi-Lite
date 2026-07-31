import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/index.dart' show chatNotifierProvider, isGeneratingProvider, messagesProvider, storageServiceProvider;
import '../providers/model_provider.dart';
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

  @override
  void initState() {
    super.initState();
    _initConversation();
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

  Future<void> _sendMessage() async {
    final text = _textController.text.trim();
    if (text.isEmpty) return;
    _textController.clear();

    final notifier = ref.read(chatNotifierProvider.notifier);
    await notifier.sendMessage(_currentConversationId, text);

    // Scroll to bottom
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
          // ---- Model status bar ----
          _buildModelStatusBar(modelState, isGenerating),

          Expanded(
            child: _initiallyLoaded
                ? _buildMessagesList()
                : const Center(child: CircularProgressIndicator()),
          ),
          _buildInputBar(isGenerating),
        ],
      ),
    );
  }

  // =========================================================================
  // Model status bar — shows current model state at top of chat screen
  // =========================================================================

  Widget _buildModelStatusBar(ModelState modelState, bool isGenerating) {
    if (modelState.phase == ModelLifecyclePhase.idle && !isGenerating) {
      return const SizedBox.shrink(); // hide when nothing to show
    }

    final color = _colorFor(modelState.phaseColor);
    final generating = isGenerating ? ' · 思考中...' : '';

    Widget trailing;
    switch (modelState.phase) {
      case ModelLifecyclePhase.loading:
        trailing = SizedBox(
          width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2),
        );
        break;
      case ModelLifecyclePhase.loaded:
        if (!isGenerating) {
          trailing = TextButton.icon(
            onPressed: () async {
              await ref.read(modelManagerProvider.notifier).unloadModel();
            },
            icon: const Icon(Icons.close, size: 16),
            label: const Text('卸载', style: TextStyle(fontSize: 12)),
          );
        } else {
          trailing = _buildPulsingDot();
        }
        break;
      case ModelLifecyclePhase.unloading:
        trailing = const SizedBox(
          width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2),
        );
        break;
      case ModelLifecyclePhase.error:
        trailing = TextButton.icon(
          onPressed: modelState.modelId != null
              ? () => ref.read(modelManagerProvider.notifier).loadModel(modelState.modelId!)
              : null,
          icon: const Icon(Icons.refresh, size: 16),
          label: const Text('重试', style: TextStyle(fontSize: 12)),
        );
        break;
      case ModelLifecyclePhase.idle:
        trailing = TextButton.icon(
          onPressed: () {
            Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen()));
          },
          icon: const Icon(Icons.download, size: 16),
          label: const Text('去加载', style: TextStyle(fontSize: 12)),
        );
        break;
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: color.withValues(alpha: 0.12),
      child: Row(
        children: [
          _buildPhaseIcon(modelState.phase, isGenerating),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        modelState.modelName != null && modelState.modelName!.isNotEmpty
                            ? '${modelState.modelName!}$generating'
                            : (modelState.isLoaded ? '模型已就绪$generating' : (isGenerating ? '推理中...' : '模型未加载')),
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                      ),
                      if (modelState.phase == ModelLifecyclePhase.loading && modelState.latestLog != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          modelState.latestLog!,
                          style: TextStyle(fontSize: 11, color: Colors.blue.shade700),
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                      if (modelState.phase == ModelLifecyclePhase.error && modelState.errorMessage != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          modelState.errorMessage!,
                          style: TextStyle(fontSize: 11, color: Colors.red.shade700),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
          trailing,
        ],
      ),
    );
  }

  Widget _buildPhaseIcon(ModelLifecyclePhase phase, bool isGenerating) {
    IconData icon;
    switch (phase) {
      case ModelLifecyclePhase.idle:
        icon = Icons.memory_outlined;
        break;
      case ModelLifecyclePhase.loading:
        icon = Icons.sync_alt;
        break;
      case ModelLifecyclePhase.loaded:
        icon = isGenerating ? Icons.auto_awesome : Icons.check_circle;
        break;
      case ModelLifecyclePhase.unloading:
        icon = Icons.sync_disabled;
        break;
      case ModelLifecyclePhase.error:
        icon = Icons.error_outline;
        break;
    }
    return Icon(icon, size: 18);
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
          itemCount: messages.length,
          itemBuilder: (context, index) {
            final msg = messages[index];
            return ChatBubble(
              role: msg.role.name,
              content: msg.content,
              timestamp: msg.timestamp,
              isStreaming: msg.isStreaming && index == messages.length - 1,
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
                      icon: const Icon(Icons.image),
                      tooltip: '图片',
                      onPressed: isGenerating ? null : () {
                        // TODO: Image picker for vision
                      },
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
