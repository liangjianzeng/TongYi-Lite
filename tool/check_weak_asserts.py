#!/usr/bin/env python3
"""弱断言参谋（只报不改，永远 exit 0）。

为什么单独一个工具、而且**不当法官**：
`tool/check_fail_texts.py` 管的是"产品说的话有没有人引用"；本工具管的是另一头 ——
**测试看着像在断言，其实什么都没过**：

    expect(r.failureOrNull!.hint, isNotEmpty);          // 产品随便说两句都过
    expect(r.failureOrNull?.message, contains('没有'));  // 2 个字，什么都能过
    expect(r.failureOrNull?.hint, contains('拍'));       // 1 个字

这类断言比没写更坏：它让"这条文案有人管"成为一句假话（见方案档 §11-C）。

但它**只能当参谋**：`contains('900')`（断越界值）、`anyOf(contains('tts'), contains('llm'))`（断二选一）
都是正当写法，脚本分不出来。所以判红绿仍归人，本工具只负责把候选清单摊开，
并且故意 **exit 0** —— 它不该把 CI 带崩，也不该被塞进 `check_fail_texts.py` 那种硬门禁里
（那样人们只会去放宽判据，判据一松就再没人信它）。

用法：python3 tool/check_weak_asserts.py [目录…]   # 不给目录就用下面默认的几个
"""

import io
import os
import re
import sys

# 默认扫描根**锚在脚本自己所在的仓库根**，不靠 cwd。
# 这条规矩是被自己抓出来的：门禁套件从 `packages/plugin_kernel` 里跑它时，相对路径全部落空，
# 于是「候选 0」永远为真、`--max` 永远不红 —— 一个永远不会红的门禁比没有门禁更坏（§11-C）。
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

DEFAULT_ROOTS = [
    os.path.join(ROOT, 'packages', 'plugin_kernel', 'test'),
    os.path.join(ROOT, 'packages', 'plugin_sdk', 'test'),
    os.path.join(ROOT, 'test', 'plugins'),
    os.path.join(ROOT, 'examples'),
]

# 失败对象上的"空断言"：isNotEmpty / isNotNull 只证明"有东西"，不证明"说了该说的话"
RE_EMPTY = re.compile(r'failureOrNull[^;]*\bis(NotEmpty|NotNull)\b')
# contains('很短')：中文字按字算，≤4 基本等于转述；ASCII 短串另说（数字、id 片段是正当的）
RE_SHORT = re.compile(r"failureOrNull.*?contains\('([^']*)'")
# 只报"看起来像中文句子的一部分"的短串；纯数字/纯 ASCII 短串留给人工判断
RE_SENTENCEISH = re.compile(r'[一-鿿]')

# 明账豁免：正当写法（断数字、断 id 片段、"异常进诊断不进 message"的 cause isNotNull…）
# 必须**写下理由**才豁免 —— 只写标记不写理由不算登记，否则三个月后没人知道当时为什么放过。
MARK = '参谋保留：'


def _exempt(lines, idx):
    """本行、或紧邻的上面两行里登记了 `参谋保留：<理由>`（理由 ≥4 字）才算明账。

    往上看到 2 行是为了让"两行注释解释一件事"这种写法也算登记；再往上就不看了 ——
    豁免必须**贴着**那条断言，否则一条注释能豁免整页测试。
    """
    for j in (idx, idx - 1, idx - 2):
        if 0 <= j < len(lines) and MARK in lines[j]:
            reason = re.sub(r'[\s*/]+', '', lines[j].split(MARK, 1)[1])
            if len(reason) >= 4:
                return True
    return False


def scan_file(path):
    out, exempt = [], 0
    try:
        lines = io.open(path, encoding='utf-8').read().split('\n')
    except (OSError, UnicodeDecodeError):
        return out, exempt
    for i, line in enumerate(lines, 1):
        if line.lstrip().startswith('//'):
            continue
        hit = None
        if RE_EMPTY.search(line):
            hit = (i, '空断言（isNotEmpty/isNotNull 当判词）', line.strip())
        else:
            m = RE_SHORT.search(line)
            if m:
                needle = m.group(1)
                if len(needle) <= 4 and RE_SENTENCEISH.search(needle):
                    hit = (i, f"短转述 contains('{needle}')", line.strip())
        if hit is None:
            continue
        if _exempt(lines, i - 1):
            exempt += 1
        else:
            out.append(hit)
    return out, exempt


def main():
    argv = sys.argv[1:]
    limit = None
    if '--max' in argv:
        k = argv.index('--max')
        if k + 1 >= len(argv) or not argv[k + 1].isdigit():
            print('用法：--max <整数>（不给整数就是参谋模式，永远退出 0）')
            return 2
        limit = int(argv[k + 1])
        del argv[k:k + 2]
    roots = argv or DEFAULT_ROOTS
    total, files, exempt = 0, 0, 0
    for root in roots:
        if os.path.isfile(root):
            walked = [('.', [os.path.basename(root)])] if root.endswith('_test.dart') else []
        elif os.path.isdir(root):
            walked = [(dp, [f for f in fns if f.endswith('_test.dart')]) for dp, _, fns in os.walk(root)]
        else:
            print(f'跳过不存在的路径：{root}')
            continue
        for dp, fns in walked:
            for fn in sorted(fns):
                hits, ex = scan_file(os.path.join(dp, fn))
                exempt += ex
                if not hits:
                    continue
                files += 1
                total += len(hits)
                print(f'--- {os.path.join(dp, fn)}  （{len(hits)} 处）')
                for ln, kind, text in hits:
                    print(f'    :{ln} [{kind}] {text[:100]}')
    print(f'\n候选 {total} 处 / {files} 个文件；另有 {exempt} 处已登记明账（{MARK}理由）。')
    print('这些只是**候选**：断数字、断 id 片段、anyOf 二选一都是正当写法。')
    print('判据：一句用户看得见的失败文案，测试里应当出现它的**原句**（≥6 字），而不是它的骨头。')
    print(f'要长期当哨兵就加 --max N；豁免必须在代码里写「{MARK}理由」，不写理由不算登记。')
    if limit is not None and total > limit:
        print(f'超线：候选 {total} > 上限 {limit}')
        return 1
    return 0  # 参谋模式（无 --max）不参与红绿灯


if __name__ == '__main__':
    sys.exit(main())
