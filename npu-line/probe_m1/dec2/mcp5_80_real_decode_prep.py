#!/usr/bin/env python3
# [npu-line] Real-conversation decode continuation prep: SAME prompt/pad/P0 as the prefill
# e2e (mcp5_77), HF greedy 8 steps after the 512-token prefill (pos 600..607). Emits
# d2e_hs0.raw + d2e_hs_t{t}.raw (teacher feeds = embed(greedy token)) and
# d2e_ref_logits_t{t}.npy per step. Device chain will run on the PREFILL's terminal KV
# (d2q_*_41 ROLL_SAVE states) — the real prefill->decode handoff.
import os
import numpy as np
import torch
from transformers import AutoModelForCausalLM, AutoTokenizer

M = "/home/liang/models/minicpm5-2b"
NC = 512
STEPS = int(os.environ.get("DEC_STEPS", "8"))
OUT = "/mnt/e/wsl_stage"

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
    cache = out.past_key_values
    lg = model.lm_head(out.last_hidden_state[:, -1:, :])
    tok_seq = [int(lg[0, 0].argmax(-1).item())]
    # Aligned protocol: device step t feeds embed(greedy_t) and outputs logits_t;
    # ref_t = HF logits AFTER feeding greedy_t (feed -> forward -> save).
    for t in range(STEPS):
        feed = model.model.embed_tokens(torch.tensor([[tok_seq[-1]]])).half()
        feed.numpy().tofile(f"{OUT}/d2e_hs0.raw" if t == 0 else f"{OUT}/d2e_hs_t{t}.raw")
        if t > 0:
            for lay in cache.layers:                      # rolled 512-row window alignment
                if lay.keys.shape[2] > NC:
                    lay.keys = lay.keys[:, :, -NC:, :]
                    lay.values = lay.values[:, :, -NC:, :]
        o = model(input_ids=torch.tensor([[tok_seq[-1]]]),
                  position_ids=torch.tensor([[600 + t]]),
                  past_key_values=cache,
                  cache_position=torch.tensor([[NC + t]]), use_cache=True)
        lg = o.logits[:, -1:, :]
        np.save(f"{OUT}/d2e_ref_logits_t{t}.npy", lg[0, 0].float().numpy().ravel())
        tok_seq.append(int(lg[0, 0].argmax(-1).item()))
print("GREEDY_TOKENS", tok_seq, flush=True)
try:
    print("GREEDY_TEXT:", tok.decode(tok_seq), flush=True)
except Exception as e:
    print("decode text skipped:", e)
print("PREP80_DONE", flush=True)
