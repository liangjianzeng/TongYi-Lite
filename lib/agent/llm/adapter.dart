/// LLM adapter seam（Phase 3）—— 模型调用抽象。
///
/// Phase 1 依赖此 seam；本地实现 [LocalEngineAdapter]（lib/agent/llm/local_adapter.dart），
/// API 实现（lib/agent/llm/openai_adapter.dart，Phase 3）共用同一接口。
///
/// 设计（对照 DSH `LlmAdapter` Part 12）：
/// - adapter 只报告**事实**（文本 + 工具调用 + 失败事实），不做策略；
/// - 失败归一化为 [LlmFailure]（code + 事实字段），策略（重试/压缩/终态）由主循环瀑布决定；
/// - `generate` 是纯模型调用；工具执行不在 adapter 里（主循环负责）。
library;

import 'dart:async';

import '../capability.dart';
import '../tool_definition.dart';

/// 生成被取消时抛出的异常（本 SDK 无 flutter/services 的
/// CancelController，故用自定义异常 + [Completer] 表达取消）。
/// 独立于 Exception 以避免其仅含 factory 构造器的限制。
final class AgentCancelledException {
  const AgentCancelledException();
}

/// 模型 provider 类型（本地引擎 / 远程 API）。
enum ProviderKind {
  local,
  api,
}

/// 模型请求失败归一化（事实，不含策略）。
enum LlmFailureCode {
  contextWindowExceeded, // 上下文窗口超出（本地引擎常见于长对话）
  rateLimit,             // 限流（429 / 本地引擎资源耗尽）
  server,                // 服务端 5xx
  timeout,               // 超时
  transport,             // 网络传输 / native channel 错误
  noAdapter,             // 无可用适配器
  emptyResponse,         // 响应为空
  unknown,
}

/// 模型请求失败。
final class LlmFailure {
  final LlmFailureCode code;
  final String message;
  final int? status;
  final int? providerRetryAfterMs;
  final String? requestId;

  const LlmFailure({
    required this.code,
    required this.message,
    this.status,
    this.providerRetryAfterMs,
    this.requestId,
  });

  bool get isContextWindowExceeded => code == LlmFailureCode.contextWindowExceeded;
  bool get isRetryableTransient =>
      code == LlmFailureCode.rateLimit ||
      code == LlmFailureCode.server ||
      code == LlmFailureCode.timeout ||
      code == LlmFailureCode.transport;
}

/// 一次模型请求的选项。
final class GenerateOptions {
  final ProviderKind provider;
  /// 历史消息（role/content 对；role ∈ {user, assistant, system, tool}）。
  /// 由 [SessionLog.deriveModelMessages] 派生；adapter 负责按 provider 翻译。
  final List<Map<String, dynamic>> messages;
  /// 可见工具（本地路线进 system 工具段；API 路线原生 tools）。
  final List<ToolDefinition> tools;
  final double temperature;
  final int? maxTokens;
  final String modelId;
  final String? imagePath;
  final String? audioPath;

  const GenerateOptions({
    required this.provider,
    required this.messages,
    required this.tools,
    required this.temperature,
    this.maxTokens,
    required this.modelId,
    this.imagePath,
    this.audioPath,
  });
}

/// 一次模型请求的结果。
final class LlmResult {
  final String text;
  final List<ToolCall> toolCalls;

  const LlmResult({
    required this.text,
    this.toolCalls = const [],
  });

  bool get hasToolCalls => toolCalls.isNotEmpty;
}

/// 一次模型调用的**能力快照**（Phase 3，对应 DSH Part 9.7 的 `prepareCall`）。
///
/// 端侧无 HMR，故将 DSH「绑定注册代际」简化为**能力快照**：协议选择在
/// [prepareCall] 时按能力驱动**固化**，避免运行中换模型导致协议不一致。
///
/// - [adapter]：本次调用绑定的 adapter（local/API）。
/// - [model]：模型标识（local=模型 id；api=API 模型 name）。
/// - [capabilities]：加载时冻结的 [EngineCapabilities] 快照；null 表示未知。
final class PreparedLlmCall {
  final LlmAdapter adapter;
  final String model;
  final EngineCapabilities? capabilities;
  const PreparedLlmCall({
    required this.adapter,
    required this.model,
    this.capabilities,
  });
}

abstract class LlmAdapter {
  /// 一次模型请求。
  ///
  /// [cancel] 若传入，adapter 应在流处理中与取消竞跑：取消先行则抛
  /// [AgentCancelledException]，让主循环把 turn 收为 interrupted。
  Future<LlmResult> generate(
    GenerateOptions options, {
    StreamController<String>? onToken,
    Completer<void>? cancel,
  });

  /// 取消当前进行中的生成（adapter 实现：本地引擎 stopGeneration / API stop）。
  void cancel() {}

  /// 绑定本次调用的能力快照（DSH `prepareCall` 端侧简化）。
  ///
  /// 默认实现：仅绑定 adapter + model。具体 adapter 可覆写以注入
  /// 加载时冻结的 [EngineCapabilities]（协议选择的依据）。
  PreparedLlmCall prepareCall(String model) =>
      PreparedLlmCall(adapter: this, model: model);
}