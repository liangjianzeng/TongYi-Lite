#!/usr/bin/env python3
# [npu-line] Realistic chunked-prefill e2e prep: 512-token prompt at pos P0..P0+511.
# Emits (prefix d2q_, into /mnt/e/wsl_stage):
#   d2q_emb_{c}.raw       embed input per chunk, DEVICE layout (hid,s)
#   d2q_cos_table.raw / d2q_sin_table.raw   512 rope rows from model rotary_emb, per-S-block
#                           transposed to (hd,s) (device rule for square [1,S,HD] tensors)
#   d2q_am_{c}.raw        protocol amask per chunk [S,NC+S] ravel (window-valid + causal)
#   d2q_ref_logits.npy    HF full-sequence forward logits at the LAST prompt token (fp32)
#   d2q_hl_{c}.raw        (filled after first device pass optional) — none: relay is device-side
# Protocol: caches start ZEROS (device chain rolls); HF ref = ONE full forward (true causal,
# no padding) — the device chain must reproduce it THROUGH the masked zero-padded protocol.
import os
import numpy as np
import torch
from transformers import AutoModelForCausalLM, AutoTokenizer

M = "/home/liang/models/minicpm5-2b"
S = int(os.environ.get("DEC_S", "128"))
NC = int(os.environ.get("DEC_NC", "512"))
P0 = int(os.environ.get("DEC_P0", "88"))
CHUNKS = NC // S
OUT = "/mnt/e/wsl_stage"
NEG = -1e4

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
print("PROMPT_TOKENS", NC, "P0", P0, "first10", ids[0, :10].tolist(), flush=True)

with torch.no_grad():
    emb = model.model.embed_tokens(ids)                       # [1,NC,HID]
    pos_ids = torch.arange(P0, P0 + NC).unsqueeze(0)
    cosT, sinT = model.model.rotary_emb(emb, pos_ids)         # [1,NC,HD]
    out = model.model(input_ids=ids, position_ids=pos_ids, use_cache=True)
    last_hidden = out.last_hidden_state                        # [1,NC,HID]
    logits = model.lm_head(last_hidden[:, -1:, :])             # [1,1,VOCAB]
np.save(f"{OUT}/d2q_ref_logits.npy", logits[0, 0].float().numpy())
print("REF_LOGITS saved absmax", float(logits.abs().max()), flush=True)

for c in range(CHUNKS):
    e = emb[0, c * S:(c + 1) * S]
    e.T.contiguous().numpy().tofile(f"{OUT}/d2q_emb_{c}.raw")  # (hid,s)
    am = torch.zeros(S, NC + S).half()
    pad = NC - c * S
    if pad > 0:
        am[:, :pad] = NEG
    am[:, NC:] = torch.triu(torch.full((S, S), NEG), diagonal=1)
    am.numpy().tofile(f"{OUT}/d2q_am_{c}.raw")
ct = cosT[0].numpy().reshape(CHUNKS, S, -1).transpose(0, 2, 1).copy()
stt = sinT[0].numpy().reshape(CHUNKS, S, -1).transpose(0, 2, 1).copy()
ct.tofile(f"{OUT}/d2q_cos_table.raw")
stt.tofile(f"{OUT}/d2q_sin_table.raw")
# zero cache files (device rolls from zeros)
NKV, HD = 2, 128
np.zeros((NC, HD, NKV), dtype="<f2").tofile(f"{OUT}/d2q_kc0.raw")
np.zeros((NC, HD, NKV), dtype="<f2").tofile(f"{OUT}/d2q_vc0.raw")
# HF reference hidden state of the last token (for intermediate cross-check via norm/head)
last_hidden[0, -1, :].contiguous().numpy().tofile(f"{OUT}/d2q_ref_last_h.raw")
print("PREP77_DONE chunks", CHUNKS, flush=True)
