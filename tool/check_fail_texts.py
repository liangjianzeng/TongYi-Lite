#!/usr/bin/env python3
"""门禁：插件平台里**每一条用户看得见的失败文案**都必须被测试引用。

为什么要有这个脚本（方案档 §11-A 第 33 行）：平台上最贵的一批缺陷是静默的 ——
守卫、状态、契约都能被 mutation 测逼红，唯独**给人看的那句话**没人管：文案改了、错别字、
指错方向（"去设置里打开"而真相是"本机没这个能力"），测试全绿而用户在原地打转。

判据：
  1. 扫产品侧文件里的 `message: '…'` / `hint: '…'` 字面量（这些是要进面板/CLI 给人读的）；
  2. 剥掉 `${…}` 插值后切成片段，**只要有任何一段（≥6 字符）在测试里原样出现**，就算被引用；
  3. 一条都没有的，必须在 `tool/fail_text_baseline.txt` 里挂着（历史欠账，逐条写原因）；
     不在基线里 = **新增未引用的文案** → 退出码 1，CI/提交前该拦住它。

首次运行没有基线文件时会生成一份（当前所有未命中项 = 已知欠账），此后只拦新增。
跑法：`python3 tool/check_fail_texts.py`（想顺手更新基线：`--update`）。
"""
import io
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BASELINE = os.path.join(ROOT, 'tool', 'fail_text_baseline.txt')

PROD_DIRS = [
    ('packages/plugin_kernel/lib/src', '.dart'),
    # 注意：`packages/plugin_sdk/lib/testing.dart` 不在扫描面里 —— 它是测试支持件，
    # 里面的 message/hint 是**测试自己写的假失败**（FakeSpeak 的预设错误等），
    # 要求它"被测试引用"是循环论证，会把真欠账淹在假账里。
    ('packages/plugin_sdk/lib/src', '.dart'),
    ('lib/plugins', '.dart'),
    ('lib/services', '.dart'),
    ('lib/widgets', '.dart'),
]
TEST_DIRS = ['packages/plugin_kernel/test', 'packages/plugin_sdk/test', 'test']
# 第 88 轮：引用判据也换成同一个扫描器（原来这里是一条 `'(?:[^'\\]|\\.)*'` 正则）。
# 那个正则有两个洞，让"必须被测试引用"这条门禁有一半是虚的：
#   * 只认**单引号** —— 写成 `message: "…"` 的文案根本不参加判定；
#   * 只认**单段** —— `message: '前半' '后半'` 只有第一段参加，而最有判别力的半句常在后面。
# 两条都是"文案没人引用而测试全绿"的静默路径，与第 87 轮 shape 那条同源，共用 `_string_arg_at`。
FIELD_REF_RE = re.compile(r"\b(?:message|hint)\s*:\s*")
MIN_LEN = 6

# —— 第 87 轮补：`PluginFailure.message` 的**形状**机检（§11-B 那条「只在代码里约定」）——
# 契约在 `outcome.dart` 里是 `assert(message.length <= 120)`：**release 把 assert 剥掉之后没人管**，
# 而且 assert 只在"那条失败真的被构造出来"时才跑 —— 没人走过的分支里塞一条 300 字的、
# 或者直接把 `Instance of 'X'` 当 message（那是异常原文，不是人话），全仓测试照样绿。
# 所以这里静态扫**全部** `message:` 字面量，不看有没有人路过。
SHAPE_BASELINE = os.path.join(ROOT, 'tool', 'fail_text_shape_baseline.txt')
MAX_MESSAGE = 120
EXCEPTION_MARKERS = [
    "Instance of", "Exception", "Error:", "type '", "Null check", "Failed assertion",
    r'#0 ', r'\n',  # 换行属于 hint/cause，给人看的一行话里不该出现
]


