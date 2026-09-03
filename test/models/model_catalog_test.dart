import 'package:flutter_test/flutter_test.dart';

import 'package:tongyi_lite/models/model_catalog.dart';
import 'package:tongyi_lite/models/model_info.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('目录可加载且含新增智能体模型', () async {
    final models = await ModelCatalog.load();

    expect(models.length, 12);

    final spark = models.firstWhere((m) => m.id == 'spark-x2.5-4b-q4_k_m');
    expect(spark.name, contains('Spark-X2.5 4B'));
    expect(spark.type, ModelType.text);
    expect(spark.bestMirrorUrl, contains('Spark-X2.5-4B-Q4_K_M.gguf'));
    expect(spark.sizeMB, greaterThan(2400));

    final hunyuan = models.firstWhere((m) => m.id == 'hunyuan-4b-q4_k_m');
    expect(hunyuan.name, contains('Hunyuan 4B'));
    expect(hunyuan.type, ModelType.text);
    expect(hunyuan.bestMirrorUrl, contains('Q4_K_M.gguf'));
    expect(hunyuan.sizeMB, greaterThan(2400));

    // 扩展字段被安全忽略（现有代码不消费，不抛错）。
    expect(spark.mtp, isFalse);
    expect(spark.mmproj, isNull);
  });
}
