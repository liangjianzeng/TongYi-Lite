#!/usr/bin/env python3
# [npu-line] Host ORT replay of the NC=640 decode protocol: 42 nc640 onnx graphs (S=1),
# cache = HF prefill terminal KV zero-padded to 640 rows, host roll (drop-oldest+append),
# per-step amask masking the drifting zero-pad window. Validates the amask window formula
# before burning device time. Variant A (derived): step t masks cache cols [512-t .. 639-t].
import sys
import numpy as np
import torch
import onnxruntime as ort
from transformers import AutoModelForCausalLM, AutoTokenizer

M = "/home/liang/models/minicpm5-2b"
ONNXD = "/home/liang/models/mcp5_dec2_640"
ST = "/mnt/e/wsl_stage"
NC, NKV, HD, HID, NH = 640, 2, 128, 2048, 16
REAL = 512
STEPS = 8
NEG = np.float16(-1e4)

model = AutoModelForCausalLM.from_pretrained(M, dtype=torch.float16,
                                             attn_implementation="eager",
                                             trust_remote_code=True).eval()
tok = AutoTokenizer.from_pretrained(M)
prompt = ("请把下面这句话翻译成英文，并简要解释语法：今天天气很好，我们一起去公园散步吧。"
          "另外，用一句话总结量子计算的核心思想。")
ids = tok(prompt, add_special_tokens=True, return_tensors="pt")["input_ids"]
if ids.shape[1] < REAL:
    pad = torch.full((1, REAL - ids.shape[1]), tok.eos_token_id or 1, dtype=ids.dtype)
    ids = torch.cat([ids, pad], dim=1)
ids = ids[:, :REAL]
with torch.no_grad():
    out = model.model(input_ids=ids, position_ids=torch.arange(88, 88 + REAL).unsqueeze(0),
                      use_cache=True)
kc0 = [out.past_key_values.layers[k].keys.detach().numpy().copy() for k in range(42)]
vc0 = [out.past_key_values.layers[k].values.detach().numpy().copy() for k in range(42)]
# zero-pad 512 -> 640 rows (matches d2e640_* on device)
kc0 = [np.concatenate([c, np.zeros((1, NKV, NC - REAL, HD), np.float16)], axis=2) for c in kc0]
vc0 = [np.concatenate([c, np.zeros((1, NKV, NC - REAL, HD), np.float16)], axis=2) for c in vc0]

sess = [ort.InferenceSession(f"{ONNXD}/mcp5_nc640_l{k}.onnx", ort.SessionOptions(),
                             providers=['CPUExecutionProvider']) for k in range(42)]


def cs(a, b):
    a = np.asarray(a, np.float32).ravel(); b = np.asarray(b, np.float32).ravel()
    return float(a @ b / (np.linalg.norm(a) * np.linalg.norm(b) + 1e-12))


def amask_v(t, lo=0):
    """additive [1,1,1,641] mask; variant window [REAL-t+lo .. 639-t+lo] negated."""
    am = np.zeros((1, 1, 1, NC + 1), np.float16)
    a, b = REAL - t + lo, NC - 1 - t + lo
    am[0, 0, 0, a:b + 1] = NEG
    return am


def replay(amask_fn):
    kc = [c.copy() for c in kc0]
    vc = [c.copy() for c in vc0]
    hs = np.fromfile(f"{ST}/d2e_hs0.raw", dtype="<f2").reshape(1, 1, HID).copy()
    allok, cs_list = True, []
    for t in range(STEPS):
        ct = np.fromfile(f"{ST}/d2_cos_table.raw", dtype="<f2").reshape(-1, HD)
        stt = np.fromfile(f"{ST}/d2_sin_table.raw", dtype="<f2").reshape(-1, HD)
        cos = np.ascontiguousarray(ct[t][None, None]).astype(np.float16)
        sin = np.ascontiguousarray(stt[t][None, None]).astype(np.float16)
        am = amask_fn(t)
        for k in range(42):
            oh, okn, ovn = sess[k].run(None, {"hs": hs, "kcache": kc[k], "vcache": vc[k],
                                              "cos": cos, "sin": sin, "amask": am})
            knew = okn.reshape(1, HD, NKV).transpose(2, 0, 1)[None]
            vnew = ovn.reshape(1, HD, NKV).transpose(2, 0, 1)[None]
            kc[k] = np.concatenate([kc[k][:, :, 1:, :], knew], axis=2)
            vc[k] = np.concatenate([vc[k][:, :, 1:, :], vnew], axis=2)
            hs = oh.reshape(1, 1, HID)
        with torch.no_grad():
            lg = model.lm_head(model.model.norm(torch.from_numpy(hs)))
        ref = np.load(f"{ST}/d2e_ref_logits_t{t}.npy")
        dev = lg[0, 0].float().numpy()
        c = cs(dev, ref)
        m = int(np.argmax(dev)) == int(np.argmax(ref))
        cs_list.append(c)
        allok &= c > 0.999 and m
        if t < STEPS - 1:
            hs = np.fromfile(f"{ST}/d2e_hs_t{t + 1}.raw", dtype="<f2").reshape(1, 1, HID).copy()
    return allok, cs_list


