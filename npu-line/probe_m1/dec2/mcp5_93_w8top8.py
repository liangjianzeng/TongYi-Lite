#!/usr/bin/env python3
# [npu-line] G3: rank/top8 closure check for the w8nat teacher chain. Reads the pulled
# logits (E:\wsl_stage\dev\natT_lit_{s}.raw vs fp16 baseline ar_lit_{s}.raw), reports
# rank of EXPECTED token, margin to top1, and whether argmax == fp16-chain top1 (cache
# same-generation check).
import numpy as np

ST = "/mnt/e/wsl_stage"
EXPECTED = [62598, 26619, 46436, 15343, 396, 5020, 18219, 1753]
for s in range(8):
    lg = np.fromfile(f"{ST}/dev/natT_lit_{s}.raw", "<f2").astype(np.float32)
    base = np.fromfile(f"{ST}/dev/ar_lit_{s}.raw", "<f2").astype(np.float32)
    top = int(np.argmax(lg))
    order = np.argsort(-lg)
    rank = int(np.where(order == EXPECTED[s])[0][0])
    in8 = EXPECTED[s] in order[:8]
    fp16top = int(np.argmax(base))
    margin = lg[order[0]] - (lg[EXPECTED[s]] if rank else 0.0)
    cos = float(lg @ base / (np.linalg.norm(lg) * np.linalg.norm(base) + 1e-12))
    print(f"step {s}: w8top {top} exp {EXPECTED[s]} rank={rank} top8={in8} "
          f"margin={margin:.3f} fp16top={fp16top} top1==fp16:{top == fp16top} cos={cos:.6f}",
          flush=True)
print("W8TOP8_DONE")
