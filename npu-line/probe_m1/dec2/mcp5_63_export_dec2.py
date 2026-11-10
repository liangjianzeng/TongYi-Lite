#!/usr/bin/env python3
# [npu-line] Decode layer-graph exporter v2 (KV chain, host-rolled cache, grouped attention).
# Fixes vs mcp5_58 (whose cos=1.0 was self-referential — device vs ORT of the same hand-rolled block):
#   1) block structure now mirrors HF LlamaDecoderLayer exactly (pre-norm on attn input,
#      post_attention_layernorm on MLP input, residual stream returned UN-normalized);
#      58 fed raw hs into qkv, normed MLP input with input_layernorm, and returned the normed out.
#   2) GQA attention via batched MatMul on [1,NKV,G,1,HD] — NO repeat_kv Gather expansion
#      (the [1,16,NC,128] materializations + transposes were the exec-time hog: 100ms@NC512).
#   3) kcache/vcache are READ-ONLY inputs; graph outputs only k_new/v_new [1,2,1,128] (post-rope k).
#      Host (chain_run5 ROLL) does drop-oldest+append in place.
# Reference = REAL HF layer forward (not a re-trace of our own math).
# Usage: python3 mcp5_63_export_dec2.py l0        # single layer (NC from env DEC_NC, default 512)
#        python3 mcp5_63_export_dec2.py all
import os, sys
import torch
import numpy as np
import onnx, onnxruntime as ort
from transformers import AutoModelForCausalLM
from transformers.models.llama.modeling_llama import apply_rotary_pos_emb

M = "/home/liang/models/minicpm5-2b"
NC = int(os.environ.get("DEC_NC", "512"))
OUT = f"/home/liang/models/mcp5_dec2_{NC}"
NH, NKV, HD = 16, 2, 128
HID = 2048
G = NH // NKV
os.makedirs(OUT, exist_ok=True)   # NC-variant dir may not pre-exist; external-data export needs it

MODE = sys.argv[1] if len(sys.argv) > 1 else "l0"
torch.manual_seed(0)

model = AutoModelForCausalLM.from_pretrained(M, dtype=torch.float16,
                                             attn_implementation="eager",
                                             trust_remote_code=True).eval()
NL = len(model.model.layers)
print("NLAYERS", NL, "NC", NC, flush=True)

# device rope table from the model's rotary_emb (pos 600..600+NT-1), 256B rows.
NTAB = int(os.environ.get("DEC_NTAB", "16"))
with torch.no_grad():
    pos_ids = torch.arange(600, 600 + NTAB).unsqueeze(0)
    _emb = model.model.embed_tokens(torch.arange(NTAB).unsqueeze(0))
    _CT, _ST = model.model.rotary_emb(_emb, pos_ids)        # [1,NTAB,HD] fp16
os.makedirs("/mnt/e/wsl_stage", exist_ok=True)
_CT[0].contiguous().numpy().tofile("/mnt/e/wsl_stage/d2_cos_table.raw")
_ST[0].contiguous().numpy().tofile("/mnt/e/wsl_stage/d2_sin_table.raw")
print("ROPE_TABLE", NTAB, flush=True)


