/// SkillProvider（Phase 5）—— 端侧 skill 扫描/注册。
///
/// 两级 rank：内置（rank 100）+ 用户（rank 200）。
/// 模型面：首次 step 注入 `<available_skills>`（name + description + whenToUse），
/// 触发时（invocation 或模型判断）注入完整 body。
library;

import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'skill.dart';

String _join(String a, String b) {
  final sep = (a.endsWith('/') || a.endsWith('\\')) ? '' : '/';
  return '$a$sep$b';
}

String _basename(String path) {
  var s = path;
  while (s.endsWith('/') || s.endsWith('\\')) {
    s = s.substring(0, s.length - 1);
  }
  final idxSlash = s.lastIndexOf('/');
  final idxBack = s.lastIndexOf('\\');
  final idx = idxSlash > idxBack ? idxSlash : idxBack;
  return idx == -1 ? s : s.substring(idx + 1);
}

/// SkillProvider（端侧简化版）。
final class SkillProvider {
  final List<Skill> _skills;

  SkillProvider({List<Skill>? skills})
      : _skills = _dedupeByRank(
            (skills ?? loadBuiltinSkills()).sortedByRank());

  /// 所有 skill（按 rank 降序，rank 大的优先）。
  List<Skill> get skills => _skills;
  int get count => _skills.length;

  /// 按名称查找 skill（不存在返回 null）。
  Skill? byName(String name) {
    for (final s in _skills) {
      if (s.name == name) return s;
    }
    return null;
  }

  /// 检查某 skill 是否存在。
  bool has(String name) => byName(name) != null;

  /// 注册用户 skill（rank 200；同名覆盖内置）。
  void registerUser(Skill skill) {
    _skills.removeWhere((s) => s.name == skill.name);
    _skills.add(skill.withRank(kRankUser));
  }

  /// 删除用户 skill（按名称）。
  bool remove(String name) {
    final idx = _skills.indexWhere((s) => s.name == name && s.rank == kRankUser);
    if (idx == -1) return false;
    _skills.removeAt(idx);
    return true;
  }

  /// 生成 `<available_skills>` 注入文本（首次 step，模型可见）。
  ///
  /// 格式（DSH Part 12.3）：
  /// ```
  /// <available_skills>
  /// name: web-research
  /// description: ...
  /// whenToUse: ...
  /// invocation: tool: web_search
  ///
  /// name: code-review
  /// ...
  /// </available_skills>
  /// ```
  String availableSkillsText() {
    if (_skills.isEmpty) return '';
    final sb = StringBuffer();
    sb.writeln('<available_skills>');
    for (final s in _skills) {
      sb.writeln(s.injectionText().trim());
      sb.writeln();
    }
    sb.writeln('</available_skills>');
    return sb.toString();
  }

  /// 生成完整 skill body 注入文本（触发时，模型可见）。
  ///
  /// 格式：
  /// ```
  /// <skill name="web-research">
  /// ...body...
  /// </skill>
  /// ```
  String skillText(String name) {
    final s = byName(name);
    if (s == null) return '';
    return '<skill name="${s.name}">\n${s.body}\n</skill>';
  }
}

extension ListSkills on List<Skill> {
  List<Skill> sortedByRank() {
    final copy = List.of(this);
    copy.sort((a, b) => b.rank.compareTo(a.rank));
    return copy;
  }
}

/// 同名去重（列表已按 rank 降序：保留第一个 = 最高 rank）。
List<Skill> _dedupeByRank(List<Skill> skills) {
  final seen = <String>{};
  final out = <Skill>[];
  for (final s in skills) {
    if (seen.add(s.name)) out.add(s);
  }
  return out;
}

/// 扫描用户 skill 目录（`ApplicationSupport/skills/<name>/SKILL.md`，rank 200）。
///
/// 目录不存在或单个 skill 文件损坏均不影响其余；失败返回空列表。
Future<List<Skill>> loadUserSkills({String? skillsDirOverride}) async {
  try {
    final dirPath = skillsDirOverride ??
        _join((await getApplicationSupportDirectory()).path, 'skills');
    final dir = Directory(dirPath);
    if (!dir.existsSync()) return const [];
    final out = <Skill>[];
    for (final entity in dir.listSync()) {
      if (entity is! Directory) continue;
      final file = File(_join(entity.path, 'SKILL.md'));
      if (!file.existsSync()) continue;
      try {
        final content = file.readAsStringSync();
        final name = _basename(entity.path);
        out.add(Skill.parse(content, name: name).withRank(kRankUser));
      } catch (_) {
        // 坏文件跳过。
      }
    }
    return out;
  } catch (_) {
    return const [];
  }
}
