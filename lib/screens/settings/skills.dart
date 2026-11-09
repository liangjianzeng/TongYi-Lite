part of '../settings_screen.dart';

/// 技能管理 Body（harness 第八轮抽取）：技能库完整管理 = 汇总行 + 展开浏览
/// + 内置查看/另存 + 用户新增（整段粘贴）/编辑/删除/重新扫描。
/// 智能体面板与「能力与实验」面板**共用本 Body**——管理动作就地完成，
/// 不再有「去智能体 Tab 管理技能」的跨面板跳（2026-10-25 用户定案）。
/// 抽取时六处非连续切割，方法块原样搬运（ModelManagementBody 同款纪律）。
class SkillsManagementBody extends StatefulWidget {
  const SkillsManagementBody({super.key});

  @override
  State<SkillsManagementBody> createState() => _SkillsManagementBodyState();
}

class _SkillsManagementBodyState extends State<SkillsManagementBody> {
  /// 用户自定义 skills（null = 扫描中）。
  List<Skill>? _userSkills;

  /// 内置技能清单（常量，取一次避免每次 build 重建）。
  final List<Skill> _builtinSkills = loadBuiltinSkills();

  /// 技能列表展开态：默认**展开**（2026-10-25 用户指令：左栏已有独立面板，
  /// 不许再折叠成一行汇总逼用户多点一次；仍可点标题手动收起）。
  bool _skillsExpanded = true;

  @override
  void initState() {
    super.initState();
    _rescanSkills();
  }

