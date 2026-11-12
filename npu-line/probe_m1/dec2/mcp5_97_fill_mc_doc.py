#!/usr/bin/env python3
# [npu-line] MC 结档填表：读 c_batch_results.json -> §7.3 汇总行 + 逐轮表 + PASS/FAIL 判定。
# 用法: python -I fill_mc_doc.py   （批量完成后跑一次，输出直接贴计划文档 §7.3）
import sys, json
sys.stdout.reconfigure(encoding="utf-8", errors="replace")
res = json.load(open("E:/MyLLM_exp/hyb/c_batch_results.json", encoding="utf-8"))
done = {k: v for k, v in res.items() if v.get("cosh0") is not None}
err = {k: v for k, v in res.items() if v.get("cosh0") is None}
print(f"rounds_done={len(done)} err={len(err)} {sorted(err, key=int) if err else ''}")
oks = sum(1 for v in done.values() if v.get("ok"))
c0 = sorted(v["cosh0"] for v in done.values())
dec_h = [k for k, v in done.items() if v.get("dec_h") is not None]
dec_u = [k for k, v in done.items() if v.get("dec_u") is not None]
pc_low = [k for k, v in done.items()
          if v.get("prefix_cos_min") is not None and v["prefix_cos_min"] < 0.95]
bad = [k for k, v in done.items() if not v.get("ok")]
med = c0[len(c0) // 2] if c0 else None
verdict = "PASS" if (len(done) == 50 and oks >= 45 and med >= 0.97) else \
          ("INCOMPLETE" if len(done) < 50 else "FAIL")
print(f"MC-JUDGE ok={oks}/{len(done)} med_cosh0={med} "
      f"dec_h={sorted(dec_h, key=int)} dec_u={sorted(dec_u, key=int)} "
      f"prefix_low={sorted(pc_low, key=int)} BAD={sorted(bad, key=int)} => {verdict}")
print("| r | real | lcp_h | lcp_u | dec_h | cosh0 | prefix_cos | ok |")
print("|---|------|-------|-------|-------|-------|------------|----|")
for k in sorted(done, key=int):
    v = done[k]
    print(f"| {int(k):02d} | {v.get('real')} | {v['lcp_h']} | {v['lcp_u']} | "
          f"{v['dec_h']} | {v['cosh0']} | {v['prefix_cos_min']} | "
          f"{'✓' if v.get('ok') else '✗'} |")
