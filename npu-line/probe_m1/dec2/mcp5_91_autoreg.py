#!/usr/bin/env python3
# [npu-line] G4 autoregressive closed loop on device: per-step gated N=1 launch, pull
# logits -> argmax -> host embed (checkpoint) -> push next feed; caches persist via
# CR5_ROLL_SAVE; amask/cos indexed by CR5_T0. Device-chosen token sequence must equal
# the HF greedy chain (teacher-forced chain already matched argmax 8/8). No HF in the loop.
import subprocess
import time
import numpy as np
import torch
from safetensors import safe_open

ADB = "/mnt/c/Users/jianz/AppData/Local/Android/Sdk/platform-tools/adb.exe"
DEV = "<redacted-serial>"
R = "/data/local/tmp/npu_m1"
CK = "/home/liang/models/minicpm5-2b/model-00000-of-00001.safetensors"
ST = "/mnt/e/wsl_stage"
STW = "E:\\wsl_stage"          # adb.exe is a Windows binary — Windows paths for push/pull
EXPECTED = [62598, 26619, 46436, 15343, 396, 5020, 18219, 1753]
STEPS = 8

with safe_open(CK, framework="pt") as f:
    emb = f.get_tensor("model.embed_tokens.weight").to(torch.float16).numpy()   # [V, 2048]
print("embed", emb.shape, flush=True)


def sh(cmd):
    return subprocess.run([ADB, "-s", DEV, "shell"] + cmd, capture_output=True, text=True).stdout


def push(src, dst):
    subprocess.run([ADB, "-s", DEV, "push", src, dst], capture_output=True)


def pull(src, dst):
    subprocess.run([ADB, "-s", DEV, "pull", src, dst], capture_output=True)


sh(["pkill -f chain_run5; sleep 1"])
for i in range(42):
    for pre in ("kc", "vc"):
        subprocess.run([ADB, "-s", DEV, "push", f"{STW}\\d2e640b_{pre}{i}.raw",
                        f"{R}/d2e640_{pre}{i}.raw"], capture_output=True, check=True)
print("CACHES_PRISTINE", flush=True)

toks = []
for s in range(STEPS):
    out = sh([f"cd {R} && ./launch_nc640_step.sh {s}"])
    assert "LAUNCHED_STEP" in out, out
    done = False
    for pi in range(90):
        time.sleep(2)
        c = sh([f"grep -al CR5_DONE {R}/cr5_s_0.log {R}/cr5_s_1.log {R}/cr5_s_2.log 2>/dev/null | wc -l"])
        if c.strip().splitlines()[-1].strip() == "3":
            done = True
            break
        if pi == 20:
            print("still waiting step", s, "c=", repr(c), flush=True)
    assert done, f"step {s} not done (last c={c!r})"
    pull(f"{R}/d2e_logits_t{s}.raw", f"{STW}\\dev\\ar_lit_{s}.raw")
    lg = np.fromfile(f"{ST}/dev/ar_lit_{s}.raw", "<f2").astype(np.float32)
    t = int(np.argmax(lg))
    toks.append(t)
    ok = "OK" if t == EXPECTED[s] else f"MISMATCH exp {EXPECTED[s]}"
    print(f"step {s}: device token {t}  {ok}", flush=True)
    if s < STEPS - 1:
        emb[t].astype("<f2").tofile(f"{ST}/d2e_hs_t{s + 1}.raw")
        push(f"{STW}\\d2e_hs_t{s + 1}.raw", f"{R}/")

w = sh(["dumpsys power | grep -m1 mWakefulness"])
print("WAKE:", w.strip())
if "Awake" in w:
    sh(["input keyevent 223"])
    print("SCREEN turned off")
print("AUTOREG_TOKENS", toks, "MATCH" if toks == EXPECTED else "MISMATCH", flush=True)
