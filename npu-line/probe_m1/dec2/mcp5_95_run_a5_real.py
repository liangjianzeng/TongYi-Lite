#!/usr/bin/env python3
# [npu-line] M2 bridge A5-real: 172-cell (no-pad) protocol judgment.
# golden = hyb_save -n 172 (real prompt tokens only)
# hybrid = hyb_load -s bridged172.state -t <first_tok of same model>
# reports token match + logits cos on Q4 (main target) and bf16 (separation control)
import sys, os, re
import numpy as np
sys.path.insert(0, "E:/MyLLM_exp/_repro/rb")
from mcp5_94_adbsock import AdbSock

S = "<redacted-tailscale>:5555"
D = "/data/local/tmp/hybllm"
Q4 = "/data/local/tmp/minicpm5-2b-q4k.gguf"
BF = "/data/local/tmp/minicpm5-2b-bf16.gguf"
VOCAB = 130560
NREAL, G = 172, 64
ad = AdbSock(S)

w = ad.shell("dumpsys power | grep -m1 mWakefulness").strip()
if "Awake" in w:
    ad.shell("input keyevent 223")
ad.push("E:/MyLLM_exp/hyb/ids.raw", D + "/ids.raw")
ad.push("E:/MyLLM_exp/hyb/bridged172.state", D + "/bridged172.state")

def cs(a, b):
    return float(a @ b / (np.linalg.norm(a) * np.linalg.norm(b) + 1e-12))

def series(text):
    return [int(l.split()[2]) for l in text.splitlines() if re.match(r"^T \d+ \d+$", l)]

def save_gold(model, tag):
    o = ad.shell(f"cd {D} && LD_LIBRARY_PATH=. ./hyb_save_up -m {model} -f ids.raw "
                 f"-o gold_{tag}.state -n {NREAL} -g {G} -p 88 -ngl 0 -L gold_{tag}.raw 2>&1 "
                 f"| grep -E 'PREFILL|^T |FAIL'")
    first = next((int(l.split("first_tok=")[1]) for l in o.splitlines() if "first_tok=" in l), -1)
    ad.pull(f"{D}/gold_{tag}.raw", f"E:/MyLLM_exp/hyb/gold_{tag}.raw")
    g = np.fromfile(f"E:/MyLLM_exp/hyb/gold_{tag}.raw", dtype="<f2").reshape(-1, VOCAB).astype(np.float32)
    gsr = series(o)
    print(f"[{tag}] first_tok={first} gold steps={g.shape} series={len(gsr)}")
    return first, g, gsr

def load_hyb(model, state, first, tag):
    o = ad.shell(f"cd {D} && LD_LIBRARY_PATH=. ./hyb_load_up -m {model} -s {state} -t {first} "
                 f"-n {NREAL} -g {G} -ngl 0 -L hyb_{tag}.raw 2>&1 | grep -E 'STATE_LOADED|FAIL|tps|^T '")
    ok = "STATE_LOADED" in o
    if not ok:
        print(f"[{tag}] LOAD FAIL: {o[:150]}"); return None, None, []
    ad.pull(f"{D}/hyb_{tag}.raw", f"E:/MyLLM_exp/hyb/hyb_{tag}.raw")
    h = np.fromfile(f"E:/MyLLM_exp/hyb/hyb_{tag}.raw", dtype="<f2").reshape(-1, VOCAB).astype(np.float32)
    return h, ok, series(o)

for tag, model in (("q4", Q4), ("bf16", BF)):
    first, gold, gsr = save_gold(model, tag)
    # (golden state already on device from save_gold)
    h, _, _ = load_hyb(model, f"gold_{tag}.state", first, tag + "_ctl")
    if h is not None:
        n = min(len(h), len(gold))
        cos = [cs(h[i], gold[i]) for i in range(n)]
        am = sum(int(h[i].argmax()) == int(gold[i].argmax()) for i in range(n))
        print(f"[{tag} ctl-golden-state] argmax {am}/{n} cos min={min(cos):.4f}")
    h, _, srs = load_hyb(model, "bridged172.state", first, tag + "_hyb")
    if h is not None:
        n = min(len(h), len(gold))
        cos = [cs(h[i], gold[i]) for i in range(n)]
        am = sum(int(h[i].argmax()) == int(gold[i].argmax()) for i in range(n))
        gs = [int(gold[i].argmax()) for i in range(n)]
        m32 = sum(a == b for a, b in zip(gs[:32], srs[:32])) if len(srs) >= 32 else -1
        m64 = sum(a == b for a, b in zip(gs[:64], srs[:64])) if len(srs) >= 64 else -1
        print(f"[{tag} HYBRID] argmax {am}/{n} cos min={min(cos):.4f} mean={sum(cos)/n:.4f} "
              f"bad(<0.99)={sum(1 for c in cos if c<0.99)}")
        print(f"[{tag} HYBRID] token series match32 = {m32}/32 (gate>=31)  match64 = {m64}/64 (gate>=55)")
        fd = next((i for i, (a, b) in enumerate(zip(gs, srs)) if a != b), -1)
        print(f"[{tag} HYBRID] first_diff={fd}")

w = ad.shell("dumpsys power | grep -m1 mWakefulness").strip()
print("WAKE_END:", w)
if "Awake" in w:
    ad.shell("input keyevent 223")
print("A5REAL_DONE")
