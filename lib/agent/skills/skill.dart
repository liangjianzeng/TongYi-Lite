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
  ];
}