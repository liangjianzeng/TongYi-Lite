#!/usr/bin/env python3
# [npu-line] G3 exec A/B: run the 8-step device-autoregressive chain with HEAD=w8 or
# fp16 and capture per-step per-process CR5_STEP exec ms BEFORE the next launch wipes
# the logs (previous runs read EXEC_LINES after the loop -> saw only the last step).
# Judge: device-chosen tokens == EXPECTED; logits cos vs the saved fp16 baseline.
import subprocess
import sys
import time
import numpy as np
import torch
from safetensors import safe_open

HEAD = sys.argv[1] if len(sys.argv) > 1 else "w8"   # w8 | w8full | fp16 | mix:mN (step0 only)
MIXGRP = HEAD.split(":")[1] if HEAD.startswith("mix:") else None
ADB = "/mnt/c/Users/jianz/AppData/Local/Android/Sdk/platform-tools/adb.exe"
DEV = "<redacted-serial>"
R = "/data/local/tmp/npu_m1"
CK = "/home/liang/models/minicpm5-2b/model-00000-of-00001.safetensors"
ST = "/mnt/e/wsl_stage"
STW = "E:\\wsl_stage"
EXPECTED = [62598, 26619, 46436, 15343, 396, 5020, 18219, 1753]
STEPS = 1 if MIXGRP else 8   # bisection needs only the step-0 token
LAUNCH = {"w8": "launch_nc640_step_w8.sh", "w8full": "launch_nc640_step_w8full.sh",
          "fp16": "launch_nc640_step.sh"}.get(HEAD, "launch_nc640_step_mix.sh")
TAGP = {"w8": "w8", "w8full": "w8f", "fp16": "fp"}.get(HEAD, "mix")

with safe_open(CK, framework="pt") as f:
    emb = f.get_tensor("model.embed_tokens.weight").to(torch.float16).numpy()
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
if MIXGRP:
    # mixed bisection manifests + launcher (layer ctxs assumed on device from a prior
    # w8full/fp16 run; d2e640_* caches re-pushed above anyway)
    for mg in ("m1", "m2", "m3"):
        for g in ("A", "B", "C"):
            push(f"E:\\MyLLM_exp\\manifest_{mg}_{g}", f"{R}/manifest_{mg}_{g}")
    push("E:\\MyLLM_exp\\_repro\\rb\\launch_nc640_step_mix.sh", f"{R}/launch_nc640_step_mix.sh")
    sh(["chmod 755 " + R + "/launch_nc640_step_mix.sh"])
    print("PRISTINE_PUSHED", MIXGRP, flush=True)
if HEAD in ("w8", "w8full"):
    subprocess.run([ADB, "-s", DEV, "push", "E:\\MyLLM_exp\\serve_dec\\w8dec_l999head_ctx.bin",
                    f"{R}/w8dec_l999head_ctx.bin"], capture_output=True, check=True)
if HEAD == "w8":
    push("E:\\MyLLM_exp\\manifest_nc640_C_w8", f"{R}/manifest_nc640_C_w8")
    push("E:\\MyLLM_exp\\_repro\\rb\\launch_nc640_step_w8.sh", f"{R}/launch_nc640_step_w8.sh")
    sh(["chmod 755 " + R + "/launch_nc640_step_w8.sh"])
elif HEAD == "w8full":
    for i in range(42):  # 42 W8 layer ctxs (~46M each); adb daemon can die mid-push
        subprocess.run([ADB, "-s", DEV, "push", f"E:\\MyLLM_exp\\serve_dec\\w8nc640_l{i}_ctx.bin",
                        f"{R}/w8nc640_l{i}_ctx.bin"], capture_output=True, check=True)
    print("W8_LAYERS_PUSHED 42", flush=True)
    for nm in ("A", "B", "C"):
        push(f"E:\\MyLLM_exp\\manifest_w8_{nm}", f"{R}/manifest_w8_{nm}")
    push("E:\\MyLLM_exp\\_repro\\rb\\launch_nc640_step_w8full.sh",
         f"{R}/launch_nc640_step_w8full.sh")
    sh(["chmod 755 " + R + "/launch_nc640_step_w8full.sh"])
print("PRISTINE_PUSHED", HEAD, flush=True)

toks, ex = [], []
for s in range(STEPS):
    envp = f"MGRP={MIXGRP} " if MIXGRP else ""
    out = sh([f"cd {R} && {envp}./{LAUNCH} {s}"])
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
    # capture exec lines NOW (next launch truncates cr5_s_*.log). Device shell is toybox
    # sh — NO bash process substitution (first attempt's paste <(...) returned empty).
    line = " | ".join(sh([f"grep -ah CR5_STEP {R}/cr5_s_{i}.log"]).strip() for i in range(3))
    ex.append(line.strip())
    pull(f"{R}/d2e_logits_t{s}.raw", f"{STW}\\dev\\{TAGP}_lit_{s}.raw")
    lg = np.fromfile(f"{ST}/dev/{TAGP}_lit_{s}.raw", "<f2").astype(np.float32)
    base = np.fromfile(f"{ST}/dev/ar_lit_{s}.raw", "<f2").astype(np.float32)
    cos = float(lg @ base / (np.linalg.norm(lg) * np.linalg.norm(base) + 1e-12))
    t = int(np.argmax(lg))
    toks.append(t)
    ok = "OK" if t == EXPECTED[s] else f"MISMATCH exp {EXPECTED[s]}"
    print(f"step {s}: token {t} {ok} cos={cos:.6f}\n   {line.strip()}", flush=True)
    if s < STEPS - 1:
        emb[t].astype("<f2").tofile(f"{ST}/d2e_hs_t{s + 1}.raw")
        push(f"{STW}\\d2e_hs_t{s + 1}.raw", f"{R}/")

w = sh(["dumpsys power | grep -m1 mWakefulness"])
print("WAKE:", w.strip())
if "Awake" in w:
    sh(["input keyevent 223"])
    print("SCREEN turned off")
print(f"{HEAD.upper()}_TOKENS", toks, "MATCH" if toks == EXPECTED else "MISMATCH", flush=True)
