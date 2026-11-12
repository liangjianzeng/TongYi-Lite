#!/usr/bin/env python3
# [npu-line] MC r09 forensics: cosh0=0.5922 while floor 64/64 -> bridged KV itself bad.
# Reproduce prompt_9 chain (deterministic feeds), pull KV to npu_kv_r09, check chain log
# for 'preload missing', then per-layer cos(bridged K/V rows vs fork-GPU gold state rows)
# to localize: chain degradation (some layers ~0) vs decode-consumption (all layers ~1).
import sys, os, re, json, shutil, struct, subprocess, time
import numpy as np
sys.path.insert(0, "E:/MyLLM_exp/_repro/rb")
from mcp5_94_adbsock import AdbSock

S = "<redacted-tailscale>:5555"
R = "/data/local/tmp/npu_m1"
D2 = "/data/local/tmp/hybllm_dev"
Q4 = "/data/local/tmp/minicpm5-2b-q4k.gguf"
HYB = "E:/MyLLM_exp/hyb"
STAGE = "E:/wsl_stage"
N, REAL = 9, 44

sys.path.insert(0, HYB)
from prompts50 import P
sys.stdout.reconfigure(encoding="utf-8", errors="replace")
WSL = ["wsl.exe", "-d", "Ubuntu-22.04", "bash", "-lc"]


def wsl(cmd, prompt_file):
    pf = "/mnt/e/wsl_stage/" + os.path.basename(prompt_file)
    return subprocess.run(WSL + [cmd.replace("python3", f"D2Q_PROMPT_FILE={pf} python3")],
                          capture_output=True, text=True,
                          encoding="utf-8", errors="replace", timeout=1200)


ad = AdbSock(S)
w = ad.shell("dumpsys power | grep -m1 mWakefulness").strip()
if "Awake" in w:
    ad.shell("input keyevent 223")

pf = f"{STAGE}/prompt_{N}.txt"
open(pf, "w", encoding="utf-8").write(P[N])
o1 = wsl("cd /mnt/e/MyLLM_exp/hyb && python3 gen_ids.py", pf)
m = re.search(r"real_tokens (\d+)", o1.stdout)
real = int(m.group(1)) if m else -1
print("GEN real:", real, "(expect", REAL, ")")
assert real == REAL
o2 = wsl("cd /mnt/e/MyLLM_exp/hyb && python3 mcp5_77b_pre2_prep.py", pf)
print("PREP:", o2.stdout.strip().splitlines()[-1][:60])
idsf = f"{HYB}/ids_r09.raw"
shutil.copyfile(HYB + "/ids.raw", idsf)

for f in (["d2q_emb_%d" % i for i in range(4)] + ["d2q_am_%d" % i for i in range(4)] +
          ["d2q_cos_table", "d2q_sin_table", "d2q_kc0", "d2q_vc0"]):
    ad.push(f"{STAGE}/{f}.raw", f"{R}/{f}.raw")
ad.push(idsf, R + "/ids.raw")
ad.shell(f"pkill -f 'chain_[r]un5' 2>/dev/null; rm -f {R}/d2q_h_l*_* {R}/d2q_knew_* "
         f"{R}/d2q_vnew_* {R}/d2q_kc_*.raw {R}/d2q_vc_*.raw {R}/p0.log {R}/p1.log "
         f"{R}/p2.log; rm -rf {R}/gate")
ad.shell(f"cd {R} && for i in $(seq 0 41); do cp d2q_kc0.raw d2q_kc_$i.raw; "
         f"cp d2q_vc0.raw d2q_vc_$i.raw; done")
for g, k in (("A", 0), ("B", 1), ("C", 2)):
    ad.shell(f"cd {R} && export LD_LIBRARY_PATH={R}/lib ADSP_LIBRARY_PATH={R}/lib && "
             f"CHAIN_KEEP=1 CR5_ROLL_SAVE=1 nohup ./chain_run5 manifest_pre2_{g} 4 "
             f"> p{k}.log 2>&1 & echo SPAWNED_{g}")
    done = False
    for t in range(240):
        c = ad.shell(f"grep -ac CR5_DONE {R}/p{k}.log 2>/dev/null || echo 0")
        if c.strip().splitlines()[-1].strip() == "1":
            done = True
            break
        time.sleep(5)
    deg = ad.shell(f"grep -ac 'preload missing' {R}/p{k}.log 2>/dev/null || echo 0")
    print(f"seg {g}: done={done} preload_missing_lines={deg.strip().splitlines()[-1]}")
    if not done:
        print(ad.shell(f"tail -4 {R}/p{k}.log"))
        sys.exit(1)
