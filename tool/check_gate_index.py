#!/usr/bin/env python3
"""门禁的门禁：§11 那份「已机检」清单本身必须可机检。

为什么要有这个脚本（第 90 轮立的）：§11-A 那 36 行是整个平台的"这条有人管"名册。
名册最坏的失效不是漏了一条约束，而是**某行说"机检在某处"，而那处其实什么都没测** ——
文件改名了、测试删了、台账少一行，读者却照着名册放心改代码。这种失效不会让任何测试变红，
只有下一次真事故才会暴露。所以这里静态查四件事：

  1. **表形状**：§11-A 必须是 `| # | 约束 | 机检在哪 | 破坏后的静默症状 |`，每行 5 个竖线；
     （第 82 轮我往表里加列时就是靠"每行恰好 5 个竖线"才敢下手 —— 那条经验进门。）
  2. **文件必须存在**：正文里反引号引出来的 `*.dart` / `*.py` / `*.sh` 路径 —— 带 `/` 的按仓库根解析，
     光板的文件名按全仓 basename 找（名册常写短名，这是**允许的**，但全仓都没有就是假账）。
  3. **每行要有证红台账**：`#### §11-A 证红台账` 里必须能找到同号行，或在末尾那段"明写人查"里点名豁免。
     台账里出现名册没有的号 = 也是错（说明名册删了行而台账还留着，或反之）。
  4. **轮次引用要落地**：§11 里写的「第 N 轮」必须在 §10 有 `### 第 N 轮` 那一节。

跑法：`python3 tool/check_gate_index.py`（可加 `--doc <路径>` 换文档）。
"""
import io
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DOC = os.path.join(ROOT, 'docs', '能力插件体系与英语听写插件_方案_2026-10-23.md')

A_HEAD = '### A. 已经机检的硬约束'
LED_HEAD = '#### §11-A 证红台账'
B_HEAD = '### B. 已知'

CODE_EXTS = ('.dart', '.py', '.sh', '.json', '.yaml')
# 全仓 basename 索引（短名引用的解析面）。跳过这些目录：里面的东西不算仓库内容。
SKIP_DIRS = {'build', '.dart_tool', '.git', 'node_modules', '.gradle', 'ios', 'android'}


def basename_index():
    idx = set()
    for base, dirs, files in os.walk(ROOT):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS and not d.startswith('.')]
        for f in files:
            if f.endswith(CODE_EXTS):
                idx.add(f)
    return idx


def sections(t):
    a = t.find(A_HEAD)
    l = t.find(LED_HEAD)
    b = t.find(B_HEAD)
    if min(a, l, b) < 0 or not (a < l < b):
        return None
    return t[a:l], t[l:b], t[b:]