class DecodeLayer2(torch.nn.Module):
    """hs[1,1,HID] (residual stream, un-normalized) + read-only kcache/vcache[1,NKV,NC,HD]
       + cos/sin[1,1,HD] -> out[1,1,HID] (residual stream) + k_new/v_new[1,NKV,1,HD]."""
    def __init__(self, ly):
        super().__init__()
        self.ly = ly
        self.attn = ly.self_attn

    def forward(self, hs, kcache, vcache, cos, sin):
        r1 = self.ly.input_layernorm(hs)[:, 0, :]          # [1,HID] pre-norm for attn
        q = self.attn.q_proj(r1).view(1, NH, 1, HD)
        k = self.attn.k_proj(r1).view(1, NKV, 1, HD)
        v = self.attn.v_proj(r1).view(1, NKV, 1, HD)
        q, k = apply_rotary_pos_emb(q, k, cos, sin)        # rope on the NEW row only
        kfull = torch.cat([kcache, k], dim=2)              # [1,NKV,NC+1,HD] one concat
        vfull = torch.cat([vcache, v], dim=2)
        # GQA grouped attention: one 4D MatMul per kv-head (heads share it). Explicit
        # per-kv loop keeps batch dims exact — no broadcast/Expand materialization.
        q4 = q.view(NKV, G, 1, HD)                         # [NKV,G,1,HD] (B=1 folded)
        scores = torch.stack([
            torch.matmul(q4[i], kfull[0, i].transpose(0, 1)) for i in range(NKV)
        ], dim=0) * (HD ** -0.5)                           # [NKV,G,1,NC+1]
        p = torch.nn.functional.softmax(scores.float(), dim=-1).half()
        ctxs = torch.stack([
            torch.matmul(p[i], vfull[0, i]) for i in range(NKV)
        ], dim=0)                                          # [NKV,G,1,HD]
        ao = ctxs.reshape(1, 1, NH * HD)                   # head-major flatten == q_proj layout
        h = hs[:, 0, :] + self.attn.o_proj(ao[0])           # residual add (attn)
        m = self.ly.mlp(self.ly.post_attention_layernorm(h.unsqueeze(1)))  # pre-norm for MLP
        # emit new rows in cache-ROW byte order [1,1,HD,NKV] (cache device layout is
        # (b,s,hd,kv)); raw memcpy from these outputs then lands rows correctly.
        return (h.unsqueeze(1) + m,
                k.permute(0, 2, 3, 1).reshape(1, 1, HD, NKV),
                v.permute(0, 2, 3, 1).reshape(1, 1, HD, NKV))


def export_layer(k):
    ly = model.model.layers[k]
    w = DecodeLayer2(ly)
    torch.manual_seed(42)
    hs = (torch.randn(1, 1, HID) * 0.5).half()
    kc = (torch.randn(1, NKV, NC, HD) * 0.5).half()
    vc = (torch.randn(1, NKV, NC, HD) * 0.5).half()
    pos = 600
    # rope cos/sin from the MODEL's rotary_emb (single source of truth). The previous
    # hand-rolled 10000^(-2i/HD) table mismatched MiniCPM5's rope -> knew cos 0.56 vs HF
    # (invisible in h: one wrong row among NC+1 barely moves the residual).
    with torch.no_grad():
        pos_ids = torch.tensor([[pos]])
        emb = model.model.embed_tokens(torch.tensor([[1]]))          # [1,1,HID]
        cosr, sinr = model.model.rotary_emb(emb, pos_ids)            # [1,1,HD] fp16
    cosf, sinf = cosr.clone(), sinr.clone()
    # ledger diagnostic: how far is the naive theta=10000 full-rotary assumption?
    inv = 1.0 / (10000.0 ** (torch.arange(0, HD, 2).float() / HD))
    naive_c = torch.cos(pos * inv).half().repeat(2)
    print(f"HANDROPE_DIFF max={(naive_c - cosr[0].float().cpu()).abs().max():.4f}", flush=True)
    with torch.no_grad():
        ho, ko, vo = w(hs, kc, vc, cosf, sinf)

    # ---- REFERENCE: real HF LlamaDecoderLayer forward with pre-populated cache ----
    # NB: self_attn writes cache.update(k, v, self.layer_idx) — pre-populate at index k,
    # not 0 (l0-only testing masked this; l1 wrote an empty layer 1 and left layer 0 stale).
    with torch.no_grad():
        ref_cache = _mk_cache(kc, vc, k)
        ro, rk, rv = _hf_layer(ly, hs, cosr[0], sinr[0], pos, ref_cache, k)
    print(f"HFREF_{k} built", flush=True)

    torch.onnx.export(
        w, (hs, kc, vc, cosf, sinf), f"{OUT}/mcp5_dec2_l{k}.onnx",
        input_names=["hs", "kcache", "vcache", "cos", "sin"],
        output_names=["h", "knew", "vnew"],
        opset_version=15, do_constant_folding=True)
    mm = onnx.load(f"{OUT}/mcp5_dec2_l{k}.onnx", load_external_data=False)
    mm.graph.name = f"dec2_l{k}"
    onnx.save(mm, f"{OUT}/mcp5_dec2_l{k}.onnx")
    from collections import Counter
    c = Counter(n.op_type for n in mm.graph.node)
    print(f"L{k}_EXPORT_OK expand={c.get('Expand')} gather={c.get('Gather')} "
          f"matmul={c.get('MatMul')} nodes={len(mm.graph.node)}", flush=True)
    s = ort.InferenceSession(f"{OUT}/mcp5_dec2_l{k}.onnx", ort.SessionOptions(),
                             providers=['CPUExecutionProvider'])
    feed = dict(zip(["hs", "kcache", "vcache", "cos", "sin"],
                    [x.numpy() for x in [hs, kc, vc, cosf, sinf]]))
    oh, ok2, ov2 = s.run(None, feed)
    def cosr_(a, b):
        a = a.astype(np.float32).ravel(); b = b.astype(np.float32).ravel()
        return float(a @ b / (np.linalg.norm(a) * np.linalg.norm(b) + 1e-12))
    # vs torch of our module (trace sanity) AND vs real HF layer (semantics truth).
    # knew/vnew refs re-permuted to the graph's cache-row emit layout before ravel-compare.
    kemit = ko.permute(0, 2, 3, 1).numpy()
    vemit = vo.permute(0, 2, 3, 1).numpy()
    rk_e = rk.transpose(0, 2, 3, 1)
    rv_e = rv.transpose(0, 2, 3, 1)
    print(f"ORT_L{k}_COS vs-torch  h={cosr_(oh, ho.numpy()):.4f} k={cosr_(ok2, kemit):.4f} "
          f"v={cosr_(ov2, vemit):.4f}", flush=True)
    print(f"ORT_L{k}_COS vs-HF     h={cosr_(oh, ro):.4f} k={cosr_(ok2, rk_e):.4f} "
          f"v={cosr_(ov2, rv_e):.4f}", flush=True)


