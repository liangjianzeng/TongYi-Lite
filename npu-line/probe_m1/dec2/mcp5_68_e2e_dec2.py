#!/usr/bin/env python3
# [npu-line] E2E decode-chain prep: per-layer device IO + REAL-HF sequential reference logits.
# Mirrors chain_run5 semantics: same hs relay file across layers, per-layer cache rolled
# (drop-oldest + append) after each step; rope rows from the model rotary table (pos 600+t).
# Reference chain = actual HF layer modules -> model.norm -> lm_head. NEVER the graph's own math.
# Usage: DEC_NC=512 DEC_STEPS=4 python3 mcp5_68_e2e_dec2.py
import os
import numpy as np, torch
from transformers import AutoModelForCausalLM, DynamicCache

NC = int(os.environ.get("DEC_NC", "512"))
STEPS = int(os.environ.get("DEC_STEPS", "4"))
M = "/home/liang/models/minicpm5-2b"
OUT = "/mnt/e/wsl_stage"
NKV, HD = 2, 128

model = AutoModelForCausalLM.from_pretrained(M, dtype=torch.float16,
                                             attn_implementation="eager",
                                             trust_remote_code=True).eval()
NL = len(model.model.layers)

torch.manual_seed(7)
hs = (torch.randn(1, 1, 2048) * 0.5).half()
hs.numpy().tofile(f"{OUT}/d2e_hs0.raw")
caches = []
for k in range(NL):
    kc = (torch.randn(1, NKV, NC, HD) * 0.5).half()
    vc = (torch.randn(1, NKV, NC, HD) * 0.5).half()
    caches.append([kc, vc])
    kc.permute(0, 2, 3, 1).contiguous().numpy().tofile(f"{OUT}/d2e_kc{k}.raw")
    vc.permute(0, 2, 3, 1).contiguous().numpy().tofile(f"{OUT}/d2e_vc{k}.raw")

ct = np.fromfile(f"{OUT}/d2_cos_table.raw", dtype="<f2").reshape(-1, HD)
st = np.fromfile(f"{OUT}/d2_sin_table.raw", dtype="<f2").reshape(-1, HD)
assert ct.shape[0] >= STEPS, "need mcp5_63 (DEC_NTAB >= STEPS) first"

def mk_cache(kc, vc, idx):
    # self_attn writes at its own layer_idx — pre-populate there (see mcp5_63 note)
    try:
        return DynamicCache(past_key_values=[(kc.clone(), vc.clone())] * (idx + 1))
    except TypeError:
        dc = DynamicCache()
        for j in range(idx):
            dc.update(torch.zeros(1, NKV, 1, HD, dtype=kc.dtype),
                      torch.zeros(1, NKV, 1, HD, dtype=vc.dtype), j)
        dc.update(kc.clone(), vc.clone(), idx)
        return dc

def cache_kv(dc, idx):
    ly = dc.layers[idx]
    return (ly.keys, ly.values) if hasattr(ly, "keys") else (ly.key, ly.value)

with torch.no_grad():
    for t in range(STEPS):
        cos = torch.from_numpy(ct[t].copy()).unsqueeze(0).unsqueeze(0)   # [1,1,HD]
        sin = torch.from_numpy(st[t].copy()).unsqueeze(0).unsqueeze(0)
        pe = (cos, sin)
        pos_ids = torch.tensor([[600 + t]])
        h = hs
        for k in range(NL):
            dc = mk_cache(caches[k][0], caches[k][1], k)
            out = model.model.layers[k](h, attention_mask=None, position_ids=pos_ids,
                                        past_key_values=dc, position_embeddings=pe,
                                        use_cache=True, cache_position=torch.tensor([NC]))
            # this custom layer returns rank-2 (1,2048) — pin to rank-3, or the next
            # layer's q/k view mis-shapes and rope dies with a misleading 16-vs-128 err
            h = out[0].reshape(1, 1, 2048)
            rk, rv = cache_kv(dc, k)
            assert rk.shape[2] == NC + 1, f"l{k} cache len {rk.shape[2]}"
            knew, vnew = rk[:, :, -1:, :], rv[:, :, -1:, :]
            caches[k][0] = torch.cat([caches[k][0][:, :, 1:, :], knew], dim=2)
            caches[k][1] = torch.cat([caches[k][1][:, :, 1:, :], vnew], dim=2)
        hs = h  # relay to next step via the same file semantics
        # per-step logits so a device run of N steps can be judged against step N
        # without re-running the whole reference per N.
        np.save(f"{OUT}/d2e_ref_logits_t{t}.npy",
                model.lm_head(model.model.norm(hs)).float().numpy().ravel())
    logits = model.lm_head(model.model.norm(hs))
    logits = logits.reshape(1, 1, -1)
    np.save(f"{OUT}/d2e_ref_logits.npy", logits.float().numpy())
    print(f"E2E68_DONE steps={STEPS} NC={NC} NL={NL} "
          f"reflogit_absmax={logits.abs().max():.3f} argmax={logits.argmax(-1).item()}", flush=True)
