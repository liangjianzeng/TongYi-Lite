#!/usr/bin/env python3
# [npu-line] G3: verify DLC per-channel scales == per-output-channel amax/127 of the
# ORIGINAL HF fp16 weights (in the onnx). Mis-binding (e.g. o_proj _permute rename, or
# scale array bound to a different weight) shows as a huge relerr for that tensor.
import json
import numpy as np
import onnx
from onnx import numpy_helper

DLC = "/home/liang/w4sim/ctx_w8nc640_l0/dlcjson"
ONNX = "/home/liang/models/mcp5_dec2_640/mcp5_nc640_l0.onnx"

d = json.load(open(DLC))["graph"]
m = onnx.load(ONNX, load_external_data=True)
inits = {i.name: numpy_helper.to_array(i) for i in m.graph.initializer}
# FC weight consumers map: find MatMul/Gemm rhs names in the onnx
wmap = {}
for n in m.graph.node:
    if n.op_type in ("MatMul", "Gemm") and len(n.input) >= 2:
        wmap[n.input[1]] = n.name
print(f"{'dlc_tensor':30s} {'onnx_src':30s} relerr  verdict")
for name, t in d["tensors"].items():
    if t.get("data_type") != 776:
        continue
    q = t["quant_params"]["axis_scale_offset"]
    sc_dlc = np.array([so["scale"] for so in q["scale_offsets"]], np.float32)
    base = name.replace("_permute", "")
    src = inits.get(base)
    if src is None:
        print(f"{name:30s} {'<no onnx init>':30s}")
        continue
    wf = src.astype(np.float32)
    cols = wf.reshape(-1, wf.shape[-1])
    sc_true = np.maximum(np.abs(cols).max(0) / 127.0, 1e-8)  # out-channel on [in,out]
    if sc_dlc.shape[0] != sc_true.shape[0]:
        # DLC stored OI [out,in]: columns already out -> recompute on stored orientation
        print(f"{name:30s} {str(wmap.get(base, '?')):30s} DIM {sc_dlc.shape} vs {sc_true.shape}")
        continue
    rel = np.abs(sc_dlc - sc_true).max() / max(sc_true.max(), 1e-12)
    print(f"{name:30s} {str(wmap.get(base, '?')):30s} {rel:.2e}  "
          f"{'OK' if rel < 1e-3 else 'MISBOUND!'}")
