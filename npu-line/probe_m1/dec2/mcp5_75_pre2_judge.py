#!/usr/bin/env python3
# [npu-line] pre2 l0 device judge: per-chunk new cache rows (device knew/vnew dumps) vs the
# HF per-chunk reference (d2p_ref_kc{c}.raw post-roll caches; last S rows == chunk c new rows).
# Induction note: initial caches are BOTH zeros and every chunk's tail rows matching =>
# the full window matches; we also compare the ROLL_SAVE final cache vs ref chunk CHUNKS-1 whole.
# Usage: DEC_S=128 DEC_CHUNKS=4 python3 mcp5_75_pre2_judge.py   (files under /mnt/e/wsl_stage/dev)
import os
import numpy as np

S = int(os.environ.get("DEC_S", "128"))
CHUNKS = int(os.environ.get("DEC_CHUNKS", "4"))
NC = int(os.environ.get("DEC_NC", "512"))
NKV, HD = 2, 128
DEV = "/mnt/e/wsl_stage/dev"
REF = "/mnt/e/wsl_stage"


def cs(a, b):
    a = a.astype(np.float32).ravel()
    b = b.astype(np.float32).ravel()
    return float(a @ b / (np.linalg.norm(a) * np.linalg.norm(b) + 1e-12))


ok = True
for c in range(CHUNKS):
    kn = np.fromfile(f"{DEV}/d2p_knew_{c}.raw", dtype="<f2").reshape(-1)
    vn = np.fromfile(f"{DEV}/d2p_vnew_{c}.raw", dtype="<f2").reshape(-1)
    rk = np.fromfile(f"{REF}/d2p_ref_kc{c}.raw", dtype="<f2").reshape(NC, HD, NKV)
    rv = np.fromfile(f"{REF}/d2p_ref_vc{c}.raw", dtype="<f2").reshape(NC, HD, NKV)
    assert kn.size == S * HD * NKV, (c, kn.size)
    ck, cv = cs(kn, rk[NC - S:].ravel()), cs(vn, rv[NC - S:].ravel())
    md = np.abs(kn.reshape(-1) - rk[NC - S:].ravel()).max()
    print(f"chunk {c}: knew cos={ck:.4f}  vnew cos={cv:.4f}  knew absmax-diff={md:.5f}")
    ok &= ck > 0.999 and cv > 0.999
# final rolled cache whole-window check vs last ref
fk = np.fromfile(f"{DEV}/d2p_kc.raw", dtype="<f2").reshape(NC, HD, NKV)
fv = np.fromfile(f"{DEV}/d2p_vc.raw", dtype="<f2").reshape(NC, HD, NKV)
rk = np.fromfile(f"{REF}/d2p_ref_kc{CHUNKS - 1}.raw", dtype="<f2").reshape(NC, HD, NKV)
rv = np.fromfile(f"{REF}/d2p_ref_vc{CHUNKS - 1}.raw", dtype="<f2").reshape(NC, HD, NKV)
ck, cv = cs(fk.ravel(), rk.ravel()), cs(fv.ravel(), rv.ravel())
print(f"final cache (ROLL_SAVE): kc cos={ck:.4f}  vc cos={cv:.4f}")
ok &= ck > 0.999 and cv > 0.999
print("PRE2_JUDGE", "PASS" if ok else "FAIL", flush=True)
