#!/usr/bin/env python3
# [npu-line] G2 A/B: per-variant single-layer l0 manifests for chain_run5 timing runs
# (steps=4, 4 chunks, single process, no gate). Feeds = 77-era d2q real-prompt prefill
# inputs; per-variant zero kcache/vcache seeds; outputs to scratch g2* files.
# Tensor ids/dims read from the ctx binaries (never hardcoded across graph variants).
import json
import os
import subprocess

SDK = "/mnt/e/MyLLM/qairt/2.44.0.260225"
SERVE = "/mnt/e/MyLLM_exp/serve_dec"
OUTD = "/mnt/e/MyLLM_exp/_repro/rb"
ST = "/mnt/e/wsl_stage"
TAGS = ["dec2p_l0", "dec2pt_l0", "dec2pc_l0", "dec2pn_l0"]


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


# per-variant zero cache seeds (s,hd,kv) 1,512,128,2 fp16 = 262144 B
for p in ("g2_kc0.raw", "g2_vc0.raw"):
    if not os.path.exists(f"{ST}/{p}") or os.path.getsize(f"{ST}/{p}") != 262144:
        open(f"{ST}/{p}", "wb").write(bytes(262144))

for tag in TAGS:
    gname, ins, outs = dump(f"{SERVE}/{tag}_ctx.bin")
    dims = lambda t: ",".join(str(x) for x in t["dimensions"])
    files = {"hs": "d2q_emb_{t}.raw", "kcache": "g2_kc0.raw", "vcache": "g2_vc0.raw",
             "cos": "d2q_cos_table.raw@32768", "sin": "d2q_sin_table.raw@32768",
             "amask": "d2q_am_{t}.raw"}
    parts = [f"{tag}_ctx.bin", gname, str(len(ins))]
    for nm, t in ins.items():
        parts += [nm, str(t["id"]), "f2", dims(t), files[nm]]
    parts.append("3")
    parts.append(f"h {outs['h']['id']} f2 {dims(outs['h'])} g2h_{tag}_{{t}}.raw")
    parts.append(f"knew:roll=kcache@512 {outs['knew']['id']} f2 {dims(outs['knew'])} "
                 f"g2k_{tag}_{{t}}.raw")
    parts.append(f"vnew:roll=vcache@512 {outs['vnew']['id']} f2 {dims(outs['vnew'])} "
                 f"g2v_{tag}_{{t}}.raw")
    with open(f"{OUTD}/manifest_g2_{tag}", "w") as f:
        f.write(" ".join(parts) + "\n")
    print(tag, "inputs", list(ins), "->manifest", flush=True)
print("GEN92_DONE", flush=True)
