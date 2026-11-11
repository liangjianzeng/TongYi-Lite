#!/usr/bin/env python3
# [npu-line] Pad all 42 prefill-terminal caches (and the 72-era HF caches) from 512 rows
# to 640 rows (tail zero pad) for the NC=640 decode variant. Output: d2e640_kc{i}.raw /
# d2e640_vc{i}.raw in declared (s,hd,kv) byte order.
import numpy as np

ST = "/mnt/e/wsl_stage"
HD, NKV = 128, 2


def pad_file(src, dst):
    a = np.fromfile(src, "<f2")
    rows = a.size // (HD * NKV)
    assert rows == 512, (src, rows)
    out = np.concatenate([a, np.zeros(128 * HD * NKV, "<f2")])
    out.tofile(dst)


for i in range(42):
    pad_file(f"{ST}/dev/d2q_kc_{i}.raw", f"{ST}/d2e640_kc{i}.raw")
    pad_file(f"{ST}/dev/d2q_vc_{i}.raw", f"{ST}/d2e640_vc{i}.raw")
print("PAD42_DONE")