def _mk_cache(kc, vc, idx):
    """Pre-populated cache at layer index idx (must match ly.self_attn.layer_idx),
       transformers-5.x API, defensive."""
    from transformers import DynamicCache
    try:
        return DynamicCache(past_key_values=[(kc.clone(), vc.clone())] * (idx + 1))
    except TypeError:
        dc = DynamicCache()
        for j in range(idx):
            dc.update(torch.zeros(1, NKV, 1, HD, dtype=kc.dtype),
                      torch.zeros(1, NKV, 1, HD, dtype=vc.dtype), j)
        dc.update(kc.clone(), vc.clone(), idx)
        return dc


def _hf_layer(ly, hs, cos, sin, pos, cache, idx):
    """Run the real HF layer at position pos with cache pre-populated (length NC).
       Returns (out[1,1,HID], k_new[1,NKV,1,HD], v_new) where k_new/v_new are the
       just-appended rows (cache[last index])."""
    pos_ids = torch.tensor([[pos]])
    cache_pos = torch.tensor([NC])
    pe = (cos.unsqueeze(0), sin.unsqueeze(0))      # [1,1,HD]
    out = ly(hs, attention_mask=None, position_ids=pos_ids, past_key_values=cache,
             position_embeddings=pe, use_cache=True, cache_position=cache_pos)
    h = out[0]
    kc, vc = _cache_kv(cache, idx)
    assert _cache_len(kc) == NC + 1, f"cache len {_cache_len(kc)} != {NC+1} (pre-populate/append broken)"
    return h.numpy(), kc[:, :, -1:, :].numpy(), vc[:, :, -1:, :].numpy()


def _cache_kv(cache, idx):
    """Extract (k,v) of layer idx across transformers cache APIs (4.x key_cache / 5.x layers)."""
    if hasattr(cache, "key_cache"):
        return cache.key_cache[idx], cache.value_cache[idx]
    if hasattr(cache, "layers"):
        ly = cache.layers[idx]
        if hasattr(ly, "keys"):
            return ly.keys, ly.values
        if hasattr(ly, "key"):
            return ly.key, ly.value
    raise RuntimeError("unknown cache API")


def _cache_len(k):
    return k.shape[2] if hasattr(k, "shape") else k.size(2)


if MODE == "all":
    for k in range(NL):
        export_layer(k)
elif MODE.startswith("l"):
    export_layer(int(MODE[1:]))
print("DEC2_EXPORT_DONE", MODE, flush=True)
