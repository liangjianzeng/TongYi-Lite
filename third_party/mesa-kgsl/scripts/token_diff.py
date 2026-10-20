#!/usr/bin/env python3
"""[Mesa 线 P2] 逐 token 比对：判定"kernel 丢失"到底从第几个 token 开始毁掉输出。

E2E_TOKDUMP=<path> 让 minicpm_e2e 把生成 token id（i32 LE）落文件。本工具把它们读回来，
以"参照序列"（通常是 CPU 腿，或已知正确的 Mesa flush=1 腿）为基准，报每条待测序列的
**首个分歧位置**与分歧率。这是 P2 的验收尺子：`OPFLUSH=0` 做到与参照 48 token 全等 = 修好。

用法：token_diff.py <参照.bin> <待测1.bin> [待测2.bin ...]
"""
import os
import struct
import sys


def load(p):
    if not os.path.exists(p):
        return None
    b = open(p, "rb").read()
    n = len(b) // 4
    return list(struct.unpack("<%di" % n, b[: n * 4]))


def first_div(a, b):
    for i, (x, y) in enumerate(zip(a, b)):
        if x != y:
            return i
    return min(len(a), len(b))


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    ref_p = sys.argv[1]
    ref = load(ref_p)
    if not ref:
        print(f"参照序列读不到：{ref_p}", file=sys.stderr)
        return 2
    print(f"参照 = {os.path.basename(ref_p)}  长度={len(ref)}  前 8: {ref[:8]}")
    print()
    print("| 待测 | 长度 | 首个分歧位置 | 分歧率 | 判定 |")
    print("|---|---|---|---|---|")
    bad = 0
    for p in sys.argv[2:]:
        t = load(p)
        if t is None:
            print(f"| {os.path.basename(p)} | 缺文件 | - | - | 未产出（腿失败） |")
            bad += 1
            continue
        d = first_div(ref, t)
        n = min(len(ref), len(t))
        rate = sum(1 for i in range(n) if ref[i] != t[i]) / max(1, n)
        verdict = "全等 PASS" if (d >= n and len(t) == len(ref)) else f"从第 {d} 个 token 起崩"
        if not verdict.endswith("PASS"):
            bad += 1
        print(f"| {os.path.basename(p)} | {len(t)} | {d} | {rate:.0%} | {verdict} |")
    print()
    print("> 读表口径：首个分歧位置 = 从第几个 token 开始与参照不同（越大越好）；"
          "`全等 PASS` 要求长度相同且逐 token 相同。P2 的验收是 **OPFLUSH=0 与 CPU 参照 48 token 全等**。")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
