#!/usr/bin/env python3
# [npu-line M3-shell] Heavy-judge-only re-run for the m3s round:
# re-push host bridged_m3s.state + ids_m3s.raw into D2 (md5 closed loop per
# pitfall 62), run GOLD/FLOOR/HYB arms, dump RAW outputs + per-step cosh so a
# step-0 divergence can be dissected (no grep-filtered blind spots).
# Reuses mcp5_99 constants. CONFIRM=1 required.
import sys, os, re, json, hashlib, subprocess

if os.environ.get("CONFIRM") != "1":
    sys.exit("REFUSED: set CONFIRM=1 (device window)")
sys.path.insert(0, "E:/MyLLM_exp/_repro/rb")
sys.stdout.reconfigure(encoding="utf-8", errors="replace")
from mcp5_94_adbsock import AdbSock
import numpy as np

S = "<redacted-tailscale>:5555"
R = "/data/local/tmp/npu_m1"
D = "/data/local/tmp/hybllm"
D2 = "/data/local/tmp/hybllm_dev"
Q4 = "/data/local/tmp/minicpm5-2b-q4k.gguf"
HYB = "E:/MyLLM_exp/hyb"
G, VOCAB, MARGIN = 64, 130560, 1.0
REAL = int(sys.argv[1]) if len(sys.argv) > 1 else 195

ad = AdbSock(S)
sh = ad.shell


def md5_local(p):
    return hashlib.md5(open(p, "rb").read()).hexdigest()


def push_verified(local, remote):
    ad.push(local, remote)
    want = md5_local(local)
    x = sh(f"md5sum {remote} 2>/dev/null").strip()
    got = x.splitlines()[0].split()[0] if x and "No such" not in x else ""
    assert got == want, f"push drift {remote}: want {want} got {got}"
    print(f"[push] {remote} md5 ok {want[:8]}", flush=True)


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


# --- push inputs (md5 closed loop) ---
push_verified(f"{HYB}/ids_m3s.raw", f"{D2}/idsm3s.raw")
push_verified(f"{HYB}/ids_m3s.raw", f"{D}/idsm3s.raw")
push_verified(f"{HYB}/bridged_m3s.state", f"{D2}/bridged_m3s.state")

# --- arms (RAW output, only tail-trimmed by grep of noise lines) ---
gold = (f"cd {D2} && LD_LIBRARY_PATH=. ./hyb_save -m {Q4} -f idsm3s.raw "
        f"-o gdm3.state -n {REAL} -g {G} -p 88 -ngl 99 -L lgm3_g.raw 2>&1")
floor = (f"cd {D} && LD_LIBRARY_PATH=. ./hyb_save_up -m {Q4} -f idsm3s.raw "
         f"-o fum3.state -n {REAL} -g {G} -p 88 -ngl 0 -L lgm3_u.raw 2>&1")

og = sh(gold)
print("== GOLD raw tail ==", flush=True)
print("\n".join([l for l in og.splitlines()
                 if not l.startswith("ggml ")][:18]), flush=True)
first = next((int(l.split("first_tok=")[1]) for l in og.splitlines()
              if "first_tok=" in l), -1)
assert first >= 0, "gold parse: " + og[-300:]
print("first_tok =", first, flush=True)

oh = sh(f"cd {D2} && LD_LIBRARY_PATH=. ./hyb_load -m {Q4} -s bridged_m3s.state "
        f"-t {first} -n {REAL} -g {G} -ngl 99 -L lgm3_h.raw 2>&1")
print("== HYB raw head ==", flush=True)
print("\n".join(oh.splitlines()[:18]), flush=True)
ou = sh(floor)
print("== FLOOR raw tail ==", flush=True)
print("\n".join([l for l in ou.splitlines()
                 if not l.startswith("ggml ")][:12]), flush=True)

gsr, usr, hsr = series(og), series(ou), series(oh)
lg = pull_logits(f"{D2}/lgm3_g.raw", f"{HYB}/lgm3_g.tmp")
lu = pull_logits(f"{D}/lgm3_u.raw", f"{HYB}/lgm3_u.tmp")
lh = pull_logits(f"{D2}/lgm3_h.raw", f"{HYB}/lgm3_h.tmp")
n = min(len(lg), len(lu), len(lh), len(gsr), len(usr), len(hsr), G)
cosh = [round(cs(lg[i], lh[i]), 4) for i in range(n)]
cosu = [round(cs(lg[i], lu[i]), 4) for i in range(n)]
marg = [round(float(np.partition(lg[i], -2)[-1] - np.partition(lg[i], -2)[-2]), 3)
        for i in range(n)]
print("steps", n, "cosh[:12]", cosh[:12], flush=True)
print("cosu[:12]", cosu[:12], flush=True)
print("marg[:12]", marg[:12], flush=True)
lcp_h = next((i for i in range(n) if hsr[i] != gsr[i]), n)
print("lcp_h", lcp_h, "gsr[:8]", gsr[:8], "hsr[:8]", hsr[:8], flush=True)
pre = cosh[:lcp_h]
dec_h = lcp_h if (lcp_h < n and marg[lcp_h] >= MARGIN) else None
out = {"first": first, "steps": n, "lcp_h": lcp_h, "cosh0": cosh[0],
       "prefix_cos_min": round(min(pre), 4) if pre else None, "dec_h": dec_h,
       "cosh12": cosh[:12], "cosu12": cosu[:12], "marg12": marg[:12]}
json.dump(out, open(HYB + "/m3s_judge2.json", "w"), ensure_ascii=False, indent=1)
ok = cosh[0] >= 0.95 and (not pre or min(pre) >= 0.95) and dec_h is None
print("JUDGE2", "PASS" if ok else "FAIL", json.dumps(out), flush=True)
