// 思考失控守卫 · 机检量化（修复前 / 修复后都跑它出对比表）
//
// 用法（在 TongYi-Lite 项目根）：
//   dart run tool/measure_thinking_guard.dart
//
// 口径：把「思考失控」拆成 7 个可复现场景，逐 token 喂给 AgentStreamProcessor，
// 用两种守卫判定是否会止损：
//   G_now = 现行守卫：只量「当前思考块」processor.thinking.length > 阈值
//           （AgentStreamProcessor 每遇闭合记号就 thinking.clear() → 分块归零）
//   G_fix = 目标守卫：跨块累计 totalThinkingChars > 阈值 且 本步尚无任何产出
// 指标：失控漏网数、正常误杀数、失控场景白烧的思考字数（越小越好）。
import 'package:tongyi_lite/providers/agent_stream_processor.dart';

const int kThreshold = 6000; // = 设置项 agentThinkingMaxChars 默认值

// 思考标签按片段拼出来：把标签字面量直接写进源码/工具参数会被上游
// 思考流过滤器当成思考块吞掉（本仓实测），拼接后写盘才安全。
const String kLt = '<';
const String kGt = '>';
final String kThinkOpen = '${kLt}think$kGt';
final String kThinkClose = '${kLt}/think$kGt';

class Scenario {
  Scenario(this.name, this.expectRunaway, this.tokens);
  final String name;
  final bool expectRunaway; // 真相：这算不算「思考失控」
  final List<String> tokens;
}

String filler(int n, String seed) {
  const unit = '这是一段端侧小模型的思考独白内容用来填充长度';
  final b = StringBuffer();
  while (b.length < n) {
    b.write(unit);
  }
  return '$seed:${b.toString().substring(0, n)}';
}

List<String> tokenize(String s) {
  final out = <String>[];
  for (var i = 0; i < s.length; i += 12) {
    out.add(s.substring(i, i + 12 > s.length ? s.length : i + 12));
  }
  return out;
}

class Result {
  Result(this.fired, this.produced, this.thinkingAtStop, this.thinkingTotal);
  final bool fired;
  final bool produced;
  final int thinkingAtStop; // 触发那一刻已累计的思考字数
  final int thinkingTotal; // 本场景实际产生的思考总字数
}

Result drive(List<String> tokens, bool Function(AgentStreamProcessor) guard) {
  final p = AgentStreamProcessor();
  var fired = false;
  var atStop = 0;
  for (final t in tokens) {
    p.add(t);
    if (guard(p)) {
      fired = true;
      atStop = p.totalThinkingChars;
      break; // 止损 = 主动 stopGeneration
    }
  }
  p.finish();
  return Result(fired, p.producedAnything, atStop, p.totalThinkingChars);
}

bool gNow(AgentStreamProcessor p) => p.thinking.length > kThreshold;
bool gFix(AgentStreamProcessor p) => p.thinkingRunaway(kThreshold);

void main() {
  final scenarios = <Scenario>[
    Scenario('S1 单块未闭合 think 标签 40k', true,
        tokenize('开场\n\n$kThinkOpen${filler(40000, '独白')}')),
    Scenario('S2 think/response 交替 20 块 共 40k', true, () {
      final t = <String>[];
      for (var i = 0; i < 20; i++) {
        t.addAll(tokenize(
            '$kThinkOpen${filler(2000, '第${i}轮')}$kThinkClose\n'));
      }
      return t;
    }()),
    Scenario('S3 无 opener 独白 40k（守卫盲区）', true,
        tokenize(filler(40000, '无标签独白'))),
    Scenario('S4 Qwen 风格 think 未闭合 40k', true,
        tokenize(' think\n\n${filler(40000, '推理')}')),
    Scenario('S5 正常 思考800+答案300', false,
        tokenize(' think\n\n${filler(800, '推理')}\n response\n\n${filler(300, '答案')}')),
    Scenario('S6 正常 思考800+工具调用', false,
        tokenize(' think\n\n${filler(800, '推理')}\n response\n\n') +
            tokenize('{"tool_call":"write_file","arguments":{"path":"a.py",'
                '"content":"${filler(600, 'print(1)')}"}}')),
    Scenario('S7 正常 40k 工具调用参数', false,
        tokenize('{"tool_call":"write_file","arguments":{"path":"big.html",'
            '"content":"${filler(40000, '<p>x</p>')}"}}')),
    // 诚实计量的取舍场景：思考确实很长（7000 字）但最终会正常作答。
    // 硬阈值 6000 下目标守卫会误杀 → 靠「止损后抢救已产出内容 + 关思考重试一次」兜住，
    // 不再像现在这样整轮判死。
    Scenario('S8 长思考 7000 + 答案 300（取舍）', false,
        tokenize(' think\n\n${filler(7000, '长推理')}\n response\n\n${filler(300, '答案')}')),
  ];

  print('思考失控守卫机检（阈值 $kThreshold 字 = agentThinkingMaxChars 默认）\n');
  print('${_pad('场景', 42)}${_pad('真相', 8)}${_pad('现行', 8)}'
      '${_pad('目标', 8)}${_pad('白烧字(现行/目标)', 24)}判定');
  print('-' * 108);

  var nowMiss = 0, fixMiss = 0, fpNow = 0, fpFix = 0, wasteNow = 0, wasteFix = 0;
  for (final s in scenarios) {
    final a = drive(s.tokens, gNow);
    final b = drive(s.tokens, gFix);
    final wN = s.expectRunaway ? (a.fired ? a.thinkingTotal - a.thinkingAtStop : a.thinkingTotal) : 0;
    final wF = s.expectRunaway ? (b.fired ? b.thinkingTotal - b.thinkingAtStop : b.thinkingTotal) : 0;

    if (s.expectRunaway && !a.fired) nowMiss++;
    if (s.expectRunaway && !b.fired) fixMiss++;
    if (!s.expectRunaway && b.fired && !b.produced) fpFix++;
    if (!s.expectRunaway && a.fired && !a.produced) fpNow++;
    wasteNow += wN;
    wasteFix += wF;

    print('${_pad(s.name, 42)}${_pad(s.expectRunaway ? '失控' : '正常', 8)}'
        '${_pad(a.fired ? '触发' : '漏网', 8)}${_pad(b.fired ? '触发' : '漏网', 8)}'
        '${_pad('$wN / $wF', 24)}${_verdict(s.expectRunaway, a.fired, b.fired)}');
  }

  print('\n==== 汇总 ====');
  print('失控漏网：  现行 $nowMiss / 目标 $fixMiss   （越少越好）');
  print('正常误杀：  现行 $fpNow / 目标 $fpFix   （必须为 0）');
  print('白烧思考：  现行 $wasteNow 字 / 目标 $wasteFix 字   （越少越好）');
  print('备注：S3「无 opener 独白」两种守卫都看不见——它不是思考块，是正文，'
      '要靠工具步关思考 + 采样反重复兜底。');
}

String _pad(String s, int w) {
  var vis = 0;
  final b = StringBuffer();
  for (final r in s.runes) {
    vis += r > 0x2E80 ? 2 : 1;
    b.write(String.fromCharCode(r));
  }
  while (vis < w) {
    b.write(' ');
    vis++;
  }
  return b.toString();
}

String _verdict(bool expect, bool now, bool fix) {
  if (expect) {
    if (!now && !fix) return '两者都漏（盲区）';
    if (!now && fix) return '★ 现行漏网 → 目标已堵';
    if (now && !fix) return '✗ 目标漏网（需修）';
    return '两者都堵';
  }
  return fix ? '✗ 目标误杀' : '放行正常';
}
