/// 本地引擎 adapter —— 包裹 [InferenceService]（llama.cpp）。
///
/// 路由：仅 local。工具调用走文本协议（由 [ToolProtocol] 注入 +
/// [AgentStreamProcessor] 从 response 文本解析）。
///
/// 取消（DSH Part 14.6）：`generate` 接受 cancel，与流完成竞跑；
/// cancel 先行则抛 [AgentCancelledException]。`cancel()` 另作安全网。
library;

import 'dart:async';
import 'dart:convert';

import '../../providers/agent_stream_processor.dart';
import '../../services/inference_service.dart';
import 'adapter.dart';
import 'base_engine_adapter.dart';
import '../capability.dart';
import '../protocol/tool_protocol.dart';

class LocalEngineAdapter extends BaseEngineAdapter {
  final InferenceService _inference;

  /// 思考失控守卫阈值（设置可调；默认 [kMaxThinkingChars]）。
  final int _maxThinkingChars;

  LocalEngineAdapter({
    required InferenceService inference,
    required ToolProtocol protocol,
    EngineCapabilities? capabilities,
    int maxThinkingChars = kMaxThinkingChars,
  })  : _inference = inference,
        _maxThinkingChars = maxThinkingChars,
        super(protocol: protocol, capabilities: capabilities);

  /// 取消：先中止 Dart 侧流（基类），再通知 native 引擎停生成。
  @override
  void cancel() {
    super.cancel();
    _inference.stopGeneration();
  }

  @override
  Future<LlmResult> generate(
    GenerateOptions options, {
    StreamController<String>? onToken,
    StreamController<String>? onThinking,
    Completer<void>? cancel,
  }) async {
    // 本地引擎：生成前确认模型已加载（查询原生 isLoaded，权威状态）。
    // 未加载 → 立即抛非重试失败（modelNotReady），避免 native 把
    // COMPLETION_ERROR 归一化成可重试的 transport 导致 agent 空转重试。
    final ready = await _inference.isModelLoaded();
    if (!ready) {
      throw LlmFailure(
        code: LlmFailureCode.modelNotReady,
        message: '本地模型未加载（模型加载失败），请在模型管理页重新加载模型',
      );
    }

    final messagesJson = jsonEncode(convertEngineMessages(options.messages));
    final rawBuffer = StringBuffer();
    final processor = AgentStreamProcessor();
    final error = StringBuffer();
    final done = Completer<void>();
    StreamSubscription<String>? sub;
    var _streamFinished = false;
    // 思考失控守卫：思考块超长未闭合（实测 agents-a1-4b thinking 下
    // `<think>` 一开就数千字独白不停）→ 主动 stopGeneration 止损，
    // 结束后按 thinkingOverflow 失败——不烧光整轮预算让用户干等数分钟。
    var _thinkingOverflow = false;
    // WP5：工具调用块生成中标记（status 流只在状态翻转/持续时推）。
    var _toolGenActive = false;
    void _finish() {
      if (_streamFinished) return;
      _streamFinished = true;
      done.complete();
    }
    try {
      final sourceStream = _inference.completionWithMessages(
        prompt: '',
        messagesJson: messagesJson,
        imagePath: options.imagePath,
        audioPath: options.audioPath,
        maxTokens: options.maxTokens ?? 512,
        temperature: options.temperature,
        topP: 0.9,
      );
      sub = sourceStream.listen(
        (token) {
          if (token.isEmpty) return;
          rawBuffer.write(token);
          processor.add(token);
          if (onToken != null) {
            onToken!.add(processor.visibleText);
          }
          if (onThinking != null) {
            onThinking!.add(processor.thinkingText);
          }
          if (!_thinkingOverflow &&
              processor.thinking.length > _maxThinkingChars) {
            _thinkingOverflow = true;
            _inference.stopGeneration();
          }
          // WP5：工具调用参数生成期反馈（大 HTML/长文本写文件时
          // 可见流为空、思考为空，UI 只能干转圈——把隐藏缓冲长度推给 UI）。
          if (options.onStatus != null) {
            final gen = processor.toolGenActive;
            if (gen && !_toolGenActive) {
              _toolGenActive = true;
            }
            if (gen) {
              options.onStatus!.add(
                  'toolgen|${processor.toolGenChars}|${processor.toolGenPreview}');
            } else if (_toolGenActive) {
              _toolGenActive = false;
              options.onStatus!.add('toolgen|0|');
            }
          }
        },
        onError: (Object e, [StackTrace? s]) {
          error.write('$e\n');
          _finish();
        },
        onDone: _finish,
      );
      currentSub = sub;
      // 与 cancel 竞跑：cancel 先行则取消。
      if (await race(done.future, cancel)) {
        throw const AgentCancelledException();
      }
      if (error.length > 0) {
        throw LlmFailure(
          code: mapEngineError(error.toString()),
          message: error.toString(),
        );
      }
      if (_thinkingOverflow) {
        throw LlmFailure(
          code: LlmFailureCode.thinkingOverflow,
          message: '思考超长未闭合（>$_maxThinkingChars 字），已中止生成：'
              '该模型思考失控。可在 设置→智能体 调大「思考失控守卫阈值」，'
              '或关闭此模型的思考模式（enableThinking）后重试',
        );
      }
      return parseAndReturn(rawBuffer, processor);
    } on AgentCancelledException catch (e) {
      rethrow;
    } on LlmFailure catch (e) {
      rethrow;
    } catch (e) {
      throw LlmFailure(
        code: mapEngineError(error.toString()),
        message: '本地引擎调用失败: $e',
      );
    } finally {
      sub?.cancel();
      if (identical(sub, currentSub)) {
        currentSub = null;
      }
    }
  }
}
