#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""X1 打点机检 + 性能台账（全 GPU 卸载战役 · 地图 §7 流程的执行体）。

用法：
  python tool/bench_log_check.py check "<[BENCH] 行>"   # 只校验
  python tool/bench_log_check.py add   "<[BENCH] 行>"   # 校验+入台账（返回台账 ID）
  python tool/bench_log_check.py verify                # 审计整本台账
  python tool/bench_log_check.py last [N]              # 看最近 N 条（默认 10）

指纹头契约（缺一即拒，拒收的数不许进决策——地图 B3 教训）：
  [BENCH] mode=<M-CPU|M-MIX|M-GPU> stack=<S-VOCL|S-MOCL|S-VK> model=<id>
          dev=<740|830|650> la=<负载小数> [thermal=<cold|warm|hot>]
          ngl=<层数|auto> kv=<f16|q4_0|q8_0> ubatch=<n|auto> [mr1=<on|off>]
          build=<构建指纹> prompt=<口径> leg=<i/n> tok=<n>
          metric=<decode|prefill> <值字段…：tps=.. [splits=..] [ops=..] [ms=..]>
"""
import json
import os
import re
import sys
import datetime

LEDGER = os.path.join(os.path.dirname(__file__), "..", "bench_ledger.jsonl")

MODES = {"M-CPU", "M-MIX", "M-GPU", "probe"}  # probe=非模型微基准（硬件特性，如发射税/命令缓冲）
STACKS = {"S-VOCL", "S-MOCL", "S-VK"}
DEVS = {"740", "830", "650"}
REQUIRED = ["mode", "stack", "model", "dev", "la", "ngl", "kv", "ubatch",
            "build", "prompt", "leg", "tok", "metric"]
VALUE_KEYS = ("tps", "ms")  # 至少一个值字段


def parse(line: str) -> dict:
    """把一行 [BENCH] k=v 解析成 dict；结构坏/字段缺/枚举错 → 抛 ValueError。"""
    line = line.strip()
    if not line.startswith("[BENCH]"):
        raise ValueError("缺 [BENCH] 前缀（无指纹头的数据一律拒收）")
    kv = dict(re.findall(r"(\w+)=(\S+)", line))
    for k in REQUIRED:
        if k not in kv or not kv[k] or kv[k].lower() in {"null", "none", "nan", "-"}:
            raise ValueError(f"必填字段缺失或空值：{k}")
    if kv["mode"] not in MODES:
        raise ValueError(f"mode 非法：{kv['mode']}（合法 {sorted(MODES)}）")
    if kv["stack"] not in STACKS:
        raise ValueError(f"stack 非法：{kv['stack']}（合法 {sorted(STACKS)}）")
    if kv["dev"] not in DEVS:
        raise ValueError(f"dev 非法：{kv['dev']}（合法档位 {sorted(DEVS)}；跨档数据只旁证）")
    try:
        la = float(kv["la"])
    except ValueError:
        raise ValueError(f"la 非数字：{kv['la']}")
    if la >= 2.0:
        raise ValueError(f"la={la} ≥2 非安静态，腿数据无效（X3 纪律；冷机窗口重跑）")
    if not any(k in kv for k in VALUE_KEYS):
        raise ValueError("缺值字段（tps=… 或 ms=…）")
    if not re.match(r"^\d+/\d+$", kv["leg"]):
        raise ValueError(f"leg 形如 i/n：{kv['leg']}")
    kv["la"] = la
    return kv


def next_id() -> str:
    n = 0
    if os.path.exists(LEDGER):
        with open(LEDGER, encoding="utf-8") as f:
            for ln in f:
                try:
                    m = int(json.loads(ln)["id"].split("-")[1])
                    n = max(n, m)
                except Exception:
                    continue
    return f"leg-{n + 1:03d}"


def add(line: str) -> str:
    kv = parse(line)
    lid = next_id()
    rec = {"id": lid,
           "ts": datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
           **kv, "raw": line.strip()}
    with open(LEDGER, "a", encoding="utf-8") as f:
        f.write(json.dumps(rec, ensure_ascii=False) + "\n")
    return lid


def verify() -> int:
    if not os.path.exists(LEDGER):
        print("台账为空（bench_ledger.jsonl 不存在）")
        return 0
    bad = 0
    with open(LEDGER, encoding="utf-8") as f:
        for i, ln in enumerate(f, 1):
            try:
                rec = json.loads(ln)
                parse(rec["raw"])
                print(f"{rec['id']}  OK   {rec['raw'][:100]}")
            except (ValueError, KeyError) as e:
                bad += 1
                print(f"行{i}  BAD  {e}")
    print(f"—— {'台账有脏数据，先清洗再引用' if bad else '全部通过'}")
    return 1 if bad else 0


def last(n: int) -> None:
    if not os.path.exists(LEDGER):
        print("台账为空")
        return
    with open(LEDGER, encoding="utf-8") as f:
        lines = f.readlines()
    for ln in lines[-n:]:
        rec = json.loads(ln)
        print(f"{rec['id']}  {rec['ts']}  {rec['raw']}")


def main() -> None:
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)
    cmd = sys.argv[1]
    if cmd == "check":
        try:
            parse(sys.argv[2])
        except ValueError as e:
            print(f"拒收：{e}"); sys.exit(1)
        print("OK")
    elif cmd == "add":
        try:
            print(add(sys.argv[2]))
        except ValueError as e:
            print(f"拒收：{e}"); sys.exit(1)
    elif cmd == "verify":
        sys.exit(verify())
    elif cmd == "last":
        last(int(sys.argv[2]) if len(sys.argv) > 2 else 10)
    else:
        print(__doc__); sys.exit(2)


if __name__ == "__main__":
    main()