  Future<void> _rescanSkills() async {
    final skills = await loadUserSkills();
    if (!mounted) return;
    setState(() => _userSkills = skills);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          leading: const Icon(Icons.extension, size: 20),
          title: Text(
            // 短形态单行：全角括号长标题在窄面板折行出「0）」孤行（真机截图定案）。
            '技能库 ${_builtinSkills.length} · 我的 ${_userSkills?.length ?? '?'}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 14),
          ),
          subtitle: const Text(
            '点开浏览/管理；整段粘贴 SKILL.md 即可新增',
            style: TextStyle(fontSize: 12),
          ),
          trailing: Icon(
            _skillsExpanded ? Icons.expand_less : Icons.expand_more,
            size: 20,
            color: Colors.grey,
          ),
          onTap: () => setState(() => _skillsExpanded = !_skillsExpanded),
        ),
        if (_skillsExpanded)
          // 高度自适应：不再按 ~10 条控高（320px）内滚（2026-10-25 用户定案）
          // ——技能面板独立成 Tab 后列表全量铺开，随条目多少自然伸缩，
          // 整页滚动交给宿主 SingleChildScrollView。
          Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final s in _builtinSkills)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      visualDensity: VisualDensity.compact,
                      leading: const Icon(Icons.extension, size: 20),
                      title: Text('内置 · ${s.name}',
                          style: const TextStyle(fontSize: 14)),
                      subtitle: Text(s.description,
                          style: const TextStyle(fontSize: 12)),
                      trailing: const Icon(Icons.chevron_right,
                          size: 18, color: Colors.grey),
                      onTap: () => _showBuiltinSkillView(s),
                    ),
                  const SizedBox(height: 6),
                  if (_userSkills == null)
                    const Text('正在扫描用户技能…',
                        style: TextStyle(fontSize: 12, color: Colors.grey))
                  else if (_userSkills!.isEmpty)
                    const Text('暂无用户技能',
                        style: TextStyle(fontSize: 12, color: Colors.grey))
                  else
                    for (final s in _userSkills!)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        visualDensity: VisualDensity.compact,
                        leading: const Icon(Icons.extension_outlined, size: 20),
                        title: Text('用户 · ${s.name}',
                            style: const TextStyle(fontSize: 14)),
                        subtitle: Text(s.description,
                            style: const TextStyle(fontSize: 12)),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline, size: 18),
                          tooltip: '删除技能',
                          onPressed: () => _confirmDeleteUserSkill(s),
                        ),
                        onTap: () => _showUserSkillDialog(existing: s),
                      ),
                ],
          ),
        Row(
          children: [
            TextButton.icon(
              onPressed: _rescanSkills,
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('重新扫描'),
            ),
            const SizedBox(width: 4),
            TextButton.icon(
              onPressed: () => _showUserSkillDialog(),
              icon: const Icon(Icons.add, size: 16),
              label: const Text('新增技能'),
            ),
          ],
        ),
        Text(
          '整段粘贴 SKILL.md 即可新增；同名覆盖内置。',
          style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
        ),
      ],
    );
  }

  Future<void> _showBuiltinSkillView(Skill s) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('内置技能：${s.name}'),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('触发：${s.whenToUse}',
                    style: const TextStyle(fontSize: 12, color: Colors.grey)),
                const SizedBox(height: 10),
                SelectableText(s.body,
                    style: const TextStyle(fontSize: 13, height: 1.4)),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
          TextButton.icon(
            onPressed: () {
              Navigator.pop(ctx);
              _showUserSkillDialog(
                  prefillText: buildSkillMarkdown(
                description: s.description,
                whenToUse: s.whenToUse,
                invocation: s.invocation,
                body: s.body,
              ));
            },
            icon: const Icon(Icons.save_as_outlined, size: 16),
            label: const Text('另存为我的技能'),
          ),
        ],
      ),
    );
  }

  /// 新增技能 = **整段粘贴一站式**：一个文本框贴完整 SKILL.md（meta 行 +
  /// `---` + 正文），技能名自动取 `name:` 行、缺省从描述派生——不再逐字段
  /// 手填。[prefillText] 用于"从内置技能另存"。编辑已有技能走字段表单。
  Future<void> _showUserSkillDialog(
      {Skill? existing, String? prefillText}) async {
    if (existing != null) {
      return _showEditSkillDialog(existing);
    }
    final rawCtrl = TextEditingController(text: prefillText ?? '');
    final formKey = GlobalKey<FormState>();
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新增技能（整段粘贴）'),
        content: Form(
          key: formKey,
          child: SizedBox(
            width: 420,
            child: TextFormField(
              controller: rawCtrl,
              autofocus: true,
              minLines: 8,
              maxLines: 16,
              decoration: const InputDecoration(
                labelText: '粘贴完整技能文本',
                hintText: 'name: 可选（技能名，缺省从描述取）\n'
                    'description: 一句话描述\n'
                    'whenToUse: 何时触发\n'
                    '---\n'
                    '正文执行指引（步骤/格式/注意）',
                border: OutlineInputBorder(),
                alignLabelWithHint: true,
              ),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? '请粘贴技能文本' : null,
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
            onPressed: () {
              if (formKey.currentState!.validate()) {
                Navigator.pop(ctx, true);
              }
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    // 弹窗关闭即取走文本并释放控制器（原实现从不 dispose，每次弹窗泄漏）。
    final raw = rawCtrl.text;
    rawCtrl.dispose();
    if (saved != true) return;
    // 技能名：`name:` 行优先；缺省从描述派生（去尾标点取前 12 字再 sanitize）。
    final nameMatch =
        RegExp(r'^\s*name\s*:\s*(.+)$', multiLine: true).firstMatch(raw);
    String? name = nameMatch?.group(1)?.trim();
    final Skill parsed;
    try {
      parsed = Skill.parse(raw, name: name ?? '');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('解析失败（格式见输入框提示）：$e')));
      return;
    }
    if (parsed.description.trim().isEmpty || parsed.whenToUse.trim().isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('缺少 description / whenToUse 行——'
              '格式：meta 行在前，`---` 分隔正文')));
      return;
    }
    if (name == null || name.isEmpty) {
      final base =
          parsed.description.trim().replaceAll(RegExp(r'[。！？!?.、，,；;：:]'), '');
      final sanitized = sanitizeSkillDirName(base);
      name = (sanitized == null || sanitized.isEmpty)
          ? null
          : (sanitized.length > 12 ? sanitized.substring(0, 12) : sanitized);
    }
    if (name == null || name.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('无法确定技能名：请在文本首行加 `name: 技能名`')));
      return;
    }
    try {
      await writeUserSkill(
        name: name,
        description: parsed.description,
        whenToUse: parsed.whenToUse,
        invocation: parsed.invocation,
        body: parsed.body,
      );
    } on ArgumentError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('保存失败：${e.message}')));
      return;
    } on Exception catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('保存失败：$e')));
      return;
    }
    await _rescanSkills();
  }

  /// 编辑已有技能（字段表单；技能名锁定）。
  Future<void> _showEditSkillDialog(Skill existing) async {
    final descCtrl = TextEditingController(text: existing.description);
    final whenCtrl = TextEditingController(text: existing.whenToUse);
    final bodyCtrl = TextEditingController(text: existing.body);
    final formKey = GlobalKey<FormState>();
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('编辑技能：${existing.name}'),
        content: Form(
          key: formKey,
          child: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    controller: descCtrl,
                    decoration: const InputDecoration(
                      labelText: '一句话描述',
                      border: OutlineInputBorder(),
                    ),
                    validator: (v) =>
                        (v == null || v.trim().isEmpty) ? '请填写描述' : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: whenCtrl,
                    decoration: const InputDecoration(
                      labelText: '何时触发（whenToUse）',
                      border: OutlineInputBorder(),
                    ),
                    validator: (v) =>
                        (v == null || v.trim().isEmpty) ? '请填写触发条件' : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: bodyCtrl,
                    minLines: 5,
                    maxLines: 12,
                    decoration: const InputDecoration(
                      labelText: '技能正文（执行指引）',
                      border: OutlineInputBorder(),
                      alignLabelWithHint: true,
                    ),
                    validator: (v) =>
                        (v == null || v.trim().isEmpty) ? '请填写正文' : null,
                  ),
                ],
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
            onPressed: () {
              if (formKey.currentState!.validate()) {
                Navigator.pop(ctx, true);
              }
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    // 弹窗关闭即取走文本并释放控制器（原实现从不 dispose，每次弹窗泄漏三个）。
    final desc = descCtrl.text;
    final when = whenCtrl.text;
    final body = bodyCtrl.text;
    descCtrl.dispose();
    whenCtrl.dispose();
    bodyCtrl.dispose();
    if (saved != true) return;
    try {
      await writeUserSkill(
        name: existing.name,
        previousName: existing.name,
        description: desc,
        whenToUse: when,
        body: body,
      );
    } on ArgumentError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('保存失败：${e.message}')));
      return;
    } on Exception catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('保存失败：$e')));
      return;
    }
    await _rescanSkills();
  }

  Future<void> _confirmDeleteUserSkill(Skill skill) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除技能：${skill.name}'),
        content: const Text('将从技能目录删除该技能（含其目录下的全部文件），'
            '删除后无法恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await deleteUserSkill(skill.name);
    await _rescanSkills();
  }
}

