import 'package:flutter_test/flutter_test.dart';

import 'package:tongyi_lite/models/model_catalog.dart';
import 'package:tongyi_lite/models/model_info.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('目录可加载且含新增智能体模型', () async {
    final models = await ModelCatalog.load();

    // 目录随发版增删模型（当前 23 个，含本机预置的 Clover 实验条目）；
    // 数量变动时同步本断言防误删。
    expect(models.length, 23);

    // Spark-X2.6-4B（2026-10-30 替换 X2.5）：架构与 X2.5 逐字相同，官方 GGUF
    // general.architecture = spark2_5，本仓 llama.cpp（b11267 ≥ 官方门槛 b10828）
    // 原生支持，无需改引擎。
    final spark = models.firstWhere((m) => m.id == 'spark-x2.6-4b-q4_k_m');
    expect(spark.name, contains('Spark-X2.6 4B'));
    expect(spark.type, ModelType.text);
    expect(spark.bestMirrorUrl, contains('Spark-X2.6-4B-Q4_K_M.gguf'));
    expect(spark.mirrors.map((m) => m.source).toList(),
        containsAll(<String>['modelscope', 'hf-mirror', 'huggingface']));
    expect(spark.sizeMB, greaterThan(3300));
    // 官方发布的 LFS sha256（ModelScope 与 HuggingFace 双源核对一致）。
    expect(spark.sha256Hash,
        '91cb2811aebb47ac916aa619d27d4cdd7f4143106b7917accb8ead4cd7f5cbd9');

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
}
