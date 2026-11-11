#!/usr/bin/env python3
# [npu-line] Step-0 chain diagnostics: ORT (protocol A step 0) logits vs device 1-step
# chain logits vs HF ref — three-way to localize the chain-level divergence.
import numpy as np
import torch
import onnxruntime as ort

ST = "/mnt/e/wsl_stage"
NKV, HD, HID = 2, 128, 2048
NEG = np.float16(-1e4)

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
hs = np.fromfile(f"{ST}/d2e_hs0.raw", "<f2").reshape(1, 1, HID)

sess = [ort.InferenceSession(f"/home/liang/models/mcp5_dec2_640/mcp5_nc640_l{k}.onnx",
                             ort.SessionOptions(), providers=['CPUExecutionProvider'])
        for k in range(42)]
for k in range(42):
    oh, _, _ = sess[k].run(["h", "knew", "vnew"], {"hs": hs, "kcache": kc[k], "vcache": vc[k],
                                                   "cos": cos, "sin": sin, "amask": am})
    hs = oh.reshape(1, 1, HID)
with torch.no_grad():
    lg = model.lm_head(model.model.norm(torch.from_numpy(hs.astype(np.float16))))
ort_lg = lg[0, 0].float().numpy()

dev = np.fromfile(f"{ST}/g_dev_lit0.raw", "<f2").astype(np.float32)
ref = np.load(f"{ST}/d2e_ref_logits_t0.npy").astype(np.float32).ravel()


def cs(a, b):
    return float(a @ b / (np.linalg.norm(a) * np.linalg.norm(b) + 1e-12))


print(f"dev|ort cos={cs(dev, ort_lg):.6f}")
print(f"ort|ref cos={cs(ort_lg, ref):.6f}")
print(f"dev|ref cos={cs(dev, ref):.6f}")
print(f"argmax dev={int(np.argmax(dev))} ort={int(np.argmax(ort_lg))} ref={int(np.argmax(ref))}")