def replay_d(t_max=STEPS):
    """No-roll variant: knew written to row REAL+t directly; static zero region above."""
    kc = [c.copy() for c in kc0]
    vc = [c.copy() for c in vc0]
    hs = np.fromfile(f"{ST}/d2e_hs0.raw", dtype="<f2").reshape(1, 1, HID).copy()
    allok, cs_list = True, []
    for t in range(t_max):
        ct = np.fromfile(f"{ST}/d2_cos_table.raw", dtype="<f2").reshape(-1, HD)
        stt = np.fromfile(f"{ST}/d2_sin_table.raw", dtype="<f2").reshape(-1, HD)
        cos = np.ascontiguousarray(ct[t][None, None]).astype(np.float16)
        sin = np.ascontiguousarray(stt[t][None, None]).astype(np.float16)
        am = np.zeros((1, 1, 1, NC + 1), np.float16)
        am[0, 0, 0, REAL + t:NC] = NEG                     # zeros above the written rows
        for k in range(42):
            oh, okn, ovn = sess[k].run(None, {"hs": hs, "kcache": kc[k], "vcache": vc[k],
                                              "cos": cos, "sin": sin, "amask": am})
            knew = okn.reshape(1, HD, NKV).transpose(2, 0, 1)[None]
            vnew = ovn.reshape(1, HD, NKV).transpose(2, 0, 1)[None]
            kc[k][:, :, REAL + t, :] = knew[0, :, 0, :]
            vc[k][:, :, REAL + t, :] = vnew[0, :, 0, :]
            hs = oh.reshape(1, 1, HID)
        with torch.no_grad():
            lg = model.lm_head(model.model.norm(torch.from_numpy(hs)))
        ref = np.load(f"{ST}/d2e_ref_logits_t{t}.npy")
        dev = lg[0, 0].float().numpy()
        c = cs(dev, ref)
        m = int(np.argmax(dev)) == int(np.argmax(ref))
        cs_list.append(c)
        allok &= c > 0.999 and m
        if t < t_max - 1:
            hs = np.fromfile(f"{ST}/d2e_hs_t{t + 1}.raw", dtype="<f2").reshape(1, 1, HID).copy()
    return allok, cs_list


for variant in (sys.argv[1:] or ["A"]):
    if variant == "A":
        fn = lambda t: amask_v(t)
    elif variant == "B":
        fn = lambda t: amask_v(t, lo=1)          # off-by-one right
    elif variant == "C":
        fn = lambda t: amask_v(t, lo=REAL)       # no roll shift: static [512..639] at t=0 style
    elif variant == "D":
        ok, cs_l = replay_d()
        print("VARIANT D (no-roll direct write): " + " ".join(f"{c:.4f}" for c in cs_l))
        print("ORT_NC640_REPLAY D", "PASS" if ok else "FAIL", flush=True)
        continue
    else:  # Z = all-zero amask
        fn = lambda t: np.zeros((1, 1, 1, NC + 1), np.float16)
    ok, cs_l = replay(fn)
    print(f"VARIANT {variant}: " + " ".join(f"{c:.4f}" for c in cs_l))
    print("ORT_NC640_REPLAY", variant, "PASS" if ok else "FAIL", flush=True)
