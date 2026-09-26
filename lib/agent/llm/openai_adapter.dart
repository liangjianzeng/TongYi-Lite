/// API adapter —— 包裹 [OpenAiService]（OpenAI 兼容接口）。
///
/// 路由：仅 api。OpenAiService 仅回 content 增量（不解析原生 tool_calls），
/// 故 API 路线同样依赖文本协议（[ToolProtocol] 注入 + 文本解析）。
///
/// 失败归一化为 [LlmFailure]（事实，不含策略）；重试策略由主循环瀑布决定。
library;

import 'dart:async';

import 'package:dio/dio.dart';

import '../../models/api_model.dart';
import '../../providers/agent_stream_processor.dart';
import '../../services/openai_service.dart';
import 'adapter.dart';
import 'base_engine_adapter.dart';
import '../capability.dart';
import '../protocol/tool_protocol.dart';

class OpenAiAdapter extends BaseEngineAdapter {
  final OpenAiService? _openAi;
  final ApiModelConfig? _apiModel;

  OpenAiAdapter({
    required ToolProtocol protocol,
    EngineCapabilities? capabilities,
    OpenAiService? openAi,
    ApiModelConfig? apiModel,
  })  : _openAi = openAi,
        _apiModel = apiModel,
        super(protocol: protocol, capabilities: capabilities);

  /// 取消：先中止 Dart 侧流（基类），再取消 API SSE 请求。
  @override
  void cancel() {
    super.cancel();
    _openAi?.stop();
  }

  @override
  Future<LlmResult> generate(
    GenerateOptions options, {
    StreamController<String>? onToken,
    Completer<void>? cancel,
  }) async {
    if (_openAi == null || _apiModel == null) {
      throw LlmFailure(
        code: LlmFailureCode.noAdapter,
        message: 'API 路线未配置（未注入 OpenAiService / 模型配置）',
      );
    }
    final openAi = _openAi!;
    final model = _apiModel!;
    // API 路线：'tool' 保留 role:tool（OpenAI 支持），助手剥除 tool_calls。
    final apiMessages = convertApiMessages(options.messages);
    final rawBuffer = StringBuffer();
    final processor = AgentStreamProcessor();
    // 流终态（null=干净完成，非 null=错误）。
    final outcome = Completer<Object?>();
    StreamSubscription<String>? sub;
    bool _streamFinished = false;
    void _finishStream(Object? err) {
      if (_streamFinished) return;
      _streamFinished = true;
      outcome.complete(err);
    }
    try {
      sub = openAi.chatCompletion(
        config: model,
        messages: apiMessages,
        temperature: options.temperature,
        maxTokens: options.maxTokens ?? 512,
      ).listen(
        (token) {
          if (token.isEmpty) return;
          rawBuffer.write(token);
          processor.add(token);
          if (onToken != null) {
            onToken!.add(processor.visibleText);
          }
        },
        onError: (Object e, [StackTrace? s]) {
          // async 生成器出错不关流 → 显式取消并标记完成。
          sub?.cancel();
          _finishStream(e);
        },
        onDone: () => _finishStream(null),
      );
      currentSub = sub;
      if (await race(outcome.future, cancel)) {
        throw const AgentCancelledException();
      }
      final error = await outcome.future;
      if (error is DioException) {
        throw LlmFailure(
          code: mapApiError(error),
          message: friendlyApiError(error),
        );
      }
      if (error != null) {
        throw LlmFailure(code: LlmFailureCode.transport, message: '$error');
      }
      return parseAndReturn(rawBuffer, processor);
    } on AgentCancelledException catch (e) {
      rethrow;
    } on DioException catch (e) {
      throw LlmFailure(code: mapApiError(e), message: friendlyApiError(e));
    } catch (e) {
      throw LlmFailure(
        code: LlmFailureCode.transport,
        message: 'API 调用失败: $e',
      );
    } finally {
      sub?.cancel();
      if (identical(sub, currentSub)) {
        currentSub = null;
      }
    }
  }
}
