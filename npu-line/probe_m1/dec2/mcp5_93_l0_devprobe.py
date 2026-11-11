#!/usr/bin/env python3
# [npu-line] G3: single-layer device probe for w8nc640_l0 — identical feeds to the host
# ORT judge (d2e_hs0 + pristine kc/vc + rope row0 + g_am640_t0), compare device h/knew/
# vnew vs ORT fp16-original. cos~1 => device exec fine and the chain bug lives elsewhere;
# cos low with per-column scale misalignment => packing/scale-order defect.
import json
import os
import subprocess
import numpy as np
import onnxruntime as ort

ADB = "/mnt/c/Users/jianz/AppData/Local/Android/Sdk/platform-tools/adb.exe"
DEV = "<redacted-serial>"
R = "/data/local/tmp/npu_m1"
SDK = "/mnt/e/MyLLM/qairt/2.44.0.260225"
SERVE = "/mnt/e/MyLLM_exp/serve_dec"
ST = "/mnt/e/wsl_stage"
STW = "E:\\wsl_stage"


def sh(cmd):
    return subprocess.run([ADB, "-s", DEV, "shell"] + cmd, capture_output=True, text=True).stdout


def dump(ctx):
    b = ctx.split("/")[-1].replace("_ctx.bin", "")
    j = f"/tmp/dumpp_{b}.json"
    subprocess.run([f"{SDK}/bin/x86_64-linux-clang/qnn-context-binary-utility",
                    "--context_binary", ctx, "--json_file", j],
                   check=True, capture_output=True,
                   env={**os.environ, "LD_LIBRARY_PATH": f"{SDK}/lib/x86_64-linux-clang"})
    d = json.load(open(j))["info"]["graphs"][0]["info"]
    ins = {t["info"]["name"]: t["info"] for t in d["graphInputs"]}
    outs = {t["info"]["name"]: t["info"] for t in d["graphOutputs"]}
    # dict insertion order == registration order from the dump (Python 3.7+)
    return d["graphName"], ins, outs, list(ins), list(outs)


def dims(t):
    return ",".join(str(x) for x in t["dimensions"])


TAG = os.environ.get("CTXTAG", "w8nc640_l0")   # ablation builds use w8ab*_l0 tags
gname, ins, outs, ins_ord, outs_ord = dump(f"{SERVE}/{TAG}_ctx.bin")
# [pitfall 57] The manifest MUST enumerate inputs/outputs in the ctx's REGISTRATION order:
# chain_run5/HTP bind APP_WRITE/READ tensors by ARRAY POSITION, and the W8 quantizer pack
# reshuffles registration (w8nc640_l0 order = vcache,cos,sin,hs,kcache,amask with ids
# 1,4,7,10,54,87) — a fixed hs,kcache,... order silently cross-feeds and garbage-results.
FILES = {"hs": "d2e_hs.raw", "kcache": "d2e640_kc0.raw", "vcache": "d2e640_vc0.raw",
         "cos": "d2_cos_table.raw@256", "sin": "d2_sin_table.raw@256",
         "amask": "g_am640_t0.raw"}
OF = {"h": "p_h.raw", "knew": "p_kn.raw", "vnew": "p_vn.raw"}
line = f"{TAG}_ctx.bin {gname} {len(ins_ord)} " + " ".join(
    f"{nm} {ins[nm]['id']} f2 {dims(ins[nm])} {FILES[nm]}" for nm in ins_ord)
line += f" {len(outs_ord)} " + " ".join(
    f"{nm} {outs[nm]['id']} f2 {dims(outs[nm])} {OF[nm]}" for nm in outs_ord)
MAN = f"manifest_l0w8_{TAG}"
open(f"/mnt/e/MyLLM_exp/{MAN}", "w").write(line + "\n")   # WSL-side path (pitfall 33)
subprocess.run([ADB, "-s", DEV, "push", f"E:\\MyLLM_exp\\{MAN}", f"{R}/{MAN}"],
               capture_output=True, check=True)
subprocess.run([ADB, "-s", DEV, "push", f"{STW}\\d2e640b_kc0.raw", f"{R}/d2e640_kc0.raw"],
               capture_output=True, check=True)
