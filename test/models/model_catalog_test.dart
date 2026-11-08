import 'package:flutter_test/flutter_test.dart';

import 'package:tongyi_lite/models/model_catalog.dart';
import 'package:tongyi_lite/models/model_info.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('目录可加载且含新增智能体模型', () async {
    final models = await ModelCatalog.load();

    // 目录随发版增删模型（当前 38 个：23 个存量 + Ornith 6 档 + Nanbeige 9 档，
    // 含本机预置的 Clover 实验条目）；数量变动时同步本断言防误删。
    expect(models.length, 38);

    // Spark-X2.6-4B（2026-10-30 替换 X2.5）：架构与 X2.5 逐字相同，官方 GGUF
    // general.architecture = spark2_5，本仓 llama.cpp（b11267 ≥ 官方门槛 b10828）
    // 原生支持，无需改引擎。
    final spark = models.firstWhere((m) => m.id == 'spark-x2.6-4b-q4_k_m');
    expect(spark.name, contains('Spark-X2.6 4B'));
    expect(spark.type, ModelType.text);
    expect(spark.bestMirrorUrl, contains('Spark-X2.6-4B-Q4_K_M.gguf'));
    expect(spark.mirrors.map((m) => m.source).toList(),
        containsAll(<String>['modelscope', 'hf-mirror', 'huggingface']));
    expect(spark.sizeMB, greaterThan(2400));
    // 官方发布的 LFS sha256（2026-11-08 与 ModelScope files API 核对一致；
    // 旧断言 91cb2811… 是 X2.5 时代的遗留值，随 X2.6 换模型未同步）。
    expect(spark.sha256Hash,
        '30b77e2ede85c37da7071048c91fcf47c3e8cbfad51971640530f8ba9753301a');

    final lfm8b = models.firstWhere((m) => m.id == 'lfm2.5-8b-a1b-q4_k_m');
    expect(lfm8b.name, contains('LFM 2.5 8B-A1B'));
    expect(lfm8b.type, ModelType.text);
    expect(lfm8b.bestMirrorUrl, contains('LFM2.5-8B-A1B-Q4_K_M.gguf'));
    expect(lfm8b.sizeMB, greaterThan(4800));

    final ling30 = models.firstWhere((m) => m.id == 'ling-3.0-tiny-q4_k_m');
    expect(ling30.name, contains('Ling 3.0 Tiny'));
    expect(ling30.type, ModelType.text);
    expect(ling30.bestMirrorUrl, contains('Ling-3.0-tiny-Q4_K_M.gguf'));
    expect(ling30.sizeMB, greaterThan(4400));

    // LFM3-VL 2B（Liquid AI 官方 QAD Q4_0 + F16 投影器，两文件形态视觉模型）。
    final lfm3vl = models.firstWhere((m) => m.id == 'lfm3-vl-2b-qad-q4_0');
    expect(lfm3vl.name, contains('LFM3-VL 2B'));
    expect(lfm3vl.type, ModelType.vision);
    expect(lfm3vl.supportsVision, isTrue);
    expect(lfm3vl.bestMirrorUrl, contains('LFM3-VL-2B-QAD-Q4_0.gguf'));
    expect(lfm3vl.sizeMB, greaterThan(950));
    expect(lfm3vl.sha256Hash, isNotNull);
    // mmproj 非空 → 走「text + mmproj 两文件」加载路径，总字节含投影器。
    expect(lfm3vl.mmproj, isNotNull);
    expect(lfm3vl.mmproj!.bestMirrorUrl, contains('mmproj-LFM3-VL-2B-F16.gguf'));
    expect(lfm3vl.mmproj!.sizeMB, greaterThan(340));
    expect(lfm3vl.totalBytes, greaterThan(lfm3vl.sizeBytes));

    final bonsai27b = models.firstWhere((m) => m.id == 'bonsai-27b-q1_0');
    expect(bonsai27b.name, contains('Bonsai 27B'));
    expect(bonsai27b.bestMirrorUrl, contains('Bonsai-27B-Q1_0.gguf'));
    expect(bonsai27b.sizeMB, greaterThan(3500));
    // dspark 投机草稿头配置解析。
    expect(bonsai27b.dspark, isNotNull);
    expect(bonsai27b.dspark!.bestMirrorUrl, contains('Bonsai-27B-dspark-Q4_1.gguf'));
    expect(bonsai27b.dspark!.sizeMB, greaterThan(1600));

    final bonsai8b = models.firstWhere((m) => m.id == 'bonsai-8b-q1_0');
    expect(bonsai8b.name, contains('Bonsai-8B'));
    expect(bonsai8b.bestMirrorUrl, contains('Bonsai-8B-Q1_0.gguf'));
    expect(bonsai8b.sizeMB, greaterThan(1100));

    // 扩展字段被安全忽略（现有代码不消费，不抛错）。
    expect(spark.mtp, isFalse);
    expect(spark.mmproj, isNull);
    expect(bonsai8b.dspark, isNull);
  });

  test('模型族字段解析：Ornith / Nanbeige 新族与存量归族', () async {
    final models = await ModelCatalog.load();

    // Ornith 1.5 9B：6 档全部 -mtp 包（自带 NextN 层，GSQ-RCO 混合精度
    // 量化），镜像 = abenzerps/Ornith-1.5-9B-GSQ-RCO-GGUF（modelscope +
    // hf-mirror + huggingface）。所有档位带官方 sha256（下载后强校验）。
    final ornith = models.where((m) => m.familyId == 'ornith-1.5-9b').toList();
    expect(ornith.length, 6);
    for (final m in ornith) {
      expect(m.mtp, isTrue, reason: m.id);
      expect(m.type, ModelType.text, reason: m.id);
      expect(m.sha256Hash, isNotNull, reason: m.id);
      expect(m.quantLabel, isNotNull, reason: m.id);
      expect(m.mirrors.map((x) => x.source).toList(),
          containsAll(<String>['modelscope', 'hf-mirror', 'huggingface']),
          reason: m.id);
      expect(m.bestMirrorUrl, endsWith('-mtp.gguf'), reason: m.id);
    }
    // quantRank 升序 = IQ2_XS < IQ2_S < IQ3_XXS < IQ3_XS < IQ3_S < IQ3_M，
    // 且档位体积随 rank 单调递增（默认最小档 = rank 0 = IQ2_XS）。
    final ornithSorted = [...ornith]..sort((a, b) => a.quantRank.compareTo(b.quantRank));
    expect(ornithSorted.map((m) => m.quantLabel).toList(),
        ['IQ2_XS', 'IQ2_S', 'IQ3_XXS', 'IQ3_XS', 'IQ3_S', 'IQ3_M']);
    expect(ornithSorted.first.sizeBytes, lessThan(ornithSorted.last.sizeBytes));

    // Nanbeige 4.2 3B：bartowski imatrix 量化精选 9 档（≤Q4_K_L），
    // nanbeige 架构（引擎 fork llama-arch.cpp 已内置 LLM_ARCH_NANBEIGE）。
    final nb = models.where((m) => m.familyId == 'nanbeige4.2-3b').toList();
    expect(nb.length, 9);
    final nbSorted = [...nb]..sort((a, b) => a.quantRank.compareTo(b.quantRank));
    expect(nbSorted.map((m) => m.quantLabel).toList(),
        ['Q2_K', 'IQ2_M', 'IQ3_XXS', 'IQ3_XS', 'IQ3_M', 'IQ4_XS', 'Q4_0', 'Q4_K_M', 'Q4_K_L']);
    expect(nb.every((m) => m.mtp == false), isTrue);
    for (final m in nb) {
      expect(m.sha256Hash, isNotNull, reason: m.id);
      expect(m.mirrors.map((x) => x.source).toList(),
          containsAll(<String>['modelscope', 'hf-mirror', 'huggingface']),
          reason: m.id);
    }
    // Q4_0 档标注 GPU 加速（引擎 OpenCL 路径开箱即用）。
    final nbQ40 = nb.firstWhere((m) => m.quantLabel == 'Q4_0');
    expect(nbQ40.tags, contains('GPU 加速'));

    // 存量三组同源对归族（每族 2 档，quantRank 0 = 原低比特档）。
    expect(models.where((m) => m.familyId == 'minicpm5-2b').length, 2);
    expect(models.where((m) => m.familyId == 'lfm2.5-8b-a1b').length, 2);
    expect(models.where((m) => m.familyId == 'ling-3.0-tiny').length, 2);
  });
}
