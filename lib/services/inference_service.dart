import 'dart:async';
import 'package:flutter/services.dart';

class InferenceService {
  static const _channel = MethodChannel('com.dgxspark.tongyilite/inference');
  static const _tokenChannel = EventChannel('com.dgxspark.tongyilite/tokens');
  static const _loadingLogChannel = EventChannel('com.dgxspark.tongyilite/loading_logs');

  StreamSubscription<String>? _loadingLogSubscription;

  // Loading log callback — invoked when native pushes a loading progress message.
  void Function(String? message)? onLoadingLog;

  static final InferenceService _instance = InferenceService._();
  factory InferenceService() => _instance;
  InferenceService._() {
    _setupLoadingLogListener();
  }

  /// Set up the EventChannel listener for native loading progress logs.
  void _setupLoadingLogListener() {
    final stream = _loadingLogChannel.receiveBroadcastStream();
    _loadingLogSubscription = stream.map((event) => event.toString()).listen((message) {
      onLoadingLog?.call(message);
    }, onError: (err) {
      // Silently ignore — channel may not be set up yet during early init.
    });
  }

  void dispose() {
    _loadingLogSubscription?.cancel();
  }

  // ------------------------------------------------------------------
  // Initialization
  // ------------------------------------------------------------------
  Future<void> initialize() async {
    await _channel.invokeMethod('init');
  }

  // ------------------------------------------------------------------
  // Model management
  // ------------------------------------------------------------------
  Future<bool> loadModel(String path, {int nCtx = 4096}) async {
    return await _channel.invokeMethod('loadModel', {
      'path': path,
      'nCtx': nCtx,
    });
  }

  Future<void> unloadModel() async {
    await _channel.invokeMethod('unloadModel');
  }

  Future<bool> isLoaded() async {
    return await _channel.invokeMethod('isLoaded');
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
      controller.add(event as String);
    }, onError: (err) {
      controller.addError(err);
    });

    // Start inference on native side
    _channel.invokeMethod('completion', {
      'prompt': prompt,
      'maxTokens': maxTokens,
      'temperature': temperature,
      'topP': topP,
    }).then((result) {
      // Final result (may be empty if streaming used all tokens)
      controller.close();
      subscription.cancel();
    }).catchError((err) {
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
  }) async {
    final result = await _channel.invokeMethod('benchmark', {
      'prompt': prompt,
      'nRepeats': nRepeats,
    });
    return Map<String, double>.from(result);
  }
}