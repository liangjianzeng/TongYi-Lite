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

/// 流终态上下文（[BaseEngineAdapter.runStreamWithGuards] 的 finalize 裁决依据）：
/// [thinkingOverflowed] 思考失控守卫闩是否已触发；[thinkingCharsAtTrigger]
/// 触发那一刻的累计思考字数（失败文案用，事后读会偏大）；
/// [streamError] 流错误对象（null=干净完成）。
typedef StreamFinalContext = ({
  bool thinkingOverflowed,
  int thinkingCharsAtTrigger,
  Object? streamError,
});

/// 一次 generate() 的取消令牌：绑定该次调用的取消信号与流订阅。
///
/// 为什么需要令牌：adapter 实例会被共享（chat_provider 默认让子代理复用
/// 父回合的 adapter），[BaseEngineAdapter.currentSub] 是实例级单槽——
/// 后发起的 generate 会覆盖先前的订阅，无条件取消槽里的流就会误杀
/// **别人**的生成（父回合 cancel() 误杀子代理的流，2026-11 缺陷定案）。
/// 令牌在 generate 入口创建、与该次调用一一对应；cancel() 只中止
/// 「归属本次取消」的令牌（判定见 [BaseEngineAdapter.cancelOwnedGenerations]）。
class CancelToken {
  /// 该次 generate 的取消竞跑信号（调用方未传 = null）。
  final Completer<void>? cancelSignal;

  /// 该次 generate 的流订阅（listen 之后由 bindGenerationStream 绑定）。
  /// dynamic：文本路线是 `StreamSubscription<String>`，API 原生工具路线是
  /// 结构化事件流订阅（`StreamSubscription<Map<String, dynamic>>`），
  /// 取消只需 `.cancel()`，无需元素类型。
  StreamSubscription<dynamic>? sub;

  CancelToken(this.cancelSignal);

  /// 该令牌是否「归属一次已表态的取消」：调用方传了信号且已触发
  /// （ReactLoopAgent.cancel 固定先 complete 自己的 completer 再调
  /// adapter.cancel()——信号就是归属凭证），或压根没传信号（旧式直调，
  /// 保留可被任意 cancel() 中止的旧行为）。信号未触发的令牌是**别人的
  /// 生成**，一律不碰。
  bool get cancellable {
    final c = cancelSignal;
    return c == null || c.isCompleted;
  }
}

abstract class BaseEngineAdapter implements LlmAdapter {
  final ToolProtocol _protocol;
  final EngineCapabilities? _capabilities;

  /// 当前进行中的流订阅（最近一次 generate 的；诊断/兼容槽位，
  /// 清理时机由令牌守卫，见 [endGeneration] / [cancelOwnedGenerations]）。
  StreamSubscription<dynamic>? currentSub;

  /// 在途生成令牌集合（generate 入口注册、finally 注销）。
  final Set<CancelToken> _activeTokens = {};

  /// 最近注册的令牌（currentSub 槽对应的令牌口径）。
  CancelToken? _currentToken;

