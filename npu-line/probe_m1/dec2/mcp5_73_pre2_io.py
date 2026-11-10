#!/usr/bin/env python3
# [npu-line] pre2 (chunked prefill) l0 device IO + HF reference with window rolling.
# Protocol (must match chain_run5 exactly): initial caches ZEROS [1,2,NC,HD]; chunk c feeds
# hs_c at pos P0+c*S..P0+(c+1)S-1 using cos/sin table rows c*S..; after each chunk the
# window drops-oldest S rows and appends the S new rows (post-rope k). Reference = real HF
# layer per chunk with cache_position=arange(NC,NC+S). Saves per-chunk post-roll cache files
# (T-layout) for device comparison.
# Usage: DEC_NC=512 DEC_S=128 DEC_CHUNKS=4 python3 mcp5_73_pre2_io.py <k>
import os
import numpy as np, torch
from transformers import AutoModelForCausalLM, DynamicCache

NC = int(os.environ.get("DEC_NC", "512"))
S = int(os.environ.get("DEC_S", "128"))
CHUNKS = int(os.environ.get("DEC_CHUNKS", "4"))
P0 = int(os.environ.get("DEC_P0", "600"))
K = int(os.sys.argv[1]) if len(os.sys.argv) > 1 else 0
NKV, HD, HID = 2, 128, 2048
OUT = "/mnt/e/wsl_stage"
M = "/home/liang/models/minicpm5-2b"

model = AutoModelForCausalLM.from_pretrained(M, dtype=torch.float16,
                                             attn_implementation="eager",
                                             trust_remote_code=True).eval()
torch.manual_seed(11)
hs_ch = [(torch.randn(1, S, HID) * 0.5).half() for _ in range(CHUNKS)]
# DEVICE IO RULE (probe 76c on 740): APP-buffer bytes = ctx-DECLARED dim order row-major,
# declared = onnx dims with dim1 moved to last (NHWC-ization). Verified: (hid,s) hs ->
# vnew/h 1.0; (hd,s) cos/sin -> knew 1.0 (0.37 with naive natural); (s,hd,kv) cache was
# already proven by the decode line's 42x1.0. S=1 hid every one of these orderings.
for c in range(CHUNKS):
    hs_ch[c][0].T.contiguous().numpy().tofile(f"{OUT}/d2p_hs_{c}.raw")      # (hid,s)
kc = torch.zeros(1, NKV, NC, HD).half()
vc = torch.zeros(1, NKV, NC, HD).half()
kc.permute(0, 2, 3, 1).contiguous().numpy().tofile(f"{OUT}/d2p_kc.raw")     # (s,hd,kv)
vc.permute(0, 2, 3, 1).contiguous().numpy().tofile(f"{OUT}/d2p_vc.raw")
ct = np.fromfile(f"{OUT}/d2_cos_table.raw", dtype="<f2").reshape(-1, HD)
st = np.fromfile(f"{OUT}/d2_sin_table.raw", dtype="<f2").reshape(-1, HD)
assert ct.shape[0] >= CHUNKS * S, "export table with DEC_NTAB >= CHUNKS*S first"
# pre2 rope tables: S-row blocks transposed WITHIN block to (hd,s); block size (stride)
# unchanged at S*HD*2 bytes — chain_run5 slices chunks at t*stride.
ct_d = ct[:CHUNKS * S].reshape(CHUNKS, S, HD).transpose(0, 2, 1).copy()
st_d = st[:CHUNKS * S].reshape(CHUNKS, S, HD).transpose(0, 2, 1).copy()
ct_d.tofile(f"{OUT}/d2p_cos_table.raw")
st_d.tofile(f"{OUT}/d2p_sin_table.raw")

def mk_cache(kk, vv, idx):
    try:
        return DynamicCache(past_key_values=[(kk.clone(), vv.clone())] * (idx + 1))
    except TypeError:
        dc = DynamicCache()
        for j in range(idx):
            dc.update(torch.zeros(1, NKV, 1, HD, dtype=kk.dtype),
                      torch.zeros(1, NKV, 1, HD, dtype=vv.dtype), j)
        dc.update(kk.clone(), vv.clone(), idx)
        return dc

NEG = -1e4
ly = model.model.layers[K]
with torch.no_grad():
    for c in range(CHUNKS):
        cos = torch.from_numpy(ct[c * S:(c + 1) * S].copy()).unsqueeze(0)   # [1,S,HD]
        sin = torch.from_numpy(st[c * S:(c + 1) * S].copy()).unsqueeze(0)
        pos_ids = torch.arange(P0 + c * S, P0 + (c + 1) * S).unsqueeze(0)
        # protocol mask: window cols valid where real rows sit (roll keeps (c+1)S fresh
        # rows at the tail), padding cols -1e4; within-chunk causal triangle.
        am = torch.zeros(S, NC + S).half()
        pad = NC - c * S
        if pad > 0:
            am[:, :pad] = NEG
        am[:, NC:] = torch.triu(torch.full((S, S), NEG), diagonal=1)
        am.numpy().tofile(f"{OUT}/d2p_am_{c}.raw")     # [S,NC+S] ravel == declared [1,128,640,1]
        dc = mk_cache(kc, vc, K)
        o = ly(hs_ch[c], attention_mask=am.unsqueeze(0).unsqueeze(0), position_ids=pos_ids,
               past_key_values=dc,
               position_embeddings=(cos, sin), use_cache=True,
               cache_position=torch.arange(NC, NC + S))
        lk = dc.layers[K]
        rk, rv = (lk.keys, lk.values) if hasattr(lk, "keys") else (lk.key, lk.value)
        assert rk.shape[2] == NC + S, (c, rk.shape)
        kc = torch.cat([kc[:, :, S:, :], rk[:, :, NC:NC + S, :]], dim=2).contiguous()
        vc = torch.cat([vc[:, :, S:, :], rv[:, :, NC:NC + S, :]], dim=2).contiguous()
        kc.permute(0, 2, 3, 1).contiguous().numpy().tofile(f"{OUT}/d2p_ref_kc{c}.raw")
        vc.permute(0, 2, 3, 1).contiguous().numpy().tofile(f"{OUT}/d2p_ref_vc{c}.raw")
        print(f"PRE2_IO chunk {c} hs_out_absmax={o[0].abs().max():.3f}", flush=True)
print("IO73_DONE chunks", CHUNKS, "S", S, "NC", NC, "layer", K, "P0", P0, flush=True)
