#!/usr/bin/env python3
# [npu-line] Judge device final logits against per-step HF ref: python3 mcp5_71_judgeN.py <N>
import sys
import numpy as np
N = sys.argv[1]
dev = np.fromfile('/mnt/e/wsl_stage/d2e_dev_logits.raw', dtype='<f2').astype(np.float32).ravel()
ref = np.load(f'/mnt/e/wsl_stage/d2e_ref_logits_t{N}.npy').astype(np.float32).ravel()
cos = dev @ ref / (np.linalg.norm(dev) * np.linalg.norm(ref) + 1e-12)
tk = 8
mt = len(set(np.argsort(-dev)[:tk]) & set(np.argsort(-ref)[:tk]))
print(f"JUDGE_N={N} cos={cos:.4f} argmax dev/ref={dev.argmax()}/{ref.argmax()} top{tk}={mt}/{tk}")
