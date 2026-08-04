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
  Completer<void>? _loadCompleter;
  ConversationsNotifier(this._storage) : super([]) {
    _ensureLoaded();
  }

  /// Load conversations from storage exactly once. Multiple callers can await
  /// the same future without triggering duplicate queries.
  Future<void> _ensureLoaded() {
    if (_loadCompleter == null) {
      _loadCompleter = Completer<void>();
      _storage.getAllConversations().then((list) {
        state = list;
        _loadCompleter!.complete();
      }).catchError((e) {
        _loadCompleter!.completeError(e);
      });
    }
    return _loadCompleter!.future;
  }

  Future<void> ensureLoaded() => _ensureLoaded();

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

  /// Which conversation currently occupies the native KV cache. When the user
  /// switches to a different conversation we must reset the cache so the OLD
  /// chat doesn't bleed into the new one (multi-turn append-only caching).
  String? _currentKvConvId;

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

    // If this is a DIFFERENT conversation than what's in the native KV cache,
    // reset the cache first so the previous chat does not bleed in. (The KV
    // cache uses append-only multi-turn caching; a fresh conversation must start
    // from a clean cache.)
    if (_currentKvConvId != conversationId) {
      debugPrint('[ChatNotifier] Conversation changed ($_currentKvConvId -> $conversationId): resetContext()');
      await _inference.resetContext();
      _currentKvConvId = conversationId;
    }

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

      // Create the assistant message up-front (empty + streaming) so the bubble
      // appears immediately and grows as tokens arrive — this lets the chat view
      // follow the stream in real time instead of waiting for the full reply.
      final assistantId = (DateTime.now().millisecondsSinceEpoch + 1).toString();
      var assistantMsg = ChatMessage(
        id: assistantId,
        conversationId: conversationId,
        role: MessageRole.assistant,
        content: '',
        isStreaming: true,
      );
      await _storage.saveMessage(assistantMsg);

      final manager = _ref.read(modelManagerProvider.notifier);
      try {
        debugPrint('[ChatNotifier] Calling completionWithMessages...');
        manager.appendInferenceLog(
          '请求 | 提示 ${prompt.length} 字 | 历史 ${messagesForTemplate.length} 条'
          ' | maxTokens=2048 temp=0.7 topP=0.9${imagePath != null ? ' [带图]' : ''}',
        );

        final startTime = DateTime.now();
        var tokenCount = 0;
        DateTime? firstTokenTime;

        final stream = _inference.completionWithMessages(
          prompt: prompt,
          messagesJson: messagesJson,
          maxTokens: 1024, // on-device cap: CPU ~0.6 tok/s, 2048 would take too long
          temperature: 0.7,
          topP: 0.9,
        );

        debugPrint('[ChatNotifier] Listening to token stream...');
        
        // --- Streaming thinking-tag filter (stateful, token-by-token) ---
        // `visible` holds the response shown to the user. Anything inside
        // <think>...</think> is routed to `thinking` and dropped from output.
        // Tag handling runs as tokens arrive, so we never surface raw
        // reasoning, and a stream that ends inside an unclosed <thinking> block
        // simply discards that incomplete block.
        final visible = StringBuffer();
        final thinking = StringBuffer();
        var inThinking = false;

        // Drop a dangling partial thinking-tag fragment at the very end of the
        // output (e.g. the stream ended mid-token with "<thi" or "</think").
        String stripDanglingTag(String s) {
          final lastLt = s.lastIndexOf('<');
          if (lastLt < 0) return s;
          final tail = s.substring(lastLt);
          final partialOpen = '<think>'.startsWith(tail) && tail != '<think>';
          final partialClose = '</think>'.startsWith(tail) && tail != '</think>';
          if (partialOpen || partialClose) return s.substring(0, lastLt);
          return s;
        }

        var lastStreamSave = DateTime.now();

        await for (final token in stream) {
          if (token.isEmpty) continue;

          tokenCount++;
          firstTokenTime ??= DateTime.now();

          if (inThinking) {
            thinking.write(token);
            final closeIdx = thinking.toString().indexOf('</think>');
            if (closeIdx >= 0) {
              // Everything after the closing tag becomes visible output.
              final after =
                  thinking.toString().substring(closeIdx + '</think>'.length);
              thinking.clear();
              visible.write(after);
              inThinking = false;
            }
            // else: still inside thinking — the token is already discarded.
          } else {
            visible.write(token);
            final openIdx = visible.toString().indexOf('<think>');
            if (openIdx >= 0) {
              // Keep pre-tag text in `visible`; move the tag + the rest into
              // `thinking` so subsequent tokens are discarded.
              final before = visible.toString().substring(0, openIdx);
              final rest = visible.toString().substring(openIdx);
              visible.clear();
              visible.write(before);
              thinking.write(rest);
              inThinking = true;
            }
          }

          // Periodically persist the visible (thinking-filtered) content so the
          // bubble updates live and the UI can scroll to follow the stream.
          final now = DateTime.now();
          if (now.difference(lastStreamSave).inMilliseconds >= 150) {
            lastStreamSave = now;
            assistantMsg = assistantMsg.copyWith(content: visible.toString());
            await _storage.saveMessage(assistantMsg);
          }
        }

        // Final pass after the stream ends.
        final String rawResponse;
        if (inThinking) {
          // Stream ended inside an unclosed <thinking> block — drop it entirely.
          // Text emitted before the tag (already in `visible`) is kept.
          rawResponse = visible.toString();
        } else {
          // Safety net: strip any complete thinking blocks that slipped through
          // (malformed/overlapping tags), then remove a dangling tag fragment.
          rawResponse = stripDanglingTag(visible
              .toString()
              .replaceAll(RegExp(r'<think>.*?</think>', dotAll: true), ''));
        }

        fullResponse = rawResponse.trim();
        final preview = fullResponse.substring(0, fullResponse.length.clamp(0, 50));
        debugPrint('[ChatNotifier] Stream done, len=${fullResponse.length}, response="$preview${fullResponse.length > 50 ? "..." : ""}"');

        final totalMs = DateTime.now().difference(startTime).inMilliseconds;
        final firstTokenMs = firstTokenTime != null
            ? firstTokenTime.difference(startTime).inMilliseconds
            : 0;
        final tokensPerSec = totalMs > 0 ? tokenCount * 1000 / totalMs : 0.0;
        manager.appendInferenceLog(
          '响应 | $tokenCount tokens | 首token ${firstTokenMs}ms | 总耗时 ${totalMs}ms'
          ' | ${tokensPerSec.toStringAsFixed(1)} tok/s | 输出 ${fullResponse.length} 字',
        );

        // Step 5: Persist final assistant message (clear streaming flag).
        assistantMsg = assistantMsg.copyWith(content: fullResponse, isStreaming: false);
        await _storage.saveMessage(assistantMsg);

        return fullResponse;
      } catch (e) {
        debugPrint('[ChatNotifier] Stream error: $e');
        manager.appendInferenceLog('响应异常 | error=$e');
        // Update the same streaming message with the error content.
        assistantMsg = assistantMsg.copyWith(content: '[Error: $e]', isStreaming: false);
        await _storage.saveMessage(assistantMsg);
        return fullResponse;
      }
    } finally {
      debugPrint('[ChatNotifier] sendMessage done, isGenerating=false');
      state = false;
      _ref.read(isGeneratingProvider.notifier).state = false;
    }
  }

  /// Stop the current generation: cancels the token stream subscription and
  /// tells the native engine to set should_stop, which makes the completion
  /// loop return promptly. The streaming controller then closes, the
  /// `await for` in [sendMessage] ends, and isGenerating flips back to false.
  Future<void> stopGeneration() async {
    await _inference.stopGeneration();
  }
}

final chatNotifierProvider = StateNotifierProvider<ChatNotifier, bool>((ref) {
  final inference = ref.read(inferenceServiceProvider);
  final storage = ref.read(storageServiceProvider);
  return ChatNotifier(ref, inference, storage);
});