def _string_arg_at(src, i):
    """从 `src[i]` 起读一条 Dart **字符串实参**，返回原文（没引号 = None）。

    两件事必须一起处理，第 87 轮注入假件时两条都漏过一次：
    * **相邻拼接**：`message: '前半' '后半'` 是合法写法，长文案几乎都这么排 ——
      只取第一段的话，一条 300 字的 message 在正则里"只有 60 字"，门禁形同虚设；
    * **双引号**：`message: "…"` 同样合法，只认单引号就是给不合格文案留了个后门。
    """
    n = len(src)
    parts = []
    while i < n:
        while i < n and src[i] in ' \t\r\n':
            i += 1
        if i >= n or src[i] not in ('"', "'"):
            break
        q = src[i]
        i += 1
        buf = []
        closed = False
        while i < n:
            c = src[i]
            if c == '\\':                      # 转义（含 \' \" \\ \n）原样带上，交给判据看
                buf.append(src[i:i + 2])
                i += 2
                continue
            if c == '$' and i + 1 < n and src[i + 1] == '{':
                # 插值段整段原样带上，但**必须认得里面的嵌套字符串与花括号**：
                # `'…${x == null ? '' : '，计划 y 移除'}）'` 里那个 `''` 的引号，
                # 不认嵌套就会在这里提前收尾（第 88 轮实测：`deprecations.dart:58` 被截成半句 → 假账）。
                depth = 0
                while i < n:
                    c2 = src[i]
                    if c2 == '\\':
                        buf.append(src[i:i + 2])
                        i += 2
                        continue
                    if c2 == '{':
                        depth += 1
                    elif c2 == '}':
                        depth -= 1
                        buf.append(c2)
                        i += 1
                        if depth == 0:
                            break
                        continue
                    elif c2 in ('"', "'"):
                        q2 = c2
                        i += 1
                        while i < n:
                            if src[i] == '\\':
                                i += 2
                                continue
                            if src[i] == q2:
                                i += 1
                                break
                            i += 1
                        continue
                    buf.append(c2)
                    i += 1
                continue
            if c == q:
                i += 1
                closed = True
                break
            buf.append(c)
            i += 1
        if not closed:
            break
        parts.append(''.join(buf))
    return ''.join(parts) if parts else None


def message_shape():
    """返回所有**不合格**的 message 字面量：`文件:行<TAB>原因`。"""
    bad = []
    for d, ext in PROD_DIRS:
        for p in walk(d, ext):
            src = read(p)
            if not src:
                continue
            for m in re.finditer(r'\bmessage\s*:\s*', src):
                lit = _string_arg_at(src, m.end())
                if lit is None:
                    continue  # `message: someVar` / 函数调用 —— 静态判不了，不猜
                plain = lit.replace("\\'", "'").replace('\\"', '"')
                # 插值段按最短算（0 字）仍然超长，才算真超长 —— 否则 `'$x'` 这种会被误伤。
                bare = re.sub(r'\$\{[^}]*\}|\$\w+', '', plain)
                rel = os.path.relpath(p, ROOT)
                line = src[:m.start()].count('\n') + 1
                if len(bare) > MAX_MESSAGE:
                    bad.append('%s:%d\t（%d 字，超过 %d）%s'
                               % (rel, line, len(bare), MAX_MESSAGE, re.sub(r'\s+', ' ', bare[:70]).strip()))
                    continue
                hit = next((k for k in EXCEPTION_MARKERS if k in plain), None)
                if hit is not None:
                    bad.append('%s:%d\t（夹了异常原文 %r，该进 cause）%s'
                               % (rel, line, hit, re.sub(r'\s+', ' ', plain[:70]).strip()))
    return bad



def read(p):
    try:
        return io.open(p, encoding='utf-8').read()
    except (OSError, UnicodeDecodeError):
        return ''


def walk(d, ext):
    out = []
    for dirpath, _dirs, names in os.walk(os.path.join(ROOT, d)):
        for n in names:
            if n.endswith(ext):
                out.append(os.path.join(dirpath, n))
    return out


def fragments(lit):
    """插值切成片段；测试里只要原样含其中任一段（≥MIN_LEN）就算这条文案被引用。"""
    parts = []
    for chunk in re.split(r'\$\{[^}]*\}|\$\w+', lit):
        c = re.sub(r'\s+', '', chunk.replace("\\'", "'"))
        if len(c) >= MIN_LEN:
            parts.append(c)
    return parts


