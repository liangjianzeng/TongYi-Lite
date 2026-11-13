#!/usr/bin/env python3
# [npu-line NC128 双档] 3 gated-process manifests for the SINGLE-chunk NC=128 prefill
# (prompts 36-81 real tokens -> one S=128 chunk, NPU exec target ~0.9s vs 3.72s static-512).
# Clone of mcp5_79_gen_pre2_manifests.py with NC=128 graph family (dec2_l{k}_ctx.bin,
# built by nc128_build_all.sh from DEC_NC=128 DEC_S=128 export). Tensor ids/dims read
# per-layer from the ctx binaries (never hardcode ids across graph variants).
# Protocol (same as pre2/512, one chunk): layer 0 hs = d2q128_emb_{t}.raw, layer i>0
# hs = d2q128_h_l{i-1}_{t}.raw; per-layer roll caches d2q128_{kc,vc}_{i}.raw (driver
# seeds from zeros; roll_row stays 512B = one (HD,NKV) fp16 row); rope stride 32768
# (single S-block); amask = d2q128_am_{t}.raw ([S,NC+S], cache cols fully masked + causal).
import json
import os
import subprocess

SDK = "/mnt/e/MyLLM/qairt/2.44.0.260225"
SERVE = "/mnt/e/MyLLM_exp/serve_dec"
OUTD = "/mnt/e/MyLLM_exp"


def dump(ctx):
    b = ctx.split("/")[-1].replace("_ctx.bin", "")
    j = f"/tmp/dump_{b}.json"
    subprocess.run([f"{SDK}/bin/x86_64-linux-clang/qnn-context-binary-utility",
                    "--context_binary", ctx, "--json_file", j],
                   check=True, capture_output=True,
                   env={**os.environ, "LD_LIBRARY_PATH": f"{SDK}/lib/x86_64-linux-clang"})
    d = json.load(open(j))["info"]["graphs"][0]["info"]
    ins = {t["info"]["name"]: t["info"] for t in d["graphInputs"]}
    outs = {t["info"]["name"]: t["info"] for t in d["graphOutputs"]}
    return d["graphName"], ins, outs


def line(i):
    ctx = f"{SERVE}/dec2_l{i}_ctx.bin"
    gname, ins, outs = dump(ctx)
    dims = lambda t: ",".join(str(x) for x in t["dimensions"])
    hsfile = f"d2q128_emb_{{t}}.raw" if i == 0 else f"d2q128_h_l{i-1}_{{t}}.raw"
    parts = [f"dec2_l{i}_ctx.bin", gname, "6",
             f"hs {ins['hs']['id']} f2 {dims(ins['hs'])} {hsfile}",
             f"kcache {ins['kcache']['id']} f2 {dims(ins['kcache'])} d2q128_kc_{i}.raw",
             f"vcache {ins['vcache']['id']} f2 {dims(ins['vcache'])} d2q128_vc_{i}.raw",
             f"cos {ins['cos']['id']} f2 {dims(ins['cos'])} d2q128_cos_table.raw@32768",
             f"sin {ins['sin']['id']} f2 {dims(ins['sin'])} d2q128_sin_table.raw@32768",
             f"amask {ins['amask']['id']} f2 {dims(ins['amask'])} d2q128_am_{{t}}.raw",
             "3",
             f"h {outs['h']['id']} f2 {dims(outs['h'])} d2q128_h_l{i}_{{t}}.raw",
             f"knew:roll=kcache@512 {outs['knew']['id']} f2 {dims(outs['knew'])} d2q128_knew_{i}_{{t}}.raw",
             f"vnew:roll=vcache@512 {outs['vnew']['id']} f2 {dims(outs['vnew'])} d2q128_vnew_{i}_{{t}}.raw"]
    return " ".join(parts)


groups = {"A": (0, 14), "B": (14, 28), "C": (28, 42)}
for name, (a, b) in groups.items():
    with open(f"{OUTD}/manifest_nc128_{name}", "w") as f:
        for i in range(a, b):
            f.write(line(i) + "\n")
    print(f"manifest_nc128_{name}: {b-a} segs", flush=True)
print("GEN98_DONE", flush=True)
