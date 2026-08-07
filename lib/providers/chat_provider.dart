import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/chat_message.dart';
import '../models/conversation.dart';

import '../services/inference_service.dart';
import '../services/openai_service.dart';
import '../services/storage_service.dart';
import 'shared_providers.dart'
    show inferenceServiceProvider, openAiServiceProvider;
import 'settings_provider.dart' show settingsProvider;

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

/// Currently selected model ID. Defaults to Qwen3.5-2B (MTP) which is the
/// recommended balance of quality, speed and memory usage for most phones.
final currentModelIdProvider = StateProvider<String>((ref) => 'qwen3.5-2b-mtp-ud-q4_k_xl');

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

  /// 用更新后的元信息替换 state 中的对应会话（标题 / 消息条数变化）。
  void update(Conversation updated) {
    state = state.map((c) => c.id == updated.id ? updated : c).toList();
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

/// 本地原生视觉是否可用。原生层已集成 mtmd（mmproj 投影器 + 图像编码），
/// 故本地路线按「支持视觉」处理：当前消息图片路径传给原生引擎编码后送入。
/// 历史带图消息仍只取文本（原生只支持单张当前图），天然安全。
const bool kLocalVisionSupported = true;

class ChatNotifier extends StateNotifier<bool> {
  final InferenceService _inference;
  final StorageService _storage;
  final Ref _ref;

  /// Which conversation currently occupies the native KV cache. When the user
  /// switches to a different conversation we must reset the cache so the OLD
  /// chat doesn't bleed into the new one (multi-turn append-only caching).
  String? _currentKvConvId;

  /// 上一轮生成是否走了 API 后备（用于 stopGeneration 分支到 openai 取消）。
  bool _lastGenWasApi = false;

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
    final settings = _ref.read(settingsProvider);
    final activeApi = settings.activeApiModel();

    // 尊重用户选择：若用户「不运行本地模型」且「未设置默认模型」，
    // 则必须直接走 API 接入——绝不再自动去加载本地模型（否则 API 永远不会
    // 被触发）。仅当用户有本地意图（已加载某模型，或设置了默认模型）时才
    // 走 local-first：本地可加载则优先本地，本地不可用才回退 API。
    final hasLocalLoaded = _ref.read(modelManagerProvider).isLoaded;
    final hasDefault = settings.defaultModelId != null;

    var ok = true;
    var useApi = false;
    if (activeApi != null && !hasLocalLoaded && !hasDefault) {
      useApi = true; // 无本地意图 → 必须走 API
    } else {
      // Local-first policy: try the local model first; ONLY when it is
      // unavailable (not cached / load failed) and an API model is activated
      // do we fall back to the remote OpenAI-compatible endpoint.
      ok = await ensureModelLoaded(targetModelId);
      if (!ok && activeApi != null) {
        useApi = true; // 本地不可用 → 走 API 后备
      } else if (!ok) {
        return '[模型加载失败，请在设置中重新下载并加载]';
      }
    }
    _lastGenWasApi = useApi;

    debugPrint('[ChatNotifier] sendMessage: convId=$conversationId prompt="$prompt"'
        ' route=${useApi ? "API(${activeApi?.name})" : "local($targetModelId)"}');
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
      // 及时刷新会话元信息：标题（取自首条用户提问）+ 消息条数，让会话列表
      // 不再是一成不变的「新对话 / 0条」。
      await _refreshConversationMeta(conversationId);

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

        // Route the completion source: local engine vs OpenAI-compatible API.
        // Both expose a Stream<String>, so the thinking-filter / persist logic
        // below consumes them uniformly.
        final Stream<String> stream;
        if (useApi) {
          // API 路线：按该 API 的视觉能力构建消息。
          //  - 支持视觉 → 历史/当前带图消息转 content-parts（base64 image_url）；
          //  - 不支持视觉 → 图片剥离为纯文本（`[图片]` 占位），绝不发送原始图。
          final apiVision = activeApi!.visionCapable;
          final apiMessages = await OpenAiService.buildMessages(
            allMessages,
            visionCapable: apiVision,
          );
          if (imagePath != null && !apiVision) {
            debugPrint('[ChatNotifier] 当前图片已剥离（该 API 未开启视觉支持）');
            manager.appendInferenceLog('⚠️ 当前图片已剥离：该 API 模型未开启视觉支持');
          }
          manager.appendInferenceLog(
            '请求(API) | ${activeApi.name} | ${activeApi.model}'
            ' | 历史 ${apiMessages.length} 条'
            ' | maxTokens=${activeApi.effectiveMaxTokens}'
            ' temp=${activeApi.effectiveTemperature}'
            ' ${apiVision ? '带图' : '文本'}',
          );
          stream = _ref.read(openAiServiceProvider).chatCompletion(
            config: activeApi,
            messages: apiMessages,
            temperature: activeApi.effectiveTemperature,
            maxTokens: activeApi.effectiveMaxTokens,
          );
        } else {
          // 本地路线：原生已集成 mtmd 视觉。当前消息图片路径直接传给原生引擎
          // （mmproj 已加载则编码送图；未加载则该模型仅文本，原生自动忽略）。
          // 历史带图消息本就只取文本，天然安全。
          if (imagePath != null) {
            debugPrint('[ChatNotifier] 本地路线携带图片: $imagePath');
            manager.appendInferenceLog('请求 | 携带当前图片');
          }
          stream = _inference.completionWithMessages(
            prompt: prompt,
            messagesJson: messagesJson,
            imagePath: imagePath,
            maxTokens: 1024, // on-device cap: large token budgets make long runs unbearable
            temperature: 0.7,
            topP: 0.9,
          );
        }

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

        // Use the REAL token count + pure generation time from native so the
        // displayed tok/s matches the native logcat line exactly (Dart used to
        // count emitted characters over wall-clock time that also included the
        // prompt prefill, so it always read lower than the native number).
        // API 后备路径没有原生 stats，改用 Dart 计数 + 总墙钟估算。
        int realTokens = tokenCount;
        double genMs = 0.0;
        int visionMs = 0;
        if (!useApi) {
          Map<String, dynamic> genStats = {};
          try {
            genStats = await _inference.getInferenceStats();
          } catch (_) {}
          realTokens = (genStats['n_gen'] as num?)?.toInt() ?? tokenCount;
          genMs = (genStats['t_gen_ms'] as num?)?.toDouble() ?? 0.0;
          visionMs = (genStats['t_vision_ms'] as num?)?.toInt() ?? 0;
        }
        final tokensPerSec =
            genMs > 0 ? realTokens * 1000 / genMs : (totalMs > 0 ? realTokens * 1000 / totalMs : 0.0);

        manager.appendInferenceLog(
          '响应 | $realTokens tokens | 首token ${firstTokenMs}ms | 生成 ${genMs.round()}ms'
          '${visionMs > 0 ? ' | 识图 ${visionMs}ms' : ''} | 总耗时 ${totalMs}ms'
          ' | ${tokensPerSec.toStringAsFixed(1)} tok/s | 输出 ${fullResponse.length} 字',
        );

        // Step 5: Persist final assistant message (clear streaming flag).
        assistantMsg = assistantMsg.copyWith(
          content: fullResponse,
          isStreaming: false,
          inferenceStats: InferenceStats(
            firstTokenMs: firstTokenMs,
            totalMs: totalMs,
            tokPerSec: tokensPerSec,
            visionMs: visionMs,
          ),
        );
        await _storage.saveMessage(assistantMsg);
        // 回复落地后再刷新一次消息条数（流式占位消息已收尾）。
        await _refreshConversationMeta(conversationId);

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
  /// 刷新单个会话的元信息（标题 + 消息条数）并写库：
  /// - 标题：若仍为空/「新对话」，取第一条用户消息（截断到 ~24 字）作标题；
  /// - 消息条数：按数据库当前消息数重算，让列表「x 条」始终准确。
  Future<void> _refreshConversationMeta(String conversationId) async {
    try {
      final convs = _ref.read(conversationsProvider);
      Conversation? conv;
      for (final c in convs) {
        if (c.id == conversationId) {
          conv = c;
          break;
        }
      }
      if (conv == null) return;

      final msgs = await _storage.getAllMessages(conversationId);
      String? newTitle;
      if (conv.title.isEmpty || conv.title == '新对话') {
        for (final m in msgs) {
          if (m.role == MessageRole.user && m.content.isNotEmpty) {
            newTitle = m.content.length <= 24
                ? m.content
                : '${m.content.substring(0, 24)}…';
            break;
          }
        }
      }

      if (newTitle != null || msgs.length != conv.messageCount) {
        await _storage.updateConversation(
          id: conversationId,
          title: newTitle,
          messageCount: msgs.length,
        );
        _ref.read(conversationsProvider.notifier).update(Conversation(
              id: conv.id,
              title: newTitle ?? conv.title,
              modelId: conv.modelId,
              messageCount: msgs.length,
              createdAt: conv.createdAt,
              updatedAt: DateTime.now(),
            ));
      }
    } catch (e) {
      debugPrint('[ChatNotifier] refreshConversationMeta failed: $e');
    }
  }

  /// tells the native engine to set should_stop (or cancels the API SSE
  /// request for the API fallback path), which makes the completion loop
  /// return promptly. The streaming controller then closes, the
  /// `await for` in [sendMessage] ends, and isGenerating flips back to false.
  Future<void> stopGeneration() async {
    if (_lastGenWasApi) {
      _ref.read(openAiServiceProvider).stop();
    } else {
      await _inference.stopGeneration();
    }
  }
}

final chatNotifierProvider = StateNotifierProvider<ChatNotifier, bool>((ref) {
  final inference = ref.read(inferenceServiceProvider);
  final storage = ref.read(storageServiceProvider);
  return ChatNotifier(ref, inference, storage);
});
