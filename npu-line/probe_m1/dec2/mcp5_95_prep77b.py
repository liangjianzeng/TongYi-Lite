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
# PREP77b: long-input translation task -> model still generating at token 512
# (source text ~350 chars; expected answer far exceeds remaining budget).
import os as _os
prompt = _os.environ.get("D2Q_PROMPT") or (
    "把下面这段技术文档完整翻译成英文，保持术语准确：大语言模型的推理过程分为预填充和解码两个阶段。"
    "预填充阶段并行处理全部提示词，计算注意力键值缓存，属于计算密集型负载；"
    "解码阶段逐个生成新词元，每步都要读取整个键值缓存，属于访存密集型负载。"
    "异构调度可以把预填充交给神经网络处理器，解码交给图形处理器，充分利用两者的算力与带宽差异。"
    "键值缓存的跨设备迁移需要注意量化格式、旋转位置编码的布局以及张量的内存排列顺序，"
    "任何一处布局错配都会导致后续生成迅速发散，因此必须用参考序列做端到端一致性验证。"
    "此外端侧部署还受内存驻留限制，进程编排与权重回收是必须解决的工程问题。"
    "请逐句翻译并保留段落结构。")
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
