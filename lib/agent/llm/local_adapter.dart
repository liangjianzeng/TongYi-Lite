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

import 'package:flutter/foundation.dart';

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

  /// 用户的全局思考开关（本步是否需要"恢复思考"的判据）。
  ///
  /// [GenerateOptions.forceNoThinking] 为真时临时把原生 enableThinking 关掉，
  /// 生成结束必须按这个值恢复，否则会把用户的设置悄悄改掉。
  final bool _thinkingEnabled;

  /// 流式无增量看门狗（C4，对齐 API 档 StallException）：超过该时长没有任何
  /// token/状态增量 → stopGeneration 止损并按 timeout 失败归档。
  /// 默认 120s——必须覆盖合法慢 prefill（2026-11-07 真机：830 上一次
  /// 14-token 首 prompt decode 卡过 104s，低于它会误杀长 prefill）。
  final Duration stallTimeout;

  LocalEngineAdapter({
    required InferenceService inference,
    required ToolProtocol protocol,
    EngineCapabilities? capabilities,
    int maxThinkingChars = kMaxThinkingChars,
    bool thinkingEnabled = false,
    this.stallTimeout = const Duration(seconds: 120),
  })  : _inference = inference,
        _maxThinkingChars = maxThinkingChars,
        _thinkingEnabled = thinkingEnabled,
        super(protocol: protocol, capabilities: capabilities);

  /// 取消：中止「归属本次取消」的 Dart 侧流（基类令牌条件），存在归属
  /// 目标才通知 native 引擎停生成——共享 adapter 下子代理的流/生成
  /// （其取消信号未触发）不得被父回合的 cancel() 误杀（T3 缺陷）。
  @override
  void cancel() {
    if (cancelOwnedGenerations()) {
      _inference.stopGeneration();
    }
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

    // 本步强制不思考（工具决策步 / 思考失控后的重试）：临时关原生思考开关，
    // finally 里按用户设置恢复。端侧思考失控的止损主力——工具步根本不需要思考。
    final suppressThinking = options.forceNoThinking && _thinkingEnabled;
    if (suppressThinking) {
      await _inference.setEnableThinking(false);
    }

    final messagesJson = jsonEncode(
        convertEngineMessages(options.messages, modelId: options.modelId));
    final rawBuffer = StringBuffer();
    final processor = AgentStreamProcessor();
    var _streamFinished = false;
    // WP5：工具调用块生成中标记（status 流只在状态翻转/持续时推）。
    var _toolGenActive = false;
    // C4 看门狗：无增量止损。token/状态任一增量都刷新 _lastActivity；
    // 周期检查超 [stallTimeout] → stopGeneration + 置 _stalled（流结束
    // 后按 timeout 失败归档——用户手停语义与挂死语义分开）。
    var _lastActivity = DateTime.now();
    var _stalled = false;
    final _stallWatch = Timer.periodic(const Duration(seconds: 5), (_) {
      // 流已终态（onStreamSettled 置位）→ 不许再碰引擎：共享引擎上
      // stopGeneration 打到的是别人的生成。
      if (_streamFinished) return;
      final idle = DateTime.now().difference(_lastActivity);
      if (idle >= stallTimeout) {
        _stalled = true;
        debugPrint('[AgentLlm] 流式挂死看门狗：无增量 ${idle.inSeconds}s '
            '→ stopGeneration 止损');
        _inference.stopGeneration();
      }
    });
    try {
      final sourceStream = _inference.completionWithMessages(
        prompt: '',
        messagesJson: messagesJson,
        imagePath: options.imagePath,
        // 多图全量送原生（长图切块序列）：mtmd 按序逐张编码。
        imagePaths: options.imagePaths,
        audioPath: options.audioPath,
        maxTokens: options.maxTokens ?? 512,
        temperature: options.temperature,
        topP: 0.9,
      );
      // 流消费骨架（守卫+终态+取消令牌+cancel 竞跑+清理）走基类
      // runStreamWithGuards（T4 收敛，此前与 API 两条路线三份复制）；
      // 本路线只注入差异：token 解析、口径判定、终态裁决顺序、失败归一化。
      return await runStreamWithGuards<String>(
        cancel: cancel,
        stream: sourceStream,
        onEvent: (token) {
          if (token.isEmpty) return;
          _lastActivity = DateTime.now();
          rawBuffer.write(token);
          processor.add(token);
          if (onToken != null) {
            onToken.add(processor.visibleText);
          }
          if (onThinking != null) {
            onThinking.add(processor.thinkingText);
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
        // 思考失控守卫（口径唯一真源：AgentStreamProcessor.thinkingRunaway）：
        // **跨块累计**思考超预算且本步还没有有用产出 → 主动 stopGeneration
        // 止损。旧口径只量「当前块长」，模型 think…response 反复横跳时每块
        // 归零 → 4 万字独白畅通无阻（用户报的"思考超 32k"），实测已复现。
        thinkingOverflowCheck: () =>
            processor.thinkingRunaway(_maxThinkingChars)
                ? processor.thinkingCharsSoFar
                : null,
        stopEngine: () => _inference.stopGeneration(),
        onStreamSettled: () => _streamFinished = true,
        finalize: (ctx) async {
          // 本地路线先查流错误再看守卫：引擎错误是真失败，失控只是伴生
          // 现象（检查顺序差异的理由见 runStreamWithGuards 文档）。
          if (ctx.streamError != null) {
            throw LlmFailure(
              code: mapEngineError('${ctx.streamError}'),
              message: '${ctx.streamError}',
            );
          }
          // C4 看门狗止损判档：已产出可交付 → 照常返回；无产出 → timeout。
          if (_stalled) {
            if (processor.hasToolCalls ||
                processor.visibleText.trim().length >=
                    AgentStreamProcessor.kMinUsefulChars) {
              debugPrint('[AgentLlm] 看门狗止损但已有产出可交付 → 照常返回');
              return _withLocalUsage(await parseAndReturn(rawBuffer, processor));
            }
            throw LlmFailure(
              code: LlmFailureCode.timeout,
              message: '本地引擎挂死：超过 ${stallTimeout.inSeconds}s 无任何增量，'
                  '已主动止损。若长 prefill 频繁触发，可在 设置→智能体 检查'
                  '上下文设置或换更小模型',
            );
          }
          if (ctx.thinkingOverflowed) {
            // 先抢救，再判死：止损前已产出的工具调用/答案照样有效。
            // 旧行为是直接丢弃整步产出并抛错 → 端侧用户白等几分钟还整轮失败。
            if (processor.hasToolCalls ||
                processor.visibleText.trim().length >=
                    AgentStreamProcessor.kMinUsefulChars) {
              debugPrint('[AgentLlm] 思考失控已止损'
                  '（累计 ${ctx.thinkingCharsAtTrigger} 字），'
                  '但已有产出可交付 → 照常返回结果');
              return _withLocalUsage(await parseAndReturn(rawBuffer, processor));
            }
            // 文案唯一真源 BaseEngineAdapter.thinkingOverflowFailure；
            // 本地尾巴：端侧有原生思考开关可关，多一句提示。
            throw BaseEngineAdapter.thinkingOverflowFailure(
              ctx.thinkingCharsAtTrigger,
              _maxThinkingChars,
              tail: '或关闭该模型思考模式',
            );
          }
          return _withLocalUsage(await parseAndReturn(rawBuffer, processor));
        },
        mapUnexpected: (e, streamError) => LlmFailure(
          code: mapEngineError('${streamError ?? ''}'),
          message: '本地引擎调用失败: $e',
        ),
        onFinally: () async {
          _stallWatch.cancel();
          // 恢复用户的思考开关（本步曾为止损临时关掉）。失败不改变本步结论。
          if (suppressThinking) {
            try {
              await _inference.setEnableThinking(true);
            } catch (_) {}
          }
        },
      );
    } on AgentCancelledException catch (_) {
      rethrow;
    } on LlmFailure catch (_) {
      rethrow;
    } catch (e) {
      // 只剩流构造等同步异常能到这里（骨架内的错误已由 mapUnexpected
      // 归一化为 LlmFailure，骨架 finally 的 onFinally 已停过表）；
      // 此处兜底停表 + 保持旧行为：按引擎错误文案归档。
      _stallWatch.cancel();
      throw LlmFailure(
        code: mapEngineError(''),
        message: '本地引擎调用失败: $e',
      );
    }
  }

  /// C4：本地 usage 回传——生成刚结束，原生 stats 即本次的真实计数。
  /// {prompt_tokens: n_prompt, completion_tokens: n_gen}（B5 起原生带
  /// n_prompt）；查询失败/全零 → null（usage 缺省语义不变）。
  /// 此前本地 usage 恒 null：回合成本只有估算、失败码里没有真用量。
  Future<Map<String, dynamic>?> _readLocalUsage() async {
    try {
      final stats = await _inference.getInferenceStats();
      final prompt = (stats['n_prompt'] as num?)?.toInt() ?? 0;
      final gen = (stats['n_gen'] as num?)?.toInt() ?? 0;
      if (prompt <= 0 && gen <= 0) return null;
      return <String, dynamic>{
        'prompt_tokens': prompt,
        'completion_tokens': gen,
      };
    } catch (_) {
      return null;
    }
  }

  Future<LlmResult> _withLocalUsage(LlmResult result) async {
    final usage = await _readLocalUsage();
    if (usage == null) return result;
    return LlmResult(
      text: result.text,
      toolCalls: result.toolCalls,
      usage: usage,
    );
  }
}
