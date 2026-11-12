#!/usr/bin/env python3
# [npu-line] M2 bridge A3b: sequential (one-at-a-time) prefill chain orchestration.
# 3-process residency hit the pitfall-60 memory wall (instant death, empty logs);
# mcp5-proven fix = serial launch, one resident process at a time (~1.3G preload).
import sys, os, time
sys.path.insert(0, "E:/MyLLM_exp/_repro/rb")
from mcp5_94_adbsock import AdbSock

S = "<redacted-tailscale>:5555"
R = "/data/local/tmp/npu_m1"
OUT = "E:/MyLLM_exp/hyb/npu_kv"
os.makedirs(OUT, exist_ok=True)
ad = AdbSock(S)

w = ad.shell("dumpsys power | grep -m1 mWakefulness").strip()
if "Awake" in w:
    ad.shell("input keyevent 223")

# push fresh prep77b IO (prompt changed) + ids for the tool chain
for f in (["d2q_emb_%d" % i for i in range(4)] + ["d2q_am_%d" % i for i in range(4)] +
          ["d2q_cos_table", "d2q_sin_table", "d2q_kc0", "d2q_vc0"]):
    ad.push(f"E:/wsl_stage/{f}.raw", f"{R}/{f}.raw")
ad.push("E:/MyLLM_exp/hyb/ids.raw", R + "/ids.raw")
print("IO pushed")
ad.shell(f"pkill -f 'chain_[r]un5' 2>/dev/null; rm -f {R}/d2q_h_l*_* {R}/d2q_knew_* {R}/d2q_vnew_* {R}/d2q_kc_*.raw {R}/d2q_vc_*.raw; rm -rf {R}/gate")
ad.shell(f"cd {R} && for i in $(seq 0 41); do cp d2q_kc0.raw d2q_kc_$i.raw; cp d2q_vc0.raw d2q_vc_$i.raw; done")

for g, k in (("A", 0), ("B", 1), ("C", 2)):
    cmd = (f"cd {R} && export LD_LIBRARY_PATH={R}/lib ADSP_LIBRARY_PATH={R}/lib && "
           f"CHAIN_KEEP=1 CR5_ROLL_SAVE=1 nohup ./chain_run5 manifest_pre2_{g} 4 > p{k}.log 2>&1 & echo SPAWNED_{g}")
    print(ad.shell(cmd).strip())
    done = False
    for t in range(240):  # up to 20 min per segment
        if "1" in ad.shell(f"grep -ac CR5_DONE {R}/p{k}.log 2>/dev/null || echo 0").strip().splitlines()[-1:]:
            done = True
            break
        try:
            alive = int(ad.shell("pgrep -f 'chain_[r]un5' | wc -l").strip().splitlines()[-1])
        except ValueError:
            alive = 1
        if alive == 0 and t > 8:
            print(f"seg {g}: process gone at t={t*5}s"); break
        time.sleep(5)
    tail = ad.shell(f"grep -aE 'CR5_DONE|CR5_FAIL' {R}/p{k}.log | tail -3")
    print(f"seg {g}: done={done}\n{tail}")
    if not done:
        print("A3_ABORT"); break

if done:
    for i in range(42):
        for t in ("kc", "vc"):
            ad.pull(f"{R}/d2q_{t}_{i}.raw", f"{OUT}/d2q_{t}_{i}.raw")
    ad.pull(f"{R}/d2q_h_l41_3.raw", f"{OUT}/d2q_h_l41_3.raw")
    print("pulled 84 kv + h_l41, kc0 size", os.path.getsize(f"{OUT}/d2q_kc_0.raw"))
ad.shell(f"pkill -f 'chain_[r]un5' 2>/dev/null || true")
w = ad.shell("dumpsys power | grep -m1 mWakefulness").strip()
print("WAKE_END:", w)
if "Awake" in w:
    ad.shell("input keyevent 223")
print("A3_DONE")
