/// 引擎 adapter 共享基类 —— 本地与 API 两条路线共用的取消、
/// 能力快照（prepareCall）与解析/错误归一化工具。
///
/// 两条路线差异仅在 [generate]：本地走 `InferenceService`，
/// API 走 `OpenAiService`。其余（取消竞跑、文本解析、错误归一化）共用。
///
/// 注意：Dart 的命名遮蔽（前导 `_`）是**按库（文件）**的，子类跨库
/// 无法访问基类私有成员。故供子类复用的状态与工具一律**公开**
/// （[currentSub] / [convertEngineMessages] / [parseAndResult] 等），
/// 仅内部私有字段（[protocol] / [capabilities]）保留 `_`。
library;

import 'dart:async';

import 'package:dio/dio.dart';

import '../../providers/agent_stream_processor.dart';
import 'adapter.dart';
import '../capability.dart';
import '../protocol/tool_protocol.dart';

abstract class BaseEngineAdapter implements LlmAdapter {
  final ToolProtocol _protocol;
  final EngineCapabilities? _capabilities;

  /// 当前进行中的流订阅（子类 [generate] 管理，[cancel] 统一中止）。
  StreamSubscription<String>? currentSub;

  BaseEngineAdapter({
    required ToolProtocol protocol,
    EngineCapabilities? capabilities,
  })  : _protocol = protocol,
        _capabilities = capabilities;

  /// 唯一实现点，由子类 [LocalEngineAdapter] / [OpenAiAdapter] 覆写。
  @override
  Future<LlmResult> generate(
    GenerateOptions options, {
    StreamController<String>? onToken,
    Completer<void>? cancel,
  }) {
    throw UnimplementedError('子类须覆写 generate');
  }

  /// 取消当前进行中的生成（两条路线共用安全网：中止流订阅）。
  @override
  void cancel() {
    currentSub?.cancel();
    currentSub = null;
  }

  /// 绑定能力快照（Phase 3，DSH `prepareCall` 端侧简化）。
  /// 协议在调用准备时按能力驱动固化，避免运行中换模型导致协议不一致。
  @override
  PreparedLlmCall prepareCall(String model) =>
      PreparedLlmCall(adapter: this, model: model, capabilities: _capabilities);

  // ---------------------------------------------------------------------------
  // 共享工具（公开，供子类跨库调用）
  // ---------------------------------------------------------------------------

  /// 引擎消息转换（local 用）：tool→user，助手剥除 tool_calls。
  List<Map<String, dynamic>> convertEngineMessages(
      List<Map<String, dynamic>> messages) {
    final out = <Map<String, dynamic>>[];
    for (final m in messages) {
      final role = m['role'] as String?;
      final content = m['content'] as String? ?? '';
      if (role == 'tool') {
        out.add({'role': 'user', 'content': content});
      } else {
        // 文本协议从 response 文本解析，工具调用不入历史。
        out.add({'role': role, 'content': content});
      }
    }
    return out;
  }

  /// API 消息转换：'tool' 保留 role:tool（OpenAI 支持），助手剥除 tool_calls。
  List<Map<String, dynamic>> convertApiMessages(
      List<Map<String, dynamic>> messages) {
    final out = <Map<String, dynamic>>[];
    for (final m in messages) {
      final role = m['role'];
      final content = m['content'] as String? ?? '';
      out.add({'role': role, 'content': content});
    }
    return out;
  }

  /// 解析最终文本流 → [LlmResult]（两条路线共用）。
  Future<LlmResult> parseAndReturn(
      StringBuffer rawBuffer, AgentStreamProcessor processor) async {
    processor.finish();
    final outcome =
        await _protocol.parseStream(Stream<String>.value(rawBuffer.toString()));
    return LlmResult(text: outcome.text, toolCalls: outcome.toolCalls);
  }

  /// 流终态 vs cancel 竞跑；返回 true 表示 cancel 先行。
  Future<bool> race(Future done, Completer<void>? cancel) async {
    if (cancel == null) {
      await done;
      return false;
    }
    return await Future.any([
      done.then((_) => false),
      cancel.future.then((_) => true),
    ]);
  }

  /// 引擎（本地）错误归一化。
  LlmFailureCode mapEngineError(String msg) {
    final lower = msg.toLowerCase();
    if (lower.contains('context') ||
        lower.contains('上下文') ||
        lower.contains('context window') ||
        lower.contains('overflow')) {
      return LlmFailureCode.contextWindowExceeded;
    }
    if (lower.contains('timeout')) {
      return LlmFailureCode.timeout;
    }
    if (lower.contains('rate') || lower.contains('限流')) {
      return LlmFailureCode.rateLimit;
    }
    return LlmFailureCode.transport;
  }

  /// API 错误归一化（dio 异常）。
  LlmFailureCode mapApiError(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return LlmFailureCode.timeout;
      case DioExceptionType.connectionError:
        return LlmFailureCode.transport;
      default:
        return LlmFailureCode.transport;
    }
  }

  String friendlyApiError(DioException e) {
    final code = e.response?.statusCode;
    final msg = e.response?.statusMessage ?? '';
    final reason = e.message ?? e.type.toString();
    if (code == 429) return 'API 限流（HTTP $code）：$msg';
    if (code != null && code >= 500) {
      return 'API 服务端错误（HTTP $code）：$msg';
    }
    return 'API 请求失败（HTTP ${code ?? ''}）：$reason';
  }
}
