import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show Uint8List;
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import '../models/chat_message.dart';
import '../models/conversation.dart';

import '../agent/agent.dart';
import '../agent/web_search/web_search_provider.dart';
import '../agent/context_eng/compaction.dart' show DeterministicCompaction;
import '../agent/loop/agent.dart'
    show ReactLoopAgent, TurnEndReason, TurnEndReasonKind;
import '../agent/loop/config.dart' as loopConfig;
import '../agent/capability.dart';
import '../agent/llm/adapter.dart' show LlmAdapter, ProviderKind;
import '../agent/llm/local_adapter.dart' show LocalEngineAdapter;
import '../agent/llm/openai_adapter.dart' show OpenAiAdapter;
import '../agent/protocol/protocol_selector.dart' show selectProtocol;
import '../agent/protocol/prompt_json_protocol.dart' show PromptJsonProtocol;
import '../agent/protocol/native_tool_protocol.dart' show NativeToolProtocol;
import '../agent/subagents/in_process.dart' show InProcessSubagentProvider;
import '../agent/subagents/subagent_tool.dart' show createSubagentTool;
import '../agent/hooks/hooks.dart' show AgentHooks;
import '../agent/skills/provider.dart' show SkillProvider, loadUserSkills;
import '../agent/skills/skill.dart' show loadBuiltinSkills;
import '../agent/agents_md/agents_md.dart' show loadAgentsMd;
import '../agent/session/store.dart' show JsonlSessionStore;
import '../models/api_model.dart';
import '../services/inference_service.dart';
import '../services/openai_service.dart';
import '../services/settings_service.dart';
import '../services/storage_service.dart';
import 'agent_approval.dart'
    show sandboxApproverProvider, toolPreApproverProvider;
