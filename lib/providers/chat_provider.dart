import 'dart:async';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/chat_message.dart';
import '../models/conversation.dart';
import 'package:path_provider/path_provider.dart';

import '../services/inference_service.dart';
import '../services/storage_service.dart';
import 'shared_providers.dart' show inferenceServiceProvider;

// Re-export for other files that need these types
export 'model_provider.dart' show ModelManagerNotifier, ModelLifecycleState;

// ---------------------------------------------------------------------------
// Services (singletons)
// ---------------------------------------------------------------------------

final storageServiceProvider = Provider<StorageService>((ref) => StorageService());

// ---------------------------------------------------------------------------
// Model selection — the currently active model ID
// ---------------------------------------------------------------------------

/// Currently selected model ID. Defaults to Qwen2.5-1.5B which is the
/// recommended balance of quality and memory usage for most phones.
final currentModelIdProvider = StateProvider<String>((ref) => 'qwen2.5-1.5b-q4_k_m');

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

final messagesProvider = FutureProvider.autoDispose.family<List<ChatMessage>,
    String>((ref, convId) async {
  final storage = ref.read(storageServiceProvider);
  return storage.getAllMessages(convId);
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
  Future<bool> ensureModelLoaded(String modelId) async {
    final isLoaded = await _inference.isLoaded();
    if (!isLoaded) {
      return await loadModelFromFile(modelId);
    }
    debugPrint('[ChatNotifier] Model already loaded, target: $modelId');
    return true;
  }

  /// Load a model from the cached .gguf file on disk.
  Future<bool> loadModelFromFile(String modelId) async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final path = '${appDir.path}/models/${modelId}.gguf';
      debugPrint('[ChatNotifier] Loading model from: $path');
      return await _inference.loadModel(path);
    } catch (e) {
      debugPrint('[ChatNotifier] loadModelFromFile failed: $e');
      return false;
    }
  }

  /// Send a message to the currently loaded model.
  /// Automatically ensures the correct model is loaded first.
  Future<String> sendMessage(
    String conversationId,
    String prompt,
  ) async {
    final targetModelId = _ref.read(currentModelIdProvider);

    // Step 1: Ensure model is loaded
    final ok = await ensureModelLoaded(targetModelId);
    if (!ok) {
      return '[模型加载失败，请在设置中重新下载并加载]';
    }

    state = true;

    try {
      // Step 2: Save user message
      final userMsg = ChatMessage(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        conversationId: conversationId,
        role: MessageRole.user,
        content: prompt,
      );
      await _storage.saveMessage(userMsg);

      // Step 3: Stream completion from native inference engine
      String fullResponse = '';
      try {
        final stream = _inference.completion(
          prompt: prompt,
          maxTokens: 2048,
          temperature: 0.7,
          topP: 0.9,
        );

        final buffer = StringBuffer();
        await for (final token in stream) {
          if (!buffer.isEmpty || token.isNotEmpty) {
            buffer.write(token);
          }
        }
        fullResponse = buffer.toString();

        // Step 4: Save assistant message
        final assistantMsg = ChatMessage(
          id: (DateTime.now().millisecondsSinceEpoch + 1).toString(),
          conversationId: conversationId,
          role: MessageRole.assistant,
          content: fullResponse,
        );
        await _storage.saveMessage(assistantMsg);

        return fullResponse;
      } catch (e) {
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
      state = false;
    }
  }
}

final chatNotifierProvider = StateNotifierProvider<ChatNotifier, bool>((ref) {
  final inference = ref.read(inferenceServiceProvider);
  final storage = ref.read(storageServiceProvider);
  return ChatNotifier(ref, inference, storage);
});
