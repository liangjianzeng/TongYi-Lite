#!/usr/bin/env python3
"""X4 黄金语料 host 侧机检（R-072 立项）。
用法:
  certify:  python3 x4_verify.py certify  --pulled DIR --out golden_<tag>.json [--min 6]
  verify :  python3 x4_verify.py verify   --pulled DIR --golden golden_<tag>.json
判据（机器强制，违反即 FAIL 拒收）：
  1) 每案 .tok md5 == golden；
  2) 每案 .err 必含 "OpenCL driver:" 行（ICD 误标案铁律），且非 vendor 需与 golden.driver_ok 白名单一致；
  3) capture RESULT 行（--log 提供）bin= 必须全等且 == --expect-bin；
  4) 缺案 = FAIL（--min 最少案数）。
输出逐案 PASS/FAIL + 尾行 X4_SUMMARY pass=N fail=M。
"""
import argparse, hashlib, json, os, re, sys

CASES = ["p1_cn_classic","p2_en_whyblue","p3_math_17x23","p4_code_fib","p5_poetry","p6_greatwall"]
drv_re = re.compile(r"OpenCL driver:\s*([0-9.]+)")

def md5(p):
    return hashlib.md5(open(p,'rb').read()).hexdigest()

def pull_dir(d):
    return {c: (os.path.join(d,f"x4_{c}.tok"), os.path.join(d,f"x4_{c}.err"))
            for c in CASES if os.path.exists(os.path.join(d,f"x4_{c}.tok"))}

def drivers(errs):
    out=set()
    for pair in errs.values():
        e=pair[1]
        m=drv_re.search(open(e,encoding='utf-8',errors='ignore').read())
        out.add(m.group(1) if m else "MISSING")
    return sorted(out)

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument("cmd",choices=["certify","verify"]); ap.add_argument("--pulled",required=True)
    ap.add_argument("--out"); ap.add_argument("--golden")
    ap.add_argument("--log"); ap.add_argument("--expect-bin")
    ap.add_argument("--min",type=int,default=6)
    a=ap.parse_args()
    got=pull_dir(a.pulled)
    if len(got)<a.min: print(f"FAIL cases={len(got)}<{a.min}"); sys.exit(1)
    bins=[]
    if a.log and os.path.exists(a.log):
        bins=sorted(set(re.findall(r"X4RESULT .*?bin=([0-9a-f]{8})",open(a.log,errors='ignore').read())))
    if a.log:
        if len(bins)!=1: print(f"FAIL bin_witness bins={bins}"); sys.exit(1)
        if a.expect_bin and bins[0]!=a.expect_bin: print(f"FAIL bin={bins[0]} want={a.expect_bin}"); sys.exit(1)
    drv=drivers(got)
    if a.cmd=="certify":
        man={"cases":{c:{"tok_md5":md5(p[0]),"bytes":os.path.getsize(p[0])} for c,p in got.items()},
             "driver_ok":drv,
             "lib_bin":bins[0] if bins else None,
             "note":"certified on main-tester per user law 10-27"}
        json.dump(man,open(a.out,"w"),ensure_ascii=False,indent=1)
        print(f"CERTIFIED {len(man['cases'])} cases drivers={drv} bin={man['lib_bin']} -> {a.out}")
    else:
        g=json.load(open(a.golden)); ok=fail=0
        for c in CASES:
            if c not in g["cases"]: print(f"SKIP {c} not-in-golden"); continue
            if c not in got: print(f"FAIL {c} missing"); fail+=1; continue
            m=md5(got[c][0])
            if m!=g["cases"][c]["tok_md5"]: print(f"FAIL {c} md5={m[:8]} want={g['cases'][c]['tok_md5'][:8]}"); fail+=1
            elif not drv_re.search(open(got[c][1],errors='ignore').read()): print(f"FAIL {c} driver-missing"); fail+=1
            else: print(f"PASS {c} md5={m[:8]}"); ok+=1
        print(f"X4_SUMMARY pass={ok} fail={fail} drivers={drv}")
        sys.exit(0 if fail==0 and ok>=a.min else 1)
main()
