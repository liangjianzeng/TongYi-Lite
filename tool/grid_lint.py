#!/usr/bin/env python3
"""grid_lint.py - 给 docs/Mesa与Vulkan线_架构问题网格 当闸门用（把 R3/R4/BLACKBOX 三条纪律变成机检）

网格最大的风险不是写歪，是**烂回去**：状态词被人随手写成"已排除"、开放格没有下一发实验、
BLACKBOX 格没有可观测判据 —— 这三种正是 2026-10-20 一天烧掉三轮真机窗口的原因。
所以这个脚本不是格式化玩具，它拒绝的是"看起来像结论的散文"。

用法:
    python3 tool/grid_lint.py [docs/Mesa与Vulkan线_架构问题网格_2026-10-21.md]
退出码: 0 = 无 error（warn 允许，但会汇总）; 1 = 有 error; 2 = 用法/文件错
"""
import os
import re
import sys
import collections

STATUS_WORDS = ("关闭", "开放", "未观测", "阻塞", "不可达", "待观测")
MALLABLE = ("OWN-BLOCKED", "OWN", "UP", "BLACKBOX", "HW", "混合", "外部")
SPLIT = re.compile(r"(?<!\\)\|")          # 单元格里用 \| 转义过竖线，别把它当分隔符
DATE = re.compile(r"20\d\d-\d\d-\d\d|(?<!\d)\d\d-\d\d(?!\d)")
LAYER_MODE = re.compile(r"L\d.*×.*M\d|\bM(9|10)\b|\bM\d\b")

def is_row(cells):
    return len(cells) >= 4 and re.match(r"^\s*\*\*G-\d+…?\*\*$", cells[0] or "")

def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    path = sys.argv[1] if len(sys.argv) > 1 else None
    if not path:
        cand = [f for f in os.listdir(os.path.join(root, "docs"))
                if f.startswith("Mesa与Vulkan线_架构问题网格")]
        if not cand:
            print("找不到网格文档", file=sys.stderr); return 2
        path = os.path.join(root, "docs", sorted(cand)[-1])

    lines = open(path, encoding="utf-8").read().splitlines()
    errors, warns, rows = [], [], []
    seen = {}

    for n, raw in enumerate(lines, 1):
        if not raw.lstrip().startswith("|"):
            continue
        cells = [c.strip() for c in SPLIT.split(raw.strip())]
        cells = cells[1:-1] if len(cells) > 2 else cells      # 去掉首尾空管道
        if not is_row(cells):
            continue
        gid = cells[0].strip("* ")
        body = " ".join(cells)
        rows.append((n, gid, cells))

        if gid in seen:
            errors.append(f"L{n} {gid}: 格号重复（首次 L{seen[gid]}）- 一格一号是网格的前提")
        seen[gid] = n

        if not LAYER_MODE.search(body):
            errors.append(f"L{n} {gid}: 缺 `层×模式` 定位 —— 没有位置就没有排除作用域（病 B1）")

        if not any(m in body for m in MALLABLE):
            errors.append(f"L{n} {gid}: 缺可改性标记（OWN/OWN-BLOCKED/UP/BLACKBOX/HW）")

        status = next((s for s in STATUS_WORDS if s in body), None)
        if status is None:
            errors.append(f"L{n} {gid}: 缺状态词（{'/'.join(STATUS_WORDS)} 之一）")
            continue

        if status == "关闭":
            if not DATE.search(body):
                errors.append(f"L{n} {gid}: 关闭态没有日期 —— 无日期的关闭 = 下一代会整格翻案（病 B1/R4）")
            if "已排除" in body and not re.search(r"仅排除|作用域|不排除", body):
                errors.append(f"L{n} {gid}: 裸『已排除』没写作用域 —— 必须写明只排除了哪一格（R4）")
            if not re.search(r"判具|gate|脚本|\.sh|\.py|实测|md5", body):
                warns.append(f"L{n} {gid}: 关闭态没提判具/证据来源，复核时无法重跑")
        elif status == "开放":
            if not re.search(r"判真|判伪|下一发|待办|待补|实验|A/B|需人接手|插桩|判据|靶子|下一刀|先跑|复跑|复验|修法|撤资|拒绝|机检", body):
                errors.append(f"L{n} {gid}: 开放态却没有下一发判定实验/两个预测 —— 这是嫌疑不是待办（R3）")
        elif status == "未观测":
            if not re.search(r"仪器|接通|没打印|恒空|未接通", body):
                warns.append(f"L{n} {gid}: 未观测态建议写明是哪件仪器没接通，便于日后接上再判")

        if "BLACKBOX" in body and not re.search(r"不可达|观测|数据表|known_bad|跟踪上游|上报", body):
            errors.append(f"L{n} {gid}: BLACKBOX 格没自带可观测判据/出口 —— 不可改又测不了的格是死账，应转 UNREACHABLE")

    by_status = collections.Counter(s for _, _, c in rows
                                    for s in STATUS_WORDS if any(s in x for x in c))
    print(f"网格: {os.path.basename(path)}")
    print(f"格子 {len(rows)} 个 | error {len(errors)} | warn {len(warns)}")
    print("状态分布: " + "  ".join(f"{k}={v}" for k, v in sorted(by_status.items())))
    print()
    for e in errors:
        print("  [ERROR] " + e)
    for w in warns:
        print("  [warn ] " + w)
    if errors:
        print("\n结论: 不许当裁决输入用 —— 先把 error 清零（R3/R4）。")
        return 1
    print("\n结论: 结构合规。开放格若仍缺判真/判伪，按 R3 视为 `待观测`，不占排查预算。")
    return 0

if __name__ == "__main__":
    sys.exit(main())
