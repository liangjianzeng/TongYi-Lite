#!/usr/bin/env python3
# [npu-line] G3 W8 head A/B: rerun the G4 device-autoregressive 8-step chain with the C
# process on manifest_nc640_C_w8 (head ctx = w8dec_l999head_ctx.bin, W8 weights). Gate:
# device-chosen tokens == HF greedy EXPECTED (same as G4), logits cos vs the fp16-run
# baseline (E:\wsl_stage\dev\ar_lit_{s}.raw), and per-process exec ms (CR5_STEP lines)
# vs the fp16 record (A 575 / B ~? / C 807 ms/step). Screen check (Dozing) at the end.
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
# W8 head ctx (258M, int8) + manifest + variant launcher (mcp5_93_gen_w8_manifest_C.py)
subprocess.run([ADB, "-s", DEV, "push", "E:\\MyLLM_exp\\serve_dec\\w8dec_l999head_ctx.bin",
                f"{R}/w8dec_l999head_ctx.bin"], capture_output=True, check=True)
print("W8_HEAD_CTX_PUSHED", flush=True)
push("E:\\MyLLM_exp\\manifest_nc640_C_w8", f"{R}/manifest_nc640_C_w8")
push("E:\\MyLLM_exp\\_repro\\rb\\launch_nc640_step_w8.sh", f"{R}/launch_nc640_step_w8.sh")
sh(["chmod 755 " + R + "/launch_nc640_step_w8.sh"])
print("PRISTINE_AND_LAUNCHER_PUSHED", flush=True)

toks = []
cos_line = []
for s in range(STEPS):
    out = sh([f"cd {R} && ./launch_nc640_step_w8.sh {s}"])
    assert "LAUNCHED_STEP_W8" in out, out
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
    pull(f"{R}/d2e_logits_t{s}.raw", f"{STW}\\dev\\w8_lit_{s}.raw")
    lg = np.fromfile(f"{ST}/dev/w8_lit_{s}.raw", "<f2").astype(np.float32)
    base = np.fromfile(f"{ST}/dev/ar_lit_{s}.raw", "<f2").astype(np.float32)
    cos = float(lg @ base / (np.linalg.norm(lg) * np.linalg.norm(base) + 1e-12))
    t = int(np.argmax(lg))
    toks.append(t)
    ok = "OK" if t == EXPECTED[s] else f"MISMATCH exp {EXPECTED[s]}"
    print(f"step {s}: device token {t}  {ok}  cos_vs_fp16={cos:.6f}", flush=True)
    if s < STEPS - 1:
        emb[t].astype("<f2").tofile(f"{ST}/d2e_hs_t{s + 1}.raw")
        push(f"{STW}\\d2e_hs_t{s + 1}.raw", f"{R}/")

execs = sh([f"cd {R} && for i in 0 1 2; do echo P$i; grep -ah CR5_STEP cr5_s_$i.log; done"])
print("EXEC_LINES\n" + execs, flush=True)
w = sh(["dumpsys power | grep -m1 mWakefulness"])
print("WAKE:", w.strip())
if "Awake" in w:
    sh(["input keyevent 223"])
    print("SCREEN turned off")
print("W8_TOKENS", toks, "MATCH" if toks == EXPECTED else "MISMATCH", flush=True)
