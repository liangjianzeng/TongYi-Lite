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
S = int(os.environ.get("DEC_S", "1"))          # >1 = chunked-prefill variant (pre2): emits S cache rows/step
P0 = int(os.environ.get("DEC_P0", "600"))      # first rope position of the table
OUT = f"/home/liang/models/mcp5_dec2_{NC}" + (f"_s{S}" if S > 1 else "")
GNM = "dec2p" if S > 1 else "dec2"             # graph-name prefix (converter names after TAG anyway)
NH, NKV, HD = 16, 2, 128
HID = 2048
G = NH // NKV
os.makedirs(OUT, exist_ok=True)   # NC-variant dir may not pre-exist; external-data export needs it

def cosr_(a, b):
    a = a.astype(np.float32).ravel(); b = b.astype(np.float32).ravel()
    return float(a @ b / (np.linalg.norm(a) * np.linalg.norm(b) + 1e-12))


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
    pos_ids = torch.arange(P0, P0 + NTAB).unsqueeze(0)
    _emb = model.model.embed_tokens(torch.arange(NTAB).unsqueeze(0))
    _CT, _ST = model.model.rotary_emb(_emb, pos_ids)        # [1,NTAB,HD] fp16
os.makedirs("/mnt/e/wsl_stage", exist_ok=True)
_CT[0].contiguous().numpy().tofile("/mnt/e/wsl_stage/d2_cos_table.raw")
_ST[0].contiguous().numpy().tofile("/mnt/e/wsl_stage/d2_sin_table.raw")
print("ROPE_TABLE", NTAB, flush=True)


class DecodeLayer2(torch.nn.Module):
    """hs[1,S,HID] (residual stream, un-normalized) + read-only kcache/vcache[1,NKV,NC,HD]
       + cos/sin[1,S,HD] -> out[1,S,HID] (residual stream) + k_new/v_new[1,S,HD,NKV]
       (post-rope k, cache-ROW byte order). S=1 decode step; S=128 chunked prefill
       (cross-chunk attention over the read-only cache — the prefill KV-output piece).
       amask[1,1,S,NC+S] (prefill only; pass zeros for S=1): additive attention mask in
       fp16 (-1e4 = masked). Needed because the prefill protocol's cache is ZERO-PADDED:
       without masking, softmax denominators inflate over zero rows (chunk 0: 640 vs 128
       effective rows) and the within-chunk causal triangle is missing. Broadcast add on
       the stack'd [NKV,G,S,NC+S] scores — broadcast-add is HTP-proven (biases)."""
    def __init__(self, ly):
        super().__init__()
        self.ly = ly
        self.attn = ly.self_attn

    def forward(self, hs, kcache, vcache, cos, sin, amask):
        r1 = self.ly.input_layernorm(hs)                    # [1,S,HID] pre-norm for attn
        # HF layout: proj out is [S, HEADS*HD] row-major (s-major, head-minor) ->
        # view(1,S,HEADS,HD).transpose(1,2). A direct view(1,HEADS,S,HD) is ELEMENTWISE
        # IDENTICAL ONLY AT S=1 (what masked this for the whole decode line) and mixes
        # token rows when S>1 — the pre2 vs-HF k/v garbage (-0.009/0.007) was exactly this.
        q = self.attn.q_proj(r1).view(1, S, NH, HD).transpose(1, 2)
        k = self.attn.k_proj(r1).view(1, S, NKV, HD).transpose(1, 2)
        v = self.attn.v_proj(r1).view(1, S, NKV, HD).transpose(1, 2)
        q, k = apply_rotary_pos_emb(q, k, cos, sin)         # rope on the NEW rows only
        kfull = torch.cat([kcache, k], dim=2)              # [1,NKV,NC+S,HD] one concat
        vfull = torch.cat([vcache, v], dim=2)
        # GQA grouped attention: one 4D MatMul per kv-head (heads share it). Explicit
        # per-kv loop keeps batch dims exact — no broadcast/Expand materialization.
        q4 = q.reshape(NKV, G, S, HD)                      # [NKV,G,S,HD] (B=1 folded; reshape: q is non-contig post-transpose)
        scores = torch.stack([
            torch.matmul(q4[i], kfull[0, i].transpose(0, 1)) for i in range(NKV)
        ], dim=0) * (HD ** -0.5) + amask                   # [NKV,G,S,NC+S] broadcast add
        p = torch.nn.functional.softmax(scores.float(), dim=-1).half()
        ctxs = torch.stack([
            torch.matmul(p[i], vfull[0, i]) for i in range(NKV)
        ], dim=0)                                          # [NKV,G,S,HD]
        # HF eager (5.20.2) attention_interface returns attn_output ALREADY transposed to
        # [B,S,H,HD]; o_proj consumes token-major (S,H,HD). Flatten (kv,g)->h FIRST
        # (reshape to [1,NH,S,HD]) THEN transpose — permute(0,2,1,3) on [NKV,G,S,HD]
        # leaves the kv dim OUTSIDE the row order and scrambles rows (head-major ravel
        # is elementwise-identical only at S=1, pitfall-44 twin, residual-masked vs-HF).
        ao = ctxs.reshape(1, NH, S, HD).permute(0, 2, 1, 3).reshape(1, S, NH * HD)
        h = hs + self.attn.o_proj(ao.reshape(S, NH * HD)).view(1, S, HID)   # residual add (attn)
        m = self.ly.mlp(self.ly.post_attention_layernorm(h))                # pre-norm for MLP
        # emit new rows in cache-ROW byte order [1,S,HD,NKV] (cache device layout is
        # (b,s,hd,kv)); raw memcpy from these outputs then lands rows correctly.
        return (h + m,
                k.permute(0, 2, 3, 1).reshape(1, S, HD, NKV),
                v.permute(0, 2, 3, 1).reshape(1, S, HD, NKV))


