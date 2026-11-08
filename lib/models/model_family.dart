// ============================================================
// 模型族（同基础模型多量化）的归组与量化档位选择解析。
// 数据侧：ModelConfig.familyId 相同的条目构成一族（model_info.dart）；
// 持久化：InferenceSettings.quantChoiceByFamily（settings_service.dart）。
// 模型管理页据此折叠为一行 + 量化选择器；下载/加载仍按 variant id 走，
// 本文件只做纯函数归组/解析，便于单测。
// ============================================================

import '../services/settings_service.dart';
import 'model_info.dart';

/// 一个模型族：同 [ModelConfig.familyId] 的全部量化档位。
class ModelFamily {
  final String familyId;

  /// 族展示名（主行标题）。
  final String name;

  /// 族内全部档位，quantRank 升序（first = 默认最小档）。
  final List<ModelConfig> variants;

  const ModelFamily({
    required this.familyId,
    required this.name,
    required this.variants,
  });
}

/// 模型管理页的一行：独立条目或一个模型族。
sealed class ModelListRow {
  const ModelListRow();
}

/// 独立条目（无 familyId，或单条目族退化）。
class SingleModelRow extends ModelListRow {
  final ModelConfig model;
  const SingleModelRow(this.model);
}

/// 模型族行（≥2 个同族量化档位折叠为一行）。
class FamilyModelRow extends ModelListRow {
  final ModelFamily family;
  const FamilyModelRow(this.family);
}

/// 按目录原序归组：familyId 相同的条目合为一个族行（插在首个成员出现的
/// 位置），族内按 quantRank 升序（并列按体积）；单条目族退化为独立行。
List<ModelListRow> buildModelRows(List<ModelConfig> catalog) {
  final rows = <ModelListRow>[];
  final emittedFamilies = <String>{};
  for (final m in catalog) {
    final fid = m.familyId;
    if (fid == null) {
      rows.add(SingleModelRow(m));
      continue;
    }
    if (emittedFamilies.contains(fid)) continue; // 族行已在首成员处插入
    final variants = catalog.where((x) => x.familyId == fid).toList()
      ..sort((a, b) {
        final byRank = a.quantRank.compareTo(b.quantRank);
        return byRank != 0 ? byRank : a.sizeBytes.compareTo(b.sizeBytes);
      });
    emittedFamilies.add(fid);
    if (variants.length == 1) {
      rows.add(SingleModelRow(variants.first));
      continue;
    }
    rows.add(FamilyModelRow(ModelFamily(
      familyId: fid,
      name: variants
              .firstWhere((v) => (v.familyName ?? '').isNotEmpty,
                  orElse: () => variants.first)
              .familyName ??
          cleanModelName(variants.first.name),
      variants: variants,
    )));
  }
  return rows;
}

/// 解析族当前选中的量化档位：
/// 1) 用户上次选择（settings.quantChoiceByFamily，档位仍存在才生效，
///    目录热更新撤档后自动回落）；
/// 2) 老用户迁移：默认模型 id 落在本族（「设为默认」星标跟到该档）；
/// 3) 默认 quantRank 最小档（variants.first）。
ModelConfig resolveSelectedVariant(
    ModelFamily family, InferenceSettings settings) {
  final saved = settings.quantChoiceByFamily[family.familyId];
  if (saved != null) {
    for (final v in family.variants) {
      if (v.id == saved) return v;
    }
  }
  final defaultId = settings.defaultModelId;
  if (defaultId != null) {
    for (final v in family.variants) {
      if (v.id == defaultId) return v;
    }
  }
  return family.variants.first;
}
