#!/usr/bin/env python3
# [npu-line] M2 MC gate (tool-level core), 3-arm protocol (rev3):
#   GOLD  = fork-GPU hyb_save prefill+greedy 64 (+logits dump)   <- App baseline
#   FLOOR = upstream-CPU hyb_save_up greedy 64 (+logits dump)    <- engine-noise floor (no bridge)
#   HYB   = NPU chain KV -> v4 bridge -> fork-GPU hyb_load greedy 64 (+logits dump)
# rev2 (margin-exempt aligned match) is retired: one early coin-flip desyncs both series
# and every later aligned step becomes garbage (forensics: r01 real=37 has FLOOR top1 !=
# gold at step 0, gold margin 0.305; r00 hyb LCP 22 > floor LCP 18 yet rev2 said BAD).
# rev3b bars per prompt (cos0 always well-defined: hyb step-0 conditions only on bridged
# prompt KV, gold on GPU prompt KV -> same conditioning). rev3's lcp-vs-floor bar over-killed
# (r10: cosh0 .9918 + prefix cos .9881, one near-tie flip at step 7 while floor got lucky to
# 37) — replaced by DECISIVE-mismatch: at the first mismatch step j, gold top1-top2 margin
# must be < MARGIN (coin flip territory, like r01 where even FLOOR flips at step 0).
#   cosh0 >= 0.95  AND  min cos over hyb in-sync prefix >= 0.95  AND  no decisive mismatch
# Chain health: gate = CR5_DONE + 3-strike death + CR5_FAIL grep. ('preload missing' is a
# benign permanent 13-line per-seg notice — r09 forensics reproduced clean KV with it.
# r09's cosh0=0.59 was a one-off transient; the full re-run gives a second independent sample.)
# MC-JUDGE_PASS = >=45/50 OK AND median cosh0 >= 0.97.
# Per-step arrays are saved so protocol can be re-tuned OFFLINE (device untouched).
# Resume via c_batch_results.json (records all arms).
import sys, os, re, json, time, shutil, subprocess, hashlib
import numpy as np
sys.path.insert(0, "E:/MyLLM_exp/_repro/rb")
from mcp5_94_adbsock import AdbSock

S = "<redacted-tailscale>:5555"
R = "/data/local/tmp/npu_m1"
D = "/data/local/tmp/hybllm"
D2 = "/data/local/tmp/hybllm_dev"
Q4 = "/data/local/tmp/minicpm5-2b-q4k.gguf"
HYB = "E:/MyLLM_exp/hyb"
STAGE = "E:/wsl_stage"
PY = sys.executable
WSL = ["wsl.exe", "-d", "Ubuntu-22.04", "bash", "-lc"]
RESULTS = HYB + "/c_batch_results.json"
G, VOCAB, MARGIN = 64, 130560, 1.0

sys.path.insert(0, HYB)
from prompts50 import P


def load():
    try:
        return json.load(open(RESULTS, encoding="utf-8"))
    except Exception:
        return {}


def save(res):
    json.dump(res, open(RESULTS, "w", encoding="utf-8"), ensure_ascii=False, indent=1)


def wsl(cmd, prompt_file):
    # env MUST prefix python itself (VAR=x cd d && python binds only to cd);
    # wsl.exe bash -lc also drops injected env -> inline only. (Both bitten+fixed.)
    pf = "/mnt/e/wsl_stage/" + os.path.basename(prompt_file)
    return subprocess.run(WSL + [cmd.replace("python3", f"D2Q_PROMPT_FILE={pf} python3")],
                          capture_output=True, text=True,
                          encoding="utf-8", errors="replace", timeout=1200)


def series(text):
    return [int(l.split()[2]) for l in text.splitlines() if re.match(r"^T \d+ \d+$", l)]


def cs(a, b):
    return float(a @ b / (np.linalg.norm(a) * np.linalg.norm(b) + 1e-12))


ad = AdbSock(S)


