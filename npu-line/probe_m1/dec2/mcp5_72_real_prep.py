#!/usr/bin/env python3
# [npu-line] REALISTIC e2e prep: seed the decode chain from an actual HF prompt forward
# (not random tensors): 511-token prompt at positions 89..599 so the 8 decode steps
# continue at pos 600..607 (matches the d2 rope table). Dumps per-layer caches (T-layout),
# hs0 = embeddings(next token), and per-step HF logits incl. greedy tokens.
# Random init was adversarial: off-distribution hs/caches exaggerate fp16 drift.
# Usage: DEC_NC=512 DEC_STEPS=8 python3 mcp5_72_real_prep.py
import os
import numpy as np, torch
from transformers import AutoModelForCausalLM, AutoTokenizer

NC = int(os.environ.get("DEC_NC", "512"))
STEPS = int(os.environ.get("DEC_STEPS", "8"))
M = "/home/liang/models/minicpm5-2b"
OUT = "/mnt/e/wsl_stage"
NKV, HD = 2, 128

tok = AutoTokenizer.from_pretrained(M, trust_remote_code=True)
model = AutoModelForCausalLM.from_pretrained(M, dtype=torch.float16,
                                             attn_implementation="eager",
                                             trust_remote_code=True).eval()
NL = len(model.model.layers)

base = "人工智能助手需要在对话中保持连贯、准确和礼貌。用户提出问题时，助手应先理解意图，再给出清晰完整的回答。" \
       "技术讨论应包含背景、方法与结论。对于不确定的内容，应坦诚说明并给出验证思路。" \
       "The assistant should reason step by step, verify claims, and keep the response grounded in context. "
ids = tok(base, add_special_tokens=False).input_ids[:NC - 1]
L = len(ids)
while len(ids) < NC:                            # EXACTLY NC rows: the chain invariant is
    ids = ids + ids                             # kcache=NC rows at input, host rolls after each step
ids = ids[:NC]
L = len(ids)                                    # re-take AFTER padding (pos must match input len)
P0 = 600 - L                                    # prompt occupies pos P0..599; decode continues at 600
print("PROMPT len", L, "pos", P0, flush=True)

with torch.no_grad():
    inp = torch.tensor([ids])
    pos = torch.arange(P0, P0 + L).unsqueeze(0)
    out = model(inp, position_ids=pos, use_cache=True)
    cache = out.past_key_values
    logits = out.logits[:, -1:, :]
    nxt = int(logits.argmax(-1).item())
    hs = model.model.embed_tokens(torch.tensor([[nxt]])).half()
    hs.numpy().tofile(f"{OUT}/d2e_hs0.raw")
    hs.numpy().tofile(f"{OUT}/d2e_hs_t0.raw")   # per-step teacher-forcing feed (see reseed)

    caches = []
    for k in range(NL):
        if hasattr(cache, "layers"):
            kc, vc = cache.layers[k].keys.half(), cache.layers[k].values.half()
        else:
            kc, vc = cache.key_cache[k].half(), cache.value_cache[k].half()
        assert kc.shape[2] == L, (k, kc.shape)
        caches.append([kc.contiguous().clone(), vc.contiguous().clone()])
        kc.permute(0, 2, 3, 1).contiguous().numpy().tofile(f"{OUT}/d2e_kc{k}.raw")
        vc.permute(0, 2, 3, 1).contiguous().numpy().tofile(f"{OUT}/d2e_vc{k}.raw")

ct = np.fromfile(f"{OUT}/d2_cos_table.raw", dtype="<f2").reshape(-1, HD)
st = np.fromfile(f"{OUT}/d2_sin_table.raw", dtype="<f2").reshape(-1, HD)

# greedy rollout continuing the prompt: layer-chain with rolling caches, pos 600+t
toks, toks_ref = [nxt], []
with torch.no_grad():
    for t in range(STEPS):
        cos = torch.from_numpy(ct[t].copy()).unsqueeze(0).unsqueeze(0)
        sin = torch.from_numpy(st[t].copy()).unsqueeze(0).unsqueeze(0)
        pe = (cos, sin)
        pos_ids = torch.tensor([[600 + t]])
        h = hs
        for k in range(NL):
            from transformers import DynamicCache
            try:
                dc = DynamicCache(past_key_values=[(caches[k][0].clone(), caches[k][1].clone())] * (k + 1))
            except TypeError:
                dc = DynamicCache()
                for j in range(k):
                    dc.update(torch.zeros(1, NKV, 1, HD, dtype=torch.float16),
                              torch.zeros(1, NKV, 1, HD, dtype=torch.float16), j)
                dc.update(caches[k][0].clone(), caches[k][1].clone(), k)
            o = model.model.layers[k](h, attention_mask=None, position_ids=pos_ids,
                                      past_key_values=dc, position_embeddings=pe,
                                      use_cache=True, cache_position=torch.tensor([NC]))
            h = o[0].reshape(1, 1, -1)
            ly = dc.layers[k]
            rk, rv = (ly.keys, ly.values) if hasattr(ly, "keys") else (ly.key, ly.value)
            assert rk.shape[2] == NC + 1, (k, rk.shape)
            caches[k][0] = torch.cat([caches[k][0][:, :, 1:, :], rk[:, :, -1:, :]], dim=2)
            caches[k][1] = torch.cat([caches[k][1][:, :, 1:, :], rv[:, :, -1:, :]], dim=2)
        hs = h
        lg = model.lm_head(model.model.norm(h)).float()
        np.save(f"{OUT}/d2e_ref_logits_t{t}.npy", lg.numpy().ravel())
        if t == STEPS - 1:                       # 69's built-in judge reads d2e_ref_logits.npy
            np.save(f"{OUT}/d2e_ref_logits.npy", lg.numpy().reshape(1, 1, -1))
        nt = int(lg.argmax(-1).item())
        toks.append(nt)
        toks_ref.append(nt)
        hs = model.model.embed_tokens(torch.tensor([[nt]])).half()   # greedy teacher-forcing
        hs.numpy().tofile(f"{OUT}/d2e_hs_t{t + 1}.raw")              # device reseeds this at step t+1
    # (per-step refs incl. the final one are saved inside the loop; no post-loop re-derivation)
    with open(f"{OUT}/d2e_greedy_tokens.txt", "w") as f:
        f.write(",".join(str(x) for x in toks_ref))
    print("REAL72_DONE toks", toks_ref, "decoded:", tok.decode(toks_ref[1:8]), flush=True)
