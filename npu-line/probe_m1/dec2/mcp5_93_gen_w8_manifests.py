#!/usr/bin/env python3
# [npu-line] G3: W8-gated nc640 decode manifests (A l0-13, B l14-27, C l28-41 + fp16
# norm/head). Same protocol as mcp5_84g (cache d2e640_*, rope stride 256, per-step
# amask g_am640_t{t}, logits d2e_logits_t{t}) but ctx = w8nc640_l{i} (DLC-built quantized
# ctxs; ids/dims always read from ctx dumps — quantization shifts tensor ids).
import json
import os
import subprocess

SDK = "/mnt/e/MyLLM/qairt/2.44.0.260225"
SERVE = "/mnt/e/MyLLM_exp/serve_dec"
OUTD = "/mnt/e/MyLLM_exp"


def dump(ctx):
    b = ctx.split("/")[-1].replace("_ctx.bin", "")
    j = f"/tmp/dumpw8_{b}.json"
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
    tag = f"w8nc640_l{i}"
    gname, ins, outs = dump(f"{SERVE}/{tag}_ctx.bin")
    return (f"{tag}_ctx.bin {gname} 6 "
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
    with open(f"{OUTD}/manifest_w8_{name}", "w") as f:
        for i in range(a, b):
            f.write(layer_line(i) + "\n")
    print(f"manifest_w8_{name}: {b - a} segs", flush=True)

with open(f"{OUTD}/manifest_w8_C", "a") as f:
    gname, ins, outs = dump(f"{SERVE}/dec_l998norm_ctx.bin")
    f.write(f"dec_l998norm_ctx.bin {gname} 1 hs {ins['hs']['id']} f2 {dims(ins['hs'])} "
            f"d2e_hs.raw 1 h {outs['h']['id']} f2 {dims(outs['h'])} d2e_hn.raw\n")
    # W8 head (device-verified: G4 token chain MATCH 8/8, logits cos 0.9999 vs fp16)
    gname, ins, outs = dump(f"{SERVE}/w8dec_l999head_ctx.bin")
    f.write(f"w8dec_l999head_ctx.bin {gname} 1 hs {ins['hs']['id']} f2 {dims(ins['hs'])} "
            f"d2e_hn.raw 1 logits {outs['logits']['id']} f2 {dims(outs['logits'])} "
            f"d2e_logits_t{{t}}.raw\n")
print("GEN93_DONE", flush=True)
