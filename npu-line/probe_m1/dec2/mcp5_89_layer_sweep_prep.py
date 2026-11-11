#!/usr/bin/env python3
# [npu-line] 42-layer sweep, chain step 0 (protocol A): ORT runs the masked nc640 chain and
# DUMPS each layer's input hs (device-declared bytes) + its own h; a device manifest feeds
# every layer the ORT hs bytes and writes per-layer h for dev|ORT comparison. A layer that
# diverges = HTP S=1 kernel collapse at K=641 for that layer's cache data.
import json
import os
import subprocess
import numpy as np
import onnxruntime as ort

ST = "/mnt/e/wsl_stage"
OUT = f"{ST}/sweep"
SDK = "/mnt/e/MyLLM/qairt/2.44.0.260225"
SERVE = "/mnt/e/MyLLM_exp/serve_dec"
NKV, HD, HID = 2, 128, 2048
NEG = np.float16(-1e4)
os.makedirs(OUT, exist_ok=True)

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
hs = np.fromfile(f"{ST}/d2e_hs0.raw", "<f2").reshape(1, 1, HID)

sess = [ort.InferenceSession(f"/home/liang/models/mcp5_dec2_640/mcp5_nc640_l{k}.onnx",
                             ort.SessionOptions(), providers=['CPUExecutionProvider'])
        for k in range(42)]


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


lines = []
for k in range(42):
    hs.astype("<f2").ravel().tofile(f"{OUT}/g_hs_{k}.raw")   # declared (hid,s) == ravel
    oh, _, _ = sess[k].run(["h", "knew", "vnew"], {"hs": hs, "kcache": kc[k], "vcache": vc[k],
                                                   "cos": cos, "sin": sin, "amask": am})
    oh.astype("<f2").ravel().tofile(f"{OUT}/g_ort_h_{k}.raw")
    hs = oh.reshape(1, 1, HID)
    gname, ins, outs = dump(f"{SERVE}/nc640_l{k}_ctx.bin")
    dm = lambda t: ",".join(str(x) for x in t["dimensions"])
    lines.append(f"nc640_l{k}_ctx.bin {gname} 6 "
                 f"hs {ins['hs']['id']} f2 {dm(ins['hs'])} sweep/g_hs_{k}.raw "
                 f"kcache {ins['kcache']['id']} f2 {dm(ins['kcache'])} d2e640_kc{k}.raw "
                 f"vcache {ins['vcache']['id']} f2 {dm(ins['vcache'])} d2e640_vc{k}.raw "
                 f"cos {ins['cos']['id']} f2 {dm(ins['cos'])} d2_cos_table.raw@256 "
                 f"sin {ins['sin']['id']} f2 {dm(ins['sin'])} d2_sin_table.raw@256 "
                 f"amask {ins['amask']['id']} f2 {dm(ins['amask'])} g_am640_t0.raw "
                 f"3 h {outs['h']['id']} f2 {dm(outs['h'])} sweep/g_dev_h_{k}.raw "
                 f"knew:roll=kcache@512 {outs['knew']['id']} f2 {dm(outs['knew'])} - "
                 f"vnew:roll=vcache@512 {outs['vnew']['id']} f2 {dm(outs['vnew'])} -")
for nm, (a, b) in {"A": (0, 14), "B": (14, 28), "C": (28, 42)}.items():
    open(f"/mnt/e/MyLLM_exp/manifest_sweep_{nm}", "w").write("\n".join(lines[a:b]) + "\n")
print("SWEEP42_PREP_DONE", flush=True)
