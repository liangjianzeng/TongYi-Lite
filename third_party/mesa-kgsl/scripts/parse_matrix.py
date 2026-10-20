#!/usr/bin/env python3
"""[Mesa 线] 把 run_mesa_matrix.sh / run_kgsl_probe.sh 的日志折成"每 token 预算分解表"。

为什么要有它（血泪教训）：上一轮"Mesa 线不成立"的裁决建立在**没有分解**的单一 t/s 上——
1.2 t/s 既可能是 GPU 执行慢，也可能是提交税、专家 IO、或 Mesa 调试版 printf。
不分层就判生死 = 拿噪声当证据。本表把一次 token 的时间拆成：
  宿主提交侧（host_ms = decode wall）/ 专家 IO（pread 累计，跨 IO 线程并行，需标注并发度）/
  GPU 提交计数（KGSLSUBMIT，只有诊断腿才有）/ 文本健康（防止拿垃圾输出换速度）。

用法：
  parse_matrix.py <主日志 p1_matrix2.log> [--dir <logdir>] [--kgsl <kgsl_probe 输出目录>]
"""
import argparse
import os
import re
import statistics
import sys

METRIC = re.compile(r"\[e2e\]\[METRIC\] leg=(\w+) gen=(\d+) wall_ms=([\d.]+) tok_s=([\d.]+)")
PREFILL = re.compile(r"\[e2e\] prefill (\d+) ms")
DECODE_IO = re.compile(r"total\[decode\]: miss=(\d+) bytes=([\d.]+) MiB pread=(\d+)ms")
LOAD = re.compile(r"load (\d+) ms")
LEGHDR = re.compile(r"^-- LEG (\S+) round=(\d+)")
ENVD = re.compile(r"^--   env: (.*)$")
RC = re.compile(r"^--   rc=(\d+)")
HEALTH = re.compile(r"health_hits=(\d+)")
IOSTAT = re.compile(r"--   io: (.*)$")
BUILD = re.compile(r"^(git=\S+|flags=\S+|built=\S+)")
SUBMIT = re.compile(r"^KGSLSUBMIT cmd\[")


def parse_main(path, logdir):
    legs = {}
    cur = None
    build = []
    for line in open(path, encoding="utf-8", errors="replace"):
        m = BUILD.match(line.strip())
        if m:
            build.append(m.group(1))
        m = LEGHDR.match(line)
        if m:
            cur = (m.group(1), int(m.group(2)))
            legs[cur] = {"env": "", "rc": None, "tok_s": None, "gen": None,
                         "wall_ms": None, "prefill_ms": None, "load_ms": None,
                         "health": None, "io": ""}
            continue
        if not cur:
            continue
        m = ENVD.match(line)
        if m:
            legs[cur]["env"] = m.group(1).strip()
            continue
        m = RC.match(line)
        if m:
            legs[cur]["rc"] = int(m.group(1))
            # 注意：不能 continue —— 同一行还带着 METRIC / prefill / health（脚本是一行 echo 出来的）
        m = HEALTH.search(line)
        if m:
            legs[cur]["health"] = int(m.group(1))
        m = IOSTAT.match(line)
        if m and m.group(1).strip() != "no_decode_io_stats":
            legs[cur]["io"] = m.group(1).strip()
        m = METRIC.search(line)
        if m:
            legs[cur]["leg_kind"] = m.group(1)
            legs[cur]["gen"] = int(m.group(2))
            legs[cur]["wall_ms"] = float(m.group(3))
            legs[cur]["tok_s"] = float(m.group(4))
        m = PREFILL.search(line)
        if m:
            legs[cur]["prefill_ms"] = int(m.group(1))
        m = LOAD.search(line)
        if m:
            legs[cur]["load_ms"] = int(m.group(1))
    # 若 METRIC 只在 stdout 而 stdout 落到了 logdir 的分腿日志，则补取
    if logdir and os.path.isdir(logdir):
        for (tag, r), d in legs.items():
            if d["tok_s"] is not None:
                continue
            f = os.path.join(logdir, f"{tag}_r{r}.log")
            if not os.path.exists(f):
                continue
            for line in open(f, encoding="utf-8", errors="replace"):
                m = METRIC.search(line)
                if m:
                    d["gen"] = int(m.group(2)); d["wall_ms"] = float(m.group(3))
                    d["tok_s"] = float(m.group(4)); d["leg_kind"] = m.group(1)
                m = DECODE_IO.search(line)
                if m:
                    d["io"] = f"miss={m.group(1)} bytes={m.group(2)}MiB pread={m.group(3)}ms"
                m = HEALTH_RE.search(line)
                if m:
                    d["health"] = (d["health"] or 0) + 1
    return legs, build