OUT = HYB + "/npu_kv_r09"
os.makedirs(OUT, exist_ok=True)
for i in range(42):
    for t in ("kc", "vc"):
        ad.pull(f"{R}/d2q_{t}_{i}.raw", f"{OUT}/d2q_{t}_{i}.raw")
ad.shell("pkill -f 'chain_[r]un5' 2>/dev/null || true")

ad.push(idsf, D2 + "/ids_r09.raw")
og = ad.shell(f"cd {D2} && LD_LIBRARY_PATH=. ./hyb_save -m {Q4} -f ids_r09.raw "
              f"-o gold_r09.state -n {REAL} -g 4 -p 88 -ngl 99 2>&1 | grep -aE 'first_tok|FAIL'")
print("GOLD:", og.strip()[:80])
ad.pull(f"{D2}/gold_r09.state", f"{HYB}/gold_r09.state")

buf = open(f"{HYB}/gold_r09.state", "rb").read()
off = 0
def rd(fmt):
    global off
    sz = struct.calcsize(fmt)
    v = struct.unpack_from(fmt, buf, off); off += sz
    return v

magic, ver = rd("<II")
n_tok, = rd("<I")
off += 4 * n_tok
n_stream, cell_count = rd("<II")
for _ in range(cell_count):
    pos, nsq = rd("<iI")
    off += 4 * nsq
v_trans, n_layer, nrotk, nrotv = rd("<IIII")
print(f"gold v{ver} n_tok={n_tok} cells={cell_count} nl={n_layer}")

def h2i(x):
    o = np.empty_like(x)
    o[0::2] = x[:64]; o[1::2] = x[64:]
    return o

def cs(a, b):
    a = a.astype(np.float64); b = b.astype(np.float64)
    return float(a @ b / (np.linalg.norm(a) * np.linalg.norm(b) + 1e-12))

kcos, vcos = [], []
for il in range(42):
    typ, row = rd("<iQ")
    rb = row * 2 if row == 256 else row
    gk = np.frombuffer(buf[off:off + rb * cell_count], "<f2").reshape(cell_count, rb // 2)
    off += rb * cell_count
    nk = np.fromfile(f"{OUT}/d2q_kc_{il}.raw", dtype="<f2").reshape(512, 128, 2)
    br = np.stack([np.concatenate([h2i(nk[t, :, j].astype(np.float32)) for j in range(2)])
                   for t in range(cell_count)], 0)
    kcos.append(np.mean([cs(gk[t], br[t]) for t in range(cell_count)]))
for il in range(42):
    typ, row = rd("<iQ")
    rb = row * 2 if row == 256 else row
    gv = np.frombuffer(buf[off:off + rb * cell_count], "<f2").reshape(cell_count, rb // 2)
    off += rb * cell_count
    nvv = np.fromfile(f"{OUT}/d2q_vc_{il}.raw", dtype="<f2").reshape(512, 128, 2)
    br = np.stack([np.concatenate([nvv[t, :, j].astype(np.float32) for j in range(2)])
                   for t in range(cell_count)], 0)
    vcos.append(np.mean([cs(gv[t], br[t]) for t in range(cell_count)]))

print("K cos min/mean:", round(min(kcos), 4), round(sum(kcos)/42, 4))
print("V cos min/mean:", round(min(vcos), 4), round(sum(vcos)/42, 4))
bad = [(i, round(kcos[i], 3), round(vcos[i], 3)) for i in range(42)
       if kcos[i] < 0.95 or vcos[i] < 0.95]
print("BAD layers:", bad[:20], "count", len(bad))
w = ad.shell("dumpsys power | grep -m1 mWakefulness").strip()
print("WAKE:", w)
if "Awake" in w:
    ad.shell("input keyevent 223")
print("DIAG_R09_DONE")
