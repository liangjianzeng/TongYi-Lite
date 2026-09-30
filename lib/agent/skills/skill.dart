/// 端侧 skill（DSH Part 12.2/12.3，Phase 5）。
///
/// 两级 rank：内置（rank 100）+ 用户（rank 200；rank 大的优先）。
/// 格式：`<name>/SKILL.md`（frontmatter：name/description/whenToUse/invocation）。
library;

const int kRankBuiltin = 100;
const int kRankUser = 200;

final class Skill {
  const Skill({
    required this.name,
    required this.description,
    required this.whenToUse,
    this.invocation,
    required this.body,
    required this.rank,
  });

  final String name;
  final String description;
  final String whenToUse;
  final String? invocation;
  final String body;
  final int rank;

  factory Skill.parse(String content, {required String name}) {
    final lines = content.split('\n');
    final meta = <String, String>{};
    int startBody = 0;
    bool done = false;
    for (var i = 0; i < lines.length; i++) {
      if (done) break;
      final raw = lines[i];
      final line = raw.trim();
      if (line.startsWith('#')) continue;
      if (line == '---') {
        // frontmatter 分隔线：正文从下一行开始。
        startBody = i + 1;
        done = true;
        break;
      }
      final colon = line.indexOf(':');
      if (colon > 0) {
        final key = line.substring(0, colon).trim();
        if (key != '') {
          meta[key] = _clean(line.substring(colon + 1));
        }
      } else {
        startBody = i;
        done = true;
      }
    }
    final body = lines.sublist(startBody).join('\n').trim();
    return Skill(
      name: name,
      description: meta['description'] ?? '',
      whenToUse: meta['whenToUse'] ?? meta['when_to_use'] ?? '',
      invocation: meta['invocation'],
      body: body,
      rank: 0,
    );
  }

  Skill withRank(int rank) => Skill(
        name: name,
        description: description,
        whenToUse: whenToUse,
        invocation: invocation,
        body: body,
        rank: rank,
      );

  String injectionText() {
    final sb = StringBuffer();
    sb.writeln('name: $name');
    sb.writeln('description: $description');
    sb.writeln('whenToUse: $whenToUse');
    if (invocation != null) {
      sb.writeln('invocation: $invocation');
    }
    return sb.toString();
  }
}

String _clean(String s) {
  var r = s.trim();
  if (r.length >= 2 && r.startsWith('"') && r.endsWith('"')) {
    r = r.substring(1, r.length - 1).trim();
  }
  return r;
}

