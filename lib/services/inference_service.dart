import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show debugPrint;

class InferenceService {
  static const _channel = MethodChannel('com.dgxspark.tongyilite/inference');
  static const _tokenChannel = EventChannel('com.dgxspark.tongyilite/tokens');
  static const _loadingLogChannel = EventChannel('com.dgxspark.tongyilite/loading_logs');

  StreamSubscription<dynamic>? _loadingLogSubscription;
  StreamSubscription<dynamic>? _currentTokenSubscription;
  bool _initialized = false;

  // Loading log callback — invoked when native pushes a loading progress message.
  void Function(String? message)? onLoadingLog;

  static final InferenceService _instance = InferenceService._();
  factory InferenceService() => _instance;
  InferenceService._() {
    _setupLoadingLogListener();
  }

  /// Set up the EventChannel listener for native loading progress logs.
  void _setupLoadingLogListener() {
    if (_initialized) return; // already set up (singleton instance)
    _initialized = true;

    final stream = _loadingLogChannel.receiveBroadcastStream();
    _loadingLogSubscription = stream.listen((event) {
      // Handle both String and null events properly
      if (event == null) {
        // Null signals end of loading batch - ignore or handle separately
        debugPrint('[InferenceService] Loading batch complete');
        return;
      }
      final message = event.toString();
      if (message.isNotEmpty && message != 'null') {
        onLoadingLog?.call(message);
      }
    }, onError: (err) {
      debugPrint('[InferenceService] EventChannel error: $err');
      onLoadingLog?.call(null); // Signal error
    });
  }

  void dispose() {
    _loadingLogSubscription?.cancel();
    _initialized = false;
  }

  // ------------------------------------------------------------------
  // Initialization
  // ------------------------------------------------------------------
  Future<void> initialize() async {
    debugPrint('[InferenceService] Initializing native engine...');
    try {
      final result = await _channel.invokeMethod('init');
      debugPrint('[InferenceService] Native engine initialized: $result');
    } catch (e) {
      debugPrint('[InferenceService] Failed to initialize: $e');
      rethrow;
    }
  }

  // ------------------------------------------------------------------
  // Model management
  // ------------------------------------------------------------------
  Future<bool> loadModel(
    String path, {
    int nCtx = 4096,
    bool enableGpu = true,
    int gpuLayers = 20,
    String gpuBackend = 'auto',
    bool enableMtp = false,

    /// 可选的 mmproj 投影器路径（text+mmproj 两文件形态的视觉模型）。
    /// 原生侧（mtmd）加载该投影器后启用图像理解；null 表示单文件 VL 或文本模型。
    String? mmprojPath,

    /// 可选的 dspark 投机解码草稿模型路径（如 Bonsai-27B-dspark-Q4_1.gguf）。
    /// 原生侧加载后启用 DFlash/DSpark 投机加速；null 表示不启用。
    String? draftPath,

    /// prefill 宽度 n_ubatch（0 = 自动：统一 512，split-MoE 按 bank 收敛）。
    /// 小值拆小 dispatch burst，缓解 Adreno GPU fault（小米13 定案）。
    int nUbatch = 0,

    /// Vulkan 禁用 subgroup（GGML_VK_NO_SUBGROUP，turnip GPU 挂死缓解）。
    bool vkNoSubgroup = false,

    /// split-MoE manifest 路径（{modelsRoot}/{modelId}.experts/manifest.json）。
    /// 非空时原生层启用专家 slot 动态加载（超大 MoE 统一架构）。
    String? moeManifest,

    /// split-MoE 每层 prefill 槽位容量（>= n_expert_used）。0 = 不启用。
    int moeBank = 0,

    /// split-MoE 单槽全层驻留字节（manifest Σ bytes_per_expert），oom 预检用。
    int moeSlotBytes = 0,

    /// in-place 整包 split：整包 gguf 内专家区总字节，oom 预检从常驻估算中扣除。
    /// packed-bins 形态传 0（主文件本就不含专家）。
    int moeExpertsBytes = 0,
    int moeResidentBytes = 0,
  }) async {
    debugPrint('[InferenceService] Loading model from: $path '
        '(nCtx=$nCtx, enableGpu=$enableGpu, gpuLayers=$gpuLayers, gpuBackend=$gpuBackend, enableMtp=$enableMtp'
        ', mmproj=$mmprojPath, draft=$draftPath, nUbatch=$nUbatch, vkNoSubgroup=$vkNoSubgroup'
        ', moe=$moeManifest/$moeBank/$moeSlotBytes/$moeExpertsBytes)');
    try {
      final result = await _channel.invokeMethod('loadModel', {
        'path': path,
        'nCtx': nCtx,
        'enableGpu': enableGpu,
        'gpuLayers': gpuLayers,
        'gpuBackend': gpuBackend,
        'enableMtp': enableMtp,
        'mmprojPath': mmprojPath,
        'draftPath': draftPath,
        'nUbatch': nUbatch,
        'vkNoSubgroup': vkNoSubgroup,
        'moeManifest': moeManifest,
        'moeBank': moeBank,
        'moeSlotBytes': moeSlotBytes,
        'moeExpertsBytes': moeExpertsBytes,
        'moeResidentBytes': moeResidentBytes,
      });
      debugPrint('[InferenceService] Model load result: $result');
      return result == true;
    } catch (e) {
      debugPrint('[InferenceService] Failed to load model: $e');
      rethrow;
    }
  }

