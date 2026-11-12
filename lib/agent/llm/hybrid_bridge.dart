/// [npu-line M2 Phase C] 混合调度编排层（NPU prefill + GPU decode）。
///
/// 把 native 混合链（android/app/src/main/cpp/hyb_jni.cpp + hyb_kv_bridge.c）
/// 的两步握手收成一个可单测的纯编排面：
///
///   startHybridPrefill → bridgeAndResumeDecode
///
/// 契约 = 结构化 outcome（{ok, code, stage, message, ...}，code ∈ HYB_*）。
/// **本层不做回退决策、不持任何跨调用状态**：任何非 ok 结果（链 helper 未
/// 接线 / KV 缺片 / 桥转失败 / state load 未启用 / 通道异常 / 超时）由
/// [LocalEngineAdapter] 判为「混合不可用」→ 自动回退纯 GPU decode 现路径
/// （默认开关 OFF = 现行为零回归，红线）。
///
/// 冻结协议常量（计划 §6.1/§6.2，与 hyb_kv_bridge.h HYB_* 同源）：
///   NC=512 链窗；pos 基 = 88（A5/172 无-pad 协议）；NREAL=真实 token 数
///   （eos-pad cell 必须剪掉——协议级要求，native prefill 产出真值）。
///
/// Phase C-2 现状：两步均为真实路径。startPrefill 拉起 chain_run5 三段
/// （manifest 驱动，native 侧 execve+监督，回包带 n_real/ids_path，
/// first_tok=-1 时 native 在 decode 前用「末 token 重算一步」出真实首
/// token）；bridgeAndResumeDecode 桥转 → llama_state_seq_load_file → GPU
/// 续 decode，整段文本在 MethodChannel 回包 `text` 中一次带回（token 级
/// 流式 ack 协议留 C-3）。任何非 ok → 调用方回退纯 GPU。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;

import '../../services/inference_service.dart';

/// 混合链单次回合的工作文件（native 读写）。
class HybridWorkPaths {
  final String kvDir; // 84 片 kc/vc raw 目录
  final String idsPath; // i32 LE token ids（ids.raw）
  final String statePath; // 桥转产出的官方 state 容器

  const HybridWorkPaths({
    required this.kvDir,
    required this.idsPath,
    required this.statePath,
  });
}

/// native 结构化回包的类型化视图。
class HybridOutcome {
  final bool ok;
  final String code;
  final String stage;
  final String message;
  final Map<String, dynamic> raw;

  const HybridOutcome({
    required this.ok,
    required this.code,
    required this.stage,
    required this.message,
    required this.raw,
  });

  factory HybridOutcome.from(Map<String, dynamic> m) {
    return HybridOutcome(
      ok: m['ok'] == true,
      code: (m['code'] ?? 'HYB_ERR_UNKNOWN').toString(),
      stage: (m['stage'] ?? '?').toString(),
      message: (m['message'] ?? '').toString(),
      raw: m,
    );
  }

  factory HybridOutcome.failure(String code, String stage, [String msg = '']) {
    return HybridOutcome(
      ok: false,
      code: code,
      stage: stage,
      message: msg,
      raw: const {},
    );
  }

  bool get notEnabled => code == 'HYB_ERR_NOT_ENABLED';

  // [npu-line M2 D5] 回包字段一律 is-守护取值（审读 D5）：契约是「任何非
  // ok/畸形回包 → 回退 GPU」，裸 as 在类型错字段（如 "n_real":"120"）时抛
  // TypeError 逃逸出回退路径、把整个回合打死。守护取值 → null → 上层判
  // 缺失 → 回退，与畸形 JSON 兜底同一语义。
  int? _int(String k) => raw[k] is num ? (raw[k] as num).toInt() : null;
  String? _str(String k) => raw[k] is String ? raw[k] as String : null;
  int? get nReal => _int('n_real');
  int? get firstTok => _int('first_tok');
  int? get posBase => _int('pos_base');
  int? get nGen => _int('n_gen');
  int? get loadMs => _int('load_ms');
  String? get idsPath => _str('ids_path');
  String? get statePath => _str('state_path');
  String? get text => _str('text'); // C-2 起非空
  String? get stopped => _str('stopped'); // 用户止损时 native 回 'user'

  @override
  String toString() =>
      'HybridOutcome(ok=$ok, code=$code, stage=$stage, message=$message)';
}

/// [runTurn] 的成功产物（回合文本 + usage 真值）；失败回 null（调用方回退 GPU）。
class HybridTurn {
  final String text;
  final int nReal;
  final int? nGen;
  final int? loadMs;
  const HybridTurn({
    required this.text,
    required this.nReal,
    this.nGen,
    this.loadMs,
  });
}

/// 两步握手的编排入口（无状态；全部失败路径回 ok=false 不 throw）。
class HybridBridge {
  HybridBridge._();

  // 冻结协议常量（MiniCPM5-2B + chain_run5，计划 §6）。
  static const int nc = 512; // 链窗
  static const int nLayers = 42;
  static const int posBase = 88; // A5/172 协议 pos 基

