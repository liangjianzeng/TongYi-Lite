#!/usr/bin/env python3
# [npu-line] G3: native-recipe W8 decode manifests (A l0-13, B l14-27, C l28-41 + fp16
# norm + W8 head). Same protocol as mcp5_93_gen_w8_manifests.py but ctx = w8nat_l{i}
# (native qnn-onnx-converter + enc -> cpp/bin -> model.so -> ctxgen). ids/dims read from
# ctx dumps; emit in the ctx's registration order (pitfall 57 discipline).
import json
import os
import subprocess

SDK = "/mnt/e/MyLLM/qairt/2.44.0.260225"
SERVE = "/mnt/e/MyLLM_exp/serve_dec"
OUTD = "/mnt/e/MyLLM_exp"


def dump(ctx):
    b = ctx.split("/")[-1].replace("_ctx.bin", "")
    j = f"/tmp/dumpnat_{b}.json"
    subprocess.run([f"{SDK}/bin/x86_64-linux-clang/qnn-context-binary-utility",
                    "--context_binary", ctx, "--json_file", j],
                   check=True, capture_output=True,
                   env={**os.environ, "LD_LIBRARY_PATH": f"{SDK}/lib/x86_64-linux-clang"})
    d = json.load(open(j))["info"]["graphs"][0]["info"]
    ins = {t["info"]["name"]: t["info"] for t in d["graphInputs"]}
    outs = {t["info"]["name"]: t["info"] for t in d["graphOutputs"]}
    return d["graphName"], ins, outs, list(ins), list(outs)


def dims(t):
    return ",".join(str(x) for x in t["dimensions"])


def layer_line(i):
    tag = f"w8nat_l{i}"
    gname, ins, outs, iord, oord = dump(f"{SERVE}/{tag}_ctx.bin")
    FILES = {"hs": "d2e_hs.raw", "kcache": f"d2e640_kc{i}.raw",
             "vcache": f"d2e640_vc{i}.raw", "cos": "d2_cos_table.raw@256",
             "sin": "d2_sin_table.raw@256", "amask": "g_am640_t{t}.raw"}
    OF = {"h": "d2e_hs.raw", "knew": "-", "vnew": "-"}  # NOTE: h MUST be d2e_hs.raw
    # (inter-process relay); "-" for h = empty output file -> next layer reads nothing and
    # the parse of the following line glues its leading "h" onto the id (h135) — silent wedge.
    ROLL = {"knew": "knew:roll=kcache@512 ", "vnew": "vnew:roll=vcache@512 "}
    line = f"{tag}_ctx.bin {gname} {len(iord)} " + " ".join(
        f"{nm} {ins[nm]['id']} f2 {dims(ins[nm])} {FILES[nm]}" for nm in iord)
    line += f" {len(oord)} " + " ".join(
        f"{ROLL.get(nm, nm + ' ')}{outs[nm]['id']} f2 {dims(outs[nm])} {OF[nm]}" for nm in oord)
    return line


groups = {"A": (0, 14), "B": (14, 28), "C": (28, 42)}
for name, (a, b) in groups.items():
    with open(f"{OUTD}/manifest_nat_{name}", "w") as f:
        for i in range(a, b):
            f.write(layer_line(i) + "\n")
    print(f"manifest_nat_{name}: {b - a} segs", flush=True)

with open(f"{OUTD}/manifest_nat_C", "a") as f:
    gname, ins, outs, iord, oord = dump(f"{SERVE}/dec_l998norm_ctx.bin")
    f.write(f"dec_l998norm_ctx.bin {gname} 1 hs {ins['hs']['id']} f2 {dims(ins['hs'])} "
            f"d2e_hs.raw 1 h {outs['h']['id']} f2 {dims(outs['h'])} d2e_hn.raw\n")
    # W8 head (device-verified: G4 token chain MATCH 8/8, logits cos 0.9999 vs fp16)
    gname, ins, outs, iord, oord = dump(f"{SERVE}/w8dec_l999head_ctx.bin")
    f.write(f"w8dec_l999head_ctx.bin {gname} 1 hs {ins['hs']['id']} f2 {dims(ins['hs'])} "
            f"d2e_hn.raw 1 logits {outs['logits']['id']} f2 {dims(outs['logits'])} "
            f"d2e_logits_t{{t}}.raw\n")
print("GENNAT_DONE", flush=True)
