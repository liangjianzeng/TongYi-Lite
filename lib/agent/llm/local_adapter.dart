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
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../providers/agent_stream_processor.dart';
import '../../services/inference_service.dart';
import 'adapter.dart';
import 'base_engine_adapter.dart';
import 'hybrid_bridge.dart';
import '../capability.dart';
import '../observability/quiet_fail.dart';
import '../protocol/tool_protocol.dart';

class LocalEngineAdapter extends BaseEngineAdapter {
  final InferenceService _inference;

  /// [npu-line M2 Phase C] NPU prefill + GPU decode 混合路径开关
  /// （设置→推理引擎→NPU 混合调度，**默认 OFF**）。
  /// OFF 时 [generate] 的混合分支短路——现路径逐字节不变（零回归红线）。
  final bool _hybridPrefillEnabled;

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
    bool hybridPrefillEnabled = false,
  })  : _inference = inference,
        _maxThinkingChars = maxThinkingChars,
        _thinkingEnabled = thinkingEnabled,
        _hybridPrefillEnabled = hybridPrefillEnabled,
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
    // [npu-line M2 D2] 本回合混合尝试进行中（闭包局部，非实例字段——
    // 共享 adapter 下子代理/父回合并发时实例标志会互相误静默看门狗）。
    var _hybridActiveLocal = false;
    final _stallWatch = Timer.periodic(const Duration(seconds: 5), (_) {
      // 流已终态（onStreamSettled 置位）→ 不许再碰引擎：共享引擎上
      // stopGeneration 打到的是别人的生成。
      if (_streamFinished) return;
      // [npu-line M2 D2] 混合尝试期本看门狗让位：prefill/decode 自带
      // 150s/300s 硬超时（hybrid_bridge），双层判死只会让 120s 无增量
      // 误杀长混合回合、把半截贪心文本当完整回复提交（审读 D2）。
      if (_hybridActiveLocal) return;
      final idle = DateTime.now().difference(_lastActivity);
      if (idle >= stallTimeout) {
        _stalled = true;
        debugPrint('[AgentLlm] 流式挂死看门狗：无增量 ${idle.inSeconds}s '
            '→ stopGeneration 止损');
        _inference.stopGeneration();
      }
    });
    try {
      // [npu-line M2 Phase C] NPU prefill + GPU decode 混合路径
      // （设置→推理引擎→NPU 混合调度，默认 OFF；OFF 时本分支短路，
      // 下面现路径逐字节不变——零回归红线）。
      // 任何一步失败（链未接线 / KV 缺片 / 桥转失败 / load 未启用 /
      // 通道异常 / 超时）→ null → 自动回退纯 GPU decode 现路径。
      // 混合链只覆盖主靶文本 prefill：视觉/音频输入不走。
      if (_hybridPrefillEnabled && _hybridEligible(options)) {
        // [npu-line M2 D1] 注册取消令牌：混合期（prefill ≤150s + decode
        // ≤300s，无 Dart token 流）cancel() 经 cancelOwnedGenerations()==true
        // 触达 native stopGeneration（decode 循环逐迭代查 should_stop 秒停）。
        // 此前混合期 _activeTokens 为空 → 停止按钮对 Dart/native 双双失效。
        _hybridActiveLocal = true;
        final hybridToken = beginGeneration(cancel: cancel);
        LlmResult? hybrid;
        try {
          hybrid = await _attemptHybridDecode(
              options, messagesJson, onToken, onThinking, cancel);
        } finally {
          endGeneration(hybridToken);
          _hybridActiveLocal = false;
        }
        if (hybrid != null) return hybrid;
        debugPrint('[AgentLlm][Hybrid] 混合链不可用 → 自动回退纯 GPU decode（现路径）');
        // 回退后重锚看门狗：混合尝试消耗的秒数不应计入流增量判死。
        _lastActivity = DateTime.now();
      }

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
              return _withLocalUsage(
                  await parseAndReturn(rawBuffer, processor));
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
              return _withLocalUsage(
                  await parseAndReturn(rawBuffer, processor));
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
          // 恢复用户的思考开关（本步曾为止损临时关掉）。失败不改变本步结论，
          // 但必须留痕：无痕迹意味着用户的思考设置被悄悄关掉而无人知晓。
          if (suppressThinking) {
            try {
              await _inference.setEnableThinking(true);
            } catch (e) {
              quietFail('local.restore-thinking', e);
            }
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

  // ------------------------------------------------------------------
  // [npu-line M2 Phase C] 混合路径（NPU prefill + KV 桥 + GPU decode）
  // 编排面在 hybrid_bridge.dart；回退决策全部收在本类（默认 OFF，任何
  // 失败回退现路径，现行为零回归）。
  // ------------------------------------------------------------------

  /// 混合链只覆盖文本 prefill（主靶 MiniCPM5-2B）：带图/音输入不走。
  bool _hybridEligible(GenerateOptions options) {
    if (options.imagePath != null) return false;
    final imgs = options.imagePaths;
    if (imgs != null && imgs.isNotEmpty) return false;
    if (options.audioPath != null) return false;
    return true;
  }

  /// 混合回合尝试：prefill → 桥转 → state load → GPU 续 decode。成功返回
  /// [LlmResult]；任何一步不 ok 返回 null，调用方回退现路径。cancel 命中抛
  /// [AgentCancelledException]（与现路径取消语义一致）。
  Future<LlmResult?> _attemptHybridDecode(
    GenerateOptions options,
    String messagesJson,
    StreamController<String>? onToken,
    StreamController<String>? onThinking,
    Completer<void>? cancel,
  ) async {
    if (cancel?.isCompleted ?? false) throw const AgentCancelledException();

    final work = await HybridBridge.prepareWorkDir();
    if (work == null) return null;
    // [npu-line M2 D6] 混合工作目录（84 片 KV + 9MB state 容器）是回合中间
    // 产物，路径已入日志可事后取证 → 出口 finally 尽力删除，防每回合泄漏。
    try {
      // NPU 链资产（chain_run5/manifest/QNN .so）解包到私有目录，幂等低成本；
      // 失败不阻断——native 预检给 stage=prefill_* 结构化错误，同样回退。
      await HybridBridge.ensureAssets(_inference);

      // 步骤 1：NPU prefill（chain_run5 三段串行收 84 片 KV；native 用 GPU
      // 路径同款模板+分词由 messagesJson 产出 ids.raw，回包 n_real/ids_path）
      final pre = await HybridBridge.startPrefill(
        _inference,
        kvDir: work.kvDir,
        idsPath: work.idsPath,
        messagesJson: messagesJson,
      );
      if (!pre.ok) {
        debugPrint('[AgentLlm][Hybrid] prefill 不可用: $pre');
        return null;
      }
      if (cancel?.isCompleted ?? false) throw const AgentCancelledException();

      // NREAL（真实 token 数，无-pad 协议）与 ids 文件以 native 为权威；缺失
      // 即协议不满足 → 回退。首 token：prefill 回包恒 -1，native 在 decode 前
      // 「重算末 prompt token 一步」取 argmax（计划 §1.3 兜底路线）。
      final nReal = pre.nReal;
      final idsPath = pre.idsPath;
      if (nReal == null || nReal < 1) {
        debugPrint('[AgentLlm][Hybrid] prefill 回包缺 n_real → 回退');
        return null;
      }

      // 步骤 2：桥转 → llama_state_seq_load_file → 续 decode
      final dec = await HybridBridge.bridgeAndResumeDecode(
        _inference,
        paths: HybridWorkPaths(
          kvDir: work.kvDir,
          idsPath: idsPath ?? work.idsPath,
          statePath: work.statePath,
        ),
        nReal: nReal,
        firstTok: pre.firstTok ?? -1,
        posBaseOverride: pre.posBase,
        maxTokens: options.maxTokens ?? 512,
        temperature: options.temperature,
      );
      if (!dec.ok) {
        debugPrint('[AgentLlm][Hybrid] 桥转/decode 不可用: $dec '
            '(state=${dec.statePath})');
        return null;
      }
      if (cancel?.isCompleted ?? false) throw const AgentCancelledException();
      // [npu-line M2 D2] native 的用户止损同样回 ok:true + partial text
      // （hyb_jni user-stop 契约）。非本回合手停却见 stopped=user ⇒ 外部
      // 止损（如引擎侧 stopGeneration）→ 回退 GPU 重生成完整答案，
      // 绝不把半截贪心文本当完整回复提交。
      if (dec.stopped == 'user') {
        debugPrint('[AgentLlm][Hybrid] decode 被外部止损（stopped=user）→ 回退 GPU');
        return null;
      }

      // C-2：native 回完整 text（token 流式形态待设备侧 ack 协议接线，见
      // hybrid_bridge.dart 头注释）。空文本按失败回退，不污染现路径语义。
      final text = dec.text;
      if (text == null || text.isEmpty) {
        debugPrint('[AgentLlm][Hybrid] decode ok 但 text 空 → 回退');
        return null;
      }

      final rawBuffer = StringBuffer(text);
      final processor = AgentStreamProcessor();
      processor.add(text);
      if (onToken != null) onToken.add(processor.visibleText);
      if (onThinking != null) onThinking.add(processor.thinkingText);
      debugPrint('[AgentLlm][Hybrid] 混合生成完成 (NPU prefill + GPU decode), '
          'len=${text.length}, state=${dec.statePath}');
      // [npu-line M2 D3/D4] usage 取回包真值：native g_last_stats 只由 GPU
      // 路径写（hyb_jni 零写入），旧 _readLocalUsage 在混合回合报的是上一
      // GPU 回合的陈旧计数。采样诚实化：混合续解码是贪心 argmax（C-3 前
      // 冻结配方），usage 声明 + 温度被弃时日志一行。
      final parsed = await parseAndReturn(rawBuffer, processor);
      final usage = <String, dynamic>{
        'prompt_tokens': nReal,
        'engine': 'npu_prefill+gpu_decode',
        'sampling': 'greedy',
      };
      final nGen = dec.nGen;
      if (nGen != null) usage['completion_tokens'] = nGen;
      final loadMs = dec.loadMs;
      if (loadMs != null) usage['load_ms'] = loadMs;
      if (options.temperature > 0) {
        debugPrint('[AgentLlm][Hybrid] 混合回合强制贪心（temperature='
            '${options.temperature} 未生效；真采样在 C-3 排期）');
      }
      return LlmResult(
        text: parsed.text,
        toolCalls: parsed.toolCalls,
        usage: usage,
      );
    } finally {
      try {
        await Directory(File(work.statePath).parent.path)
            .delete(recursive: true);
      } catch (_) {}
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

  Future<LlmResult> _withLocalUsage(LlmResult result, {String? engine}) async {
    final usage = await _readLocalUsage();
    final merged = <String, dynamic>{...?usage};
    if (engine != null) merged['engine'] = engine;
    if (merged.isEmpty) return result;
    return LlmResult(
      text: result.text,
      toolCalls: result.toolCalls,
      usage: merged,
    );
  }
}
