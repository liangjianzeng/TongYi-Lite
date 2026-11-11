#!/usr/bin/env python3
# [npu-line] G3 bisection: mixed fp16/W8 manifests. m1=(W8 A, fp B, fp C), m2=(fp,W8,fp),
# m3=(fp,fp,W8+head). Layer line builders read ids/dims from ctx dumps (pitfall 56).
import json
import os
import subprocess

SDK = "/mnt/e/MyLLM/qairt/2.44.0.260225"
SERVE = "/mnt/e/MyLLM_exp/serve_dec"
OUTD = "/mnt/e/MyLLM_exp"


def dump(ctx):
    b = ctx.split("/")[-1].replace("_ctx.bin", "")
    j = f"/tmp/dumpm_{b}.json"
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


def layer_line(prefix, i):
    tag = f"{prefix}_l{i}"
    gname, ins, outs, iord, oord = dump(f"{SERVE}/{tag}_ctx.bin")
    FILES = {"hs": "d2e_hs.raw", "kcache": f"d2e640_kc{i}.raw",
             "vcache": f"d2e640_vc{i}.raw", "cos": "d2_cos_table.raw@256",
             "sin": "d2_sin_table.raw@256", "amask": "g_am640_t{t}.raw"}
    OF = {"h": "d2e_hs.raw", "knew": "-", "vnew": "-"}
    ROLL = {"knew": "knew:roll=kcache@512 ", "vnew": "vnew:roll=vcache@512 "}
    line = f"{tag}_ctx.bin {gname} {len(iord)} " + " ".join(
        f"{nm} {ins[nm]['id']} f2 {dims(ins[nm])} {FILES[nm]}" for nm in iord)
    line += f" {len(oord)} " + " ".join(
        f"{ROLL.get(nm, nm)}{outs[nm]['id']} f2 {dims(outs[nm])} {OF[nm]}" for nm in oord)
    return line


def norm_head_lines(head_w8):
    gname, ins, outs, iord, oord = dump(f"{SERVE}/dec_l998norm_ctx.bin")
    a = (f"dec_l998norm_ctx.bin {gname} 1 hs {ins['hs']['id']} f2 {dims(ins['hs'])} "
         f"d2e_hs.raw 1 h {outs['h']['id']} f2 {dims(outs['h'])} d2e_hn.raw")
    tag = "w8dec_l999head" if head_w8 else "dec_l999head"
    gname, ins, outs, iord, oord = dump(f"{SERVE}/{tag}_ctx.bin")
    b = (f"{tag}_ctx.bin {gname} 1 hs {ins['hs']['id']} f2 {dims(ins['hs'])} d2e_hn.raw "
         f"1 logits {outs['logits']['id']} f2 {dims(outs['logits'])} d2e_logits_t{{t}}.raw")
    return [a, b]


GROUPS = {"A": (0, 14), "B": (14, 28), "C": (28, 42)}
# (A-prefix, B-prefix, C-prefix, head-w8?)
MIXES = {"m1": ("w8nc640", "nc640", "nc640", False),
         "m2": ("nc640", "w8nc640", "nc640", False),
         "m3": ("nc640", "nc640", "w8nc640", True)}
for mname, (pa, pb, pc, hw) in MIXES.items():
    prefixes = {"A": pa, "B": pb, "C": pc}
    for gname_, (a, b) in GROUPS.items():
        lines = [layer_line(prefixes[gname_], i) for i in range(a, b)]
        if gname_ == "C":
            lines += norm_head_lines(hw)
        with open(f"{OUTD}/manifest_{mname}_{gname_}", "w") as f:
            f.write("\n".join(lines) + "\n")
    print("MIX", mname, prefixes, "head_w8", hw, flush=True)
print("GENMIX_DONE", flush=True)
