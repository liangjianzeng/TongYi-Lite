#!/usr/bin/env python3
# [npu-line] Chain-feed sweep (S) + norm/head tail test (T), step 0 only.
# S: per-layer hs input = PREVIOUS layer's DEVICE output (self-feeding chain), fresh cache
#    files, amask t0 — isolates whether device-on-device feeding destabilizes any layer
#    (fp16 overflow / amplification) even though each layer matched ORT from clean inputs.
# T: device norm+head over the chain layer-41 h vs torch norm+head of the same h.
import json
import os
import subprocess
import numpy as np
import torch
import onnxruntime as ort

ST = "/mnt/e/wsl_stage"
OUT = f"{ST}/chain_sweep"
SDK = "/mnt/e/MyLLM/qairt/2.44.0.260225"
SERVE = "/mnt/e/MyLLM_exp/serve_dec"
NKV, HD, HID = 2, 128, 2048
NEG = np.float16(-1e4)
os.makedirs(OUT, exist_ok=True)

from transformers import AutoModelForCausalLM
model = AutoModelForCausalLM.from_pretrained("/home/liang/models/minicpm5-2b",
                                             dtype=torch.float16,
                                             attn_implementation="eager",
                                             trust_remote_code=True).eval()

kc = [np.fromfile(f"{ST}/dev/d2q_kc_{i}.raw", "<f2").reshape(512, HD, NKV)
      .transpose(2, 0, 1)[None].copy() for i in range(42)]
vc = [np.fromfile(f"{ST}/dev/d2q_vc_{i}.raw", "<f2").reshape(512, HD, NKV)
      .transpose(2, 0, 1)[None].copy() for i in range(42)]
kc = [np.concatenate([c, np.zeros((1, NKV, 128, HD), "<f2")], axis=2) for c in kc]
vc = [np.concatenate([c, np.zeros((1, NKV, 128, HD), "<f2")], axis=2) for c in vc]
ct = np.fromfile(f"{ST}/d2_cos_table.raw", "<f2").reshape(-1, HD)
stt = np.fromfile(f"{ST}/d2_sin_table.raw", "<f2").reshape(-1, HD)
cos = np.ascontiguousarray(ct[0][None, None])
sin = np.ascontiguousarray(stt[0][None, None])
am = np.zeros((1, 1, 1, 641), "<f2")
am[0, 0, 0, 512:640] = NEG
hs0 = np.fromfile(f"{ST}/d2e_hs0.raw", "<f2").reshape(1, 1, HID)

# ORT chain (reference) with per-layer h dumps (reuse sweep files if present)
sess = [ort.InferenceSession(f"/home/liang/models/mcp5_dec2_640/mcp5_nc640_l{k}.onnx",
                             ort.SessionOptions(), providers=['CPUExecutionProvider'])
        for k in range(42)]
hs = hs0.copy()
ort_hs = []
for k in range(42):
    oh, _, _ = sess[k].run(["h", "knew", "vnew"], {"hs": hs, "kcache": kc[k], "vcache": vc[k],
                                                   "cos": cos, "sin": sin, "amask": am})
    ort_hs.append(oh.astype(np.float16).reshape(1, 1, HID).copy())
    hs = oh.reshape(1, 1, HID)
with torch.no_grad():
    lg = model.lm_head(model.model.norm(torch.from_numpy(ort_hs[41])))
ort_lg = lg[0, 0].float().numpy()
ref = np.load(f"{ST}/d2e_ref_logits_t0.npy").astype(np.float32).ravel()


def dump(ctx):
    b = ctx.split("/")[-1].replace("_ctx.bin", "")
    j = f"/tmp/dump_{b}.json"
    if not os.path.exists(j):
        subprocess.run([f"{SDK}/bin/x86_64-linux-clang/qnn-context-binary-utility",
                        "--context_binary", ctx, "--json_file", j], check=True,
                       capture_output=True,
                       env={**os.environ, "LD_LIBRARY_PATH": f"{SDK}/lib/x86_64-linux-clang"})
    d = json.load(open(j))["info"]["graphs"][0]["info"]
    ins = {t["info"]["name"]: t["info"] for t in d["graphInputs"]}
    outs = {t["info"]["name"]: t["info"] for t in d["graphOutputs"]}
    return d["graphName"], ins, outs


def dm(t):
    return ",".join(str(x) for x in t["dimensions"])


lines = []
for k in range(42):
    hs_in = "d2e_hs0.raw" if k == 0 else f"chain_sweep/g_ch_h_{k - 1}.raw"
    gname, ins, outs = dump(f"{SERVE}/nc640_l{k}_ctx.bin")
    lines.append(f"nc640_l{k}_ctx.bin {gname} 6 "
                 f"hs {ins['hs']['id']} f2 {dm(ins['hs'])} {hs_in} "
                 f"kcache {ins['kcache']['id']} f2 {dm(ins['kcache'])} d2e640_kc{k}.raw "
                 f"vcache {ins['vcache']['id']} f2 {dm(ins['vcache'])} d2e640_vc{k}.raw "
                 f"cos {ins['cos']['id']} f2 {dm(ins['cos'])} d2_cos_table.raw@256 "
                 f"sin {ins['sin']['id']} f2 {dm(ins['sin'])} d2_sin_table.raw@256 "
                 f"amask {ins['amask']['id']} f2 {dm(ins['amask'])} g_am640_t0.raw "
                 f"3 h {outs['h']['id']} f2 {dm(outs['h'])} chain_sweep/g_ch_h_{k}.raw "
                 f"knew:roll=kcache@512 {outs['knew']['id']} f2 {dm(outs['knew'])} - "
                 f"vnew:roll=vcache@512 {outs['vnew']['id']} f2 {dm(outs['vnew'])} -")
for nm, (a, b) in {"A": (0, 14), "B": (14, 28), "C": (28, 42)}.items():
    open(f"/mnt/e/MyLLM_exp/manifest_chsw_{nm}", "w").write("\n".join(lines[a:b]) + "\n")

# T: tail manifest (norm+head) fed by device chain h_41
gname, ins, outs = dump(f"{SERVE}/dec_l998norm_ctx.bin")
tail = (f"dec_l998norm_ctx.bin {gname} 1 hs {ins['hs']['id']} f2 {dm(ins['hs'])} "
        f"chain_sweep/g_ch_h_41.raw 1 h {outs['h']['id']} f2 {dm(outs['h'])} g_ch_hn.raw\n")
gname, ins, outs = dump(f"{SERVE}/dec_l999head_ctx.bin")
tail += (f"dec_l999head_ctx.bin {gname} 1 hs {ins['hs']['id']} f2 {dm(ins['hs'])} "
         f"g_ch_hn.raw 1 logits {outs['logits']['id']} f2 {dm(outs['logits'])} "
         f"g_ch_lit0.raw\n")
open("/mnt/e/MyLLM_exp/manifest_chsw_T", "w").write(tail)

np.save(f"{OUT}/g_ort_lg0.npy", ort_lg.astype(np.float32))
np.save(f"{OUT}/g_ort_h41.npy", ort_hs[41].astype(np.float32).ravel())
print("CHAIN_SWEEP_PREP_DONE", flush=True)
