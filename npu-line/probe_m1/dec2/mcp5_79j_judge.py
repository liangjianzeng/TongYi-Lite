#!/usr/bin/env python3
# [npu-line] e2e prefill judge: device l41 last-token row (declared (hid,s) layout) ->
# model.model.norm + lm_head (verified decode-line pieces, host torch) -> logits vs the
# HF full-sequence reference from mcp5_77.
import numpy as np
import torch
from transformers import AutoModelForCausalLM

M = "/home/liang/models/minicpm5-2b"
S = 128
model = AutoModelForCausalLM.from_pretrained(M, dtype=torch.float16,
                                             attn_implementation="eager",
                                             trust_remote_code=True).eval()

hb = np.fromfile("/mnt/e/wsl_stage/dev/d2q_h_l41_3.raw", dtype="<f2")
assert hb.size == 2048 * S, hb.size
h_last = hb.reshape(2048, S)[:, S - 1]            # declared (hid,s): last token = col S-1
h = torch.from_numpy(h_last.copy()).half().unsqueeze(0).unsqueeze(0)   # [1,1,HID]
with torch.no_grad():
    logits = model.lm_head(model.model.norm(h))[0, 0].float().numpy()
ref = np.load("/mnt/e/wsl_stage/d2q_ref_logits.npy")
cos = float(logits @ ref / (np.linalg.norm(logits) * np.linalg.norm(ref) + 1e-12))
top_d = np.argsort(-logits)[:8]
top_r = np.argsort(-ref)[:8]
print(f"E2E_PREFILL logits cos={cos:.4f} absmax dev={np.abs(logits).max():.3f} ref={np.abs(ref).max():.3f}")
print(f"argmax dev={top_d[0]} ref={top_r[0]} MATCH={top_d[0] == top_r[0]}")
print(f"top8 dev={top_d.tolist()} ref={top_r.tolist()} overlap={len(set(top_d) & set(top_r))}/8")
print("JUDGE79_DONE", flush=True)