  Future<void> unloadModel() async {
    debugPrint('[InferenceService] Unloading model...');
    await _channel.invokeMethod('unloadModel');
  }

  /// 推送 OOM 内存守卫设置到原生层（设置→推理引擎→内存守卫）。
  ///
  /// 必须在每次 loadModel 之前调用：原生侧在加载时读取这组值判定
  /// 「预检拒绝 / 加载后 KV 预算」。guard=false 时完全跳过守卫拒绝
  /// （风险：整台机器硬死机重启，仅高级用户排障用）。
  Future<void> setOomGuard({
    required bool enabled,
    int preHeadroomMb = 768,
    int postHeadroomMb = 1536,
  }) async {
    try {
      await _channel.invokeMethod('setOomGuard', {
        'enabled': enabled,
        'preHeadroomMb': preHeadroomMb,
        'postHeadroomMb': postHeadroomMb,
      });
    } catch (e) {
      debugPrint('[InferenceService] setOomGuard failed: $e');
    }
  }

  /// 推送 KV 缓存精度到原生层（设置→推理引擎→KV 精度）。
  ///
  /// 必须在每次 loadModel 之前调用；重载模型后生效。[type] 取 'q4_0' 或 'q8_0'，
  /// 仅量化 K；V 恒为 F16（V 量化要求开启 flash attention，本 app 保持关闭）。
  /// 不兼容的模型架构（MLA 系）原生层会自动回退 F16 KV。
  Future<void> setKvCacheType(String type) async {
    try {
      await _channel.invokeMethod('setKvCacheType', {'type': type});
    } catch (e) {
      debugPrint('[InferenceService] setKvCacheType failed: $e');
    }
  }

  /// [dspark 2026-10-14] P1: flash attention 开关。必须在每次 loadModel 之前
  /// 调用；重载模型后生效。hybrid（recurrent 层）架构原生层会强制关闭。
  Future<void> setFlashAttn(bool enabled) async {
    try {
      await _channel.invokeMethod('setFlashAttn', {'enabled': enabled});
    } catch (e) {
      debugPrint('[InferenceService] setFlashAttn failed: $e');
    }
  }

  Future<bool> isLoaded() async {
    final result = await _channel.invokeMethod('isLoaded');
    return result == true;
  }

  Future<Map<String, dynamic>> getModelInfo() async {
    return await _channel.invokeMethod('getModelInfo');
  }

  // ------------------------------------------------------------------
  // Memory
  // ------------------------------------------------------------------
  /// System + process memory snapshot:
  /// {sysTotalMB, sysAvailMB, sysUsedMB, procRssMB, modelMB}.
  ///
  /// NOTE: the platform channel always hands back `Map<Object?, Object?>`.
  /// Returning it directly as `Map<String, int>` throws a TypeError at runtime
  /// (which silently broke the memory panel), so convert explicitly.
  Future<Map<String, int>> getMemoryInfo() async {
    final r = await _channel.invokeMethod('getMemoryInfo');
    if (r is! Map) return {};
    final out = <String, int>{};
    r.forEach((k, v) {
      if (k == null) return;
      if (v is num) out[k.toString()] = v.toInt();
    });
    return out;
  }

