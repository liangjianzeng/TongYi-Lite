#!/usr/bin/env python3
# [npu-line] Generate the 3 gated-process prefill manifests (A l0-13, B l14-27, C l28-41)
# for the 4-chunk full prefill chain. Tensor ids/dims are read per-layer from the ctx
# binaries (qnn-context-binary-utility) — never hardcode ids across graph variants.
# Protocol: layer 0 hs = d2q_emb_{t}.raw, layer i>0 hs = d2q_h_l{i-1}_{t}.raw;
# per-layer roll caches d2q_kc_{i}.raw/d2q_vc_{i}.raw (driver seeds them from zeros);
# rope stride 32768 (S-blocks), amask per chunk d2q_am_{t}.raw.
import json
import os
import subprocess
import sys

SDK = "/mnt/e/MyLLM/qairt/2.44.0.260225"
SERVE = "/mnt/e/MyLLM_exp/serve_dec"
OUTD = "/mnt/e/MyLLM_exp"
NC, S, NKV, HD = 512, 128, 2, 128


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
    ctx = f"{SERVE}/dec2p_l{i}_ctx.bin"
    gname, ins, outs = dump(ctx)
    dims = lambda t: ",".join(str(x) for x in t["dimensions"])
    hsfile = f"d2q_emb_{{t}}.raw" if i == 0 else f"d2q_h_l{i-1}_{{t}}.raw"
    parts = [f"dec2p_l{i}_ctx.bin", gname, "6",
             f"hs {ins['hs']['id']} f2 {dims(ins['hs'])} {hsfile}",
             f"kcache {ins['kcache']['id']} f2 {dims(ins['kcache'])} d2q_kc_{i}.raw",
             f"vcache {ins['vcache']['id']} f2 {dims(ins['vcache'])} d2q_vc_{i}.raw",
             f"cos {ins['cos']['id']} f2 {dims(ins['cos'])} d2q_cos_table.raw@32768",
             f"sin {ins['sin']['id']} f2 {dims(ins['sin'])} d2q_sin_table.raw@32768",
             f"amask {ins['amask']['id']} f2 {dims(ins['amask'])} d2q_am_{{t}}.raw",
             "3",
             f"h {outs['h']['id']} f2 {dims(outs['h'])} d2q_h_l{i}_{{t}}.raw",
             f"knew:roll=kcache@512 {outs['knew']['id']} f2 {dims(outs['knew'])} d2q_knew_{i}_{{t}}.raw",
             f"vnew:roll=vcache@512 {outs['vnew']['id']} f2 {dims(outs['vnew'])} d2q_vnew_{i}_{{t}}.raw"]
    return " ".join(parts)


groups = {"A": (0, 14), "B": (14, 28), "C": (28, 42)}
for name, (a, b) in groups.items():
    with open(f"{OUTD}/manifest_pre2_{name}", "w") as f:
        for i in range(a, b):
            f.write(line(i) + "\n")
    print(f"manifest_pre2_{name}: {b-a} segs", flush=True)
print("GEN79_DONE", flush=True)