HEALTH_RE = re.compile(r"上海|四大发明|造纸|印刷|指南针|火药")


def kgsl_counts(d):
    """诊断腿（stderr 落文件）才有：提交次数 / 每 op 提交 / pread。"""
    out = {}
    if not d or not os.path.isdir(d):
        return out
    for name in sorted(os.listdir(d)):
        if not name.endswith(".log"):
            continue
        p = os.path.join(d, name)
        subs = waits = 0
        io = None
        for line in open(p, encoding="utf-8", errors="replace"):
            if SUBMIT.match(line):
                subs += 1
            elif line.startswith("KGSLWAIT"):
                waits += 1
            else:
                m = DECODE_IO.search(line)
                if m:
                    io = (int(m.group(1)), float(m.group(2)), int(m.group(3)))
        out[name[:-4]] = {"submits": subs, "waits": waits, "io": io}
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("main_log")
    ap.add_argument("--dir", default=None, help="矩阵 logdir（分腿 stdout）")
    ap.add_argument("--kgsl", default=None, help="kgsl_probe 输出目录（含 stderr 的诊断腿）")
    ap.add_argument("--io-threads", type=int, default=1,
                    help="LLAMA_MOE_IO_THREADS，用于把 pread 累计折算成墙上时间下界")
    a = ap.parse_args()

    legs, build = parse_main(a.main_log, a.dir)
    if not legs:
        print("没解析到任何腿，检查主日志路径", file=sys.stderr)
        return 2
    # 按腿名聚合多轮 → 中位数 + 极差
    agg = {}
    for (tag, r), d in legs.items():
        agg.setdefault(tag, []).append((r, d))

    print("## 每 token 预算分解（同会话交错 / 90s 冷却 / stderr 丢弃 → 只认 stdout METRIC）")
    if build:
        print("构建指纹：" + " | ".join(build))
    print()
    print("| 腿 | 轮数 | 中位 tok/s | tok/s 极差 | 每 token 墙上 ms | prefill ms | 专家 pread 累计 ms | IO 墙上下界 ms/token | 提交数 | 文本健康 |")
    print("|---|---|---|---|---|---|---|---|---|---|")
    kg = kgsl_counts(a.kgsl)
    for tag, rows in sorted(agg.items()):
        good = [d for _, d in rows if d["tok_s"]]
        if not good:
            print(f"| {tag} | {len(rows)} | 无 METRIC（腿失败，看 rc） | - | - | - | - | - | - | - |")
            continue
        ts = [d["tok_s"] for d in good]
        med = statistics.median(ts)
        spread = f"{min(ts):.2f}–{max(ts):.2f}" if len(ts) > 1 else "单轮"
        ms_tok = 1000.0 / med
        pf = statistics.median([d["prefill_ms"] for d in good if d["prefill_ms"]] or [0])
        # 专家 IO：pread 是多 IO 线程累计，墙上时间 ≥ pread/io_threads
        pre = 0
        gen = max(d["gen"] or 0 for d in good)
        for d in good:
            m = re.search(r"pread=(\d+)ms", d["io"] or "")
            if m:
                pre = max(pre, int(m.group(1)))
        io_wall = (pre / max(1, a.io_threads) / gen) if gen and pre else 0
        subs = ""
        for k, v in kg.items():
            if tag.lower().replace("mesa_", "") in k.lower():
                subs = str(v["submits"])
                break
        health = sum(1 for d in good if (d["health"] or 0) > 0)
        print(f"| {tag} | {len(good)} | **{med:.2f}** | {spread} | {ms_tok:.0f} | {pf:.0f} | "
              f"{pre} | {io_wall:.0f} | {subs or '—'} | {health}/{len(good)} |")
    print()
    print("> 读表口径：`每 token 墙上 ms` 与 CPU 对手腿同列比较即为 L3 裁决输入；"
          "`IO 墙上下界` = pread 累计 / IO 线程数 / token 数，真值 ≥ 此数（重叠率另测）；"
          "`提交数` 只有诊断腿（stderr 落文件）才有，用于 kernel 丢失计数，不参与计时。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
