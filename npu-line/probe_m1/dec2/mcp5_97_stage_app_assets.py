#!/usr/bin/env python3
# [npu-line] MC §7.6-③: stage 42 dec2p ctx.bin into App filesDir/npu_m1 via ON-DEVICE
# run-as cp (source already on device at /data/local/tmp/npu_m1 — no 3.9GB host push).
# Idempotent: skips when dst size == src size. Verifies sizes after cp. Red line: Dozing
# entry/exit (staging is headless; screen should already be Dozing).
#   usage: python -I stage_app_assets.py
import sys, os, json, time
sys.path.insert(0, "E:/MyLLM_exp/_repro/rb")
sys.stdout.reconfigure(encoding="utf-8", errors="replace")
from mcp5_94_adbsock import AdbSock

S = "<redacted-tailscale>:5555"
PKG = "com.dgxspark.tongyilite"
SRC = "/data/local/tmp/npu_m1"
DST = "/data/data/%s/files/npu_m1" % PKG
ad = AdbSock(S)


def doze(tag):
    x = ad.shell("dumpsys power | grep -m1 mWakefulness").strip()
    if "Awake" in x:
        ad.shell("input keyevent 223")
        x = ad.shell("dumpsys power | grep -m1 mWakefulness").strip()
    print(f"[wake {tag}] {x}", flush=True)
    assert "Dozing" in x or "Asleep" in x, f"screen stuck Awake at {tag}"


def runas(cmd):
    return ad.shell(f"run-as {PKG} sh -c '{cmd}'")


doze("entry")
# file list from the three manifests (frozen single source of truth)
names = set()
for m in ("manifest_pre2_A", "manifest_pre2_B", "manifest_pre2_C"):
    out = ad.shell(f"cat {SRC}/{m}")
    for tok in out.replace(",", " ").replace('"', " ").split():
        if tok.endswith("_ctx.bin") and "/" not in tok:
            names.add(tok)
names = sorted(names)
print(f"manifests reference {len(names)} ctx.bin", flush=True)
assert len(names) == 42, f"expected 42 ctx.bin, got {len(names)}"

runas(f"mkdir -p files/npu_m1")
# src sizes in one shot
sz_src = {}
for line in ad.shell(f"cd {SRC} && stat -c '%n %s' " + " ".join(names)).splitlines():
    p = line.rsplit(" ", 1)
    if len(p) == 2 and p[1].isdigit():
        sz_src[p[0].split("/")[-1]] = int(p[1])
assert len(sz_src) == 42, f"stat got {len(sz_src)}"
tot = sum(sz_src.values())
print(f"total staged bytes = {tot/2**30:.2f} GiB", flush=True)

# free space gate: need tot bytes free in /data (leave 2G margin).
# toybox df has no -B1 (silently errors) — parse default 1K-block columns.
free = None
line = ad.shell("df /data/user/0 | tail -1").strip()
f = line.split()
if len(f) >= 4 and f[3].isdigit():
    free = int(f[3]) * 1024
print(f"/data free = {(free or 0)/2**30:.1f} GiB", flush=True)
assert free and free > tot + 2 * 2**30, "insufficient /data free space"

missing = [n for n in names if n not in sz_src]
assert not missing, f"missing on device: {missing}"

report = {}
for i, n in enumerate(names):
    want = sz_src[n]
    out = runas(f"stat -c '%s' files/npu_m1/{n} 2>/dev/null || echo -1")
    have = int(out.strip().splitlines()[-1]) if out.strip() else -1
    if have == want:
        report[n] = "skip"
        continue
    t0 = time.time()
    r = runas(f"cp {SRC}/{n} files/npu_m1/{n}.tmp && mv files/npu_m1/{n}.tmp files/npu_m1/{n} && stat -c '%s' files/npu_m1/{n}")
    got = int(r.strip().splitlines()[-1])
    ok = got == want
    report[n] = f"cp {got}/{want} {time.time()-t0:.1f}s {'OK' if ok else 'MISMATCH'}"
    print(f"[{i+1:02d}/42] {n} {report[n]}", flush=True)
    assert ok, f"byte-size mismatch {n}: {got} != {want}"

bad = [k for k, v in report.items() if "OK" not in v and v != "skip"]
print("STAGE_" + ("DONE" if not bad else f"FAIL {bad}"))
doze("exit")
json.dump({"sizes": sz_src, "report": report},
          open("E:/MyLLM_exp/hyb/stage_app_assets.json", "w"), indent=1)
