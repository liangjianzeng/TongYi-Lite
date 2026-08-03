import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/chat_message.dart';
import '../models/conversation.dart';

import '../services/inference_service.dart';
import '../services/storage_service.dart';
import 'shared_providers.dart' show inferenceServiceProvider;

// Re-export for other files that need these types.
export 'model_provider.dart' show ModelManagerNotifier, ModelState, ModelLifecyclePhase;

// Import model_managerProvider so ChatNotifier can reference it without circular imports.
import 'model_provider.dart';

// ---------------------------------------------------------------------------
// Services (singletons)
// ---------------------------------------------------------------------------

final storageServiceProvider = Provider<StorageService>((ref) => StorageService());

// ---------------------------------------------------------------------------
// Model selection — the currently active model ID
// ---------------------------------------------------------------------------

/// Currently selected model ID. Defaults to Qwen2.5-1.5B which is the
/// recommended balance of quality and memory usage for most phones.
final currentModelIdProvider = StateProvider<String>((ref) => 'qwen3-1.7b-q4_k_m');

// ---------------------------------------------------------------------------
// Conversations
// ---------------------------------------------------------------------------

final conversationsProvider =
    StateNotifierProvider<ConversationsNotifier, List<Conversation>>((ref) {
  return ConversationsNotifier(ref.read(storageServiceProvider));
});

class ConversationsNotifier extends StateNotifier<List<Conversation>> {
  final StorageService _storage;
  ConversationsNotifier(this._storage) : super([]) {
    _load();
  }

  Future<void> _load() async {
    state = await _storage.getAllConversations();
  }

  Future<void> create({String title = '新对话'}) async {
    final conv = await _storage.createConversation(title: title);
    state = [conv, ...state];
  }

  Future<void> delete(String id) async {
    await _storage.deleteConversation(id);
    state = state.where((c) => c.id != id).toList();
  }
}

final currentConversationProvider = StateProvider<Conversation?>((ref) => null);

final messagesProvider = StreamProvider.autoDispose.family<List<ChatMessage>,
    String>((ref, convId) async* {
  final storage = ref.read(storageServiceProvider);
  // Yield the current messages immediately.
  yield await storage.getAllMessages(convId);

  // Then poll for changes every 500ms to pick up new messages.
  while (true) {
    await Future.delayed(const Duration(milliseconds: 500));
    yield await storage.getAllMessages(convId);
  }
});

// ---------------------------------------------------------------------------
// Generation state
// ---------------------------------------------------------------------------

final isGeneratingProvider = StateProvider<bool>((ref) => false);

// ---------------------------------------------------------------------------
// Chat logic — model loading + streaming completion
// ---------------------------------------------------------------------------

class ChatNotifier extends StateNotifier<bool> {
  final InferenceService _inference;
  final StorageService _storage;
  final Ref _ref;

  ChatNotifier(this._ref, this._inference, this._storage) : super(false);

  /// Ensure the correct model is loaded before sending a message.
  /// Uses [modelManagerProvider] so that loading state is visible in UI.
  Future<bool> ensureModelLoaded(String modelId) async {
    debugPrint('[ChatNotifier] ensureModelLoaded called, modelId=$modelId');
    // Delegate to ModelManagerNotifier — it handles unload-previous + state.
    final manager = _ref.read(modelManagerProvider.notifier);

    if (manager.state.isLoaded && manager.currentModelId == modelId) {
      debugPrint('[ChatNotifier] Model $modelId already loaded, skipping reload');
      return true;
    }

    debugPrint('[ChatNotifier] Reloading model: $modelId (isLoaded=${manager.state.isLoaded}, currentId=${manager.modelId})');
    // If a different model is loaded, we still go through loadModel which
    // handles the unload-then-load flow.
    return await manager.loadModel(modelId);
  }

