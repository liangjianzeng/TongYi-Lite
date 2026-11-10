#!/usr/bin/env python3
# [npu-line] Layout scan on RANDOM inputs (export-scoring regime): our ctx in both
# plausible o_proj layouts vs HF hook output, plus HF-style ctx replay. Decides whether
# the 0.44 branch mismatch is layout or content (q/scores) on random data.
import numpy as np
import torch
import torch.nn.functional as F
from transformers import AutoModelForCausalLM, DynamicCache
from transformers.models.llama.modeling_llama import apply_rotary_pos_emb

M = "/home/liang/models/minicpm5-2b"
S, NC, NKV, HD, HID, NH = 128, 512, 2, 128, 2048, 16
G = NH // NKV
NEG = -1e4

torch.manual_seed(42)
model = AutoModelForCausalLM.from_pretrained(M, dtype=torch.float16,
                                             attn_implementation="eager",
                                             trust_remote_code=True).eval()
ly = model.model.layers[0]
attn = ly.self_attn
hs = (torch.randn(1, S, HID) * 0.5).half()
kc = (torch.randn(1, NKV, NC, HD) * 0.5).half()
vc = (torch.randn(1, NKV, NC, HD) * 0.5).half()
emb = model.model.embed_tokens(torch.arange(S).unsqueeze(0))
cos, sin = model.model.rotary_emb(emb, torch.arange(600, 600 + S).unsqueeze(0))
am = torch.zeros(1, 1, S, NC + S).half()
am[0, 0, :, NC:] = torch.triu(torch.full((S, S), NEG), diagonal=1)

r1 = ly.input_layernorm(hs)
q = attn.q_proj(r1).view(1, S, NH, HD).transpose(1, 2)
k_ = attn.k_proj(r1).view(1, S, NKV, HD).transpose(1, 2)
v_ = attn.v_proj(r1).view(1, S, NKV, HD).transpose(1, 2)
q2, k2 = apply_rotary_pos_emb(q, k_, cos, sin)
kf = torch.cat([kc, k2], 2); vf = torch.cat([vc, v_], 2)
q4 = q2.reshape(NKV, G, S, HD)
sc = torch.stack([torch.matmul(q4[i], kf[0, i].transpose(0, 1)) for i in range(NKV)]) * (HD ** -0.5) + am
pp = F.softmax(sc.float(), dim=-1).half()
cx = torch.stack([torch.matmul(pp[i], vf[0, i]) for i in range(NKV)], dim=0)

cap = {}
h = attn.register_forward_hook(lambda m, i, o: cap.__setitem__(
    "ao", (o[0] if isinstance(o, (tuple, list)) else o).detach()))
dc = DynamicCache(); dc.update(kc.clone(), vc.clone(), 0)
with torch.no_grad():
    ly(hs, attention_mask=am, position_ids=torch.arange(600, 600 + S).unsqueeze(0),
       past_key_values=dc, position_embeddings=(cos, sin), use_cache=True,
       cache_position=torch.arange(NC, NC + S))
h.remove()
hf_ao = cap["ao"].reshape(1, S, HID)


def cs(a, b):
    a = np.asarray(a.detach(), np.float32).ravel(); b = np.asarray(b.detach(), np.float32).ravel()
    return float(a @ b / (np.linalg.norm(a) * np.linalg.norm(b) + 1e-12))


# HF-style ctx replay (probs expanded per head @ v repeated) for content check
vrep = vf.repeat_interleave(G, dim=1)
pp_exp = pp.reshape(NKV, G, S, NC + S)
pph = torch.empty(1, NH, S, NC + S, dtype=torch.float16)
for i in range(NKV):
    pph[0, i * G:(i + 1) * G] = pp_exp[i]
ctx_hf = torch.matmul(pph, vrep)
print(f"content ctx ours vs HF-replay: {cs(cx.reshape(1, NH, S, HD), ctx_hf):.4f}")
dd = (cx.reshape(1, NH, S, HD).float() - ctx_hf.float()).abs()
print(f"ctx absmax-diff {dd.max():.5f}  rel {(dd.max() / (ctx_hf.abs().max() + 1e-9)):.5f}")
for i in range(NH):
    print(f"  head {i:2d}: cos {cs(cx.reshape(NH, S, HD)[i], ctx_hf[0, i]):.4f} "
          f"absmax {dd[0, i].max():.5f}", end="\n" if i in (0, 1, 7, 8, 15) else "")
a1 = cx.permute(0, 2, 1, 3).reshape(S, NH * HD)
a2 = ctx_hf.transpose(1, 2).reshape(S, NH * HD)
print(f"ao layouts direct: absmax {(a1.float() - a2.float()).abs().max():.6f} cos {cs(a1, a2):.6f}")
with torch.no_grad():
    for nm, aov in {
        "ours permute (S,H,HD)": cx.permute(0, 2, 1, 3).reshape(S, NH * HD),
        "ours head-major (H,S,HD)": cx.reshape(S, NH * HD),
        "HF-replay (S,H,HD)": ctx_hf.transpose(1, 2).reshape(S, NH * HD),
    }.items():
        print(f"  o_proj[{nm}] vs hf_attn_out: {cs(attn.o_proj(aov).view(1, S, HID), hf_ao):.4f}")
print("SCAN79N_DONE", flush=True)