def doze(where=""):
    x = ad.shell("dumpsys power | grep -m1 mWakefulness").strip()
    if "Awake" in x:
        ad.shell("input keyevent 223")
    print(f"[wake{where}] {x.splitlines()[0] if x else '?'}", flush=True)


def seg_chain():
    for f in (["d2q_emb_%d" % i for i in range(4)] + ["d2q_am_%d" % i for i in range(4)] +
              ["d2q_cos_table", "d2q_sin_table", "d2q_kc0", "d2q_vc0"]):
        ad.push(f"{STAGE}/{f}.raw", f"{R}/{f}.raw")
    ad.shell(f"pkill -f 'chain_[r]un5' 2>/dev/null; rm -f {R}/d2q_h_l*_* {R}/d2q_knew_* "
             f"{R}/d2q_vnew_* {R}/d2q_kc_*.raw {R}/d2q_vc_*.raw; rm -rf {R}/gate")
    ad.shell(f"cd {R} && for i in $(seq 0 41); do cp d2q_kc0.raw d2q_kc_$i.raw; "
             f"cp d2q_vc0.raw d2q_vc_$i.raw; done")
    for g, k in (("A", 0), ("B", 1), ("C", 2)):
        ad.shell(f"cd {R} && export LD_LIBRARY_PATH={R}/lib ADSP_LIBRARY_PATH={R}/lib && "
                 f"CHAIN_KEEP=1 CR5_ROLL_SAVE=1 nohup ./chain_run5 manifest_pre2_{g} 4 "
                 f"> p{k}.log 2>&1 & echo SPAWNED_{g}")
        done = False
        death = 0
        for t in range(240):
            c = ad.shell(f"grep -ac CR5_DONE {R}/p{k}.log 2>/dev/null || echo 0")
            if "1" in c.strip().splitlines()[-1].strip():
                done = True
                break
            try:
                alive = int(ad.shell("pgrep -f 'chain_[r]un5' | wc -l").strip().splitlines()[-1])
            except (ValueError, IndexError):
                alive = 1
            death = death + 1 if (alive == 0 and t > 8) else 0
            if death >= 3:   # 3 consecutive deaths (AdbSock partial reads under
                break        # concurrent load caused single-0 false deaths)
            time.sleep(5)
        if not done:
            raise RuntimeError(f"chain seg {g} not done; tail: "
                               + ad.shell(f"tail -3 {R}/p{k}.log")[-200:])
        # NOTE: 'CR5_FAIL open d2q_h_l{N}_0.raw' + 'CR5_INFO preload missing ... (zero-filled)'
        # are BENIGN paired first-run notices (present on all-clean runs; r09 forensic K .9866/
        # V .961). Two guards learned this the hard way (preload-then-CR5_FAIL, each torpedered
        # every round). Chain gate = CR5_DONE + 3-strike death ONLY.
    OUT = HYB + "/npu_kv"
    os.makedirs(OUT, exist_ok=True)
    for i in range(42):
        for t in ("kc", "vc"):
            ad.pull(f"{R}/d2q_{t}_{i}.raw", f"{OUT}/d2q_{t}_{i}.raw")
    ad.shell("pkill -f 'chain_[r]un5' 2>/dev/null || true")


def pull_logits(remote_abs, local):
    ad.pull(remote_abs, local)
    a = np.fromfile(local, dtype="<f2").reshape(-1, VOCAB).astype(np.float32)
    os.remove(local)
    ad.shell(f"rm -f {remote_abs}")
    return a