  /// Returns the last generation's real stats from native: {n_gen, t_gen_ms,
  /// t_prompt_ms}. n_gen is the true llama.cpp token count and t_gen_ms is the
  /// pure generation time, so UI tok/s matches the native logcat line exactly.
  Future<Map<String, dynamic>> getInferenceStats() async {
    final r = await _channel.invokeMethod('getInferenceStats');
    if (r == null) return {};
    if (r is Map) return Map<String, dynamic>.from(r);
    try {
      final decoded = jsonDecode(r as String);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {}
    return {};
  }



  /// 获取设备硬件信息（SoC 等），用于按芯片禁用不支持的 GPU 后端。
  Future<Map<String, String>> getDeviceInfo() async {
    try {
      final r = await _channel.invokeMethod('getDeviceInfo');
      if (r is Map) {
        return r.map((k, v) => MapEntry(k.toString(), v?.toString() ?? ''));
      }
    } catch (e) {
      debugPrint('[InferenceService] getDeviceInfo failed: $e');
    }
    return const {
      'board': '', 'hardware': '', 'socManufacturer': '', 'socModel': '',
      'manufacturer': '', 'model': '',
    };
  }

  // ------------------------------------------------------------------
  // Streaming completion (raw prompt, no chat template)
  // ------------------------------------------------------------------
  Stream<String> completion({
    required String prompt,
    int maxTokens = 2048,
    double temperature = 0.7,
    double topP = 0.9,
  }) {
    final controller = StreamController<String>();

    // Set up the token event listener. Cancel any previous subscription so a
    // new generation doesn't deliver tokens to a stale controller (leak/dup).
    _currentTokenSubscription?.cancel();
    final subscription = _tokenChannel.receiveBroadcastStream().listen((event) {
      if (event != null) {
        controller.add(event.toString());
      }
    }, onError: (err) {
      controller.addError(err);
    });
    _currentTokenSubscription = subscription;

    debugPrint('[InferenceService] Invoking native completion, prompt="$prompt"');
    // Start inference on native side
    _channel.invokeMethod('completion', {
      'prompt': prompt,
      'maxTokens': maxTokens,
      'temperature': temperature,
      'topP': topP,
    }).then((result) {
      final resStr = result?.toString() ?? '';
      debugPrint('[InferenceService] Native completion done, len=${resStr.length}, preview="${resStr.substring(0, resStr.length.clamp(0, 50))}"');
      // Final result (may be empty if streaming used all tokens)
      controller.close();
      _currentTokenSubscription?.cancel();
      _currentTokenSubscription = null;
    }).catchError((err) {
      debugPrint('[InferenceService] Native completion error: $err');
      controller.addError(err);
      controller.close();
      _currentTokenSubscription?.cancel();
      _currentTokenSubscription = null;
    });

    return controller.stream;
  }

  // ------------------------------------------------------------------
  // Streaming completion with chat history (applies chatml template)
  // @param messagesJson JSON array of {role, content} for conversation history.
  //   The [prompt] is appended as the final user message before generation.
  // ------------------------------------------------------------------
  Stream<String> completionWithMessages({
    required String prompt,
    required String messagesJson,
    String? imagePath,
    List<String>? imagePaths,
    String? audioPath,
    int maxTokens = 2048,
    double temperature = 0.7,
    double topP = 0.9,
  }) {
    final controller = StreamController<String>();

    _currentTokenSubscription?.cancel();
    final subscription = _tokenChannel.receiveBroadcastStream().listen((event) {
      if (event != null) {
        controller.add(event.toString());
      }
    }, onError: (err) {
      controller.addError(err);
    });
    _currentTokenSubscription = subscription;

    debugPrint('[InferenceService] Invoking completionWithMessages, prompt="$prompt", msgs=$messagesJson, image=$imagePath, images=${imagePaths?.length ?? 0}, audio=$audioPath');
    _channel.invokeMethod('completionWithMessages', {
      'prompt': prompt,
      'messagesJson': messagesJson,
      'imagePath': imagePath,
      // 多图（长图切块/多图上传）：原生视觉按序逐张编码（≤10）。
      if (imagePaths != null && imagePaths.isNotEmpty) 'imagePaths': imagePaths,
      'audioPath': audioPath,
      'maxTokens': maxTokens,
      'temperature': temperature,
      'topP': topP,
    }).then((result) {
      final resStr = result?.toString() ?? '';
      debugPrint('[InferenceService] completionWithMessages done, len=${resStr.length}, preview="${resStr.substring(0, resStr.length.clamp(0, 50))}"');
      controller.close();
      _currentTokenSubscription?.cancel();
      _currentTokenSubscription = null;
    }).catchError((err) {
      debugPrint('[InferenceService] completionWithMessages error: $err');
      controller.addError(err);
      controller.close();
      _currentTokenSubscription?.cancel();
      _currentTokenSubscription = null;
    });

    return controller.stream;
  }

  // ------------------------------------------------------------------
  // Non-streaming completion (for benchmarks, model selection, etc.)
  // ------------------------------------------------------------------
  Future<String> complete({
    required String prompt,
    int maxTokens = 2048,
    double temperature = 0.7,
    double topP = 0.9,
  }) async {
    return await _channel.invokeMethod('completion', {
      'prompt': prompt,
      'maxTokens': maxTokens,
      'temperature': temperature,
      'topP': topP,
    });
  }

  // ------------------------------------------------------------------
  // Stop / benchmark
  // ------------------------------------------------------------------
  Future<void> stopGeneration() async {
    // Cancel the token stream so no further tokens reach a closed controller.
    _currentTokenSubscription?.cancel();
    _currentTokenSubscription = null;
    await _channel.invokeMethod('stopGeneration');
  }

  /// 设置是否允许 Qwen3 思考模式。false = 直接作答（默认）。
  Future<void> setEnableThinking(bool enable) async {
    try {
      await _channel.invokeMethod('setEnableThinking', {'enable': enable});
    } catch (e) {
      debugPrint('[InferenceService] setEnableThinking failed: $e');
    }
  }

  /// 清空 KV 缓存，开始全新对话（多轮追加式缓存下，避免旧对话污染新对话）。
  Future<void> resetContext() async {
    try {
      await _channel.invokeMethod('resetContext');
    } catch (e) {
      debugPrint('[InferenceService] resetContext failed: $e');
    }
  }

  /// 当前模型是否已加载（查询原生引擎 isLoaded，权威状态）。
  /// 本地引擎 adapter 在生成前用它快速失败：模型未加载时直接抛非重试失败，
  /// 避免 native COMPLETION_ERROR 被归一化为可重试的 transport 导致 agent 空转。
  Future<bool> isModelLoaded() async {
    try {
      return await _channel.invokeMethod<bool>('isLoaded') == true;
    } catch (e) {
      debugPrint('[InferenceService] isModelLoaded failed: $e');
      return false;
    }
  }

  // ------------------------------------------------------------------
  // [npu-line M2 Phase C] 混合调度（NPU prefill + GPU decode，hyb_jni.cpp）
  //
  // 两步契约（native 返回结构化 JSON {ok, code, stage, message, ...}，
  // code ∈ HYB_*；见 android/app/src/main/cpp/hyb_kv_bridge.h）：
  //   1. startHybridPrefill     — 拉起 chain_run5/QNN 收 84 片 KV；
  //   2. bridgeAndResumeDecode  — native 桥转（官方 state 容器）→
  //                               llama_state_seq_load_file → 续 decode。
  // Phase C-1：chain helper / state load 未接线 → code=HYB_ERR_NOT_ENABLED。
  // **调用方（lib/agent/llm/hybrid_bridge.dart）在任何非 ok 结果上自动
  // 回退纯 GPU decode 现路径**——本层只转发，不做回退决策。
  // ------------------------------------------------------------------

  static Map<String, dynamic> _asOutcomeMap(dynamic r) {
    if (r is Map) return Map<String, dynamic>.from(r);
    if (r is String) {
      try {
        final d = jsonDecode(r);
        if (d is Map) return Map<String, dynamic>.from(d);
      } catch (_) {}
    }
    return <String, dynamic>{
      'ok': false,
      'code': 'HYB_ERR_BAD_REPLY',
      'stage': 'channel',
      'message': 'unrecognized native reply: $r',
    };
  }

  /// 拉起 NPU 分层链（chain_run5 三段串行）收 84 片 KV。
  ///
  /// [idsPath] i32 LE prompt token 文件（native 由 [messagesJson]/[prompt] 经
  /// GPU 路径同款模板+分词产出并落盘，回包 `ids_path`/`n_real` 为真值——
  /// [nRealCap] 只是链窗上界 NC=512）。[chainDir] null → native 默认
  /// filesDir/npu_m1（NpuAssets 解包目录）；[manifests] null → 冻结三段
  /// manifest_pre2_A/B/C；[nChunks] 每段链步数（冻结 4）。每段超时
  /// [timeoutMs]，进程消失时回包带 p{k}.log 尾巴。失败/异常一律回结构化
  /// outcome，不 throw。
  Future<Map<String, dynamic>> startHybridPrefill({
    required String kvDir,
    required String idsPath,
    String? chainDir,
    String? chainBin,
    String? qnnLibDir,
    List<String>? manifests,
    int nChunks = 4,
    String? prompt,
    String messagesJson = '[]',
    int nRealCap = 512,
    int timeoutMs = 120000,
  }) async {
    debugPrint(
        '[InferenceService] startHybridPrefill kvDir=$kvDir ids=$idsPath chain=$chainDir manifests=${manifests?.join(",")} nChunks=$nChunks cap=$nRealCap msgs=${messagesJson.length}');
    try {
      final r = await _channel.invokeMethod('startHybridPrefill', {
        'kvDir': kvDir,
        'idsPath': idsPath,
        'chainDir': chainDir,
        'chainBin': chainBin,
        'qnnLibDir': qnnLibDir,
        'manifests': manifests,
        'nChunks': nChunks,
        'prompt': prompt,
        'messagesJson': messagesJson,
        'nRealCap': nRealCap,
        'timeoutMs': timeoutMs,
      });
      return _asOutcomeMap(r);
    } catch (e) {
      debugPrint('[InferenceService] startHybridPrefill failed: $e');
      return <String, dynamic>{
        'ok': false,
        'code': 'HYB_ERR_EXCEPTION',
        'stage': 'channel',
        'message': '$e',
      };
    }
  }

  /// [npu-line M2 Phase C-2] NPU 链资产解包（assets/npu_libs → filesDir/npu_m1，
  /// NpuAssets.kt）。幂等；[force] 全量重写。返回 {相对路径 -> copied/skipped}；
  /// 通道异常回 null（调用方按「资产未就绪」处理）。
  Future<Map<String, dynamic>?> extractNpuAssets({bool force = false}) async {
    try {
      final r = await _channel.invokeMethod('extractNpuAssets', {
        'force': force,
      });
      if (r is Map) return Map<String, dynamic>.from(r);
      return null;
    } catch (e) {
      debugPrint('[InferenceService] extractNpuAssets failed: $e');
      return null;
    }
  }

  /// native 桥转 + state load + 从 [firstTok] 续 decode。
  /// [posBase] 冻结 A5/172 协议默认 88；state 容器输出到 [outPath]。
  Future<Map<String, dynamic>> bridgeAndResumeDecode({
    required String kvDir,
    required String idsPath,
    required String outPath,
    required int nReal,
    required int firstTok,
    int posBase = 88,
    int maxTokens = 512,
    double temperature = 0.7,
    double topP = 0.9,
  }) async {
    debugPrint(
        '[InferenceService] bridgeAndResumeDecode kvDir=$kvDir ids=$idsPath out=$outPath nReal=$nReal posBase=$posBase firstTok=$firstTok');
    try {
      final r = await _channel.invokeMethod('bridgeAndResumeDecode', {
        'kvDir': kvDir,
        'idsPath': idsPath,
        'outPath': outPath,
        'nReal': nReal,
        'posBase': posBase,
        'firstTok': firstTok,
        'maxTokens': maxTokens,
        'temperature': temperature,
        'topP': topP,
      });
      return _asOutcomeMap(r);
    } catch (e) {
      debugPrint('[InferenceService] bridgeAndResumeDecode failed: $e');
      return <String, dynamic>{
        'ok': false,
        'code': 'HYB_ERR_EXCEPTION',
        'stage': 'channel',
        'message': '$e',
      };
    }
  }

  // ------------------------------------------------------------------
  // 语音输入（端侧拾音 + 原生语音理解）
  // ------------------------------------------------------------------

  /// 当前已加载模型是否支持语音（音频）理解。false 时麦克风按钮应禁用。
  Future<bool> supportsAudio() async {
    try {
      return await _channel.invokeMethod('supportsAudio') == true;
    } catch (e) {
      debugPrint('[InferenceService] supportsAudio failed: $e');
      return false;
    }
  }

  /// 开始麦克风拾音（按住说话）。返回 true 表示已开始；原生侧按模型要求的
  /// 采样率录制 16-bit PCM 单声道。
  Future<bool> startRecording() async {
    try {
      return await _channel.invokeMethod('startRecording') == true;
    } catch (e) {
      debugPrint('[InferenceService] startRecording failed: $e');
      return false;
    }
  }

  /// 停止拾音并落盘 WAV 文件。返回 WAV 路径；过短/失败时返回 null。
  Future<String?> stopRecording() async {
    try {
      final path = await _channel.invokeMethod('stopRecording');
      return path as String?;
    } catch (e) {
      debugPrint('[InferenceService] stopRecording failed: $e');
      return null;
    }
  }

  Future<Map<String, double>> benchmark({
    String prompt = 'List 5 common fruits.',
    int nRepeats = 3,
  }) {
    final result = _channel.invokeMethod('benchmark', {
      'prompt': prompt,
      'nRepeats': nRepeats,
    });
    return result.then((data) => Map<String, double>.from(data));
  }

  // ------------------------------------------------------------------
  // Dispose (called when app shuts down)
  // ------------------------------------------------------------------
}
