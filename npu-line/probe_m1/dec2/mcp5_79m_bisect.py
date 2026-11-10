#!/usr/bin/env python3
# [npu-line] Node-level bisect, REAL chunk0 inputs: our graph math (torch replay of
# DecodeLayer2, verified == ORT == device) vs official HF eager layer, spying HF's
# internal softmax/matmul inputs via F-monkeypatch. First node whose cos drops = culprit.
import numpy as np
import torch
import torch.nn.functional as F
from transformers import AutoModelForCausalLM, AutoTokenizer, DynamicCache

M = "/home/liang/models/minicpm5-2b"
ST = "/mnt/e/wsl_stage"
S, NC, NKV, HD, HID, NH = 128, 512, 2, 128, 2048, 16
G = NH // NKV

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

c = 0
emb = model.model.embed_tokens(ids)[0]
e = emb[c * S:(c + 1) * S].detach()
hs = np.ascontiguousarray(e.T.numpy().reshape(HID, S).T[None]).astype(np.float16)
kc = np.zeros((1, NKV, NC, HD), dtype=np.float16)
vc = np.zeros((1, NKV, NC, HD), dtype=np.float16)
ctb = np.fromfile(f"{ST}/d2q_cos_table.raw", dtype="<f2").reshape(4, HD, S)
stb = np.fromfile(f"{ST}/d2q_sin_table.raw", dtype="<f2").reshape(4, HD, S)
cos = np.ascontiguousarray(ctb[c].T[None]).astype(np.float16)
sin = np.ascontiguousarray(stb[c].T[None]).astype(np.float16)
am = np.fromfile(f"{ST}/d2q_am_{c}.raw", dtype="<f2").reshape(1, 1, S, NC + S)

ly = model.model.layers[0]
attn = ly.self_attn
hsT = torch.from_numpy(hs)
cosT = torch.from_numpy(cos)
sinT = torch.from_numpy(sin)
amT = torch.from_numpy(am)

# ---- our graph math, node by node ----
r1 = ly.input_layernorm(hsT)
q = attn.q_proj(r1).view(1, S, NH, HD).transpose(1, 2)
k = attn.k_proj(r1).view(1, S, NKV, HD).transpose(1, 2)
v = attn.v_proj(r1).view(1, S, NKV, HD).transpose(1, 2)
from transformers.models.llama.modeling_llama import apply_rotary_pos_emb
qr, kr = apply_rotary_pos_emb(q, k, cosT, sinT)
kfull = torch.cat([torch.from_numpy(kc), kr], dim=2)
vfull = torch.cat([torch.from_numpy(vc), v], dim=2)
q4 = qr.reshape(NKV, G, S, HD)
ours_scores = torch.stack([
    torch.matmul(q4[i], kfull[0, i].transpose(0, 1)) for i in range(NKV)
], dim=0) * (HD ** -0.5) + amT                      # [NKV,G,S,NC+S]
ours_probs = F.softmax(ours_scores.float(), dim=-1).half()
ours_ctx = torch.stack([torch.matmul(ours_probs[i], vfull[0, i]) for i in range(NKV)], dim=0)
ours_ao = ours_ctx.reshape(1, S, NH * HD)
ours_attn_out = hsT + attn.o_proj(ours_ao.reshape(S, NH * HD)).view(1, S, HID)
ours_m = ly.mlp(ly.post_attention_layernorm(ours_attn_out))
ours_h = ours_attn_out + ours_m

# ---- HF official layer with spies ----
cap = {}
_sm = F.softmax
def spy_sm(x, *a, **kw):
    cap["sm_in"] = x.detach().clone()
    out = _sm(x, *a, **kw)
    cap["sm_out"] = out.detach().clone()
    return out
F.softmax = spy_sm
attn_cap = {}
attn_hook = attn.register_forward_hook(
    lambda m, i, o: attn_cap.__setitem__("ao", (o[0] if isinstance(o, tuple) else o).detach()))
mlp_cap = {}
mlp_hook = ly.mlp.register_forward_hook(
    lambda m, i, o: mlp_cap.__setitem__("m", (o[0] if isinstance(o, tuple) else o).detach()))
_dc = DynamicCache()
_dc.update(torch.from_numpy(kc.copy()), torch.from_numpy(vc.copy()), 0)
with torch.no_grad():
    hf_out = ly(torch.from_numpy(hs), attention_mask=amT,
                position_ids=torch.arange(88, 88 + S).unsqueeze(0), past_key_values=_dc,
                position_embeddings=(cosT, sinT), use_cache=True,
                cache_position=torch.arange(NC, NC + S))
F.softmax = _sm
attn_hook.remove(); mlp_hook.remove()
hf_h = hf_out[0].reshape(S, HID) if hf_out[0].dim() == 3 else hf_out[0]

def cs(a, b):
    a = np.asarray(a, np.float32).ravel(); b = np.asarray(b, np.float32).ravel()
    return float(a @ b / (np.linalg.norm(a) * np.linalg.norm(b) + 1e-12))

print(f"final h  ours|HF : {cs(ours_h.detach(), hf_h.detach()):.4f}")
sm_in = cap["sm_in"]
print("sm_in shape", tuple(sm_in.shape), "ours_scores", tuple(ours_scores.shape))
sm_in_g = sm_in.reshape(NKV, G, S, NC + S)
print(f"scores+mask ours|HF: {cs(ours_scores.detach(), sm_in_g.detach()):.4f}")
sm_out = cap["sm_out"].reshape(NKV, G, S, NC + S)
print(f"probs      ours|HF: {cs(ours_probs.detach(), sm_out.detach()):.4f}  "
      f"absmax ours {ours_probs.abs().max():.4f} hf {sm_out.abs().max():.4f}")
ours_ao_pre = attn.o_proj(ours_ao.reshape(S, NH * HD)).view(1, S, HID)
hf_ao = attn_cap["ao"].reshape(1, S, HID) if attn_cap["ao"].dim() == 3 else attn_cap["ao"].reshape(1, S, HID)
print(f"attn_out   ours|HF: {cs(ours_ao_pre.detach(), hf_ao.detach()):.4f}")
# replay HF-style ctx: probs(fp16) @ v repeated per head — then scan o_proj input layouts
vh = vfull.repeat_interleave(G, dim=1)                       # [1,16,NC+S,HD]
ctx_hf = torch.matmul(cap["sm_out"].to(torch.float16), vh)   # [1,16,S,HD]
print(f"ctx replay(HF-style) vs ours_ctx: {cs(ctx_hf.detach(), ours_ctx.reshape(1, NH, S, HD).detach()):.4f}")
with torch.no_grad():
    variants = {
        "(H,S,HD) ours": ours_ao.reshape(S, NH * HD),
        "(S,H,HD)": ctx_hf.transpose(1, 2).reshape(S, NH * HD),
        "(S,HD,H)": ctx_hf.permute(0, 2, 3, 1).reshape(S, NH * HD),
        "(HD,H,S)": ctx_hf.permute(0, 2, 3, 1).permute(2, 1, 0).reshape(S, NH * HD) if False else None,
    }
    for nm, ao in variants.items():
        if ao is None:
            continue
        with torch.no_grad():
            o = attn.o_proj(ao).view(1, S, HID)
        print(f"  o_proj[{nm}] vs hf_attn_out: {cs(o.detach(), hf_ao.detach()):.4f}")
hf_m = mlp_cap["m"]
print(f"mlp        ours|HF: {cs(ours_m.detach(), hf_m.reshape(1, S, HID).detach() if hf_m.dim()==3 else hf_m.detach()):.4f}")
print("BISECT79M_DONE", flush=True)
