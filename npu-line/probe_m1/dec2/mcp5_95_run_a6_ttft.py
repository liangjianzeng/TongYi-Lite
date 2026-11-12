#!/usr/bin/env python3
# [npu-line] M2 bridge A6: TTFT segmentation for the hybrid path (NPU prefill ->
# KV bridge -> GPU decode) vs pure-GPU baseline (19.0 t/s pp measured previously).
import sys, os, time
import numpy as np
sys.path.insert(0, "E:/MyLLM_exp/_repro/rb")
from mcp5_94_adbsock import AdbSock

S = "<redacted-tailscale>:5555"
D = "/data/local/tmp/hybllm"
Q4 = "/data/local/tmp/minicpm5-2b-q4k.gguf"
ad = AdbSock(S)
ad.push("E:/MyLLM_exp/hyb/bin/hyb_load_up", D + "/hyb_load_up")
ad.shell(f"chmod 755 {D}/hyb_load_up")

w = ad.shell("dumpsys power | grep -m1 mWakefulness").strip()
if "Awake" in w:
    ad.shell("input keyevent 223")

# 1) bridge synthesis time (host)
t0 = time.time()
os.system("E:\\MyLLM_exp 2>/dev/null; true")
PY = sys.executable
import subprocess
subprocess.run([PY, "-I", "E:/MyLLM_exp/hyb/kv_bridge.py", "copy",
                "E:/MyLLM_exp/hyb/bridged172.state", "172"],
               capture_output=True)
t_bridge = time.time() - t0

# 2) push state
t0 = time.time()
ad.push("E:/MyLLM_exp/hyb/bridged172.state", D + "/bridged172.state")
t_push = time.time() - t0

# 3) load + first token on device
o = ad.shell(f"cd {D} && LD_LIBRARY_PATH=. ./hyb_load_up -m {Q4} -s bridged172.state "
             f"-t 32291 -n 172 -g 8 -ngl 0 2>&1 | grep -E 'STATE_LOADED|FIRST_TOK_MS|tps'")
print(o)
load_ms = next((float(l.split("load_ms=")[1]) for l in o.splitlines() if "load_ms" in l), -1)
first_ms = next((float(l.split("FIRST_TOK_MS ")[1].split()[0]) for l in o.splitlines() if "FIRST_TOK_MS" in l), -1)

NPU_EXEC = 3.72   # 4 chunks x 929.5 ms (measured CR5, static 512-token shape)
NPU_PRELOAD_ONCE = 20.0  # serial 3-seg ctx preload, paid once at daemon start
GPU_PP_TPS = 19.0
for ntok in (172, 256, 512):
    gpu_ttft = ntok / GPU_PP_TPS
    hyb_ttft = NPU_EXEC + t_bridge + t_push + load_ms / 1000 + first_ms / 1000
    print(f"prompt={ntok:3d}: pure-GPU TTFT={gpu_ttft:6.2f}s   "
          f"hybrid TTFT={hyb_ttft:5.2f}s (+{NPU_PRELOAD_ONCE:.0f}s daemon cold-start once)  "
          f"speedup={gpu_ttft / hyb_ttft:.1f}x")
w = ad.shell("dumpsys power | grep -m1 mWakefulness").strip()
print("WAKE_END:", w)
if "Awake" in w:
    ad.shell("input keyevent 223")
print("A6_DONE")