subprocess.run([ADB, "-s", DEV, "push", f"{STW}\\d2e640b_vc0.raw", f"{R}/d2e640_vc0.raw"],
               capture_output=True, check=True)
subprocess.run([ADB, "-s", DEV, "push", f"{STW}\\d2e_hs0.raw", f"{R}/d2e_hs.raw"],
               capture_output=True, check=True)
# the layer ctx itself must be on the device too (manifest references ${TAG}_ctx.bin)
subprocess.run([ADB, "-s", DEV, "push", "E:\\MyLLM_exp\\serve_dec\\%s_ctx.bin" % TAG,
                f"{R}/{TAG}_ctx.bin"], capture_output=True, check=True)
sh(["pkill -f chain_run5; sleep 1"])
# manifest writes outputs to UNtagged remote names p_h/p_kn/p_vn.raw (see manifest line
# above); pull those into per-tag local files (an earlier version pulled p_{TAG}_*.raw
# from the remote — nonexistent, silently failed, then FileNotFoundError on the host).
PH, PKN, PVN = "p_h.raw", "p_kn.raw", "p_vn.raw"
out = sh([f"cd {R} && rm -f {PH} {PKN} {PVN} l0p.log && "
          f"export LD_LIBRARY_PATH=$PWD/lib ADSP_LIBRARY_PATH=$PWD/lib && "   # 0x36b1 w/o it (pitfall 47)
          f"CHAIN_KEEP=1 ./chain_run5 {MAN} 1 > l0p.log 2>&1; tail -3 l0p.log"])
print("DEV:", out.strip(), flush=True)
for f, remote in (("h", PH), ("kn", PKN), ("vn", PVN)):
    subprocess.run([ADB, "-s", DEV, "pull", f"{R}/{remote}", f"{STW}\\dev\\p_{TAG}_{f}.raw"],
                   capture_output=True)

# host ORT with the same feeds
import onnx
m_path = "/home/liang/models/mcp5_dec2_640/mcp5_nc640_l0.onnx"
m0 = ort.InferenceSession(m_path, providers=["CPUExecutionProvider"])
# ORT NodeArg.type is a string — read shapes from the onnx proto instead
_mi = onnx.load(m_path, load_external_data=False).graph.input
mi = {i.name: [d.dim_value for d in i.type.tensor_type.shape.dim] for i in _mi}
def feed(name, arr):
    shape = mi[name]
    return arr.astype("<f2").reshape(shape).copy()
F = {"hs": feed("hs", np.fromfile(f"{ST}/d2e_hs0.raw", "<f2")),
     "kcache": feed("kcache", np.fromfile(f"{ST}/d2e640b_kc0.raw", "<f2")),
     "vcache": feed("vcache", np.fromfile(f"{ST}/d2e640b_vc0.raw", "<f2")),
     "cos": feed("cos", np.fromfile(f"{ST}/d2_cos_table.raw", "<f2")[:128]),
     "sin": feed("sin", np.fromfile(f"{ST}/d2_sin_table.raw", "<f2")[:128]),
     "amask": feed("amask", np.fromfile(f"{ST}/g_am640_t0.raw", "<f2"))}
r = m0.run(["h", "knew", "vnew"], F)
for nm, ref, devf in zip(("h", "knew", "vnew"), r, (f"p_{TAG}_h", f"p_{TAG}_kn", f"p_{TAG}_vn")):
    a = ref.astype(np.float32).ravel()
    b = np.fromfile(f"{ST}/dev/{devf}.raw", "<f2").astype(np.float32).ravel()
    n = min(len(a), len(b))
    cos = float(a[:n] @ b[:n] / (np.linalg.norm(a[:n]) * np.linalg.norm(b[:n]) + 1e-12))
    print(f"DEV-vs-ORT {nm} cos={cos:.6f} maxdiff={np.abs(a[:n] - b[:n]).max():.4g}", flush=True)
w = sh(["dumpsys power | grep -m1 mWakefulness"])
print("WAKE:", w.strip())
if "Awake" in w:
    sh(["input keyevent 223"])