  /// 链式 manifest（chain_run5 三段串行，mcp5_95_run_a3b_seq.py 同源协议）。
  static const List<String> defaultManifests = [
    'manifest_pre2_A',
    'manifest_pre2_B',
    'manifest_pre2_C',
  ];
  static const int nChunks = 4; // 每段链步数（d2q_emb_0..3）

  /// prefill 步上限。native 三段串行、每段上限 [prefillSegTimeout]（40s：
  /// 实测 3.72s/chunk × 4 chunk + 冷启动图加载富余），native 侧是硬超时与
  /// 回收者（进程 SIGKILL + p{k}.log 回收）；本层截止取 150s > 3×40s+开销，
  /// 只兜「通道挂死」——若本层先到期，引擎线程仍被链占着，回退 GPU 会被
  /// 排队拖住，故宁松勿紧。
  static const Duration prefillTimeout = Duration(seconds: 150);
  static const int prefillSegTimeoutMs = 40000;

  /// decode 步上限：state load + 逐 token GPU decode（maxTokens 上界 512），
  /// 端侧 ~10-25 tok/s → 分钟级；超时同样判失败回退（此时未吐任何 token）。
  static const Duration decodeTimeout = Duration(minutes: 5);

  /// 建单次回合的工作目录（temp/hyb_m2_*）。失败回 null（调用方回退）。
  static Future<HybridWorkPaths?> prepareWorkDir() async {
    try {
      final base = await Directory.systemTemp.createTemp('hyb_m2_');
      final kvDir = Directory('${base.path}/npu_kv');
      await kvDir.create(recursive: true);
      return HybridWorkPaths(
        kvDir: kvDir.path,
        idsPath: '${base.path}/ids.raw',
        statePath: '${base.path}/hyb.state',
      );
    } catch (e) {
      debugPrint('[HybridBridge] prepareWorkDir failed: $e');
      return null;
    }
  }

  /// 资产就绪（尽力而为）：chain_run5/manifest/QNN .so 由 APK assets 解包到
  /// filesDir/npu_m1（NpuAssets.kt）。幂等且已存在即跳过，每次 prefill 前
  /// 低成本调用一次；解包失败不阻断——native 预检会给 stage=prefill_bin 的
  /// 结构化错误，调用方照常回退 GPU。
  static Future<void> ensureAssets(InferenceService inference) async {
    try {
      await inference.extractNpuAssets().timeout(const Duration(seconds: 20));
    } catch (e) {
      debugPrint('[HybridBridge] ensureAssets failed (non-fatal): $e');
    }
  }

  /// 步骤 1：拉起 NPU 分层链（chain_run5 三段串行）收 84 片 KV。
  /// prompt 经 [messagesJson]/[prompt] 交给 native，用 GPU 路径同款模板 +
  /// 分词产出 ids.raw（回包 n_real/ids_path 为真值）。
  static Future<HybridOutcome> startPrefill(
    InferenceService inference, {
    required String kvDir,
    required String idsPath,
    String? chainDir,
    String? chainBin,
    String? qnnLibDir,
    List<String>? manifests,
    int? nChunksOverride,
    String? prompt,
    String messagesJson = '[]',
  }) async {
    try {
      final r = await inference
          .startHybridPrefill(
            kvDir: kvDir,
            idsPath: idsPath,
            chainDir: chainDir,
            chainBin: chainBin,
            qnnLibDir: qnnLibDir,
            manifests: manifests ?? defaultManifests,
            nChunks: nChunksOverride ?? nChunks,
            prompt: prompt,
            messagesJson: messagesJson,
            nRealCap: nc,
            timeoutMs: prefillSegTimeoutMs,
          )
          .timeout(prefillTimeout);
      return HybridOutcome.from(r);
    } on TimeoutException {
      debugPrint('[HybridBridge] startPrefill timeout');
      return HybridOutcome.failure('HYB_ERR_TIMEOUT', 'prefill_timeout');
    } catch (e) {
      debugPrint('[HybridBridge] startPrefill threw: $e');
      return HybridOutcome.failure('HYB_ERR_EXCEPTION', 'prefill', '$e');
    }
  }

