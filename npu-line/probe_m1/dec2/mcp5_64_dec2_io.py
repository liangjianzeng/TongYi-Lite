#!/usr/bin/env python3
# [npu-line] dec2 chain IO prep + multi-step ORT reference WITH host-side cache rolling
# (mirrors chain_run5 ROLL semantics exactly: memmove-left + append new row).
# Usage: python3 mcp5_64_dec2_io.py <k>    (envs: DEC_NC default 512, DEC_STEPS default 3)
import os
import numpy as np, onnxruntime as ort, torch

NC = int(os.environ.get("DEC_NC", "512"))
STEPS = int(os.environ.get("DEC_STEPS", "3"))
K = int(os.sys.argv[1]) if len(os.sys.argv) > 1 else 0
HD, NKV, HID = 128, 2, 2048
OUT = "/mnt/e/wsl_stage"

torch.manual_seed(42)
hs = (torch.randn(1, 1, HID).half() * 0.5)
kc = (torch.randn(1, NKV, NC, HD).half() * 0.5)
vc = (torch.randn(1, NKV, NC, HD).half() * 0.5)

# device files (cache in T-layout [1,NC,HD,NKV] like converter's flip)
hs.numpy().tofile(f"{OUT}/d2_hs0.raw")
kc.permute(0, 2, 3, 1).contiguous().numpy().tofile(f"{OUT}/d2_kc.raw")
vc.permute(0, 2, 3, 1).contiguous().numpy().tofile(f"{OUT}/d2_vc.raw")
# rope table comes from mcp5_63 (model rotary_emb) — do NOT re-derive here
ct = np.fromfile(f"{OUT}/d2_cos_table.raw", dtype="<f2").reshape(-1, HD)
stb = np.fromfile(f"{OUT}/d2_sin_table.raw", dtype="<f2").reshape(-1, HD)
assert ct.shape[0] >= STEPS, "run mcp5_63 with DEC_NTAB >= steps first"

s = ort.InferenceSession(f"/home/liang/models/mcp5_dec2_{NC}/mcp5_dec2_l{K}.onnx",
                         ort.SessionOptions(), providers=['CPUExecutionProvider'])
k_np, v_np = kc.numpy().copy(), vc.numpy().copy()
h_np = hs.numpy().copy()
for t in range(STEPS):
    c = ct[t].reshape(1, 1, HD)
    sn = stb[t].reshape(1, 1, HD)
    oh, ok, ov = s.run(None, dict(zip(["hs", "kcache", "vcache", "cos", "sin"],
                                      [h_np, k_np, v_np, c, sn])))
    np.save(f"{OUT}/d2_ref_h{t}.npy", oh)
    # graph emits new rows in cache-row byte order [1,1,HD,NKV] -> back to natural [1,2,1,HD]
    ok_nat = ok.transpose(0, 3, 1, 2)
    ov_nat = ov.transpose(0, 3, 1, 2)
    # host roll = drop-oldest + append (chain_run5 ROLL semantics)
    k_np = np.concatenate([k_np[:, :, 1:, :], ok_nat], axis=2)
    v_np = np.concatenate([v_np[:, :, 1:, :], ov_nat], axis=2)
    h_np = oh
print("IO64_DONE steps", STEPS, "NC", NC, "layer", K, flush=True)