def main():
    doc = DOC
    if '--doc' in sys.argv:
        doc = sys.argv[sys.argv.index('--doc') + 1]
    if not os.path.exists(doc):
        print('❌ 找不到文档：', doc)
        return 1
    t = io.open(doc, encoding='utf-8').read()
    secs = sections(t)
    if secs is None:
        print('❌ §11 的三个锚点（A / 证红台账 / B）没按顺序找齐 —— 名册结构被改动过，脚本先拒绝猜测。')
        return 1
    A, LED, B = secs
    errs = []

    # —— 1. 表形状 ——
    rows = [l for l in A.split('\n') if l.startswith('| ')]
    if not rows or '| # |' not in rows[0]:
        errs.append('§11-A 表头缺失或不是第一行（应形如 `| # | 约束 | 机检在哪 | 破坏后的静默症状 |`）')
        body = rows
    else:
        body = rows[1:]
    n_rows = 0
    line_ids = set()
    for l in body:
        if set(l.replace('|', '')) <= {'-'}:
            continue
        n_rows += 1
        m = re.match(r'^\|\s*(\d+)[a-z]?\s*\|', l)
        if m:
            line_ids.add(m.group(1))
        # 竖线要**先抹掉行内代码**再数：`capture|llm_extract|…` 这类并集写法里的 `|`
        # 是内容不是分隔符（第 28 / 30 条就是这么写的，直接数会虚报"表形坏了"）。
        shape = re.sub(r'`[^`\n]*`', '', l)
        if shape.count('|') != 5:
            errs.append('§11-A 某行竖线数 = %d（应为 5）：%s…' % (shape.count('|'), l[:40]))

    # —— 2. 引用的文件必须存在 ——
    # 只查"**看起来就是仓库真源**"的引用：名册里同样会出现运行时产物（`课堂.json` 是测试在临时目录
    # 里造的档）、内存夹具（`plugins/bogus/plugin.json` 走 MemIo，从不落盘）、通配（`lib/*.dart`）、
    # 占位（`test/xxx_test.dart`）与注入假件（`mutNN_probe.dart`，跑完就删 —— 它们**本来就该不存在**）。
    # 把这些也算成"假账"的话，脚本会天天红，然后人就学会无视它 —— 那比没脚本更坏。
    REAL_PREFIX = ('lib/', 'packages/', 'test/', 'tool/', 'scripts/', 'docs/', 'android/')
    SKIP_MARKS = ('*', '…', 'xxx', 'XXX', '<', 'NN', 'probe.dart')
    STRICT_EXTS = ('.dart', '.py', '.sh', '.yaml')
    idx = basename_index()
    cited = set()
    for m in re.finditer(r'`([^`\n]+)`', A + LED + B):
        s = m.group(1).strip()
        for tok in re.split(r'[、，,;；\s]+', s):
            tok = tok.strip('()（）*·。')
            if tok.endswith(CODE_EXTS) and not tok.startswith('<'):
                cited.add(tok)
    for p in sorted(cited):
        if p.startswith('/tmp/') or any(k in p for k in SKIP_MARKS):
            continue
        if '/' in p:
            if not p.startswith(REAL_PREFIX):
                continue
            if not os.path.exists(os.path.join(ROOT, p)):
                errs.append('名册引用的路径不存在：`%s`（文件改名/删除后，这一行就成了"说有测试其实没有"）' % p)
        elif p.endswith(STRICT_EXTS) and p not in idx:
            # 光板名只查代码文件：`.json` 常是运行时造的档，查它必假红。
            errs.append('名册引用的文件名全仓找不到：`%s`' % p)

    # —— 3. 每行要有台账 ——
    ledger_ids = set()
    for l in LED.split('\n'):
        m = re.match(r'^\|\s*([0-9]+[a-z]?)\s*\|', l)
        if m:
            ledger_ids.add(m.group(1))
    exempt = set()
    for m in re.finditer(r'第\s*(\d+)(?:\s*/\s*(\d+))?\s*条', LED):
        exempt.add(m.group(1))
        if m.group(2):
            exempt.add(m.group(2))
    for l in body:
        m = re.match(r'^\|\s*(\d+)\s*\|', l)
        if not m:
            continue
        n = m.group(1)
        if n not in ledger_ids and n not in exempt:
            errs.append('§11-A 第 %s 行写着"已机检"，但证红台账里没有它，也没在"明写人查"里点名豁免'
                        '（名册不能只靠印象存在）：%s…' % (n, l[:40]))
    # 台账里出现了名册没有的号 = 假证据（名册删了行、台账还留着，或编号打错）。
    # 允许 `27b` 这种**子行**：它挂在自己的主行 27 下面（第 89 轮就是这么补的）。
    def base(x):
        return re.sub(r'[a-z]+$', '', x)

    orphans = sorted((i for i in ledger_ids
                      if base(i) not in line_ids), key=lambda s: (int(base(s) or 0), s))
    if orphans:
        errs.append('台账里有名册没有的号（名册删了行、台账还留着 = 假证据）：%s' % ', '.join(orphans))

    # —— 4. 轮次引用要落地 ——
    heads = set(re.findall(r'### 第 (\d+) 轮', t))
    cited_rounds = set(re.findall(r'第 (\d+) 轮', A + LED))
    dangling = sorted((r for r in cited_rounds if r not in heads), key=int)
    for r in dangling:
        errs.append('§11 引用了「第 %s 轮」，但 §10 里没有 `### 第 %s 轮` 那一节（证据无处可查）' % (r, r))

    print('§11-A 名册 %d 行；台账 %d 条；短名/路径引用 %d 个；轮次引用 %d 个'
          % (n_rows, len(ledger_ids), len(cited), len(cited_rounds)))
    if errs:
        print('❌ 名册自检发现 %d 处问题：' % len(errs))
        for e in errs:
            print('   ·', e)
        return 1
    print('OK：名册每一行都对得上文件、台账与轮次')
    return 0


if __name__ == '__main__':
    sys.exit(main())
