#!/usr/bin/env python3
# [npu-line] G3: manifest_nc640_C_w8 = manifest_nc640_C with the head line replaced by
# the W8 head ctx (w8dec_l999head_ctx.bin). Graph name = TAG basename and tensor ids
# come from the fresh ctx dump (pitfall 56 — quantization shifts ids; never hardcode).
import json
import os
import subprocess

SDK = "/mnt/e/MyLLM/qairt/2.44.0.260225"
SERVE = "/mnt/e/MyLLM_exp/serve_dec"
OUTD = "/mnt/e/MyLLM_exp"
CTX = os.environ.get("W8HEAD", f"{SERVE}/w8dec_l999head_ctx.bin")


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


gname, ins, outs = dump(CTX)
head_line = (f"{CTX.split('/')[-1]} {gname} 1 "
             f"hs {ins['hs']['id']} f2 {dims(ins['hs'])} d2e_hn.raw "
             f"1 logits {outs['logits']['id']} f2 {dims(outs['logits'])} "
             f"d2e_logits_t{{t}}.raw")
lines = [l for l in open(f"{OUTD}/manifest_nc640_C").read().splitlines()
         if "head_ctx.bin" not in l]
lines.append(head_line)
open(f"{OUTD}/manifest_nc640_C_w8", "w").write("\n".join(lines) + "\n")
print("W8C_DONE graph=%s ins=%s outs=%s" % (gname, {k: v["id"] for k, v in ins.items()},
                                            {k: v["id"] for k, v in outs.items()}))