def export_layer(k):
    ly = model.model.layers[k]
    w = DecodeLayer2(ly)
    torch.manual_seed(42)
    hs = (torch.randn(1, S, HID) * 0.5).half()
    kc = (torch.randn(1, NKV, NC, HD) * 0.5).half()
    vc = (torch.randn(1, NKV, NC, HD) * 0.5).half()
    pos = P0
    # rope cos/sin from the MODEL's rotary_emb (single source of truth). The previous
    # hand-rolled 10000^(-2i/HD) table mismatched MiniCPM5's rope -> knew cos 0.56 vs HF
    # (invisible in h: one wrong row among NC+1 barely moves the residual).
    with torch.no_grad():
        pos_ids = torch.arange(P0, P0 + S).unsqueeze(0)              # [1,S]
        emb = model.model.embed_tokens(torch.arange(S).unsqueeze(0)) # [1,S,HID]
        cosr, sinr = model.model.rotary_emb(emb, pos_ids)            # [1,S,HD] fp16
    cosf, sinf = cosr.clone(), sinr.clone()
    # Attention mask under the real chunked-prefill protocol. The zero-padded cache window
    # needs -1e4 on padding columns (else softmax denominators inflate over zero rows) and
    # the within-chunk causal triangle. Use the FULL-WINDOW pattern (all NC cols valid,
    # c = NC//S - 1) so one export run exercises BOTH cross-chunk attention and the mask.
    # S=1 decode: all-zero (attends to full cache + self).
    NEG = -1e4
    if S == 1:
        am = torch.zeros(1, 1, S, NC + S).half()
    else:
        am = torch.zeros(1, 1, S, NC + S).half()
        tri = torch.triu(torch.full((S, S), NEG), diagonal=1)
        am[0, 0, :, NC:] = tri
    am = am.contiguous()
    # ledger diagnostic: how far is the naive theta=10000 full-rotary assumption?
    inv = 1.0 / (10000.0 ** (torch.arange(0, HD, 2).float() / HD))
    naive_c = torch.cos(pos * inv).half().repeat(2)
    print(f"HANDROPE_DIFF max={(naive_c - cosr[0].float().cpu()).abs().max():.4f}", flush=True)
    with torch.no_grad():
        ho, ko, vo = w(hs, kc, vc, cosf, sinf, am)

    # ---- REFERENCE: real HF LlamaDecoderLayer forward with pre-populated cache ----
    # NB: self_attn writes cache.update(k, v, self.layer_idx) — pre-populate at index k,
    # not 0 (l0-only testing masked this; l1 wrote an empty layer 1 and left layer 0 stale).
    with torch.no_grad():
        ref_cache = _mk_cache(kc, vc, k)
        attn_cap = {}
        _h = ly.self_attn.register_forward_hook(lambda m, i, o: attn_cap.__setitem__(
            "ao", (o[0] if isinstance(o, (tuple, list)) else o).detach()))
        ro, rk, rv = _hf_layer(ly, hs, cosr[0], sinr[0], pos, ref_cache, k, am)
        _h.remove()
        # SENSITIVE branch check: attention branch alone (o_proj out, pre-residual).
        # h-vs-HF alone is residual-masked and hid the (H,S,HD) layout bug for 42 layers.
        r1 = ly.input_layernorm(hs)
        q = ly.self_attn.q_proj(r1).view(1, S, NH, HD).transpose(1, 2)
        k_ = ly.self_attn.k_proj(r1).view(1, S, NKV, HD).transpose(1, 2)
        v_ = ly.self_attn.v_proj(r1).view(1, S, NKV, HD).transpose(1, 2)
        q2, k2 = apply_rotary_pos_emb(q, k_, cosf, sinf)
        kf = torch.cat([kc, k2], 2); vf = torch.cat([vc, v_], 2)
        q4 = q2.reshape(NKV, G, S, HD)
        sc = torch.stack([torch.matmul(q4[i], kf[0, i].transpose(0, 1))
                          for i in range(NKV)]) * (HD ** -0.5) + am
        pp = torch.nn.functional.softmax(sc.float(), dim=-1).half()
        cx = torch.stack([torch.matmul(pp[i], vf[0, i]) for i in range(NKV)], dim=0)
        ao = cx.reshape(1, NH, S, HD).permute(0, 2, 1, 3).reshape(1, S, NH * HD)
        attn_branch = ly.self_attn.o_proj(ao.reshape(S, NH * HD)).view(1, S, HID)
        hf_ao = attn_cap["ao"]
        if hf_ao.dim() == 3:
            hf_ao = hf_ao.reshape(1, S, HID)
        else:
            hf_ao = hf_ao.reshape(S, HID).unsqueeze(0)
    print(f"HFREF_{k} built", flush=True)
    print(f"BRANCH_{k}_COS attn-branch vs HF: {cosr_(attn_branch.numpy(), hf_ao.numpy()):.4f}", flush=True)

    torch.onnx.export(
        w, (hs, kc, vc, cosf, sinf, am), f"{OUT}/mcp5_dec2_l{k}.onnx",
        input_names=["hs", "kcache", "vcache", "cos", "sin", "amask"],
        output_names=["h", "knew", "vnew"],
        opset_version=15, do_constant_folding=True)
    mm = onnx.load(f"{OUT}/mcp5_dec2_l{k}.onnx", load_external_data=False)
    mm.graph.name = f"{GNM}_l{k}"
    onnx.save(mm, f"{OUT}/mcp5_dec2_l{k}.onnx")
    from collections import Counter
    c = Counter(n.op_type for n in mm.graph.node)
    print(f"L{k}_EXPORT_OK expand={c.get('Expand')} gather={c.get('Gather')} "
          f"matmul={c.get('MatMul')} nodes={len(mm.graph.node)}", flush=True)
    s = ort.InferenceSession(f"{OUT}/mcp5_dec2_l{k}.onnx", ort.SessionOptions(),
                             providers=['CPUExecutionProvider'])
    feed = dict(zip(["hs", "kcache", "vcache", "cos", "sin", "amask"],
                    [x.numpy() for x in [hs, kc, vc, cosf, sinf, am]]))
    oh, ok2, ov2 = s.run(None, feed)
    # vs torch of our module (trace sanity) AND vs real HF layer (semantics truth).
    # NB: ko/vo are ALREADY in cache-row emit layout (the module permutes before return);
    # permuting again here is the layout bug that S=1 masked ([1,1,x,y] ravel == [1,x,y,1]).
    kemit = ko.numpy()
    vemit = vo.numpy()
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


def _hf_layer(ly, hs, cos, sin, pos, cache, idx, amask=None):
    """Run the real HF layer on S tokens starting at position pos, cache pre-populated
       (length NC; DynamicLayer.update cats the new rows on). Passes amask as the eager
       attention_mask verbatim (eager does attn_weights + mask, [1,1,S,NC+S] broadcasts).
       Returns (out[1,S,HID], k_new[1,NKV,S,HD], v_new) — the just-appended rows."""
    pos_ids = torch.arange(P0, P0 + S).unsqueeze(0)                # [1,S]
    cache_pos = torch.arange(NC, NC + S)                           # append slot per token
    pe = (cos.unsqueeze(0), sin.unsqueeze(0))                      # [1,S,HD]
    out = ly(hs, attention_mask=amask, position_ids=pos_ids, past_key_values=cache,
             position_embeddings=pe, use_cache=True, cache_position=cache_pos)
    h = out[0]
    kc, vc = _cache_kv(cache, idx)
    assert _cache_len(kc) == NC + S, f"cache len {_cache_len(kc)} != {NC+S} (pre-populate/append broken)"
    return h.numpy(), kc[:, :, NC:NC + S, :].numpy(), vc[:, :, NC:NC + S, :].numpy()


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
