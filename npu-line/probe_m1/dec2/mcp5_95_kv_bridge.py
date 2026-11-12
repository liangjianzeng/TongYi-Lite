#!/usr/bin/env python3
# [npu-line] M2 bridge A4: synthesize a llama.cpp sequence-state file from NPU prefill
# KV caches, per the official writer layout (upstream 5c200e0 llama-kv-cache.cpp,
# 100% parsed in A2 with zero leftover — golden-backed).
# NPU cache file: [NC=512, HD=128, NKV=2] fp16 S-major == HF post-rope space
#   (K gold-checked cos=1.0 vs HF past_kv; row<->token order proven by A3c diff probe).
# llama state row (proven for K, cos 0.9996): per head half2inter — out[0::2]=x[:64],
#   out[1::2]=x[64:]. V mode selectable (A5 judge is the oracle): copy | h2i.
import sys, struct, os
import numpy as np

KV = "E:/MyLLM_exp/hyb/npu_kv"
IDS = "E:/MyLLM_exp/hyb/ids.raw"
VMODE = sys.argv[1] if len(sys.argv) > 1 else "copy"     # copy | h2i
OUTF = sys.argv[2] if len(sys.argv) > 2 else "E:/MyLLM_exp/hyb/bridged.state"
# NREAL: keep only the first NREAL token cells (prompt tail is eos-pad under
# the 77 protocol; decode causal mask cannot exclude pads, so we drop them)
NREAL = int(sys.argv[3]) if len(sys.argv) > 3 else 172
NC, HD, NKV, NL, P0 = 512, 128, 2, 42, 88
MAGIC, VER, F16 = 0x67677371, 3, 1
ROW = 512

ids = np.fromfile(IDS, dtype="<i4")[:NREAL]
NC_ = NREAL

def h2i(x):
    o = np.empty_like(x)
    o[0::2] = x[:HD // 2]; o[1::2] = x[HD // 2:]
    return o

def rows(path, transpose_rope):
    a = np.fromfile(path, dtype="<f2").reshape(NC, HD, NKV)
    out = np.empty((NC_, HD * NKV), np.float32)
    for t in range(NC_):
        for j in range(NKV):
            v = a[t, :, j].astype(np.float32)
            out[t, j * HD:(j + 1) * HD] = h2i(v) if transpose_rope else v
    return out.astype(np.float16)

kc = [rows(f"{KV}/d2q_kc_{i}.raw", True) for i in range(NL)]
vm = True if VMODE == "h2i" else False
vc = [rows(f"{KV}/d2q_vc_{i}.raw", vm) for i in range(NL)]

with open(OUTF, "wb") as f:
    w = lambda *x: f.write(struct.pack(*x))
    w("<II", MAGIC, VER)
    w("<I", NC_); f.write(ids.astype("<i4").tobytes())
    w("<I", 1); w("<I", NC_)
    for i in range(NC_):
        w("<iII", P0 + i, 1, 0)
    w("<II", 0, NL)
    for il in range(NL):
        w("<iQ", F16, ROW); f.write(kc[il][:NC_].tobytes())
    for il in range(NL):
        w("<iQ", F16, ROW); f.write(vc[il][:NC_].tobytes())
print("BRIDGE_OK", VMODE, OUTF, os.path.getsize(OUTF))
