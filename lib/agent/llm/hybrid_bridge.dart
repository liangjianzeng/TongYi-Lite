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
import 'package:path_provider/path_provider.dart';

import '../../services/inference_service.dart';
import '../adb/adb_client.dart';
import '../adb/adb_connection.dart' show AdbTransportException;
import '../adb/adb_rsa.dart';

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

  // =========================================================================
  // [npu-line M3-shell] shell 域混合模式：App 进程域跑 QNN 判死（计划 §7.6bis
  // 域墙：deviceCreate 0x36b1，MIUI 对 App uid 关 Hexagon fastrpc，targetSdk27
  // 逃生门亦死），而 shell 域同二进制全绿（工具级判卷 50/50）。本模式把
  // prefill 派发到 **App 自带 adb 通道**（AdbClient 自连本机 adbd TCP 5555）
  // 的 shell 域执行：native 只做 tokenize+feeds（feedsOnly）→ adb push 12 件
  // → 三段 chain_run5（工具级硬化协议：rm log + DONE 伴 CR5 segs= 头行 +
  // 三击死亡）→ adb pull 84 片 KV → 回 App 进程走既有 native 桥转 + GPU
  // decode。任何一步失败 → null → 调用方回退纯 GPU（零回归红线不变）。
  // 信任模型 = 开发者/评测路径（与 PC 侧工具面同一授权域：需设备 adbd TCP
  // 已开且 App 持已授权 RSA 私钥；§7.4 ① 的机内变体）。
  // =========================================================================

  static const List<String> _shellFeedFiles = [
    'd2q_emb_0.raw',
    'd2q_emb_1.raw',
    'd2q_emb_2.raw',
    'd2q_emb_3.raw',
    'd2q_am_0.raw',
    'd2q_am_1.raw',
    'd2q_am_2.raw',
    'd2q_am_3.raw',
    'd2q_cos_table.raw',
    'd2q_sin_table.raw',
    'd2q_kc0.raw',
    'd2q_vc0.raw',
  ];

  /// 开发者/评测密钥：App 专属外置目录 `adbkey.pem`（adb shell 可写 → 免 UI
  /// 贴 key；与 ~/.android/adbkey 同格式，AdbRsaKeyPair.fromPem 直收）。
  /// 生产分发（M3 议题）时改走 secure store + 设置页导入。
  static Future<AdbRsaKeyPair?> loadDeveloperKey() async {
    try {
      final dir = await getExternalStorageDirectory();
      if (dir == null) return null;
      final f = File('${dir.path}/adbkey.pem');
      if (!await f.exists()) return null;
      return AdbRsaKeyPair.fromPem(await f.readAsString());
    } catch (e) {
      debugPrint('[HybridShell] loadDeveloperKey failed: $e');
      return null;
    }
  }

  static void _t(String stage, Stopwatch sw) {
    debugPrint('[HybridShell][T] stage=$stage ms=${sw.elapsedMilliseconds}');
    sw
      ..reset()
      ..start();
  }

  /// shell 域混合回合（与 [runTurn] 同契约：成功回 [HybridTurn]，任何一步
  /// 不 ok 回 null 由调用方回退纯 GPU）。[key] 为已获目标 adbd 授权的私钥。
  static Future<HybridTurn?> runTurnShell(
    InferenceService inference, {
    required String messagesJson,
    required int maxTokens,
    required double temperature,
    required AdbRsaKeyPair key,
    String host = '127.0.0.1',
    int port = 5555,
    String remoteDir = '/data/local/tmp/npu_m1',
    List<String> manifests = defaultManifests,
    int? nChunksOverride,
    bool Function()? cancelled,
  }) async {
    final nCh = nChunksOverride ?? nChunks;
    if (cancelled?.call() ?? false) return null;
    final work = await prepareWorkDir();
    if (work == null) return null;
    final baseDir = File(work.statePath).parent.path;
    final feedsDir = Directory('$baseDir/feeds')..createSync(recursive: true);
    final sw = Stopwatch()..start();
    try {
      // ① native tokenize + ids.raw + d2q feeds（feedsOnly：App 域零 QNN 触碰）
      final pre = HybridOutcome.from(await inference
          .startHybridPrefill(
            kvDir: feedsDir.path,
            idsPath: work.idsPath,
            chainDir: feedsDir.path,
            messagesJson: messagesJson,
            nRealCap: nc,
            timeoutMs: 60000,
            feedsOnly: true,
          )
          .timeout(const Duration(seconds: 90)));
      if (!pre.ok) {
        debugPrint('[HybridShell] feeds 准备失败: $pre');
        return null;
      }
      final nReal = pre.nReal;
      if (nReal == null || nReal < 1 || nReal > nc) {
        debugPrint('[HybridShell] n_real 非法: $nReal');
        return null;
      }
      _t('feeds', sw);

      // ②〜⑥ shell 域段。[m3shell 2026-11-13 判例] adbd「流已关闭」抖动
      // 两次（push/seed 段）→ 整段封装为可重跑闭包：hygiene rm 幂等、链
      // 从头重 spawn、pull 覆盖写，断线只许重连重跑一击再回退。
      Future<bool> shellDomainRun() async {
        final adb = await AdbClient.connect(host: host, port: port, key: key)
            .timeout(const Duration(seconds: 10));
        try {
          _t('adb_connect', sw);

          // ③ 预检 shell 域资产（fail-closed：缺件直接回退，绝不动设备状态）
          final chk = await adb.shell(
              'test -f $remoteDir/chain_run5 && test -f $remoteDir/${manifests.first} '
              '&& ls $remoteDir/dec2p_l0_ctx.bin >/dev/null 2>&1 && test -d $remoteDir/lib '
              '&& echo STAGED_OK || echo STAGED_MISS');
          if (!chk.stdout.contains('STAGED_OK')) {
            debugPrint('[HybridShell] shell 域资产未入位: ${chk.stdout.trim()}');
            return false;
          }

          // ④ 卫生 + push 12 件 feeds（shell uid，回合产物目录复用工具级 npu_m1）
          await adb.shell(
              'rm -f $remoteDir/d2q_kc_*.raw $remoteDir/d2q_vc_*.raw '
              '$remoteDir/d2q_knew_* $remoteDir/d2q_vnew_* $remoteDir/d2q_h_l*_* '
              '$remoteDir/p0.log $remoteDir/p1.log $remoteDir/p2.log; '
              'rm -rf $remoteDir/gate');
          for (final f in _shellFeedFiles) {
            final lf = File('${feedsDir.path}/$f');
            if (!await lf.exists()) {
              debugPrint('[HybridShell] 本地 feeds 缺件 $f');
              return false;
            }
            await adb.push(await lf.readAsBytes(), '$remoteDir/$f');
          }
          // ids.raw 也上机：链不读它（只认 d2q_*），但 App 侧回合后的 rev3b
          // 判卷/ids 审计需要（App 沙箱内临时目录随回合销毁，设备副本是凭证）。
          await adb.push(
              await File(work.idsPath).readAsBytes(), '$remoteDir/ids.raw');
          await adb.shell(
              'cd $remoteDir && for i in \$(seq 0 ${nLayers - 1}); do '
              'cp d2q_kc0.raw d2q_kc_\$i.raw; cp d2q_vc0.raw d2q_vc_\$i.raw; done');
          _t('push+seed', sw);

          // ⑤ 三段链（工具级硬化：spawn 前 rm log；DONE 须伴新 run 头行；
          //    3 击死亡；</dev/null + 父壳 sleep 1 护脱身）+ h 计数硬闸
          final nSeg = manifests.length;
          for (var k = 0; k < nSeg; k++) {
            final log = '$remoteDir/p$k.log';
            var started = false;
            for (var attempt = 0; attempt < 3 && !started; attempt++) {
              await adb.shell('rm -f $log');
              await adb.shell(
                  'cd $remoteDir && export LD_LIBRARY_PATH=$remoteDir/lib '
                  'ADSP_LIBRARY_PATH=$remoteDir/lib && CHAIN_KEEP=1 CR5_ROLL_SAVE=1 '
                  'nohup ./chain_run5 ${manifests[k]} $nCh > p$k.log 2>&1 </dev/null '
                  '& sleep 1; touch $log; echo SPAWNED_$k');
              for (var t = 0; t < 5 && !started; t++) {
                await Future<void>.delayed(const Duration(seconds: 3));
                final hdr = await adb
                    .shell("grep -ac 'CR5 segs=' $log 2>/dev/null || echo 0");
                started = hdr.stdout.trim().split('\n').last.trim() == '1';
              }
              if (!started) {
                debugPrint(
                    '[HybridShell] seg $k attempt $attempt 无头行 → 重 spawn');
                await adb.shell("pkill -f 'chain_[r]un5' 2>/dev/null || true");
                await Future<void>.delayed(const Duration(seconds: 3));
              }
            }
            if (!started) {
              debugPrint('[HybridShell] seg $k spawn 失败');
              return false;
            }
            var done = false;
            var death = 0;
            for (var t = 0; t < 100; t++) {
              final c = await adb
                  .shell('grep -ac CR5_DONE $log 2>/dev/null || echo 0');
              final h = await adb
                  .shell("grep -ac 'CR5 segs=' $log 2>/dev/null || echo 0");
              if (c.stdout.trim().split('\n').last.trim() == '1' &&
                  h.stdout.trim().split('\n').last.trim() == '1') {
                done = true;
                break;
              }
              final a = await adb.shell("pgrep -f 'chain_[r]un5' | wc -l");
              final alive =
                  int.tryParse(a.stdout.trim().split('\n').last.trim()) ?? 1;
              death = (alive == 0 && t > 4) ? death + 1 : 0;
              if (death >= 3) break;
              await Future<void>.delayed(const Duration(seconds: 3));
            }
            if (!done) {
              final tail = await adb.shell('tail -3 $log 2>/dev/null');
              debugPrint('[HybridShell] seg $k 未 DONE: ${tail.stdout.trim()}');
              return false;
            }
            final nh =
                await adb.shell('ls $remoteDir/d2q_h_l*_* 2>/dev/null | wc -l');
            final hcount =
                int.tryParse(nh.stdout.trim().split('\n').last.trim()) ?? -1;
            // 每段 h 件 = 14 层 × nChunks（512 档 4 chunk → 56/段；NC128 单
            // chunk 档才是 14——2026-11-13 冒烟定罪照搬 128 档闸的错）。
            final hWant = 14 * nCh * (k + 1);
            if (hcount != hWant) {
              debugPrint('[HybridShell] seg $k h 计数 $hcount != $hWant');
              return false;
            }
            final dl = await adb.shell('grep -a CR5_DONE $log');
            debugPrint('[HybridShell] seg $k: ${dl.stdout.trim()}');
          }
          _t('chain(3seg)', sw);
          await adb.shell("pkill -f 'chain_[r]un5' 2>/dev/null || true");

          // ⑥ 收 84 片 KV（sync RECV，shell 文件 o+r；回 App 私有 kvDir）
          for (var i = 0; i < nLayers; i++) {
            for (final t in const ['kc', 'vc']) {
              final name = 'd2q_${t}_$i.raw';
              final data = await adb.pull('$remoteDir/$name',
                  timeout: const Duration(seconds: 30));
              File('${work.kvDir}/$name').writeAsBytesSync(data);
            }
          }
          _t('pull84', sw);
          return true;
        } finally {
          try {
            adb.close();
          } catch (_) {}
        }
      }

      var shellOk = false;
      for (var attempt = 0; attempt < 2 && !shellOk; attempt++) {
        try {
          shellOk = await shellDomainRun();
        } on AdbTransportException catch (e) {
          debugPrint('[HybridShell] adb 断线（attempt $attempt）：$e → '
              '${attempt == 0 ? '重连重跑 shell 段' : '回退 GPU'}');
        }
      }
      if (!shellOk) return null;

      // ⑦ 桥转 + GPU decode —— App 进程内既有真路径（GPU 无域墙）
      if (cancelled?.call() ?? false) return null;
      final dec = await bridgeAndResumeDecode(
        inference,
        paths: HybridWorkPaths(
          kvDir: work.kvDir,
          idsPath: work.idsPath,
          statePath: work.statePath,
        ),
        nReal: nReal,
        firstTok: -1,
        maxTokens: maxTokens,
        temperature: temperature,
      );
      if (!dec.ok) {
        debugPrint('[HybridShell] 桥转/decode 不可用: $dec');
        // [m3shell 取证] 拒载容器留档到 code_cache 根（App 内部：run-as 可读，
        // 外置目录 FUSE 对 run-as 判死判例 2026-11-13），供主机重桥字节比对定罪。
        try {
          final root = File(work.statePath).parent.parent.path; // code_cache
          if (await File(work.statePath).exists()) {
            await File(work.statePath).copy('$root/m3s_forensic.state');
            await File(work.idsPath).copy('$root/m3s_forensic_ids.raw');
            debugPrint('[HybridShell] 取证容器已留档 code_cache/m3s_forensic.state');
          }
        } catch (_) {}
        return null;
      }
      if (dec.stopped == 'user') {
        debugPrint('[HybridShell] decode 被外部止损 → 回退 GPU');
        return null;
      }
      final text = dec.text;
      if (text == null || text.isEmpty) {
        debugPrint('[HybridShell] decode ok 但 text 空 → 回退');
        return null;
      }
      _t('bridge+decode', sw);
      debugPrint('[HybridShell] shell 域混合完成 nReal=$nReal len=${text.length}');
      return HybridTurn(
          text: text, nReal: nReal, nGen: dec.nGen, loadMs: dec.loadMs);
    } catch (e) {
      debugPrint('[HybridShell] 异常（回退 GPU）: $e');
      return null;
    } finally {
      try {
        await Directory(baseDir).delete(recursive: true);
      } catch (_) {}
    }
  }
}
