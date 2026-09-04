import 'package:flutter_test/flutter_test.dart';

import 'package:tongyi_lite/models/model_catalog.dart';
import 'package:tongyi_lite/models/model_info.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('目录可加载且含新增智能体模型', () async {
    final models = await ModelCatalog.load();

    expect(models.length, 13);

    final spark = models.firstWhere((m) => m.id == 'spark-x2.5-4b-q4_k_m');
    expect(spark.name, contains('Spark-X2.5 4B'));
    expect(spark.type, ModelType.text);
    expect(spark.bestMirrorUrl, contains('Spark-X2.5-4B-Q4_K_M.gguf'));
    expect(spark.sizeMB, greaterThan(2400));

    final lfm8b = models.firstWhere((m) => m.id == 'lfm2.5-8b-a1b-ud-iq3_xxs');
    expect(lfm8b.name, contains('LFM 2.5 8B-A1B'));
    expect(lfm8b.type, ModelType.text);
    expect(lfm8b.bestMirrorUrl, contains('LFM2.5-8B-A1B-UD-IQ3_XXS.gguf'));
    expect(lfm8b.sizeMB, greaterThan(3000));

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