  /// 能力快照只读访问（子类协议路由用；Dart 私有按库隔离，
  /// 子类跨库读不到 `_capabilities`，故开只读门）。
  EngineCapabilities? get capabilities => _capabilities;

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
    StreamController<String>? onThinking,
    Completer<void>? cancel,
  }) {
    throw UnimplementedError('子类须覆写 generate');
  }

  /// generate 入口调用：创建并登记本次生成的取消令牌。
  /// 尽早登记（流还没 listen 时信号也可能已触发）——native 侧是否要停
  /// 生成只看令牌归属，不看 Dart 订阅是否已建立。
  CancelToken beginGeneration({Completer<void>? cancel}) {
    final t = CancelToken(cancel);
    _activeTokens.add(t);
    _currentToken = t;
    return t;
  }

  /// listen 之后调用：令牌绑定流订阅并更新 [currentSub] 槽。
  void bindGenerationStream(CancelToken token, StreamSubscription<dynamic> sub) {
    token.sub = sub;
    currentSub = sub;
  }

  /// finally 调用：注销令牌。currentSub 槽只在**本令牌仍是当前令牌**时
  /// 才清——identical 防误清从 sub 升级为令牌口径（子代理的 generate
  /// 覆盖槽位后，先结束的父回合不得把后来者的槽清掉）。
  void endGeneration(CancelToken token) {
    if (identical(token, _currentToken)) {
      _currentToken = null;
      currentSub = null;
    }
    token.sub = null;
    _activeTokens.remove(token);
  }

  /// 中止「归属本次取消」的在途流。
  ///
  /// 归属判定（令牌条件）：该次 generate 的取消信号已触发，或压根没传
  /// 信号（旧式直调保留旧行为）。信号未触发的令牌是别人的生成——共享
  /// adapter 时不碰，否则父回合 cancel() 会误杀子代理的流。
  ///
  /// 返回是否存在归属目标（无论 Dart 订阅是否已建立）：本地引擎据此
  /// 决定是否调 native stopGeneration——没有归属目标时调用会把引擎里
  /// **别人**的生成一并停掉，等于绕过令牌隔离。
  bool cancelOwnedGenerations() {
    var had = false;
    for (final t in _activeTokens.toList()) {
      if (!t.cancellable) continue;
      had = true;
      t.sub?.cancel();
      if (identical(t, _currentToken)) {
        _currentToken = null;
        currentSub = null;
      }
      t.sub = null;
      _activeTokens.remove(t);
    }
    return had;
  }

  /// 取消当前进行中的生成（公开 API，签名不变，调用方无感知）。
  /// 安全网语义收窄为「只中止归属本次取消的流」；是否顺带停 native
  /// 后端由子类按 [cancelOwnedGenerations] 的归属结论决定。
  @override
  void cancel() {
    cancelOwnedGenerations();
  }

  /// 绑定能力快照（Phase 3，DSH `prepareCall` 端侧简化）。
  /// 协议在调用准备时按能力驱动固化，避免运行中换模型导致协议不一致。
  /// 现状：生产路径的 local/API 选择在 ChatNotifier 组装期完成、不走此口，
  /// 本实现是能力驱动演进的落点（详见 [PreparedLlmCall] 的现状注记）。
  @override
  PreparedLlmCall prepareCall(String model) =>
      PreparedLlmCall(adapter: this, model: model, capabilities: _capabilities);

  // ---------------------------------------------------------------------------
  // 共享工具（公开，供子类跨库调用）
  // ---------------------------------------------------------------------------

  /// 引擎消息转换（local 用）：assistant 的 tool_calls 按 B4 回放为模型
  /// 自身的文本协议形态拼回 content（模型在历史里看见自己发过的调用，
  /// 参数自纠/多步规划/复用此前调用恢复）；tool 结果角色按模板能力分流
  /// ——Bailing V3（Ling 3.x）模板原生支持 role:tool（渲染为
  /// `<role>OBSERVATION</role>\n<tool_response>…`，贴合训练分布），其余
  /// 模板不识别 tool 角色（minja 渲染会**静默丢消息**）→ 保持 tool→user。
  List<Map<String, dynamic>> convertEngineMessages(
      List<Map<String, dynamic>> messages,
      {String modelId = ''}) {
    // 仅 Bailing V3 模板吃 role:tool（其 jinja 有 `message.role == "tool"`
    // 分支）；其余模板没有该分支，tool 消息会落不进任何渲染分支被丢弃。
    final keepToolRole = _capabilities?.toolTemplate == 'bailing-v3';
    final out = <Map<String, dynamic>>[];
    for (final m in messages) {
      final role = m['role'] as String?;
      var content = m['content'] as String? ?? '';
      if (role == 'tool') {
        out.add({'role': keepToolRole ? 'tool' : 'user', 'content': content});
      } else if (role == 'assistant') {
        final replay = _replayAssistant(m, modelId);
        if (replay != null) {
          content = content.isEmpty ? replay : '$content\n$replay';
        }
        out.add({'role': role, 'content': content});
      } else {
        out.add({'role': role, 'content': content});
      }
    }
    return out;
  }

  /// API 消息转换（文本协议路线）：'tool' 保留 role:tool（部分服务端宽容
  /// 处理），assistant 的 tool_calls 按 B4 回放为文本形态拼回 content。
  /// 原生 function calling 路线不走本方法（toOpenAiWireMessages 保留
  /// 结构化 tool_calls，服务端要求结构化配对）。
  List<Map<String, dynamic>> convertApiMessages(
      List<Map<String, dynamic>> messages,
      {String modelId = ''}) {
    final out = <Map<String, dynamic>>[];
    for (final m in messages) {
      final role = m['role'];
      var content = m['content'] as String? ?? '';
      if (role == 'assistant') {
        final replay = _replayAssistant(m, modelId);
        if (replay != null) {
          content = content.isEmpty ? replay : '$content\n$replay';
        }
      }
      out.add({'role': role, 'content': content});
    }
    return out;
  }

  /// assistant 历史条目的工具调用回放文本；无调用/协议无回放形态 → null。
  String? _replayAssistant(Map<String, dynamic> m, String modelId) {
    final calls = m['tool_calls'];
    if (calls is! List || calls.isEmpty) return null;
    final typed = <Map<String, dynamic>>[
      for (final c in calls)
        if (c is Map<String, dynamic>) c,
    ];
    if (typed.isEmpty) return null;
    return _protocol.replayToolCalls(modelId, typed);
  }

  /// 解析最终文本流 → [LlmResult]（两条路线共用）。
  ///
  /// 解析最终文本流 → [LlmResult]（两条路线共用）。
  ///
  /// 优先用 [AgentStreamProcessor.cleanText]（原始流去掉思考块、保留工具调用）
  /// 喂协议解析——而非原始流，否则 Qwen 的  think/response 思考块
  /// 会渗入 LlmResult.text，成为历史 assistant 内容，污染上下文、
  /// 把"思考内容"冒充回复并断开执行链。processor 未经流喂入（cleanText 空）
  /// 时退回 [rawBuffer]（测试桩/调用方自持缓冲的形态）。
  ///
  /// 空响应兜底（fail-loud）：流干净结束但既无文本也无工具调用时抛
  /// [LlmFailureCode.emptyResponse] 走失败瀑布——否则主循环会把空结果当
  /// "最终回答" 静默完成，UI 存一条空白消息（API 思考型模型推理耗尽
  /// max_tokens 时的真实形态）。
  Future<LlmResult> parseAndReturn(
      StringBuffer rawBuffer, AgentStreamProcessor processor) async {
    processor.finish();
    final clean = processor.cleanText;
    final text = clean.isEmpty ? rawBuffer.toString() : clean;
    final outcome =
        await _protocol.parseStream(Stream<String>.value(text));
    final result = LlmResult(text: outcome.text, toolCalls: outcome.toolCalls);
    if (result.text.trim().isEmpty && !result.hasToolCalls) {
      throw const LlmFailure(
        code: LlmFailureCode.emptyResponse,
        message: '模型返回空响应（无文本也无工具调用）',
      );
    }
    return result;
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

  /// 思考失控失败文案（**唯一真源**，三路线共用；此前逐字节重复 3 份，
  /// 改文案只改一处）。[tail] 是路线差异尾巴：本地多一句"或关闭该模型
  /// 思考模式"（端侧有原生思考开关可关），API 路线服务端自决、无此句。
  static LlmFailure thinkingOverflowFailure(int charsAtTrigger, int threshold,
      {String tail = ''}) {
    return LlmFailure(
      code: LlmFailureCode.thinkingOverflow,
      message: '思考失控：已累计思考 $charsAtTrigger 字仍无任何产出，'
          '已主动中止（阈值 $threshold 字）。'
          '本次自动改用「不思考」重试一次；若频繁出现，'
          '请在 设置→智能体 调大「思考失控守卫阈值」$tail',
    );
  }

  /// 流消费统一骨架（三份复制粘贴的收敛，T4）：取消令牌生命周期 + 流终态
  /// Completer + cancel 竞跑 + 思考失控守卫（一次性止损闩）+ 异常归一化 +
  /// finally 清理。
  ///
  /// 纪律（adapter 只报事实不做策略，见 adapter.dart 头注释）：本骨架只做
  /// **机制**——谁先到、谁被取消、守卫只止损一次、资源必清理；不做**策略**
  /// （失控算不算失败、错误归哪档、要不要抢救产出）。策略差异全部由回调
  /// 注入：[finalize] 按路线 own 结果裁决（错误检查顺序各路线不同：本地
  /// 先查流错误再看守卫，API 先看守卫——stop() 以 cancel 错误收场，先查
  /// 错误会把失控思考归进可重试档）。
  ///
  /// 类型参数 [T]：流元素类型。本地/API 文本路线是 token 字符串，API 原生
  /// 工具路线是结构化事件 Map。
  Future<LlmResult> runStreamWithGuards<T>({
    /// 调用方取消信号（原样传给取消令牌，作归属凭证）。
    required Completer<void>? cancel,

    /// 引擎流（已经各路线构建好请求参数）。
    required Stream<T> stream,

    /// 引擎事件 → 状态推进：processor/assembler 吃事件、推 onToken/onThinking
    /// 快照、工具调用生成期的 status 反馈（WP5）。
    required void Function(T event) onEvent,

    /// 思考失控守卫判定，每个事件后调用一次；null=未命中，否则返回触发
    /// 那一刻的累计思考字数（闩住，供失败文案）。口径唯一真源仍是
    /// [AgentStreamProcessor.thinkingRunaway]（原生路线无 processor，
    /// 用等价条件手写）。守卫只止损一次：stop 后事件可能仍在途，重复
    /// 判定会反复调 stop。
    required int? Function() thinkingOverflowCheck,

    /// 守卫触发时的止损动作（native stopGeneration / API stop）。
    required void Function() stopEngine,

    /// 流终态后的结果裁决——各路线策略差异全在这里：错误检查顺序、
    /// 失控抢救（已有产出照样交付）、空响应判定、usage 回填。
    required Future<LlmResult> Function(StreamFinalContext ctx) finalize,

    /// 流终态即时信号（onError/onDone 任一先到，恰好一次，早于 finally）：
    /// 本地路线据此停看门狗——从流结束到 finally 之间还有 finalize 的
    /// await 窗口，期间周期 tick 若再调 stopGeneration，共享引擎上会打到
    /// **别人**的生成（T3 场景），守卫必须在这里置位而不是 finally 里。
    void Function()? onStreamSettled,

    /// 兜底 catch 的失败归一化（local: mapEngineError(流错误)；
    /// API 文本: DioException 走 mapApiError，其余 transport）。
    required LlmFailure Function(Object error, Object? streamError)
        mapUnexpected,

    /// finally 尾部的路线专属清理（本地看门狗 Timer 取消、思考开关恢复）。
    /// 在流订阅取消与令牌注销之后执行（贴合旧 finally 的清理顺序）。
    Future<void> Function()? onFinally,
  }) async {
    final token = beginGeneration(cancel: cancel);
    StreamSubscription<T>? sub;
    // 流终态（null=干净完成，非 null=错误）。onError/onDone 谁先到都只
    // 完成一次；async* 生成器出错不关流 → 显式取消订阅（三条路线同款坑）。
    final outcome = Completer<Object?>();
    var finished = false;
    void finishStream(Object? err) {
      if (finished) return;
      finished = true;
      outcome.complete(err);
      // 终态即时通知（看门狗守卫置位）；回调不许抛，抛了会吞掉流终态。
      try {
        onStreamSettled?.call();
      } catch (_) {}
    }

    var thinkingOverflowed = false;
    var thinkingCharsAtTrigger = 0;
    try {
      sub = stream.listen(
        (event) {
          onEvent(event);
          if (!thinkingOverflowed) {
            final hit = thinkingOverflowCheck();
            if (hit != null) {
              thinkingOverflowed = true;
              thinkingCharsAtTrigger = hit;
              stopEngine();
            }
          }
        },
        onError: (Object e, [StackTrace? s]) {
          sub?.cancel();
          finishStream(e);
        },
        onDone: () => finishStream(null),
      );
      bindGenerationStream(token, sub);
      // 与 cancel 竞跑：cancel 先行则取消（令牌归属判定见 cancelOwnedGenerations）。
      if (await race(outcome.future, cancel)) {
        throw const AgentCancelledException();
      }
      return await finalize((
        thinkingOverflowed: thinkingOverflowed,
        thinkingCharsAtTrigger: thinkingCharsAtTrigger,
        streamError: await outcome.future,
      ));
    } on AgentCancelledException catch (_) {
      rethrow;
    } on LlmFailure catch (_) {
      rethrow;
    } catch (e) {
      throw mapUnexpected(e, outcome.isCompleted ? await outcome.future : null);
    } finally {
      sub?.cancel();
      // 槽位清理只在本令牌仍是当前令牌时执行（endGeneration 守卫，
      // 防止先结束的 generate 清掉后来者的 currentSub）。
      endGeneration(token);
      await onFinally?.call();
    }
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

  /// API 错误归一化（dio 异常）。4xx（除 429）为请求非法——确定性错误，
  /// 归 [LlmFailureCode.invalidRequest] 永久失败档（重试无意义）；
  /// 但 4xx 文案命中上下文溢出 → [LlmFailureCode.contextWindowExceeded]
  /// （走压缩瀑布，见 [mapApiStatus]）；429 → 限流，5xx → 服务端错误，均可重试。
  LlmFailureCode mapApiError(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return LlmFailureCode.timeout;
      case DioExceptionType.badResponse:
        return mapApiStatus(
          e.response?.statusCode,
          message: friendlyApiError(e),
        );
      default:
        return LlmFailureCode.transport;
    }
  }

  /// 上下文溢出文案特征（小写匹配）。各主流 OpenAI 兼容端点措辞不一，
  /// 宁可窄勿宽——误判会把真正的参数错误送去压缩重试（必失败）。
  static const List<String> _contextOverflowPatterns = [
    'context length',
    'context_length',
    'context window',
    'maximum context',
    'max context length',
    'prompt is too long',
    'too many input tokens',
    'input tokens exceed',
    'reduce the length',
    '上下文长度',
    '上下文窗口',
    '超出上下文',
    '超过上下文',
  ];

  /// message 是否为上下文溢出类错误文案。
  static bool isContextOverflowMessage(String? message) {
    if (message == null || message.isEmpty) return false;
    final lower = message.toLowerCase();
    for (final p in _contextOverflowPatterns) {
      if (lower.contains(p)) return true;
    }
    return false;
  }

  /// 按 HTTP 状态码分档失败类别（[OpenAiHttpException] 与 dio 共用）。
  ///
  /// [message]：错误详情文案（含响应体时）。4xx 且文案命中上下文溢出
  /// （OpenAI/DeepSeek/Qwen 等的 "maximum context length is N tokens"）→
  /// 归 [LlmFailureCode.contextWindowExceeded]——失败瀑布第一步触发压缩、
  /// 压缩成功后有界重试；否则 4xx 归 invalidRequest（终态失败）。
  LlmFailureCode mapApiStatus(int? statusCode, {String? message}) {
    if (statusCode == 429) return LlmFailureCode.rateLimit;
    if (statusCode != null && statusCode >= 500) {
      return LlmFailureCode.server;
    }
    if (statusCode != null && statusCode >= 400) {
      if (isContextOverflowMessage(message)) {
        return LlmFailureCode.contextWindowExceeded;
      }
      return LlmFailureCode.invalidRequest;
    }
    return LlmFailureCode.transport;
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
