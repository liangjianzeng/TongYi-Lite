#!/usr/bin/env python3
# [npu-line] G1 judge: 8 greedy decode steps, device per-step logits vs HF rolled-window
# greedy reference (80 prep). cos + argmatch + top8 per step, printed as a table.
import numpy as np

ST = "/mnt/e/wsl_stage"
STEPS = 8


def cs(a, b):
    a = a.astype(np.float32).ravel()
    b = b.astype(np.float32).ravel()
    return float(a @ b / (np.linalg.norm(a) * np.linalg.norm(b) + 1e-12))


allok = True
for t in range(STEPS):
    try:
        d = np.fromfile(f"{ST}/dev/d2e_logits_t{t}.raw", dtype="<f2")
        r = np.load(f"{ST}/d2e_ref_logits_t{t}.npy")
    except (FileNotFoundError, OSError):
        print(f"step {t}: MISSING FILES")
        allok = False
        continue
    c = cs(d, r)
    td = np.argsort(-d)[:8]
    tr = np.argsort(-r)[:8]
    match = int(np.argmax(d)) == int(np.argmax(r))
    print(f"step {t}: cos={c:.4f} argmax dev={np.argmax(d)} ref={np.argmax(r)} MATCH={match} "
          f"top8 {len(set(td) & set(tr))}/8  ref-token {int(np.argmax(r))}")
    allok &= c > 0.999 and match
print("REAL_CHAIN_JUDGE", "PASS" if allok else "FAIL", flush=True)
