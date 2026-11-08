import 'package:flutter_test/flutter_test.dart';

import 'package:tongyi_lite/models/model_family.dart';
import 'package:tongyi_lite/models/model_info.dart';
import 'package:tongyi_lite/services/settings_service.dart';

ModelConfig _m(String id,
    {String? familyId,
    String? familyName,
    String? quantLabel,
    int quantRank = 0,
    int sizeGB = 1}) {
  return ModelConfig(
    id: id,
    name: 'Test Model ($quantLabel)',
    type: ModelType.text,
    mirrors: [MirrorEntry('https://example.com/$id.gguf', 'modelscope')],
    sizeBytes: sizeGB * 1024 * 1024 * 1024,
    sizeMBDisplay: '$sizeGB GB',
    familyId: familyId,
    familyName: familyName,
    quantLabel: quantLabel,
    quantRank: quantRank,
  );
}

void main() {
  group('buildModelRows 归组', () {
    test('独立条目保持原序，同族条目折叠为一行且按 quantRank 升序', () {
      final catalog = [
        _m('solo-a'),
        _m('fam-b-q8',
            familyId: 'fam-b',
            familyName: 'Fam B',
            quantLabel: 'Q8_0',
            quantRank: 1),
        _m('solo-c'),
        _m('fam-b-q4',
            familyId: 'fam-b',
            familyName: 'Fam B',
            quantLabel: 'Q4_K_M',
            quantRank: 0),
      ];
      final rows = buildModelRows(catalog);
      expect(rows.length, 3);
      expect(rows[0], isA<SingleModelRow>());
      expect((rows[0] as SingleModelRow).model.id, 'solo-a');
      final fam = rows[1] as FamilyModelRow;
      expect(fam.family.familyId, 'fam-b');
      expect(fam.family.name, 'Fam B');
      // quantRank 升序，与目录出现顺序无关；族行插在首个成员的位置。
      expect(fam.family.variants.map((v) => v.id).toList(),
          ['fam-b-q4', 'fam-b-q8']);
      expect((rows[2] as SingleModelRow).model.id, 'solo-c');
    });

    test('单条目族退化为独立行（不值得折叠）', () {
      final rows = buildModelRows([
        _m('one', familyId: 'one', familyName: 'One', quantLabel: 'Q4_K_M'),
      ]);
      expect(rows.single, isA<SingleModelRow>());
    });

    test('familyName 取第一个非空条目；rank 并列按体积升序', () {
      final rows = buildModelRows([
        _m('f-x', familyId: 'f', quantLabel: 'Q8_0', quantRank: 1, sizeGB: 1),
        _m('f-y',
            familyId: 'f',
            familyName: 'Fam F',
            quantLabel: 'Q4_0',
            quantRank: 1,
            sizeGB: 2),
      ]);
      final fam = (rows.single as FamilyModelRow).family;
      expect(fam.name, 'Fam F');
      expect(fam.variants.map((v) => v.id).toList(), ['f-x', 'f-y']);
    });

    test('无 familyId 的纯独立目录不归组', () {
      final catalog = [_m('a'), _m('b')];
      final rows = buildModelRows(catalog);
      expect(rows.length, 2);
      expect(rows.every((r) => r is SingleModelRow), isTrue);
    });
  });

  group('resolveSelectedVariant 选择解析', () {
    final family = ModelFamily(familyId: 'f', name: 'F', variants: [
      _m('f-q2', familyId: 'f', quantLabel: 'Q2_K', quantRank: 0),
      _m('f-q4', familyId: 'f', quantLabel: 'Q4_K_M', quantRank: 1),
      _m('f-q8', familyId: 'f', quantLabel: 'Q8_0', quantRank: 2),
    ]);

    test('无任何记录 → 默认最小档（quantRank 0）', () {
      expect(
          resolveSelectedVariant(family, const InferenceSettings()).id, 'f-q2');
    });

    test('用户上次选择优先（持久化后下次直接生效）', () {
      const s = InferenceSettings(quantChoiceByFamily: {'f': 'f-q8'});
      expect(resolveSelectedVariant(family, s).id, 'f-q8');
    });

    test('上次选择指向已下架档位 → 先回落默认模型，再最小档', () {
      const s = InferenceSettings(
          quantChoiceByFamily: {'f': 'f-gone'}, defaultModelId: 'f-q4');
      expect(resolveSelectedVariant(family, s).id, 'f-q4');
    });

    test('上次选择指向已下架档位且无默认模型 → 最小档兜底', () {
      const s = InferenceSettings(quantChoiceByFamily: {'f': 'f-gone'});
      expect(resolveSelectedVariant(family, s).id, 'f-q2');
    });

    test('无选择记录但默认模型在本族 → 星标迁移到该档', () {
      const s = InferenceSettings(defaultModelId: 'f-q8');
      expect(resolveSelectedVariant(family, s).id, 'f-q8');
    });

    test('显式选择优先于默认模型', () {
      const s = InferenceSettings(
          quantChoiceByFamily: {'f': 'f-q2'}, defaultModelId: 'f-q8');
      expect(resolveSelectedVariant(family, s).id, 'f-q2');
    });
  });
}
