#!/usr/bin/env python3
# [npu-line] Host ORT replay of the REAL decode chain: 42 dec2 onnx graphs (S=1), cache =
# HF prefill terminal KV (natural layout), host roll (drop-oldest+append), feeds/refs from
# 80 prep. If ORT replay == refs, protocol+graphs are clean and the device side is guilty;
# else the protocol itself diverges (debuggable on host).
import numpy as np
import torch
import onnxruntime as ort
from transformers import AutoModelForCausalLM, AutoTokenizer

M = "/home/liang/models/minicpm5-2b"
ONNXD = "/home/liang/models/mcp5_dec2_512"
ST = "/mnt/e/wsl_stage"
NC, NKV, HD, HID, NH = 512, 2, 128, 2048, 16
STEPS = 8

model = AutoModelForCausalLM.from_pretrained(M, dtype=torch.float16,
                                             attn_implementation="eager",
                                             trust_remote_code=True).eval()
tok = AutoTokenizer.from_pretrained(M)
prompt = ("请把下面这句话翻译成英文，并简要解释语法：今天天气很好，我们一起去公园散步吧。"
          "另外，用一句话总结量子计算的核心思想。")
ids = tok(prompt, add_special_tokens=True, return_tensors="pt")["input_ids"]
if ids.shape[1] < NC:
    pad = torch.full((1, NC - ids.shape[1]), tok.eos_token_id or 1, dtype=ids.dtype)
    ids = torch.cat([ids, pad], dim=1)
ids = ids[:, :NC]
with torch.no_grad():
    out = model.model(input_ids=ids, position_ids=torch.arange(88, 88 + NC).unsqueeze(0),
                      use_cache=True)
kc = [out.past_key_values.layers[k].keys.detach().numpy().copy() for k in range(42)]  # [1,2,NC,HD]
vc = [out.past_key_values.layers[k].values.detach().numpy().copy() for k in range(42)]

sess = [ort.InferenceSession(f"{ONNXD}/mcp5_dec2_l{k}.onnx", ort.SessionOptions(),
                             providers=['CPUExecutionProvider']) for k in range(42)]

def cs(a, b):
    a = np.asarray(a, np.float32).ravel(); b = np.asarray(b, np.float32).ravel()
    return float(a @ b / (np.linalg.norm(a) * np.linalg.norm(b) + 1e-12))


hs = np.fromfile(f"{ST}/d2e_hs0.raw", dtype="<f2").reshape(1, 1, HID).copy()
allok = True
for t in range(STEPS):
    ct = np.fromfile(f"{ST}/d2_cos_table.raw", dtype="<f2").reshape(-1, HD)
    stt = np.fromfile(f"{ST}/d2_sin_table.raw", dtype="<f2").reshape(-1, HD)
    cos = np.ascontiguousarray(ct[t][None, None]).astype(np.float16)   # [1,1,128] pos 600+t
    sin = np.ascontiguousarray(stt[t][None, None]).astype(np.float16)
    for k in range(42):
        oh, okn, ovn = sess[k].run(None, {"hs": hs, "kcache": kc[k], "vcache": vc[k],
                                          "cos": cos, "sin": sin})
        # host roll in cache-ROW order then store back in natural (kv,s,hd)
        knew = okn.reshape(S1 := 1, HD, NKV).transpose(2, 0, 1)[None]         # [1,NKV,1,HD]
        vnew = ovn.reshape(S1, HD, NKV).transpose(2, 0, 1)[None]
        kc[k] = np.concatenate([kc[k][:, :, 1:, :], knew], axis=2)
        vc[k] = np.concatenate([vc[k][:, :, 1:, :], vnew], axis=2)
        hs = oh.reshape(1, 1, HID)
    # logits via norm+head in torch (verified components)
    with torch.no_grad():
        lg = model.lm_head(model.model.norm(torch.from_numpy(hs)))
    ref = np.load(f"{ST}/d2e_ref_logits_t{t}.npy")
    dev = lg[0, 0].float().numpy()
    c = cs(dev, ref)
    m = int(np.argmax(dev)) == int(np.argmax(ref))
    print(f"step {t}: ORT-replay|ref cos={c:.4f} argmax {np.argmax(dev)} vs {np.argmax(ref)} MATCH={m}")
    allok &= c > 0.999 and m
    if t < STEPS - 1:
        hs = np.fromfile(f"{ST}/d2e_hs_t{t + 1}.raw", dtype="<f2").reshape(1, 1, HID).copy()
print("ORT_REPLAY", "PASS" if allok else "FAIL", flush=True)