import 'agent_state_provider.dart' show agentUiStateProvider;
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
  final JsonlSessionStore _sessionStore = JsonlSessionStore();

  /// Which conversation currently occupies the native KV cache. When the user
  /// switches to a different conversation we must reset the cache so the OLD
  /// chat doesn't bleed into the new one (multi-turn append-only caching).
  String? _currentKvConvId;

  /// 当前 KV 缓存是否装载的是智能体模式上下文（含系统提示词/工具轮）。
  /// 同一会话内「智能体 ↔ 普通聊天」模式切换时必须 resetContext，
  /// 否则普通聊天会续跑在被大提示词污染的 KV 上（prefill 白白翻倍）。
  bool _currentKvWasAgentMode = false;

  /// 上一轮生成是否走了 API 后备（用于 stopGeneration 分支到 openai 取消）。
  bool _lastGenWasApi = false;

  /// 用户是否主动点过「停止」。用户主动停止时 API 侧会抛
  /// `DioException [request cancelled]`，属正常停止信号而非错误——
  /// 此标记用于区分二者，避免把「用户停止」误报成「发送失败」。
  bool _userCancelled = false;

  /// 新智能体模式的当前主循环（Phase 0+）。非 null 且 running 时，
  /// [stopGeneration] 走 agent.cancel()；turn 结束置 null。
  ReactLoopAgent? _currentAgent;

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
    String? audioPath,
  }) async {
    // 智能体模式：走工具循环（无工具时单轮直答，与普通聊天一致）。
    final settings = _ref.read(settingsProvider);
    if (settings.agentEnabled) {
      return _sendAgentMessage(conversationId, prompt,
          imagePath: imagePath, audioPath: audioPath);
    }

    final targetModelId = _ref.read(currentModelIdProvider);
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
    _userCancelled = false;

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
    } else if (_currentKvWasAgentMode) {
      // 智能体 → 普通聊天（模式切换）：KV 里是系统提示词 + 工具轮，必须重置，
      // 本轮以最小 prefill 重放纯对话历史。
      debugPrint('[ChatNotifier] Agent→plain mode switch: resetContext()');
      await _inference.resetContext();
    }
    _currentKvWasAgentMode = false;

    try {
      // Step 2: Save user message first (so it's available in history for template)
      final userMsg = ChatMessage(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        conversationId: conversationId,
        role: MessageRole.user,
        content: prompt,
        imagePath: imagePath,
        audioPath: audioPath,
      );
      debugPrint('[ChatNotifier] Saving user message...');
      await _storage.saveMessage(userMsg);
      // 及时刷新会话元信息：标题（取自首条用户提问）+ 消息条数，让会话列表
      // 不再是一成不变的「新对话 / 0条」。
      await _refreshConversationMeta(conversationId);

      // Step 3: Build chat history JSON from all messages in this conversation.
      // 排除智能体工具活动消息（🔧 前缀）—— 它们仅用于 UI 展示，不入模型上下文。
      final allMessages = await _storage.getMessages(conversationId, limit: 200);
      final messagesForTemplate = <Map<String, String>>[];
      for (final msg in allMessages) {
        if (msg.content.isNotEmpty && !_isToolActivityMessage(msg)) {
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
          if (audioPath != null) {
            debugPrint('[ChatNotifier] 本地路线携带语音: $audioPath');
            manager.appendInferenceLog('请求 | 携带语音消息 🎤');
          }
          stream = _inference.completionWithMessages(
            prompt: prompt,
            messagesJson: messagesJson,
            imagePath: imagePath,
            audioPath: audioPath,
            maxTokens: 1024, // on-device cap: large token budgets make long runs unbearable
            temperature: 0.7,
            topP: 0.9,
          );
        }

        debugPrint('[ChatNotifier] Listening to token stream...');
        // 过滤「用户主动停止」产生的 DioException：点停止时 API 会抛
        // [request cancelled]，属正常停止信号，静默丢弃而非当成发送失败。
        final tokenStream = _suppressUserCancelled(stream);

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

        await for (final token in tokenStream) {
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
        int audioMs = 0;
        if (!useApi) {
          Map<String, dynamic> genStats = {};
          try {
            genStats = await _inference.getInferenceStats();
          } catch (_) {}
          realTokens = (genStats['n_gen'] as num?)?.toInt() ?? tokenCount;
          genMs = (genStats['t_gen_ms'] as num?)?.toDouble() ?? 0.0;
          visionMs = (genStats['t_vision_ms'] as num?)?.toInt() ?? 0;
          audioMs = (genStats['t_audio_ms'] as num?)?.toInt() ?? 0;
        }
        final tokensPerSec =
            genMs > 0 ? realTokens * 1000 / genMs : (totalMs > 0 ? realTokens * 1000 / totalMs : 0.0);

        manager.appendInferenceLog(
          '响应 | $realTokens tokens | 首token ${firstTokenMs}ms | 生成 ${genMs.round()}ms'
          '${visionMs > 0 ? ' | 视觉 ${visionMs}ms' : ''}'
          '${audioMs > 0 ? ' | 听音 ${audioMs}ms' : ''} | 总耗时 ${totalMs}ms'
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
            audioMs: audioMs,
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

  /// 智能体模式发送消息：路由（本地/API）→ 新主循环 → 最终回答持久化。
  ///
  /// 工具轮的活动消息（🔧）逐工具独立落库，供对话内嵌工作流展示与
  /// 历史回合回看；循环内部的历史（含工具结果回填）不落库，避免污染存储。
  Future<String> _sendAgentMessage(
    String conversationId,
    String prompt, {
    String? imagePath,
    String? audioPath,
  }) async {
    final settings = _ref.read(settingsProvider);
    return _sendAgentMessageNew(
      conversationId,
      prompt,
      imagePath: imagePath,
      audioPath: audioPath,
      settings: settings,
    );
  }

  /// 智能体模式发送（Phase 0+ 重写，唯一实现）：事件源 [ReactLoopAgent] +
  /// [EngineLlmAdapter]（local/API 双路，共用文本协议）。
  ///
  /// 用户可见行为：
  /// - 模型路由（local/api/默认兜底）；
  /// - KV 缓存策略（会话切换 resetContext）；
  /// - 历史从 SQLite 读（排除 🔧 工具活动消息）→ [JsonlSessionStore.importFromMessages]；
  /// - 流式占位 + 工具活动（[_AgentActivitySession]，逐工具落库）；
  /// - 最终回答持久化 + 返回。
  Future<String> _sendAgentMessageNew(
    String conversationId,
    String prompt, {
    String? imagePath,
    String? audioPath,
    required InferenceSettings settings,
  }) async {
    // ---- 模型路由（与旧路径一致）----
    var useApi = false;
    ApiModelConfig? activeApi;
    var targetModelId = _ref.read(currentModelIdProvider);

    if (settings.agentModelSource == 'api') {
      for (final m in settings.apiModels) {
        if (m.id == settings.agentModelId) {
          activeApi = m;
          break;
        }
      }
      if (activeApi == null) {
        return '[智能体配置的 API 模型不存在，请在设置中重新选择]';
      }
      useApi = true;
    } else if (settings.agentModelSource == 'local') {
      targetModelId = settings.agentModelId ?? targetModelId;
      final ok = await ensureModelLoaded(targetModelId);
      if (!ok) {
        return '[模型加载失败，请在设置中重新下载并加载]';
      }
      useApi = false;
    } else {
      final hasLocalLoaded = _ref.read(modelManagerProvider).isLoaded;
      final hasDefault = settings.defaultModelId != null;
      if (settings.activeApiModel() != null && !hasLocalLoaded && !hasDefault) {
        useApi = true;
        activeApi = settings.activeApiModel();
      } else {
        final ok = await ensureModelLoaded(targetModelId);
        if (!ok) {
          final fallback = settings.activeApiModel();
          if (fallback != null) {
            useApi = true;
            activeApi = fallback;
          } else {
            return '[模型加载失败，请在设置中重新下载并加载]';
          }
        }
      }
    }
    _lastGenWasApi = useApi;
    debugPrint('[ChatNotifier] new-agent route='
        '${useApi ? "API(${activeApi?.name})" : "local($targetModelId)"}');

    state = true;
    _ref.read(isGeneratingProvider.notifier).state = true;

    // 会话切换时重置原生 KV 缓存（沿用现有策略）。
    if (_currentKvConvId != conversationId) {
      debugPrint(
          '[ChatNotifier] new-agent conversation changed: resetContext()');
      await _inference.resetContext();
      _currentKvConvId = conversationId;
    } else if (!_currentKvWasAgentMode) {
      // 普通聊天 → 智能体（模式切换）：KV 是纯对话上下文，需重置后
      // 由主循环带系统提示词/工具协议重建。
      debugPrint(
          '[ChatNotifier] plain→agent mode switch: resetContext()');
      await _inference.resetContext();
    }
    _currentKvWasAgentMode = true;

    // ---- 构建组件（复用旧路径共享件）----
    // 智能体模型标识：本地=模型 id；API=API 模型名。工具可见性过滤、
    // 协议选择、系统提示渲染、子代理都按它走——此前 API 路线沿用本地模型
    // id，协议指令/工具清单全被本地模型"张冠李戴"。
    final agentModelKey =
        useApi ? (activeApi?.model ?? targetModelId) : targetModelId;

    final registry = _buildAgentRegistry(settings, agentModelKey);

    // 能力快照（Phase 3）：API 声明原生工具调用 → selectProtocol 选出
    // NativeToolProtocol（tools 进请求体）；本地走 prompt-json 文本协议。
    final caps = _engineCapabilitiesFor(agentModelKey, activeApi);
    final protocol =
        selectProtocol([NativeToolProtocol(), PromptJsonProtocol()], caps);
    final systemPrompt = buildSystemPrompt(
      modelName: useApi ? (activeApi?.name ?? 'API 模型') : targetModelId,
      registry: registry,
      protocol: protocol,
      modelId: agentModelKey,
    );
    final newConfig = loopConfig.AgentConfig(
      maxStepsPerTurn: settings.agentMaxRounds,
      maxTokensPerRound: settings.agentTokensPerRound,
      temperature: settings.agentTemperature,
      toolTimeout: Duration(milliseconds: settings.agentToolTimeoutMs),
      allowParallelTools: settings.agentAllowParallelTools,
      maxParallel: settings.agentMaxParallel,
    );
    // 按路由选 adapter（local/API），各自冻结能力快照。
    final LlmAdapter engine = useApi
        ? OpenAiAdapter(
            protocol: protocol,
            capabilities: caps,
            openAi: _ref.read(openAiServiceProvider),
            apiModel: activeApi,
          )
        : LocalEngineAdapter(
            inference: _inference,
            protocol: protocol,
            capabilities: caps,
          );

    // [NewAgent] 新 seam 活跃标记（验证 Phase 3 代码路径；验证后可删）
    debugPrint(
      '[NewAgent] seam=active route=$useApi '
      'adapter=${useApi ? 'OpenAiAdapter' : 'LocalEngineAdapter'} '
      'protocol=${protocol.id} model=$agentModelKey caps=$caps',
    );

    // ---- 历史 → 事件日志（导入，log-only 标记）----
    final allMessages =
        await _storage.getMessages(conversationId, limit: 200);
    final history = allMessages
        .where((m) => m.content.isNotEmpty && !_isToolActivityMessage(m))
        .toList();
    final sessionLog =
        _sessionStore.importFromMessages(conversationId, history);

    // Phase 6：UI 活动状态订阅本 turn 事件流（工具卡片/压缩/重试/徽章）。
    _ref.read(agentUiStateProvider.notifier).attach(sessionLog);

    // ---- 子代理接缝（Phase 4）：in-process spawn/fork（设置可关）----
    // 复用当前 registry/adapter/模型/系统提示（同模型、同工具集，§10.6）。
    // 子代理审批恒 `never`（自动拒绝沙箱升级，恒 workspace-write）。
    if (settings.agentSubagentEnabled) {
      final subagentProvider = InProcessSubagentProvider(
        adapter: engine,
        registry: registry,
        modelId: agentModelKey,
        providerKind: useApi ? ProviderKind.api : ProviderKind.local,
        systemPrompt: systemPrompt,
        parentSession: sessionLog,
      );
      // 注册 subagent 工具（每 turn 新建 registry → 无同名冲突）。
      registry.register(createSubagentTool(subagentProvider));
    }

    // 保存用户消息（UI 立即可见）。
    final userMsg = ChatMessage(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      conversationId: conversationId,
      role: MessageRole.user,
      content: prompt,
      imagePath: imagePath,
      audioPath: audioPath,
    );
    await _storage.saveMessage(userMsg);
    await _refreshConversationMeta(conversationId);

    // ---- 流式占位 + 活动会话（与旧路径共享 UI 契约）----
    final tokenController = StreamController<String>.broadcast();
    // 思考流（agent 模式单独展示）：adapter 推全量快照，节流后落 UI state。
    final thinkingController = StreamController<String>.broadcast();
    final agentUi = _ref.read(agentUiStateProvider.notifier);
    var lastThinkingPush = DateTime.now();
    final thinkingSub = thinkingController.stream.listen((thinking) {
      if (thinking.isEmpty) return;
      final now = DateTime.now();
      if (now.difference(lastThinkingPush).inMilliseconds < 120) return;
      lastThinkingPush = now;
      agentUi.setThinking(thinking);
    });
    final session = _AgentActivitySession(
      conversationId: conversationId,
      storage: _storage,
    );
    final assistantId =
        (DateTime.now().millisecondsSinceEpoch + 1).toString();
    var assistantMsg = ChatMessage(
      id: assistantId,
      conversationId: conversationId,
      role: MessageRole.assistant,
      content: '',
      isStreaming: true,
    );
    await _storage.saveMessage(assistantMsg);

    // 消费替换式 visible text → 周期持久化（节流）。
    StreamSubscription<String>? sub;
    var _lastSave = DateTime.now();
    sub = tokenController.stream.listen((visible) async {
      if (visible.isEmpty ||
          visible.length == assistantMsg.content.length) {
        return;
      }
      final now = DateTime.now();
      // 与旧路径一致的节流（150ms）；此前误用秒级导致流式文字迟迟不更新。
      if (now.difference(_lastSave).inMilliseconds >= 150) {
        final next = assistantMsg.copyWith(content: visible);
        assistantMsg = next;
        await _storage.saveMessage(next).catchError((_) {});
        _lastSave = now;
      }
    });

    // ---- Phase 5：hooks / skills / AGENTS.md ----
    // AGENTS.md（全局；workspace 暂无路径来源，留空）。
    String? agentsMdText;
    try {
      final agentsMd = await loadAgentsMd();
      agentsMdText = agentsMd.content;
    } on Exception catch (_) {}
    // Skills：内置（rank 100）+ 用户目录 ApplicationSupport/skills（rank 200）。
    final userSkills = await loadUserSkills();
    final skillProvider = userSkills.isEmpty
        ? SkillProvider()
        : SkillProvider(
            skills: [...loadBuiltinSkills(), ...userSkills]);
    // Hooks（默认：模型缓存 guard 已在 guard.dart；pre-step 暂无内置 reject）。
    final hooks = AgentHooks();
    // ---- 主循环 ----
    final agent = ReactLoopAgent(
      session: sessionLog,
      adapter: engine,
      registry: registry,
      config: newConfig,
      modelId: agentModelKey,
      providerKind: useApi ? ProviderKind.api : ProviderKind.local,
      systemPrompt: systemPrompt,
      onToolActivity: session.update,
      sandboxApprover: _ref.read(sandboxApproverProvider),
      // Phase 6：pre-execute `ask` → 审批确认框（ApprovalDialog）。
      preApprover: _ref.read(toolPreApproverProvider),
      hooks: hooks,
      skills: skillProvider,
      agentsMd: agentsMdText,
      // 上下文压缩（确定性裁剪）：设置可关；关 = 超限直接走失败终止。
      compaction: settings.agentCompactEnabled
          ? DeterministicCompaction()
          : null,
      // 超长工具输出溢写：写 ApplicationSupport/agent_spill/，模型侧留摘要。
      spillStore: settings.agentSpillEnabled ? _writeSpillFile : null,
    );
    _currentAgent = agent;
    String answer = '';
    TurnEndReason? reason;
    // 推理日志：本轮路由与请求规模（「推理日志」页可见，配合排障）。
    final logManager = _ref.read(modelManagerProvider.notifier);
    logManager.appendInferenceLog(
      '智能体请求 | ${useApi ? "API(${activeApi?.name})" : "本地($targetModelId)"} '
      '事件数=${sessionLog.eventsCount}',
    );
    try {
      reason = await agent.kick(
        prompt,
        imagePath: imagePath,
        audioPath: audioPath,
        onToken: tokenController,
        onThinking: thinkingController,
      );
      // 只取**本轮**产出的答案；失败时为空——绝不回退历史旧回复冒充本回复。
      answer = agent.lastTurnAnswer;
      debugPrint(
          '[ChatNotifier] new-agent done: reason=${reason.kind.name}, '
          'answer len=${answer.length}');
    } catch (e, s) {
      answer = agent.lastTurnAnswer;
      debugPrint('[ChatNotifier] new-agent error: $e\n$s');
    } finally {
      // 收尾（无论正常/异常/取消）：重置 UI 生成态 + 清 agent 引用 + 收流。
      _currentAgent = null;
      state = false;
      _ref.read(isGeneratingProvider.notifier).state = false;
      // Phase 6：停止订阅本 turn 事件流（状态保留供面板展示本轮末态）。
      _ref.read(agentUiStateProvider.notifier).detach();
      sub?.cancel();
      await thinkingSub.cancel();
      tokenController.close();
      unawaited(thinkingController.close());
    }

    // 最终占位文本 = 本轮最终回答（turn 末位 assistant/message）。
    // 本轮没产出答案（失败/异常）→ 明确报错误文案，绝不拿历史旧回复冒充。
    final turnFailed = reason?.kind != TurnEndReasonKind.completed;
    if (answer.isEmpty && turnFailed) {
      final detail = agent.lastTurnError;
      answer = '⚠️ 本轮执行失败${detail != null ? '：$detail' : ''}'
          '（详见推理日志）';
      logManager.appendInferenceLog('本轮失败 | ${detail ?? '未知错误'}');
    }
    // 达到最大轮数仍在调工具：明确告知"没做完"而不是假装完成。
    if (reason?.kind == TurnEndReasonKind.maxSteps) {
      logManager.appendInferenceLog(
        '达到最大轮数上限（${settings.agentMaxRounds}）仍未产出最终回答，'
        '可在设置中调大「工具循环最大轮数」',
      );
      answer = answer.isEmpty
          ? 'ℹ️ 工具循环达到最大轮数（${settings.agentMaxRounds}），任务未完成。'
              '可在设置中调大「工具循环最大轮数」后重试。'
          : '$answer\n\nℹ️（注意：达到最大轮数上限，任务可能未完成）';
    }
    assistantMsg = assistantMsg.copyWith(content: answer, isStreaming: false);
    await _storage.saveMessage(assistantMsg);
    await _refreshConversationMeta(conversationId);
    return answer;
  }

  /// 构建 agent 工具注册表：全量内置工具 → 联网类按配置移除 → 按模型过滤。
  ///
  /// 核心工具（get_time/calculator/todo/note/unit_converter/memory/文件类）
  /// 引擎能力快照（Phase 3 能力驱动协议选择依据，对应 [PreparedLlmCall.capabilities]）。
  ///
  /// 端侧简化：当前为**静态声明**（模型目录暂不承载 capability 字段）。
  /// - **api**：OpenAI 兼容 → 原生工具调用可用（nativeToolCall）。
  /// - **local**：Spark/Qwen 系给 `toolTemplate: spark-xml`（为 xml-tool 协议
  ///   预留）；其余本地模型全默认（prompt-json 兜底）。
  ///
  /// 后续增强：模型目录加 capability 字段 + 引擎运行时探测
  /// （`EngineCapabilities.resolve(declared:, probed:)`）替换本静态映射，
  /// 协议选择（`selectProtocol`）即自动跟随能力变化，无需改调用方。
  EngineCapabilities _engineCapabilitiesFor(
    String modelId,
    ApiModelConfig? activeApi,
  ) {
    if (activeApi != null) {
      // API 路线：OpenAI 兼容，原生工具调用 + 并行（API 侧能力较松）。
      return const EngineCapabilities(
        nativeToolCall: true,
        maxParallelToolCalls: 5,
      );
    }
    // 本地路线：静态声明。Spark/Qwen 系标 xml 模板；其余默认 prompt-json。
    final lower = modelId.toLowerCase();
    final isXmlFamily = ['spark', 'qwen', 'tongyi'].any(lower.contains);
    return EngineCapabilities(
      toolTemplate: isXmlFamily ? 'spark-xml' : null,
      maxParallelToolCalls: 2,
    );
  }

  /// 溢写存储：超长工具输出落盘 `ApplicationSupport/agent_spill/`，
  /// 返回文件路径（模型侧摘要里带定位，可按需读取）。
  static Future<String> _writeSpillFile(Uint8List bytes) async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/agent_spill');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final file = File('${dir.path}/'
        'spill_${DateTime.now().microsecondsSinceEpoch}_${bytes.length}.bin');
    await file.writeAsBytes(bytes);
    return file.path;
  }

  /// 默认全启用；联网类（web_search/get_weather）由 [settings.webSearchEnabled]
  /// 控制；shell_exec 默认启用（端侧能力向强扩展，不做自我设限）。
  ToolRegistry _buildAgentRegistry(
      InferenceSettings settings, String modelId) {
    final registry = ToolRegistry();
    for (final tool in createBuiltinTools()) {
      registry.register(tool);
    }

    // 联网搜索：把当前 SearXNG provider 注册到接缝（对齐 DSH ctx.web 的可插拔
    // 搜索能力）。web_search 工具只接接缝、不写死搜索源；替换搜索源无需改工具。
    applySearXNGProviderFromSettings(settings);

    // 联网类工具（web_search/get_weather）：配置关闭时不可见。
    if (!settings.webSearchEnabled) {
      registry.unregister('web_search');
      registry.unregister('get_weather');
    }

    // shell 执行：用户设置关闭时不可见（默认开启，能力不设限）。
    if (!settings.agentShellEnabled) {
      registry.unregister('shell_exec');
    }

    // python_exec：用户设置关闭时不可见（默认开启；无 Chaquopy 时工具优雅降级）。
    if (!settings.agentPythonEnabled) {
      registry.unregister('python_exec');
    }

    // 长期记忆：默认关闭（跨会话记忆可能积累偶发错误）；开启后才暴露
    // memory_set/memory_get，模型才能写入/读取持久化记忆。
    if (!settings.agentMemoryEnabled) {
      registry.unregister('memory_set');
      registry.unregister('memory_get');
    }

    // 按模型工具启用（设置层配置；空 = 不限制，全部可见）。
    final modelTools = settings.agentToolsFor(modelId);
    if (modelTools.isNotEmpty) {
      registry.restrictModel(modelId, allow: modelTools.toSet());
    }
    return registry;
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
  /// 是否为智能体工具活动消息（🔧 前缀）。此类消息仅用于 UI 展示，
  /// 不入模型上下文（history 构建时排除）。
  static bool _isToolActivityMessage(ChatMessage msg) =>
      msg.role == MessageRole.assistant && msg.content.startsWith('🔧');

  /// return promptly. The streaming controller then closes, the
  /// `await for` in [sendMessage] ends, and isGenerating flips back to false.
  Future<void> stopGeneration() async {
    // 标记为用户主动停止：API 侧取消会抛 [request cancelled]，
    // 由 [_suppressUserCancelled] 静默丢弃，避免误报「发送失败」。
    _userCancelled = true;
    // 智能体回合：通知主循环取消（adapter.cancel 会中止 native/API 后端）。
    final agent = _currentAgent;
    if (agent != null && agent.isRunning) {
      debugPrint('[ChatNotifier] stopGeneration: cancel agent turn');
      await agent.cancel();
      return;
    }
    // 普通聊天：直接中止 native/API。
    if (_lastGenWasApi) {
      _ref.read(openAiServiceProvider).stop();
    } else {
      await _inference.stopGeneration();
    }
  }

  /// 过滤掉「用户主动停止」产生的 [DioException] 取消异常。
  /// 用户点停止时 API 会抛 `request cancelled`，属正常停止信号；仅在此情况
  /// 下静默丢弃，否则原样重抛由调用方兜底（真实网络/服务端错误仍会上报）。
  Stream<String> _suppressUserCancelled(Stream<String> source) async* {
    try {
      await for (final token in source) {
        yield token;
      }
    } on DioException {
      if (_userCancelled) return;
      rethrow;
    }
  }
}

/// 工具活动会话：新主循环回合内，每次工具调用**独立落一条 🔧 活动消息**。
///
/// 存储约定（与 [_isToolActivityMessage] 匹配，历史回合步骤回看依赖）：
/// - executing：`🔧 正在调用 {name}…`
/// - done/failed：`🔧 {name} ✓/⚠️{summary}`
/// 活动消息 `isStreaming` 恒为 false（静态文本）；实时"执行中"状态由
/// agentUiStateProvider 事件流驱动，存储只负责可回看的步骤记录。
class _AgentActivitySession {
  final String conversationId;
  final StorageService storage;

  var _seq = 0;

  _AgentActivitySession({
    required this.conversationId,
    required this.storage,
  });

  /// 更新活动消息（executing → 新建独立消息；done/failed → 对位更新）。
  Future<void> update(ToolActivity activity) async {
    if (activity.status == 'executing') {
      final n = _seq++;
      final now = DateTime.now().millisecondsSinceEpoch;
      final msg = ChatMessage(
        id: 'agent_tool_${now}_${n}',
        conversationId: conversationId,
        role: MessageRole.assistant,
        content: '🔧 正在调用 ${activity.name}…',
        isStreaming: false,
        timestamp: DateTime.fromMillisecondsSinceEpoch(now + 1000 + n),
      );
      await storage.saveMessage(msg);
      return;
    }
    // done/failed：新主循环固定顺序回调（同一步 tool/call 先全部触发
    // executing，随后按同一顺序触发 done/failed）→ 对位到最早"执行中"
    // 的 🔧 消息。
    final msgs = await storage.getAllMessages(conversationId);
    for (final m in msgs) {
      if (m.role == MessageRole.assistant &&
          m.content.startsWith('🔧 正在调用')) {
        final mark = activity.isFailed ? '⚠️' : '✓';
        final summary = _summarizeToolResult(activity.result);
        await storage.saveMessage(m.copyWith(
          content: '🔧 ${activity.name} $mark$summary',
          isStreaming: false,
        ));
        return;
      }
    }
  }
}

/// 工具结果摘要：多行/长文本压缩为单行，截断到 ~60 字符（UI 展示用）。
String _summarizeToolResult(String? result) {
  if (result == null || result.isEmpty) return '';
  final oneLine = result.replaceAll('\n', ' ').trim();
  return oneLine.length <= 60 ? oneLine : '${oneLine.substring(0, 57)}…';
}

final chatNotifierProvider = StateNotifierProvider<ChatNotifier, bool>((ref) {
  final inference = ref.read(inferenceServiceProvider);
  final storage = ref.read(storageServiceProvider);
  return ChatNotifier(ref, inference, storage);
});
