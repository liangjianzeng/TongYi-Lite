import 'package:flutter_test/flutter_test.dart';

import 'package:tongyi_lite/agent/skills/load_skill_tool.dart';
import 'package:tongyi_lite/agent/skills/provider.dart';
import 'package:tongyi_lite/agent/skills/skill.dart';

void main() {
  group('内置通用技能（2026-09-30 扩充）', () {
    test('内置技能清单：2 个原有 + 8 个新增通用技能', () {
      final skills = loadBuiltinSkills();
      final names = skills.map((s) => s.name).toSet();
      expect(names, containsAll([
        'web-research',
        'code-review',
        'translation',
        'writing-polish',
        'summarize',
        'data-analysis',
        'email-draft',
        'explain-code',
        'plan-todo',
        'file-report',
      ]));
      expect(skills.length, 10);
      // 每个技能都必须有 whenToUse 与非空 body（否则目录注入/正文加载没意义）。
      for (final s in skills) {
        expect(s.whenToUse, isNotEmpty, reason: '${s.name} 缺 whenToUse');
        expect(s.body, isNotEmpty, reason: '${s.name} 缺 body');
      }
    });

    test('load_skill 工具可拉到每个新增技能的全文', () async {
      final provider = SkillProvider();
      final tool = createLoadSkillTool(provider);
      for (final name in [
        'translation',
        'writing-polish',
        'summarize',
        'data-analysis',
        'email-draft',
        'explain-code',
        'plan-todo',
        'file-report',
      ]) {
        final result = await tool.execute({'name': name});
        expect(result.content, contains('<skill name="$name">'),
            reason: 'load_skill 拉不到 $name');
      }
    });

    test('availableSkillsText 目录包含新增技能（API 模式 load_skill 前置）',
        () {
      final text = SkillProvider().availableSkillsText();
      expect(text, contains('translation'));
      expect(text, contains('data-analysis'));
      expect(text, contains('file-report'));
    });

    test('用户同名技能（rank 200）仍覆盖内置（rank 100）', () {
      final provider = SkillProvider();
      provider.registerUser(const Skill(
        name: 'translation',
        description: '用户自定义翻译技能',
        whenToUse: '自定义触发',
        body: '用户 body',
        rank: 0,
      ));
      final skill = provider.byName('translation');
      expect(skill!.rank, kRankUser);
      expect(skill.body, '用户 body');
      expect(provider.count, 10, reason: '同名覆盖不增加数量');
    });
  });
}