List<Skill> loadBuiltinSkills() {
  return [
    Skill(
      name: 'web-research',
      description: '联网搜索并总结（实时信息/新闻/价格）。',
      whenToUse: '用户问实时信息、新闻、价格、版本等需要联网的事实。',
      invocation: 'tool: web_search',
      body: '## 使用\n'
          '调用 web_search 工具，获取来源后总结。'
          '\n- 优先权威来源（官方/主流媒体）。'
          '\n- 多引擎交叉验证（若配置）。'
          '\n- 总结时注明来源（URL）与时效性。',
      rank: kRankBuiltin,
    ),
    Skill(
      name: 'code-review',
      description: '代码审查（风格/安全/性能）。',
      whenToUse: '用户要求 review 代码、检查 bug/风格、或提交前审查。',
      invocation: null,
      body: '## 使用\n'
          '- 先 read 相关文件（不要猜测）。'
          '\n- 按风格、安全、性能顺序审查。'
          '\n- 指出具体行号与修改建议。'
          '\n- 不要自动修改；除非用户明确要求。',
      rank: kRankBuiltin,
    ),
    Skill(
      name: 'translation',
      description: '高质量翻译（中英/多语互译，保留格式与术语）。',
      whenToUse: '用户要求翻译、润色译文、或解释外文内容。',
      body: '## 使用\n'
          '- 先判断源语言与目标语言；用户未指明目标语时，中文内容译英、'
          '外语内容译中。'
          '\n- 保留原文的段落/列表/代码块结构；代码与专有名词不译，'
          '首次出现可在括号内附原文。'
          '\n- 专业术语按领域惯例统一（同一术语全文一致）。'
          '\n- 译文自然流畅，不逐词硬译；歧义处给出 1-2 个备选译法并说明差异。'
          '\n- 用户只贴片段时按片段翻译，不要主动扩写或总结。',
      rank: kRankBuiltin,
    ),
    Skill(
      name: 'writing-polish',
      description: '写作与润色（改写/扩写/语气调整/纠错）。',
      whenToUse: '用户要求润色、改写、扩写、换语气、或纠正文稿。',
      body: '## 使用\n'
          '- 先问清（或从原文推断）目标：更正式/更口语/更简洁/更详细。'
          '\n- 保持原意与关键信息不丢失；只调整表达。'
          '\n- 修改多、改动大时用列表给出「主要改动点」，便于用户对照。'
          '\n- 用户提供的文稿在附件里时先 read_file 完整阅读再动手。',
      rank: kRankBuiltin,
    ),
    Skill(
      name: 'summarize',
      description: '长文/文件摘要提炼（要点/结论/数据）。',
      whenToUse: '用户要求总结、提炼要点、或快速了解长内容。',
      body: '## 使用\n'
          '- 附件指向 workspace/_uploads/ 时先 read_file 完整阅读；'
          '网页类信息用 web_search 获取来源内容。'
          '\n- 摘要结构：一句话结论 → 3-7 条要点 → 值得注意的风险/数据。'
          '\n- 保留关键数字、日期、来源；不要编造原文没有的信息。'
          '\n- 用户可指定字数/条数上限，遵守之。',
      rank: kRankBuiltin,
    ),
    Skill(
      name: 'data-analysis',
      description: '数据统计与分析（CSV/表格/数值计算）。',
      whenToUse: '用户给数据要求统计、对比、找规律、或生成图表文件。',
      body: '## 使用\n'
          '- 数据文件先 read_file 看清列名与格式，再动手。'
          '\n- 统计与转换用 python_exec 批量做（平均值/分组合并/透视），'
          '纯算术才用 calculator；绝不在回答里手算大数据。'
          '\n- 结论给「数字 + 一句话解读」；注明样本量与口径。'
          '\n- 需要交付图表/结果文件时写入 workspace 文件（csv/html），'
          '再调用 export_file 导出并告知文件名。',
      rank: kRankBuiltin,
    ),
    Skill(
      name: 'email-draft',
      description: '邮件/消息/通知文书起草。',
      whenToUse: '用户要求写邮件、回复、通知、申请、感谢信等正式文本。',
      body: '## 使用\n'
          '- 先明确：收件人与关系、目的、期望对方做什么、语气正式程度。'
          '\n- 结构：称呼 → 一句话目的 → 背景/细节（≤3 点）→ 明确请求 → 结尾。'
          '\n- 直接给出可发送的成稿；用户未要求时不要附大段解释。'
          '\n- 需要多个版本（正式/简短）时分别给出并标注适用场景。',
      rank: kRankBuiltin,
    ),
    Skill(
      name: 'explain-code',
      description: '代码讲解与教学（逐段解释/排查报错）。',
      whenToUse: '用户要求解释代码、理解报错、或学习某段实现。',
      body: '## 使用\n'
          '- 用户贴了代码直接分析；代码在文件里先 read_file。'
          '\n- 讲解顺序：这段代码做什么 → 关键步骤逐段拆 → 隐含的坑/边界。'
          '\n- 报错类：先定位报错行与真实原因，再给最小修复 diff，'
          '不整段重写。'
          '\n- 验证修复可用 python_exec/shell_exec 跑最小复现，'
          '不凭感觉断言「应该能跑」。',
      rank: kRankBuiltin,
    ),
    Skill(
      name: 'plan-todo',
      description: '任务拆解与计划制定（多步任务列待办）。',
      whenToUse: '用户提出多步任务、要求做计划、或任务预计 3 步以上。',
      body: '## 使用\n'
          '- 用 todo_write 把任务拆成可勾选的子步骤（每步一个可验证的结果）。'
          '\n- 有依赖关系的步骤标明先后；可并行的步骤说明可并行。'
          '\n- 执行中每完成一步就更新 todo 状态，让用户看到进度。'
          '\n- 关键不确定点先向用户确认，不要带着错误假设跑完全程。',
      rank: kRankBuiltin,
    ),
    Skill(
      name: 'file-report',
      description: '生成报告/网页/文档产物并导出交付。',
      whenToUse: '用户要求生成报告、网页、简历、表格文件等可下载产物。',
      body: '## 使用\n'
          '- 产物先写入 workspace 文件（如 report.html / report.md），'
          '再调用 export_file 导出到下载目录，并告知文件名与内容摘要。'
          '\n- HTML 报告自带样式（内联 CSS），不依赖外部资源。'
          '\n- 长内容绝不直接输出在回答里；回答里只给摘要与文件说明。'
          '\n- 数据来源标注在文末（工具结果/用户输入）。',
      rank: kRankBuiltin,
    ),
  ];
}