  /// Send a message to the currently loaded model.
  /// Automatically ensures the correct model is loaded first via ModelManager.
  Future<String> sendMessage(
    String conversationId,
    String prompt, {
    String? imagePath,
  }) async {
    final targetModelId = _ref.read(currentModelIdProvider);

    // Step 1: Ensure model is loaded (via ModelManager for state consistency)
    final ok = await ensureModelLoaded(targetModelId);
    if (!ok) {
      return '[模型加载失败，请在设置中重新下载并加载]';
    }

    debugPrint('[ChatNotifier] sendMessage: convId=$conversationId prompt="$prompt"');
    state = true;
    _ref.read(isGeneratingProvider.notifier).state = true;

    try {
      // Step 2: Save user message first (so it's available in history for template)
      final userMsg = ChatMessage(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        conversationId: conversationId,
        role: MessageRole.user,
        content: prompt,
        imagePath: imagePath,
      );
      debugPrint('[ChatNotifier] Saving user message...');
      await _storage.saveMessage(userMsg);

      // Step 3: Build chat history JSON from all messages in this conversation
      final allMessages = await _storage.getMessages(conversationId, limit: 200);
      final messagesForTemplate = <Map<String, String>>[];
      for (final msg in allMessages) {
        if (msg.content.isNotEmpty) {
          messagesForTemplate.add({'role': msg.role.name, 'content': msg.content});
        }
      }
      final messagesJson = jsonEncode(messagesForTemplate);
      debugPrint('[ChatNotifier] Chat history: ${messagesForTemplate.length} msgs, jsonLen=${messagesJson.length}');

      // Step 4: Stream completion from native inference engine (with chatml template)
      String fullResponse = '';
      try {
        debugPrint('[ChatNotifier] Calling completionWithMessages...');
        final stream = _inference.completionWithMessages(
          prompt: prompt,
          messagesJson: messagesJson,
          maxTokens: 2048,
          temperature: 0.7,
          topP: 0.9,
        );

        debugPrint('[ChatNotifier] Listening to token stream...');
        final buffer = StringBuffer();
        bool inThinking = false;
        await for (final token in stream) {
          if (!buffer.isEmpty || token.isNotEmpty) {
            buffer.write(token);
          }

          // Track <thinking> tags — skip everything until </think> is seen.
          final text = buffer.toString();
          if (!inThinking && text.contains('<think>')) {
            inThinking = true;
          } else if (inThinking && text.contains('</think>')) {
            inThinking = false;
          }
        }

        // If the stream ended while still inside thinking tags, truncate at </think>.
        String rawResponse = buffer.toString();
        final endTagIndex = rawResponse.indexOf('</think>');
        if (inThinking && endTagIndex >= 0) {
          rawResponse = rawResponse.substring(endTagIndex + '</think>'.length);
        } else if (!inThinking) {
          // Stream finished normally — strip any thinking tags that fully appeared.
          rawResponse = rawResponse.replaceAll(RegExp(r'<think>.*?</think>', dotAll: true), '');
        }

        fullResponse = rawResponse.trim();
        final preview = fullResponse.substring(0, fullResponse.length.clamp(0, 50));
        debugPrint('[ChatNotifier] Stream done, len=${fullResponse.length}, response="$preview${fullResponse.length > 50 ? "..." : ""}"');

        // Step 5: Save assistant message
        final assistantMsg = ChatMessage(
          id: (DateTime.now().millisecondsSinceEpoch + 1).toString(),
          conversationId: conversationId,
          role: MessageRole.assistant,
          content: fullResponse,
        );
        await _storage.saveMessage(assistantMsg);

        return fullResponse;
      } catch (e) {
        debugPrint('[ChatNotifier] Stream error: $e');
        // Save error message to conversation
        final errMsg = ChatMessage(
          id: (DateTime.now().millisecondsSinceEpoch + 1).toString(),
          conversationId: conversationId,
          role: MessageRole.assistant,
          content: '[Error: $e]',
        );
        await _storage.saveMessage(errMsg);
        return fullResponse;
      }
    } finally {
      debugPrint('[ChatNotifier] sendMessage done, isGenerating=false');
      state = false;
      _ref.read(isGeneratingProvider.notifier).state = false;
    }
  }
}

final chatNotifierProvider = StateNotifierProvider<ChatNotifier, bool>((ref) {
  final inference = ref.read(inferenceServiceProvider);
  final storage = ref.read(storageServiceProvider);
  return ChatNotifier(ref, inference, storage);
});