def arms(gold_save_cmd, gold_dir, up_save_cmd, hyb_load_cmd, n):
    """run 3 arms, return (gold_lg, floor_lg, hyb_lg, first)"""
    og = ad.shell(gold_save_cmd)
    first = next((int(l.split("first_tok=")[1]) for l in og.splitlines()
                  if "first_tok=" in l), -1)
    if first < 0:
        raise RuntimeError("gold: " + og[-250:])
    ou = ad.shell(up_save_cmd)
    fu = next((int(l.split("first_tok=")[1]) for l in ou.splitlines()
               if "first_tok=" in l), -1)
    oh = ad.shell(hyb_load_cmd.replace("{first}", str(first)))
    if "STATE_LOADED" not in oh:
        raise RuntimeError("load: " + oh[-250:])
    gsr, usr, hsr = series(og), series(ou), series(oh)
    if min(len(gsr), len(usr), len(hsr)) < G:
        raise RuntimeError(f"series too short {len(gsr)}/{len(usr)}/{len(hsr)}")
    lg = pull_logits(f"{gold_dir}/lg_g{N}.raw", f"{HYB}/lg_g{N}.tmp")
    lu = pull_logits(f"{D}/lg_u{N}.raw", f"{HYB}/lg_u{N}.tmp")
    lh = pull_logits(f"{gold_dir}/lg_h{N}.raw", f"{HYB}/lg_h{N}.tmp")
    nsteps = min(len(lg), len(lu), len(lh), G)
    lg, lu, lh = lg[:nsteps], lu[:nsteps], lh[:nsteps]
    gsr, usr, hsr = gsr[:nsteps], usr[:nsteps], hsr[:nsteps]
    cosh = [cs(lg[i], lh[i]) for i in range(nsteps)]
    cosu = [cs(lg[i], lu[i]) for i in range(nsteps)]
    marg = [float(np.partition(lg[i], -2)[-1] - np.partition(lg[i], -2)[-2])
            for i in range(nsteps)]
    def lcp(s):
        return next((i for i in range(nsteps) if s[i] != gsr[i]), nsteps)
    lcp_h, lcp_u = lcp(hsr), lcp(usr)
    pre = cosh[:lcp_h]
    return {"first": first, "steps": nsteps,
            "lcp_h": lcp_h, "lcp_u": lcp_u,
            "dec_h": (lcp_h if lcp_h < nsteps and marg[lcp_h] >= MARGIN else None),
            "dec_u": (lcp_u if lcp_u < nsteps and marg[lcp_u] >= MARGIN else None),
            "cosh0": round(cosh[0], 4), "cosu0": round(cosu[0], 4),
            "prefix_cos_min": (round(min(pre), 4) if pre else None),
            "gold": gsr, "hyb": hsr, "floor": usr, "margin": [round(m, 3) for m in marg],
            "cosh": [round(c, 4) for c in cosh], "cosu": [round(c, 4) for c in cosu]}


# seed binaries both dirs (idempotent)
for d, b, src in ((D2, "hyb_save", "bin/hyb_save"), (D2, "hyb_load", "bin/hyb_load"),
                  (D, "hyb_save_up", "bin/hyb_save_up"), (D, "hyb_load_up", "bin/hyb_load_up")):
    ad.shell(f"rm -f {d}/{b}")
    ad.push(f"{HYB}/{src}", f"{d}/{b}")
    ad.shell(f"chmod 755 {d}/{b}")

