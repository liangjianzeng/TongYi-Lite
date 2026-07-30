import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:async';
import '../models/chat_message.dart';
import '../models/conversation.dart';
import '../services/inference_service.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../services/model_manager.dart';
import '../services/storage_service.dart';

final inferenceServiceProvider = Provider((ref) => InferenceService());
final storageServiceProvider = Provider((ref) => StorageService());

/// Currently selected model ID - change from SettingsScreen to switch models.
final currentModelIdProvider = StateProvider<String>((ref) => 'qwen3-1.7b-q4_k_m');

final conversationsProvider = StateNotifierProvider<ConversationsNotifier, List<Conversation>>((ref) {
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
final messagesProvider = FutureProvider.autoDispose.family<List<ChatMessage>, String>((ref, convId) async {
  final storage = ref.read(storageServiceProvider);
  return storage.getAllMessages(convId);
});

final isGeneratingProvider = StateProvider<bool>((ref) => false);
final streamTokensProvider = StateProvider<List<String>>((ref) => []);

class ChatNotifier extends ConsumerStateNotifier<bool> {
  final InferenceService _inference;
  final StorageService _storage;

  /// Ensure the correct model is loaded before sending a message.
  Future<void> ensureModelLoaded(String modelId) async {
    final isLoaded = await _inference.isLoaded();
    if (!isLoaded) {
      await loadModelFromFile(modelId);
    }
  }

  /// Load a model from the cached .gguf file on disk.
  Future<void> loadModelFromFile(String modelId) async {
    final appDir = await getApplicationDocumentsDirectory();
    final path = '${appDir.path}/models/${modelId}.gguf';
    debugPrint('[ChatNotifier] Loading model from: $path');
    await _inference.loadModel(path);
  }
  ChatNotifier(this._inference, this._storage) : super(false);

  Future<String> sendMessage(String conversationId, String prompt) async {
    // Ensure model is loaded before sending message
    final modelId = ref.read(currentModelIdProvider);
    await ensureModelLoaded(modelId);
    state = true;
    final userMsg = ChatMessage(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      conversationId: conversationId,
      role: MessageRole.user,
      content: prompt,
    );
    await _storage.saveMessage(userMsg);

    try {
      final stream = _inference.completion(prompt: prompt, maxTokens: 2048);
      final buffer = StringBuffer();

      await for (final token in stream) {
        buffer.write(token);
        // Update streaming state
      }

      final fullResponse = buffer.toString();
      final assistantMsg = ChatMessage(
        id: (DateTime.now().millisecondsSinceEpoch + 1).toString(),
        conversationId: conversationId,
        role: MessageRole.assistant,
        content: fullResponse,
      );
      await _storage.saveMessage(assistantMsg);
      return fullResponse;
    } catch (e) {
      return '[Error: $e]';
    } finally {
      state = false;
    }
  }
}

final chatNotifierProvider = StateNotifierProvider<ChatNotifier, bool>((ref) {
  final inference = ref.read(inferenceServiceProvider);
  final storage = ref.read(storageServiceProvider);
  return ChatNotifier(inference, storage);
});