  /// 步骤 2：native 桥转 → state load → 从 [firstTok] 续 decode。
  /// [firstTok] <0 时 native 先「重算末 prompt token 一步」取 argmax 作首
  /// token（计划 §1.3 兜底路线）。整段回复文本在回包 `text`（token 级流式
  /// 协议留 C-3）。
  static Future<HybridOutcome> bridgeAndResumeDecode(
    InferenceService inference, {
    required HybridWorkPaths paths,
    required int nReal,
    required int firstTok,
    int? posBaseOverride,
    required int maxTokens,
    required double temperature,
    double topP = 0.9,
  }) async {
    try {
      final r = await inference
          .bridgeAndResumeDecode(
            kvDir: paths.kvDir,
            idsPath: paths.idsPath,
            outPath: paths.statePath,
            nReal: nReal,
            firstTok: firstTok,
            posBase: posBaseOverride ?? posBase,
            maxTokens: maxTokens,
            temperature: temperature,
            topP: topP,
          )
          .timeout(decodeTimeout);
      return HybridOutcome.from(r);
    } on TimeoutException {
      debugPrint('[HybridBridge] bridgeAndResumeDecode timeout');
      return HybridOutcome.failure('HYB_ERR_TIMEOUT', 'bridge_timeout');
    } catch (e) {
      debugPrint('[HybridBridge] bridgeAndResumeDecode threw: $e');
      return HybridOutcome.failure('HYB_ERR_EXCEPTION', 'bridge', '$e');
    }
  }

  /// 完整混合回合的**唯一编排真源**：workDir → 资产 → prefill → 桥转 → state
  /// load → GPU 续 decode → 工作目录清理（finally）。成功回 [HybridTurn]，
  /// 任何一步不 ok 回 null——调用方回退纯 GPU（零回归红线）。
  ///
  /// 两个调用面共用本函数（协议单点，防漂移）：
  ///  - `LocalEngineAdapter._attemptHybridDecode`（agent/新 seam 路径：外裹
  ///    cancel 令牌 D1、processor/LlmResult/usage D3/D4）；
  ///  - `ConversationsNotifier` 普通聊天本地路线（C-3 设备窗口定罪：UI 发消息
  ///    走 chat_provider 直调 completionWithMessages，**不经过 LlmAdapter**，
  ///    混合分支必须在这里也有入口，否则设置开关对普通聊天永远无效）。
  ///
  /// [cancelled] 逐段检查（prefill 前/后、decode 后）；命中回 null 语义 = 调用方
  /// 自行按取消处理（agent 侧抛 AgentCancelledException）。
  /// [stopped]=='user'（native 外部止损，partial text 不可当完整答案）回 null。
  static Future<HybridTurn?> runTurn(
    InferenceService inference, {
    required String messagesJson,
    required int maxTokens,
    required double temperature,
    bool Function()? cancelled,
  }) async {
    if (cancelled?.call() ?? false) return null;
    final work = await prepareWorkDir();
    if (work == null) return null;
    try {
      // NPU 链资产（chain_run5/manifest/QNN .so）解包幂等低成本；失败不阻断
      // ——native 预检给 stage=prefill_* 结构化错误，同样回退。
      await ensureAssets(inference);

      final pre = await startPrefill(
        inference,
        kvDir: work.kvDir,
        idsPath: work.idsPath,
        messagesJson: messagesJson,
      );
      if (!pre.ok) {
        debugPrint('[HybridBridge] prefill 不可用: $pre');
        return null;
      }
      if (cancelled?.call() ?? false) return null;

      // NREAL（无-pad 协议真实 token 数）与 ids 文件以 native 为权威；缺失即
      // 协议不满足 → 回退。首 token：prefill 回包恒 -1，native decode 前
      // 「重算末 prompt token 一步」取 argmax（计划 §1.3 兜底路线）。
      final nReal = pre.nReal;
      final idsPath = pre.idsPath;
      if (nReal == null || nReal < 1) {
        debugPrint('[HybridBridge] prefill 回包缺 n_real → 回退');
        return null;
      }

      final dec = await bridgeAndResumeDecode(
        inference,
        paths: HybridWorkPaths(
          kvDir: work.kvDir,
          idsPath: idsPath ?? work.idsPath,
          statePath: work.statePath,
        ),
        nReal: nReal,
        firstTok: pre.firstTok ?? -1,
        posBaseOverride: pre.posBase,
        maxTokens: maxTokens,
        temperature: temperature,
      );
      if (!dec.ok) {
        debugPrint(
            '[HybridBridge] 桥转/decode 不可用: $dec (state=${dec.statePath})');
        return null;
      }
      if (cancelled?.call() ?? false) return null;
      // [npu-line M2 D2] native 用户止损回 ok:true + partial text——半截贪心
      // 文本绝不作完整回复提交（外部 stopGeneration 语义）。
      if (dec.stopped == 'user') {
        debugPrint('[HybridBridge] decode 被外部止损（stopped=user）→ 回退 GPU');
        return null;
      }
      final text = dec.text;
      if (text == null || text.isEmpty) {
        debugPrint('[HybridBridge] decode ok 但 text 空 → 回退');
        return null;
      }
      debugPrint('[HybridBridge] 混合生成完成 (NPU prefill + GPU decode), '
          'len=${text.length}, state=${dec.statePath}');
      return HybridTurn(
          text: text, nReal: nReal, nGen: dec.nGen, loadMs: dec.loadMs);
    } finally {
      // [npu-line M2 D6] 84 片 KV + state 容器是回合中间产物 → 出口尽力删。
      try {
        await Directory(File(work.statePath).parent.path)
            .delete(recursive: true);
      } catch (_) {}
    }
  }
}
