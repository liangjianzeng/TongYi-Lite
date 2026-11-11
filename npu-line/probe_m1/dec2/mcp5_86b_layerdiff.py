#!/usr/bin/env python3
# [npu-line] Decisive layer-level bifurcation: ORT nc640 l0 (padded cache + mask 512:640)
# vs ORT dec2-512 l0 (proven == HF at layer level, 42/42). Same hs/know/vnew/rope.
# cos==1 -> nc640 graph clean, protocol is the suspect; <1 -> NC=640 export bug.
import numpy as np
import torch
import onnxruntime as ort
from transformers import AutoModelForCausalLM, AutoTokenizer

M = "/home/liang/models/minicpm5-2b"
ST = "/mnt/e/wsl_stage"
NKV, HD, HID = 2, 128, 2048
NEG = np.float16(-1e4)

model = AutoModelForCausalLM.from_pretrained(M, dtype=torch.float16,
                                             attn_implementation="eager",
                                             trust_remote_code=True).eval()
tok = AutoTokenizer.from_pretrained(M)
prompt = ("请把下面这句话翻译成英文，并简要解释语法：今天天气很好，我们一起去公园散步吧。"
          "另外，用一句话总结量子计算的核心思想。")
ids = tok(prompt, add_special_tokens=True, return_tensors="pt")["input_ids"]
if ids.shape[1] < 512:
    pad = torch.full((1, 512 - ids.shape[1]), tok.eos_token_id or 1, dtype=ids.dtype)
    ids = torch.cat([ids, pad], dim=1)
ids = ids[:, :512]
with torch.no_grad():
    out = model.model(input_ids=ids, position_ids=torch.arange(88, 88 + 512).unsqueeze(0),
                      use_cache=True)
kc = out.past_key_values.layers[0].keys.detach().numpy().copy()   # [1,2,512,128]
vc = out.past_key_values.layers[0].values.detach().numpy().copy()
kcp = np.concatenate([kc, np.zeros((1, NKV, 128, HD), np.float16)], axis=2)
vcp = np.concatenate([vc, np.zeros((1, NKV, 128, HD), np.float16)], axis=2)
ct = np.fromfile(f"{ST}/d2_cos_table.raw", dtype="<f2").reshape(-1, HD)
stt = np.fromfile(f"{ST}/d2_sin_table.raw", dtype="<f2").reshape(-1, HD)
cos = np.ascontiguousarray(ct[0][None, None]).astype(np.float16)
sin = np.ascontiguousarray(stt[0][None, None]).astype(np.float16)
hs = np.fromfile(f"{ST}/d2e_hs0.raw", dtype="<f2").reshape(1, 1, HID).copy()
am = np.zeros((1, 1, 1, 641), np.float16)
am[0, 0, 0, 512:640] = NEG


def cs(a, b):
    a = np.asarray(a, np.float32).ravel(); b = np.asarray(b, np.float32).ravel()
    return float(a @ b / (np.linalg.norm(a) * np.linalg.norm(b) + 1e-12))


s512 = ort.InferenceSession("/home/liang/models/mcp5_dec2_512/mcp5_dec2_l0.onnx",
                            ort.SessionOptions(), providers=['CPUExecutionProvider'])
s640 = ort.InferenceSession("/home/liang/models/mcp5_dec2_640/mcp5_nc640_l0.onnx",
                            ort.SessionOptions(), providers=['CPUExecutionProvider'])
names512 = [o.name for o in s512.get_outputs()]
print("s512 outputs:", names512)
o512 = s512.run(["h", "knew", "vnew"], {"hs": hs, "kcache": kc, "vcache": vc,
                                        "cos": cos, "sin": sin,
                                        "amask": np.zeros((1, 1, 1, 513), np.float16)})
h512, k512, v512 = o512
print("s640 outputs:", [o.name for o in s640.get_outputs()])
h640, k640, v640 = s640.run(["h", "knew", "vnew"], {"hs": hs, "kcache": kcp, "vcache": vcp,
                                                     "cos": cos, "sin": sin, "amask": am})
# amask WITHOUT pad masking (zero) to isolate pad-column contamination:
amz = np.zeros((1, 1, 1, 641), np.float16)
hz640, _, _ = s640.run(["h", "knew", "vnew"], {"hs": hs, "kcache": kcp, "vcache": vcp,
                                               "cos": cos, "sin": sin, "amask": amz})
print(f"h nc640(mask)|dec2  cos={cs(h640, h512):.6f}")
print(f"k knew nc640|dec2   cos={cs(k640, k512):.6f}")
print(f"h nc640(zeroam)|dec2 cos={cs(hz640, h512):.6f}")
print(f"h nc640(mask)|nc640(zeroam) cos={cs(h640, hz640):.6f}")
