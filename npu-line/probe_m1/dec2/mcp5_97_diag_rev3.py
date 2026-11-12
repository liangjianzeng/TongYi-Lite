#!/usr/bin/env python3
# [npu-line] MC rev3 forensics: per-step cos/match/LCP for N in {0,1,2}.
# r00/r01 collapsed in BOTH hyb and FLOOR (cos 0.15/-0.31 floor) => suspect
# protocol artifact (desync makes aligned comparison garbage), not bridge defect.
# Reuses bridged_cN.state + ids_cN.raw already on device; reruns 3 arms, pulls
# logits, dumps per-step arrays so protocol bars can be tuned OFFLINE.
import sys, os, re, json
import numpy as np
sys.path.insert(0, "E:/MyLLM_exp/_repro/rb")
from mcp5_94_adbsock import AdbSock

S = "<redacted-tailscale>:5555"
D = "/data/local/tmp/hybllm"
D2 = "/data/local/tmp/hybllm_dev"
Q4 = "/data/local/tmp/minicpm5-2b-q4k.gguf"
HYB = "E:/MyLLM_exp/hyb"
G, VOCAB = 64, 130560

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
ad = AdbSock(S)
w = ad.shell("dumpsys power | grep -m1 mWakefulness").strip()
if "Awake" in w:
    ad.shell("input keyevent 223")


def series(text):
    return [int(l.split()[2]) for l in text.splitlines() if re.match(r"^T \d+ \d+$", l)]


def cs(a, b):
    return float(a @ b / (np.linalg.norm(a) * np.linalg.norm(b) + 1e-12))


def pull_logits(remote_abs, local):
    ad.pull(remote_abs, local)
    a = np.fromfile(local, dtype="<f2").reshape(-1, VOCAB).astype(np.float32)
    os.remove(local)
    ad.shell(f"rm -f {remote_abs}")
    return a


out = {}
for N, real in ((0, 60), (1, 37), (2, 54)):
    og = ad.shell(f"cd {D2} && LD_LIBRARY_PATH=. ./hyb_save -m {Q4} -f ids_c{N}.raw "
                  f"-o gd_c{N}.state -n {real} -g {G} -p 88 -ngl 99 -L lg_g{N}.raw 2>&1 "
                  f"| grep -aE 'PREFILL|^T |first_tok|FAIL'")
    first = next((int(l.split("first_tok=")[1]) for l in og.splitlines()
                  if "first_tok=" in l), -1)
    ou = ad.shell(f"cd {D} && LD_LIBRARY_PATH=. ./hyb_save_up -m {Q4} -f ids_c{N}.raw "
                  f"-o fu_c{N}.state -n {real} -g {G} -p 88 -ngl 0 -L lg_u{N}.raw 2>&1 "
                  f"| grep -aE 'PREFILL|^T |first_tok|FAIL'")
    oh = ad.shell(f"cd {D2} && LD_LIBRARY_PATH=. ./hyb_load -m {Q4} -s bridged_c{N}.state "
                  f"-t {first} -n {real} -g {G} -ngl 99 -L lg_h{N}.raw 2>&1 "
                  f"| grep -aE 'STATE_LOADED|^T |FAIL'")
    assert first >= 0 and "STATE_LOADED" in oh, f"r{N} arm fail: {og[-150:]} | {oh[-150:]}"
    gsr, usr, hsr = series(og), series(ou), series(oh)
    lg = pull_logits(f"{D2}/lg_g{N}.raw", f"{HYB}/lg_g{N}.tmp")
    lu = pull_logits(f"{D}/lg_u{N}.raw", f"{HYB}/lg_u{N}.tmp")
    lh = pull_logits(f"{D2}/lg_h{N}.raw", f"{HYB}/lg_h{N}.tmp")
    n = min(map(len, (gsr, usr, hsr, lg, lu, lh)))
    lg, lu, lh, gsr, usr, hsr = (lg[:n], lu[:n], lh[:n], gsr[:n], usr[:n], hsr[:n])
    marg = [float(np.partition(lg[i], -2)[-1] - np.partition(lg[i], -2)[-2]) for i in range(n)]
    cosh = [round(cs(lg[i], lh[i]), 4) for i in range(n)]
    cosu = [round(cs(lg[i], lu[i]), 4) for i in range(n)]
    lcp_h = next((i for i in range(n) if hsr[i] != gsr[i]), n)
    lcp_u = next((i for i in range(n) if usr[i] != gsr[i]), n)
    rec = {"first": first, "steps": n, "gold": gsr, "hyb": hsr, "floor": usr,
           "margin": [round(m, 3) for m in marg], "cosh": cosh, "cosu": cosu,
           "lcp_h": lcp_h, "lcp_u": lcp_u, "cosh0": cosh[0], "cosu0": cosu[0]}
    out[str(N)] = rec
    print(f"== r{N} real={real} first={first} lcp_h={lcp_h} lcp_u={lcp_u} "
          f"cosh0={cosh[0]} cosu0={cosu[0]}", flush=True)
    print("  step gold hyb floor margin cosh cosu")
    for i in range(min(n, 14)):
        print(f"  {i:3d} {gsr[i]:6d} {hsr[i]:6d} {usr[i]:6d} {marg[i]:8.3f} "
              f"{cosh[i]:7.4f} {cosu[i]:7.4f}")
json.dump(out, open(HYB + "/diag_rev3.json", "w", encoding="utf-8"))
w = ad.shell("dumpsys power | grep -m1 mWakefulness").strip()
print("WAKE:", w)
if "Awake" in w:
    ad.shell("input keyevent 223")
print("DIAG_REV3_DONE")
