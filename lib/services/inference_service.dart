import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show debugPrint;

class InferenceService {
  static const _channel = MethodChannel('com.dgxspark.tongyilite/inference');
  static const _tokenChannel = EventChannel('com.dgxspark.tongyilite/tokens');
  static const _loadingLogChannel = EventChannel('com.dgxspark.tongyilite/loading_logs');

  StreamSubscription<dynamic>? _loadingLogSubscription;
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
  Future<bool> loadModel(String path, {int nCtx = 4096}) async {
    debugPrint('[InferenceService] Loading model from: $path');
    try {
      final result = await _channel.invokeMethod('loadModel', {
        'path': path,
        'nCtx': nCtx,
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
  Future<Map<String, int>> getMemoryInfo() async {
    return await _channel.invokeMethod('getMemoryInfo');
  }

  // ------------------------------------------------------------------
  // Streaming completion
  // ------------------------------------------------------------------
  Stream<String> completion({
    required String prompt,
    int maxTokens = 2048,
    double temperature = 0.7,
    double topP = 0.9,
  }) {
    final controller = StreamController<String>();

    // Set up the token event listener
    final subscription = _tokenChannel.receiveBroadcastStream().listen((event) {
      if (event != null) {
        controller.add(event.toString());
      }
    }, onError: (err) {
      controller.addError(err);
    });

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
      subscription.cancel();
    }).catchError((err) {
      debugPrint('[InferenceService] Native completion error: $err');
      controller.addError(err);
      controller.close();
      subscription.cancel();
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
    await _channel.invokeMethod('stopGeneration');
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