def main():
    update = '--update' in sys.argv
    tests = []
    for d in TEST_DIRS:
        for p in walk(d, '.dart'):
            t = read(p)
            if t:
                tests.append(re.sub(r'\s+', '', t))
    blob = '\n'.join(tests)
    # 反向判据（第 33 轮立的：命中不了要**双向**匹配）：测试常常只引用一条长文案里最有判别力的
    # 半句（产品写「这次扫描一个插件都没能解析出来，先沿用上一次好的清单」，测试只断「沿用上一次好的清单」）。
    # 只按"产品片段 ⊆ 测试"会把这些判成没引用，欠账虚高到人开始往基线里塞东西，门禁就废了。
    # 取测试里的字符串字面量做反向比对；≥8 字符才算数，太短的谁都能撞上（那是误伤）。
    test_snips = set()
    for d in TEST_DIRS:
        for p in walk(d, '.dart'):
            for m in re.finditer(r"'((?:[^'\\]|\\.)*)'", read(p)):
                s = re.sub(r'\s+', '', m.group(1))
                s = re.sub(r'\$\{[^}]*\}|\$\w+', '', s)
                if len(s) >= 8:
                    test_snips.add(s)
    snips = sorted(test_snips, key=len, reverse=True)

    unrefed = []
    total = 0
    for d, ext in PROD_DIRS:
        for p in walk(d, ext):
            src = read(p)
            if not src:
                continue
            for m in FIELD_REF_RE.finditer(src):
                lit = _string_arg_at(src, m.end())
                if lit is None:
                    continue  # `message: someVar` / `message: f(x)` —— 静态判不了，不猜
                if '${' not in lit and len(re.sub(r'\s+', '', lit)) < MIN_LEN:
                    continue  # 短到没有判别力的（如 "ok"）不参与
                total += 1
                frags = fragments(lit)
                if not frags:
                    continue
                whole = re.sub(r'\$\{[^}]*\}|\$\w+', '', re.sub(r'\s+', '', lit))
                if any(f in blob for f in frags) or any(s in whole for s in snips):
                    continue
                line = src[:m.start()].count('\n') + 1
                rel = os.path.relpath(p, ROOT)
                # 存盘前把空白压平并 strip：读基线时是逐行 strip 的，
                # 尾随空格不抹掉的话同一批文案每次跑都被当成"新增" —— 门禁自己不稳定，比没门禁更坏。
                one = re.sub(r'\s+', ' ', lit[:100]).strip()
                unrefed.append(f'{rel}:{line}\t{one}')

    known = set()
    if os.path.exists(BASELINE):
        for ln in read(BASELINE).splitlines():
            ln = ln.strip()
            if ln and not ln.startswith('#'):
                known.add(ln)

    fresh = [u for u in unrefed if u not in known]

    if update or not os.path.exists(BASELINE):
        head = ('# 用户可见失败文案 —— 尚无测试引用的历史欠账（check_fail_texts.py 生成）。\n'
                '# 每行「文件:行<TAB>文案前缀」。**不要**为了消红把新文案塞进来：给它写一条测试引用才是正解。\n')
        io.open(BASELINE, 'w', encoding='utf-8').write(head + '\n'.join(u for u in unrefed) + '\n')
        print(f'基线已写入 {os.path.relpath(BASELINE, ROOT)}：共 {len(unrefed)} 条未引用（历史欠账）')
        return 0

    rc = 0
    print(f'扫到用户可见文案 {total} 条；基线内历史欠账 {len(unrefed) - len(fresh)} 条')
    if not fresh:
        print('OK：没有新增未引用的用户可见文案')
    else:
        print(f'❌ 新增 {len(fresh)} 条用户看得见的文案没有任何测试引用：')
        for u in fresh:
            print('   ·', u)
        print('正解是给这句话写一条测试（断文案原样出现在测试里），不是把它加进基线。')
        rc = 1

    shape = message_shape()
    known_shape = set()
    if os.path.exists(SHAPE_BASELINE):
        for ln in read(SHAPE_BASELINE).splitlines():
            ln = ln.strip()
            if ln and not ln.startswith('#'):
                known_shape.add(ln)
    fresh_shape = [s for s in shape if s not in known_shape]
    if '--update-shape' in sys.argv:
        head = ('# PluginFailure.message 的形状欠账（check_fail_texts.py --update-shape 生成）。\n'
                '# 每行「文件:行<TAB>原因」。正解是把文案改短、把异常原文挪进 cause，'
                '不是往这里塞一条就完事。\n')
        io.open(SHAPE_BASELINE, 'w', encoding='utf-8').write(head + '\n'.join(shape) + '\n')
        print(f'形状基线已写入 {os.path.relpath(SHAPE_BASELINE, ROOT)}：共 {len(shape)} 条历史欠账')
    else:
        print(f'message 形状不合格 {len(shape)} 条；基线内 {len(shape) - len(fresh_shape)} 条')
        if fresh_shape:
            print(f'❌ 新增 {len(fresh_shape)} 条不合格 message（超长，或把异常原文当成人话）：')
            for s in fresh_shape:
                print('   ·', s)
            print('正解：给用户的一句人话；异常原文进 cause，长说明进 hint。')
            rc = 1
        else:
            print('OK：没有新增不合格的 message')
    return rc


if __name__ == '__main__':
    sys.exit(main())
