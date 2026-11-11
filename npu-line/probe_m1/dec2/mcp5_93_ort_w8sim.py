#!/usr/bin/env python3
# [npu-line] G3: host ORT simulation of the W8 build — quantize+dequantize every MatMul
# rhs with the SAME per-out-channel scales as mcp5_93_gen_enc.py, run fp16-original vs
# w8-simulated layer on identical feeds, cos(h/knew/vnew). cos~1 -> quantization math OK,
# the device W8 graph itself misapplies scales/packing; cos low -> scale semantics wrong.
# Usage: python3 mcp5_93_ort_w8sim.py <layer N>
import json
import sys
import numpy as np
import onnx
import onnxruntime as ort
from onnx import numpy_helper

N = int(sys.argv[1]) if len(sys.argv) > 1 else 0
ST = "/mnt/e/wsl_stage"
NKV, HD, HID = 2, 128, 2048
NEG = np.float16(-1e4)
ONNX = f"/home/liang/models/mcp5_dec2_640/mcp5_nc640_l{N}.onnx"
ENC = f"/home/liang/l{N}_enc.json"

enc = json.load(open(ENC))["param_encodings"]
m = onnx.load(ONNX, load_external_data=True)
inits = {i.name: i for i in m.graph.initializer}
n_q = 0
for name, e in enc.items():
    if name not in inits:
        print("ENC-NOINIT", name)
        continue
    W = numpy_helper.to_array(inits[name]).astype(np.float32)
    scales = np.array([d["scale"] for d in e], np.float32)  # list order = out columns
    flat = W.reshape(-1, W.shape[-1])
    q = np.clip(flat / scales, -127, 127)
    dq = (np.rint(q) * scales).astype(np.float16).reshape(W.shape)
    newt = numpy_helper.from_array(dq, name)
    inits[name].CopyFrom(newt)
    n_q += 1
print("W8SIM quantized", n_q, "tensors for layer", N, flush=True)
SIM = f"/home/liang/mcp5_nc640_l{N}_w8sim.onnx"
onnx.save(m, SIM)

kc = np.fromfile(f"{ST}/d2e640b_kc{N}.raw", "<f2")
vc = np.fromfile(f"{ST}/d2e640b_vc{N}.raw", "<f2")
hs = np.fromfile(f"{ST}/d2e_hs0.raw", "<f2").reshape(1, 1, HID)
ct = np.fromfile(f"{ST}/d2_cos_table.raw", "<f2").reshape(-1, HD)
stt = np.fromfile(f"{ST}/d2_sin_table.raw", "<f2").reshape(-1, HD)
# feeds sized by ctx-declared bytes: reshape to the onnx input dims
mi = {i.name: [d.dim_value for d in i.type.tensor_type.shape.dim] for i in m.graph.input}
def feed(name, arr):
    shape = mi[name]
    n = int(np.prod(shape))
    return arr.astype("<f2").reshape(shape).copy()
F = {"hs": feed("hs", hs.ravel()), "kcache": feed("kcache", kc), "vcache": feed("vcache", vc),
     "cos": feed("cos", ct[0]), "sin": feed("sin", stt[0])}
# amask: per-step 641-col row (decode step0 layout used by g_am640_t0)
am_path = f"{ST}/g_am640_t0.raw"
import os
if os.path.exists(am_path):
    F["amask"] = feed("amask", np.fromfile(am_path, "<f2"))
else:
    a = np.zeros(int(np.prod(mi["amask"])), "<f2")
    F["amask"] = a.reshape(mi["amask"])

so = ort.SessionOptions()
outs = ["h", "knew", "vnew"]
r1 = ort.InferenceSession(ONNX, so, providers=["CPUExecutionProvider"]).run(outs, F)
r2 = ort.InferenceSession(SIM, so, providers=["CPUExecutionProvider"]).run(outs, F)
for nm, a, b in zip(outs, r1, r2):
    a = a.astype(np.float32).ravel(); b = b.astype(np.float32).ravel()
    cos = float(a @ b / (np.linalg.norm(a) * np.linalg.norm(b) + 1e-12))
    print(f"{nm} cos={cos:.6f} maxdiff={np.abs(a-b).max():.4g}", flush=True)
