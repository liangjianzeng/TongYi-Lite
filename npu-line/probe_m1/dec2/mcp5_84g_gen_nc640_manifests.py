#!/usr/bin/env python3
# [npu-line] Generate the 3 gated-process NC=640 decode manifests (A l0-13, B l14-27,
# C l28-41 + norm + head). Per-layer tensor ids/dims from ctx dumps (never hardcode).
# Cache files are the 640-row padded d2e640_kc{i}.raw / d2e640_vc{i}.raw; rope table
# stride 256 (S=1 rows); per-step logits via {t} for judging.
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


def dims(t):
    return ",".join(str(x) for x in t["dimensions"])


def layer_line(i):
    ctx = f"{SERVE}/nc640_l{i}_ctx.bin"
    gname, ins, outs = dump(ctx)
    return (f"nc640_l{i}_ctx.bin {gname} 6 "
            f"hs {ins['hs']['id']} f2 {dims(ins['hs'])} d2e_hs.raw "
            f"kcache {ins['kcache']['id']} f2 {dims(ins['kcache'])} d2e640_kc{i}.raw "
            f"vcache {ins['vcache']['id']} f2 {dims(ins['vcache'])} d2e640_vc{i}.raw "
            f"cos {ins['cos']['id']} f2 {dims(ins['cos'])} d2_cos_table.raw@256 "
            f"sin {ins['sin']['id']} f2 {dims(ins['sin'])} d2_sin_table.raw@256 "
            f"amask {ins['amask']['id']} f2 {dims(ins['amask'])} g_am640_t{{t}}.raw "
            f"3 h {outs['h']['id']} f2 {dims(outs['h'])} d2e_hs.raw "
            f"knew:roll=kcache@512 {outs['knew']['id']} f2 {dims(outs['knew'])} - "
            f"vnew:roll=vcache@512 {outs['vnew']['id']} f2 {dims(outs['vnew'])} -")


groups = {"A": (0, 14), "B": (14, 28), "C": (28, 42)}
for name, (a, b) in groups.items():
    with open(f"{OUTD}/manifest_nc640_{name}", "w") as f:
        for i in range(a, b):
            f.write(layer_line(i) + "\n")
    print(f"manifest_nc640_{name}: {b - a} segs", flush=True)

_, nins, nouts = dump(f"{SERVE}/nc640_l0_ctx.bin")
with open(f"{OUTD}/manifest_nc640_C", "a") as f:
    gname, ins, outs = dump(f"{SERVE}/dec_l998norm_ctx.bin")
    f.write(f"dec_l998norm_ctx.bin {gname} 1 hs {ins['hs']['id']} f2 {dims(ins['hs'])} "
            f"d2e_hs.raw 1 h {outs['h']['id']} f2 {dims(outs['h'])} d2e_hn.raw\n")
    gname, ins, outs = dump(f"{SERVE}/dec_l999head_ctx.bin")
    f.write(f"dec_l999head_ctx.bin {gname} 1 hs {ins['hs']['id']} f2 {dims(ins['hs'])} "
            f"d2e_hn.raw 1 logits {outs['logits']['id']} f2 {dims(outs['logits'])} "
            f"d2e_logits_t{{t}}.raw\n")
print("GEN84_DONE", flush=True)