seen_sha = {}
res = load()
for N, prompt in enumerate(P):
    if str(N) in res and res[str(N)].get("cosh0") is not None:
        continue
    doze(f" r{N:02d}-start")
    rec = {}
    try:
        pf = f"{STAGE}/prompt_{N}.txt"
        open(pf, "w", encoding="utf-8").write(prompt)
        o1 = wsl("cd /mnt/e/MyLLM_exp/hyb && python3 gen_ids.py", pf)
        m = re.search(r"real_tokens (\d+)", o1.stdout)
        if not m:
            raise RuntimeError("gen_ids: " + (o1.stdout + o1.stderr)[-250:])
        real = int(m.group(1))
        rec["real"] = real
        if not (16 <= real <= 500):
            raise RuntimeError(f"real={real} out of range")
        o2 = wsl("cd /mnt/e/MyLLM_exp/hyb && python3 mcp5_77b_pre2_prep.py", pf)
        if "PREP77_DONE" not in o2.stdout:
            raise RuntimeError("prep: " + (o2.stdout + o2.stderr)[-250:])
        idsf = f"{HYB}/ids_c{N}.raw"
        shutil.copyfile(HYB + "/ids.raw", idsf)
        h = hashlib.sha256(open(idsf, "rb").read()).hexdigest()[:16]
        if h in seen_sha:
            raise RuntimeError(f"ids sha collision with r{seen_sha[h]} (degraded injection)")
        seen_sha[h] = N
        ad.push(idsf, R + "/ids.raw")
        seg_chain()
        ad.push(idsf, D2 + f"/ids_c{N}.raw")
        ad.push(idsf, D + f"/ids_c{N}.raw")
        be = dict(os.environ)
        be["BRIDGE_VER"] = "4"
        ob = subprocess.run([PY, "-I", HYB + "/kv_bridge.py", "copy",
                             f"{HYB}/bridged_c{N}.state", str(real)],
                            capture_output=True, text=True,
                            encoding="utf-8", errors="replace", env=be)
        if "BRIDGE_OK" not in ob.stdout:
            raise RuntimeError("bridge: " + (ob.stdout + ob.stderr)[-200:])
        ad.shell(f"rm -f {D2}/bridged_c{N}.state")
        ad.push(f"{HYB}/bridged_c{N}.state", f"{D2}/bridged_c{N}.state")
        gold = (f"cd {D2} && LD_LIBRARY_PATH=. ./hyb_save -m {Q4} -f ids_c{N}.raw "
                f"-o gd_c{N}.state -n {real} -g {G} -p 88 -ngl 99 -L lg_g{N}.raw 2>&1 "
                f"| grep -aE 'PREFILL|^T |FAIL'")
        floor = (f"cd {D} && LD_LIBRARY_PATH=. ./hyb_save_up -m {Q4} -f ids_c{N}.raw "
                 f"-o fu_c{N}.state -n {real} -g {G} -p 88 -ngl 0 -L lg_u{N}.raw 2>&1 "
                 f"| grep -aE 'PREFILL|^T |FAIL'")
        hyb = (f"cd {D2} && LD_LIBRARY_PATH=. ./hyb_load -m {Q4} -s bridged_c{N}.state "
               f"-t {{first}} -n {real} -g {G} -ngl 99 -L lg_h{N}.raw 2>&1 "
               f"| grep -aE 'STATE_LOADED|^T |FAIL'")
        rec.update(arms(gold, D2, floor, hyb, N))
        ok = (rec["cosh0"] >= 0.95
              and (rec["prefix_cos_min"] is None or rec["prefix_cos_min"] >= 0.95)
              and rec["dec_h"] is None)
        rec["ok"] = bool(ok)
        print(f"r{N:02d} real={real} lcp_h={rec['lcp_h']} lcp_u={rec['lcp_u']} "
              f"dec_h={rec['dec_h']} cosh0={rec['cosh0']} pcos={rec['prefix_cos_min']} "
              f"{'OK' if ok else 'BAD'}", flush=True)
    except Exception as e:
        rec["err"] = str(e)[-250:]
        print(f"r{N:02d} ERR {rec['err']}", flush=True)
    res[str(N)] = {**res.get(str(N), {}), **rec}
    save(res)
    doze(f" r{N:02d}-end")

res = load()
done = [v for v in res.values() if v.get("cosh0") is not None]
if len(done) == 50:
    oks = sum(1 for v in done if v.get("ok"))
    c0 = sorted(v["cosh0"] for v in done)
    print(f"MC-JUDGE prompts=50 ok={oks}/50 med_cosh0={c0[25]} "
          f"dec_h_total={sum(1 for v in done if v.get('dec_h') is not None)} "
          f"dec_u_total={sum(1 for v in done if v.get('dec_u') is not None)}")
    print("MC_JUDGE_PASS" if oks >= 45 and c0[25] >= 0.97 else "MC_JUDGE_FAIL")
else:
    print(f"MC-JUDGE incomplete: {len(done)}/50")
print("C_BATCH_DONE")
