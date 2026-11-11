#!/usr/bin/env python3
# [npu-line] G5: W8-prefill single-layer quality vs the fp16 device outputs of the SAME
# feeds (g2ab pulls g2{h,k,v}_{tag}_{t}.raw to E:/wsl_stage/g2dev). Expect cos in the
# quantization lower-bound band (k ~0.9999x, v ~0.9996x, h lower — depth accumulation),
# NOT bit-exact. Decisive defect signature would be ~0 / NaN / huge absmax.
import numpy as np

ST = "/mnt/e/wsl_stage/g2dev"
for t in range(4):
    row = [f"chunk {t}"]
    for o in ("h", "k", "v"):
        a = np.fromfile(f"{ST}/g2{o}_dec2p_l0_{t}.raw", "<f2").astype(np.float32)
        b = np.fromfile(f"{ST}/g2{o}_w8natp_l0_{t}.raw", "<f2").astype(np.float32)
        cos = float(a @ b / (np.linalg.norm(a) * np.linalg.norm(b) + 1e-12))
        nan = int(np.isnan(b).sum())
        row.append(f"{o}: cos={cos:.6f} absmaxdiff={np.abs(a-b).max():.4f} nan={nan}")
    print(" | ".join(row), flush=True)
print("W8P_JUDGE_DONE")
