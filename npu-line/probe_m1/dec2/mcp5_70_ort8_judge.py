#!/usr/bin/env python3
# [npu-line] Third-party check: run the dec2 ORT graph chain 8 steps with the SAME seeded
# inputs as mcp5_68 (device semantics incl. host-roll), judge logits vs the HF reference.
#   ORT ~= ref            -> graph semantics fine -> device/host relay bug
#   ORT ~= device, << ref -> systematic fp16/graph drift from HF math
import os
import numpy as np, onnxruntime as ort

NC = int(os.environ.get("DEC_NC", "512"))
STEPS = int(os.environ.get("DEC_STEPS", "8"))
NL, NKV, HD = 42, 2, 128
OUT = "/mnt/e/wsl_stage"

hs = np.fromfile(f"{OUT}/d2e_hs0.raw", dtype="<f2").reshape(1, 1, 2048)
caches = []
for k in range(NL):
    kc = np.fromfile(f"{OUT}/d2e_kc{k}.raw", dtype="<f2").reshape(1, NC, HD, NKV).transpose(0, 3, 1, 2)
    vc = np.fromfile(f"{OUT}/d2e_vc{k}.raw", dtype="<f2").reshape(1, NC, HD, NKV).transpose(0, 3, 1, 2)
    caches.append([np.ascontiguousarray(kc), np.ascontiguousarray(vc)])
ct = np.fromfile(f"{OUT}/d2_cos_table.raw", dtype="<f2").reshape(-1, HD)
stb = np.fromfile(f"{OUT}/d2_sin_table.raw", dtype="<f2").reshape(-1, HD)

sessions = [ort.InferenceSession(f"/home/liang/models/mcp5_dec2_{NC}/mcp5_dec2_l{k}.onnx",
                                 ort.SessionOptions(), providers=['CPUExecutionProvider'])
            for k in range(NL)]

h = hs
for t in range(STEPS):
    cos = ct[t].reshape(1, 1, HD); sin = stb[t].reshape(1, 1, HD)
    for k in range(NL):
        oh, ok, ov = sessions[k].run(None, dict(zip(
            ["hs", "kcache", "vcache", "cos", "sin"], [h, caches[k][0], caches[k][1], cos, sin])))
        ok_nat = ok.transpose(0, 3, 1, 2); ov_nat = ov.transpose(0, 3, 1, 2)
        caches[k][0] = np.ascontiguousarray(np.concatenate([caches[k][0][:, :, 1:, :], ok_nat], axis=2))
        caches[k][1] = np.ascontiguousarray(np.concatenate([caches[k][1][:, :, 1:, :], ov_nat], axis=2))
        h = oh
# final norm + head in fp32-free numpy mirror of HF (RMSNorm eps=1e-5 then matmul lm_head)
import torch
model_w = torch.load("/dev/null", map_location="cpu", weights_only=False) if False else None
# use safetensors-free route: norm weight + lm_head from HF via transformers (CPU, fp16)
from safetensors import safe_open
import glob, json
cfg_dir = "/home/liang/models/minicpm5-2b"
wfiles = sorted(glob.glob(f"{cfg_dir}/*.safetensors"))
def get_tensor(name):  # checkpoint stores bf16 -> must go via torch, numpy chokes on 'bfloat16'
    for f in wfiles:
        with safe_open(f, framework="pt") as sf:
            if name in sf.keys():
                return sf.get_tensor(name)
    raise KeyError(name)
norm_w = get_tensor("model.norm.weight").float().numpy()
ln_h = h.astype(np.float32)
var = (ln_h ** 2).mean(-1, keepdims=True)
hn = (ln_h / np.sqrt(var + 1e-5) * norm_w).astype(np.float16)
lm_w = get_tensor("lm_head.weight").half().numpy()   # [vocab, HID] fp16
logits = (hn.reshape(-1, 2048) @ lm_w.T).astype(np.float32)

ref = np.load(f"{OUT}/d2e_ref_logits.npy").astype(np.float32).ravel()
dev = np.fromfile(f"{OUT}/d2e_dev_logits.raw", dtype="<f2").astype(np.float32).ravel()
def cos_(a, b):
    return float(a @ b / (np.linalg.norm(a) * np.linalg.norm(b) + 1e-12))
def topm(a, b, k=8):
    return len(set(np.argsort(-a)[:k]) & set(np.argsort(-b)[:k]))
print(f"ORT70 vs ref   cos={cos_(logits.ravel(), ref):.4f} argmax {logits.ravel().argmax()}/{ref.argmax()} top8={topm(logits.ravel(), ref)}/8")
print(f"DEV vs ref     cos={cos_(dev, ref):.4f} argmax {dev.argmax()}/{ref.argmax()} top8={topm(dev, ref)}/8")
print(f"DEV vs ORT70   cos={cos_(dev, logits.ravel()):.4f} argmax {dev.argmax()}/{logits.ravel().argmax()} top8={topm(dev, logits.ravel())}/8")
