/// API adapter —— 包裹 [OpenAiService]（OpenAI 兼容接口）。
///
/// 双协议路由（能力驱动，对照 DSH `native-tools` / prompt-json）：
/// - **原生**（`capabilities.nativeToolCall == true` 且带工具）：工具 schema 走
///   请求体 `tools`，模型产出结构化 `delta.tool_calls`，由
///   [OpenAiNativeStreamAssembler] 流式组装——文本协议的解析降级/截断/
///   思考污染问题在此路径不存在。
/// - **文本**（无原生能力）：与本地路线同构，response 文本交给注入的
///   [ToolProtocol] 解析。
///
/// 失败归一化为 [LlmFailure]（事实，不含策略）；HTTP 状态码分档：
/// 429/5xx 瞬态可重试，4xx（除 429）为 invalidRequest 永久失败档。
library;

import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../../models/api_model.dart';
import '../../providers/agent_stream_processor.dart';
import '../../services/openai_service.dart';
import 'adapter.dart';
import 'base_engine_adapter.dart';
import '../capability.dart';
import '../protocol/tool_protocol.dart';
import '../tool_definition.dart';

/// 把 [ToolDefinition] 列表渲染为 OpenAI function 工具 schema。
List<Map<String, dynamic>> buildOpenAiToolsSchema(List<ToolDefinition> tools) {
  return tools
      .map((t) => {
            'type': 'function',
            'function': {
              'name': t.name,
              'description': t.description,
              'parameters': t.parameters,
            },
          })
      .toList();
}

/// 把 [SessionLog.deriveModelMessages] 的中性消息翻译为 OpenAI 线格式。
///
/// 关键差异（相对文本路线的 convertApiMessages）：
/// - assistant 的 `tool_calls`（type:tool_call/function_name/arguments）翻译为
///   OpenAI `{id, type:'function', function:{name, arguments:JSON字符串}}`——
///   保留后 `role:'tool'` 消息才有配对锚点，严格服务端不再 400；
/// - `role:'tool'` 保留并携带 `tool_call_id`。
List<Map<String, dynamic>> toOpenAiWireMessages(
    List<Map<String, dynamic>> messages) {
  final out = <Map<String, dynamic>>[];
  for (final m in messages) {
    final role = m['role'] as String? ?? 'user';
    final content = m['content'] as String? ?? '';
    if (role == 'tool') {
      out.add({
        'role': 'tool',
        'tool_call_id': m['tool_call_id'] as String? ?? '',
        'content': content,
      });
      continue;
    }
    if (role == 'assistant') {
      final calls = m['tool_calls'] as List<dynamic>?;
      if (calls != null && calls.isNotEmpty) {
        final wire = <Map<String, dynamic>>[];
        for (final c in calls) {
          if (c is! Map<String, dynamic>) continue;
          final name = ((c['function_name'] ?? c['name']) as String?) ?? '';
          if (name.isEmpty) continue;
          final rawArgs = c['arguments'];
          final argsStr = rawArgs == null
              ? '{}'
              : (rawArgs is String ? rawArgs : jsonEncode(rawArgs));
          final id = c['id'] as String? ?? '';
          wire.add({
            // 缺 id 时用消息内序号兜底（服务端要求 id 在消息内可配对即可）。
            'id': id.isNotEmpty ? id : 'call_${wire.length}',
            'type': 'function',
            'function': {'name': name, 'arguments': argsStr},
          });
        }
        if (wire.isNotEmpty) {
          out.add({'role': 'assistant', 'content': content, 'tool_calls': wire});
          continue;
        }
      }
    }
    out.add({'role': role, 'content': content});
  }
  return out;
}

/// 原生工具调用的流式分片组装器。
///
/// OpenAI 流式 tool_calls 按 `index` 分片到达：首片带 id/name，
/// `function.arguments` 是 JSON 字符串的增量分片（跨多片拼齐后整体解码）。
class OpenAiNativeStreamAssembler {
  final StringBuffer _text = StringBuffer();
  final Map<int, _PendingNativeCall> _pending = {};
  String? finishReason;

  String get textSoFar => _text.toString();

  /// 消费一条 [OpenAiService.chatCompletionEvents] 事件。
  void addEvent(Map<String, dynamic> event) {
    switch (event['type']) {
      case 'text':
        final t = event['text'];
        if (t is String) _text.write(t);
        break;
      case 'tool_call':
        final idx = (event['index'] as num?)?.toInt() ?? 0;
        final slot = _pending.putIfAbsent(idx, _PendingNativeCall.new);
        final id = event['id'];
        if (id is String && id.isNotEmpty) slot.id = id;
        final name = event['name'];
        if (name is String && name.isNotEmpty && slot.name == null) {
          slot.name = name;
        }
        final frag = event['argumentsFragment'];
        if (frag is String) slot.args.write(frag);
        break;
      case 'finish':
        final r = event['reason'];
        if (r is String) finishReason = r;
        break;
    }
  }

  /// 组装终态：文本 + 按 index 序排列的工具调用。
  ({String text, List<ToolCall> calls}) finalize() {
    final indexes = _pending.keys.toList()..sort();
    final calls = <ToolCall>[];
    for (final idx in indexes) {
      final p = _pending[idx]!;
      Map<String, dynamic>? args;
      final raw = p.args.toString().trim();
      if (raw.isEmpty) {
        args = const {};
      } else {
        try {
          final decoded = jsonDecode(raw);
          if (decoded is Map<String, dynamic>) args = decoded;
        } catch (_) {
          // 分片拼齐后仍非法 JSON（服务端异常）→ args=null，
          // 交由执行前必填校验给出可读错误，模型可重试。
        }
      }
      calls.add(ToolCall(
        id: p.id.isNotEmpty ? p.id : 'call_${idx}_${DateTime.now().microsecondsSinceEpoch}',
        name: p.name ?? '',
        arguments: args,
      ));
    }
    return (text: _text.toString(), calls: calls);
  }
}

final class _PendingNativeCall {
  String id = '';
  String? name;
  final StringBuffer args = StringBuffer();
}

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
    // 能力驱动双路由：原生工具调用（API）优先，文本协议兜底。
    final useNative =
        (capabilities?.nativeToolCall ?? false) && options.tools.isNotEmpty;
    if (useNative) {
      return _generateNative(options, onToken: onToken, cancel: cancel);
    }
    return _generateTextProtocol(options, onToken: onToken, cancel: cancel);
  }

  /// 原生工具调用路径：tools 进请求体，tool_calls 结构化组装。
  Future<LlmResult> _generateNative(
    GenerateOptions options, {
    StreamController<String>? onToken,
    Completer<void>? cancel,
  }) async {
    final openAi = _openAi!;
    final model = _apiModel!;
    final wireMessages = toOpenAiWireMessages(options.messages);
    final tools = buildOpenAiToolsSchema(options.tools);
    final assembler = OpenAiNativeStreamAssembler();
    // 流终态（null=干净完成，非 null=错误）。
    final outcome = Completer<Object?>();
    StreamSubscription<Map<String, dynamic>>? sub;
    bool _streamFinished = false;
    void _finishStream(Object? err) {
      if (_streamFinished) return;
      _streamFinished = true;
      outcome.complete(err);
    }

    try {
      sub = openAi.chatCompletionEvents(
        config: model,
        messages: wireMessages,
        tools: tools,
        temperature: options.temperature,
        maxTokens: options.maxTokens ?? 512,
      ).listen(
        (event) {
          assembler.addEvent(event);
          if (onToken != null) {
            onToken.add(assembler.textSoFar);
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
      if (error != null) {
        final f = _normalizeStreamError(error);
        if (f.code == LlmFailureCode.invalidRequest) {
          // 请求体带 tools 被服务端拒收：端点很可能不支持 function calling。
          // fail-loud + 明确指引，不静默降级文本协议（会产生解析降级新问题）。
          throw LlmFailure(
            code: f.code,
            message: '${f.message}'
                '（当前端点可能不支持 tools/function calling，'
                '请检查 API 服务是否支持原生工具调用）',
          );
        }
        throw f;
      }
      final r = assembler.finalize();
      if (r.text.trim().isEmpty && r.calls.isEmpty) {
        // 空响应 fail-loud：推理耗尽 max_tokens（finish=length）等场景，
        // 不能当"最终回答"静默完成。
        throw LlmFailure(
          code: LlmFailureCode.emptyResponse,
          message: assembler.finishReason == null
              ? '模型返回空响应（无文本也无工具调用）'
              : '模型返回空响应（finish_reason=${assembler.finishReason}）',
        );
      }
      return LlmResult(text: r.text, toolCalls: r.calls);
    } on AgentCancelledException catch (e) {
      rethrow;
    } on LlmFailure catch (e) {
      rethrow;
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

  /// 文本协议路径（与本地路线同构）：response 文本交给注入协议解析。
  Future<LlmResult> _generateTextProtocol(
    GenerateOptions options, {
    StreamController<String>? onToken,
    Completer<void>? cancel,
  }) async {
    final openAi = _openAi!;
    final model = _apiModel!;
    // 文本路线：'tool' 保留 role:tool（部分服务端宽容处理），助手剥除 tool_calls。
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
      if (error != null) {
        throw _normalizeStreamError(error);
      }
      // [AGDBG] 诊断（开发用，可删）：打印原始 content 流。
      print('[AGDBG/API] rawLen=${rawBuffer.length} raw=<<<${rawBuffer.toString()}>>>');
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

  /// 流错误 → [LlmFailure]：[OpenAiHttpException]（携带状态码）按状态分档，
  /// dio 异常走 [mapApiError]，其余归 transport。
  LlmFailure _normalizeStreamError(Object error) {
    if (error is OpenAiHttpException) {
      return LlmFailure(
        code: mapApiStatus(error.statusCode),
        message: error.message,
      );
    }
    if (error is DioException) {
      return LlmFailure(
        code: mapApiError(error),
        message: friendlyApiError(error),
      );
    }
    return LlmFailure(code: LlmFailureCode.transport, message: '$error');
  }
}
