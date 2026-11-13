#!/usr/bin/env python3
# [npu-line NC128 双档] line-B main driver: single-chunk NC=128 prefill gear for the
# prompts50 real set (36-81 real tokens all fit one S=128 chunk). Chain/arms/judge are
# the proven 97 MC driver (rev3b, 3-arm GOLD/FLOOR/HYB, resume-safe); deltas:
#   - manifests manifest_nc128_{A,B,C} (dec2_l{k} ctx, per-layer d2q128_* caches, roll@512)
#   - one chunk: chain_run5 <manifest> 1 (static-512 gear paid 4 chunks = 3.72s exec;
#     NC128 target: chain exec ~0.93s, hybrid TTFT 4.94 -> ~2.5s)
#   - prep77b runs DEC_NC=128 D2Q_PFX=d2q128; kv_bridge runs NPU_NC=128 NPU_KV_DIR=npu_kv128
#   - per-round timing: chain wall/exec (CR5_DONE parse) + bridge + push + load/first_tok
# Modes: verify (md5-audit 42 device ctx vs serve_dec, chunked re-push on drift),
#        sanity (round 0 only), batch (all pending rounds, resumable via nc128_results.json).
# Redlines honored: mWakefulness check+223 both ends of every round; work only in
# E:\MyLLM_exp / /home/liang; device files under /data/local/tmp (npu_m1, hybllm*);
# big pushes = 60MB socket chunks + per-chunk stat + device cat + md5.
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
SERVE = "E:/MyLLM_exp/serve_dec"
PY = sys.executable
WSL = ["wsl.exe", "-d", "Ubuntu-22.04", "bash", "-lc"]
RESULTS = HYB + "/nc128_results.json"
seen_sha = set()   # 97's ids-collision guard: two rounds with identical ids = WSL env
                   # injection degraded (same prompt 50x -> false 50/50). Both bitten.
G, VOCAB, MARGIN = 64, 130560, 1.0
NCHUNK = 1                      # NC128: single chunk
PREP_ENV = "DEC_NC=128 D2Q_PFX=d2q128"

sys.path.insert(0, HYB)
from prompts50 import P

ad = AdbSock(S)


def load():
    try:
        return json.load(open(RESULTS, encoding="utf-8"))
    except Exception:
        return {}


def save(res):
    json.dump(res, open(RESULTS, "w", encoding="utf-8"), ensure_ascii=False, indent=1)


def wsl(cmd, prompt_file, env=""):
    pf = "/mnt/e/wsl_stage/" + os.path.basename(prompt_file)
    pre = f"{env} D2Q_PROMPT_FILE={pf} "
    return subprocess.run(WSL + [cmd.replace("python3", pre + "python3")],
                          capture_output=True, text=True,
                          encoding="utf-8", errors="replace", timeout=1200)


def series(text):
    return [int(l.split()[2]) for l in text.splitlines() if re.match(r"^T \d+ \d+$", l)]


def cs(a, b):
    return float(a @ b / (np.linalg.norm(a) * np.linalg.norm(b) + 1e-12))


def doze(where=""):
    x = ad.shell("dumpsys power | grep -m1 mWakefulness").strip()
    if "Awake" in x:
        ad.shell("input keyevent 223")
    print(f"[wake{where}] {x.splitlines()[0] if x else '?'}", flush=True)


def md5_local(p):
    h = hashlib.md5()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def push_chunked(local, remote_abs):
    """60MB socket chunks + per-chunk stat + device cat + md5 (adbd big-flow law, 坑31/59)."""
    size = os.path.getsize(local)
    CH = 60 * 1024 * 1024
    n = (size + CH - 1) // CH
    base = os.path.basename(remote_abs)
    tmpd = HYB + "/tmp98"
    os.makedirs(tmpd, exist_ok=True)
    try:
        with open(local, "rb") as f:
            for i in range(n):
                data = f.read(CH)
                p = f"{tmpd}/part{i}"
                open(p, "wb").write(data)
                ad.push(p, f"{remote_abs}.part{i}")
                os.remove(p)
                got = ad.shell(f"stat -c %s {remote_abs}.part{i}").strip().splitlines()[-1]
                if int(got) != len(data):
                    raise RuntimeError(f"chunk {i} size {got} != {len(data)}")
        ad.shell(f"cd {R} && rm -f {base} && cat " +
                 " ".join(f"{base}.part{i}" for i in range(n)) + f" > {base} && " +
                 " ".join(f"rm -f {base}.part{i};" for i in range(n)) + " echo CAT_OK")
        want = md5_local(local)
        got = ad.shell(f"md5sum {remote_abs}").split()[0]
        if got != want:
            raise RuntimeError(f"md5 drift {got} != {want}")
    finally:
        shutil.rmtree(tmpd, ignore_errors=True)


def verify_ctx():
    bad = []
    files = [f"dec2_l{i}_ctx.bin" for i in range(42)]
    out = ad.shell(f"cd {R} && md5sum " + " ".join(files) + " 2>/dev/null")
    dev = dict((l.split()[1], l.split()[0]) for l in out.splitlines() if len(l.split()) == 2)
    for fn in files:
        lp = f"{SERVE}/{fn}"
        want = md5_local(lp)
        got = dev.get(fn)
        if got != want:
            print(f"MD5_DRIFT {fn} dev={got} host={want} -> repush", flush=True)
            push_chunked(lp, f"{R}/{fn}")
            bad.append(fn)
    print(f"VERIFY_CTX_DONE drift={len(bad)}", flush=True)


def push_manifests():
    for g in "ABC":
        ad.push(f"E:/MyLLM_exp/manifest_nc128_{g}", f"{R}/manifest_nc128_{g}")
    print("MANIFESTS_PUSHED", flush=True)


def seg_chain128():
    t_wall = {}
    for f in (["d2q128_emb_0", "d2q128_am_0", "d2q128_cos_table",
               "d2q128_sin_table", "d2q128_kc0", "d2q128_vc0"]):
        ad.push(f"{STAGE}/{f}.raw", f"{R}/{f}.raw")
    ad.shell(f"pkill -f 'chain_[r]un5' 2>/dev/null; rm -f {R}/d2q128_h_l*_* {R}/d2q128_knew_* "
             f"{R}/d2q128_vnew_* {R}/d2q128_kc_*.raw {R}/d2q128_vc_*.raw; rm -rf {R}/gate")
    ad.shell(f"cd {R} && for i in $(seq 0 41); do cp d2q128_kc0.raw d2q128_kc_$i.raw; "
             f"cp d2q128_vc0.raw d2q128_vc_$i.raw; done")
    timing = {}
    for g, k in (("A", 0), ("B", 1), ("C", 2)):
        t0 = time.time()
        # spawn hardening (2026-11-13 double failure: stale-log false DONE, then a
        # spawn that died with adbd session teardown leaving NO log at all):
        #   rm log first; touch it in-parent so absence == never spawned;
        #   </dev/null + parent `sleep 1` keep the child through shell teardown;
        #   re-spawn (max 3) unless the fresh "CR5 segs=" header shows within 15s.
        hdr = ""
        for attempt in range(3):
            ad.shell(f"rm -f {R}/p128_{k}.log")
            ad.shell(f"cd {R} && export LD_LIBRARY_PATH={R}/lib ADSP_LIBRARY_PATH={R}/lib && "
                     f"CHAIN_KEEP=1 CR5_ROLL_SAVE=1 nohup ./chain_run5 manifest_nc128_{g} {NCHUNK} "
                     f"> p128_{k}.log 2>&1 </dev/null & sleep 1; touch {R}/p128_{k}.log; "
                     f"echo SPAWNED_{g}")
            hdr = "0"
            for _ in range(5):
                time.sleep(3)
                hdr = ad.shell(f"grep -ac 'CR5 segs=' {R}/p128_{k}.log 2>/dev/null || echo 0")
                if "1" in hdr.strip().splitlines()[-1].strip():
                    break
            if "1" in hdr.strip().splitlines()[-1].strip():
                break
            print(f"seg {g} spawn attempt {attempt} no header -> pkill+respawn", flush=True)
            ad.shell("pkill -f 'chain_[r]un5' 2>/dev/null || true")
            time.sleep(3)
        done = False
        death = 0
        for t in range(240):
            # trust DONE only with the fresh-run header present (belt vs stale logs)
            c = ad.shell(f"grep -ac CR5_DONE {R}/p128_{k}.log 2>/dev/null || echo 0")
            hdr = ad.shell(f"grep -ac 'CR5 segs=' {R}/p128_{k}.log 2>/dev/null || echo 0")
            if "1" in c.strip().splitlines()[-1].strip() \
               and "1" in hdr.strip().splitlines()[-1].strip():
                done = True
                break
            try:
                alive = int(ad.shell("pgrep -f 'chain_[r]un5' | wc -l").strip().splitlines()[-1])
            except (ValueError, IndexError):
                alive = 1
            death = death + 1 if (alive == 0 and t > 8) else 0
            if death >= 3:
                break
            time.sleep(5)
        t_wall[g] = time.time() - t0
        if not done:
            raise RuntimeError(f"chain seg {g} not done; tail: "
                               + ad.shell(f"tail -3 {R}/p128_{k}.log")[-200:])
        # gate = CR5_DONE + 3-strike death ONLY (benign preload-missing/CR5_FAIL open
        # first-run notices documented in plan §7.2 — never guard on them).
        ln = ad.shell(f"grep -a CR5_DONE {R}/p128_{k}.log").strip().splitlines()[-1]
        m = re.search(r"wall=([\d.]+) ms.*exec=([\d.]+)", ln)
        timing[g] = {"done_line": ln, "wall": float(m.group(1)), "exec": float(m.group(2))}
        # relay integrity hard-gate (DONE alone is blind to missing h dumps — 2026-11-13):
        nh = int(ad.shell(f"ls {R}/d2q128_h_l*_* 2>/dev/null | wc -l").strip().splitlines()[-1])
        if nh != 14 * (k + 1):
            raise RuntimeError(f"seg {g} done but h dumps {nh} != {14 * (k + 1)}")
    OUT = HYB + "/npu_kv128"
    os.makedirs(OUT, exist_ok=True)
    for i in range(42):
        for t in ("kc", "vc"):
            ad.pull(f"{R}/d2q128_{t}_{i}.raw", f"{OUT}/d2q128_{t}_{i}.raw")
    ad.shell("pkill -f 'chain_[r]un5' 2>/dev/null || true")
    return timing


def pull_logits(remote_abs, local):
    ad.pull(remote_abs, local)
    a = np.fromfile(local, dtype="<f2").reshape(-1, VOCAB).astype(np.float32)
    os.remove(local)
    ad.shell(f"rm -f {remote_abs}")
    return a


def arms(gold_save_cmd, gold_dir, up_save_cmd, hyb_load_cmd):
    og = ad.shell(gold_save_cmd)
    first = next((int(l.split("first_tok=")[1]) for l in og.splitlines()
                  if "first_tok=" in l), -1)
    if first < 0:
        raise RuntimeError("gold: " + og[-250:])
    ou = ad.shell(up_save_cmd)
    oh = ad.shell(hyb_load_cmd.replace("{first}", str(first)))
    if "STATE_LOADED" not in oh:
        raise RuntimeError("load: " + oh[-250:])
    gsr, usr, hsr = series(og), series(ou), series(oh)
    if min(len(gsr), len(usr), len(hsr)) < G:
        raise RuntimeError(f"series too short {len(gsr)}/{len(usr)}/{len(hsr)}")
    lg = pull_logits(f"{gold_dir}/lg128_g{N}.raw", f"{HYB}/lg128_g{N}.tmp")
    lu = pull_logits(f"{D}/lg128_u{N}.raw", f"{HYB}/lg128_u{N}.tmp")
    lh = pull_logits(f"{gold_dir}/lg128_h{N}.raw", f"{HYB}/lg128_h{N}.tmp")
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
    lt = lambda pat: (lambda m: float(m.group(1)) if m else None)(re.search(pat, oh))
    return {"first": first, "steps": nsteps,
            "lcp_h": lcp_h, "lcp_u": lcp_u,
            "dec_h": (lcp_h if lcp_h < nsteps and marg[lcp_h] >= MARGIN else None),
            "dec_u": (lcp_u if lcp_u < nsteps and marg[lcp_u] >= MARGIN else None),
            "cosh0": round(cosh[0], 4), "cosu0": (round(cosu[0], 4) if cosu else None),
            "prefix_cos_min": (round(min(pre), 4) if pre else None),
            "load_ms": lt(r"load_ms=([\d.]+)"), "first_ms": lt(r"FIRST_TOK_MS ([\d.]+)"),
            "gold": gsr, "hyb": hsr, "floor": usr, "margin": [round(m, 3) for m in marg],
            "cosh": [round(c, 4) for c in cosh], "cosu": [round(c, 4) for c in cosu]}


def run_round(N, rec):
    pf = f"{STAGE}/prompt128_{N}.txt"
    open(pf, "w", encoding="utf-8").write(P[N])
    o1 = wsl("cd /mnt/e/MyLLM_exp/hyb && python3 gen_ids.py", pf)
    m = re.search(r"real_tokens (\d+)", o1.stdout)
    if not m:
        raise RuntimeError("gen_ids: " + (o1.stdout + o1.stderr)[-250:])
    real = int(m.group(1))
    rec["real"] = real
    if not (16 <= real <= 120):
        raise RuntimeError(f"real={real} out of NC128 range")
    o2 = wsl("cd /mnt/e/MyLLM_exp/hyb && python3 mcp5_77b_pre2_prep.py", pf, PREP_ENV)
    if "PREP77_DONE" not in o2.stdout:
        raise RuntimeError("prep: " + (o2.stdout + o2.stderr)[-250:])
    idsf = f"{HYB}/ids128_c{N}.raw"
    shutil.copyfile(HYB + "/ids.raw", idsf)
    h = hashlib.sha256(open(idsf, "rb").read()).hexdigest()[:16]
    if h in seen_sha:
        raise RuntimeError(f"ids sha collision {h} with earlier round (prompt injection degraded)")
    seen_sha.add(h)
    ad.push(idsf, R + "/ids.raw")
    rec["chain"] = seg_chain128()
    ad.push(idsf, D2 + f"/ids128_c{N}.raw")
    ad.push(idsf, D + f"/ids128_c{N}.raw")
    be = dict(os.environ)
    be.update({"BRIDGE_VER": "4", "NPU_VER": "4", "NPU_NC": "128", "NPU_PFX": "d2q128",
               "NPU_KV_DIR": HYB + "/npu_kv128", "NPU_IDS": HYB + "/ids.raw"})
    t0 = time.time()
    ob = subprocess.run([PY, "-I", HYB + "/kv_bridge.py", "copy",
                         f"{HYB}/bridged128_c{N}.state", str(real)],
                        capture_output=True, text=True,
                        encoding="utf-8", errors="replace", env=be)
    if "BRIDGE_OK" not in ob.stdout:
        raise RuntimeError("bridge: " + (ob.stdout + ob.stderr)[-200:])
    rec["bridge_s"] = round(time.time() - t0, 2)
    ad.shell(f"rm -f {D2}/bridged128_c{N}.state")
    t0 = time.time()
    ad.push(f"{HYB}/bridged128_c{N}.state", f"{D2}/bridged128_c{N}.state")
    rec["push_state_s"] = round(time.time() - t0, 2)
    gold = (f"cd {D2} && LD_LIBRARY_PATH=. ./hyb_save -m {Q4} -f ids128_c{N}.raw "
            f"-o gd128_c{N}.state -n {real} -g {G} -p 88 -ngl 99 -L lg128_g{N}.raw 2>&1 "
            f"| grep -aE 'PREFILL|^T |first_tok|FAIL'")
    floor = (f"cd {D} && LD_LIBRARY_PATH=. ./hyb_save_up -m {Q4} -f ids128_c{N}.raw "
             f"-o fu128_c{N}.state -n {real} -g {G} -p 88 -ngl 0 -L lg128_u{N}.raw 2>&1 "
             f"| grep -aE 'PREFILL|^T |first_tok|FAIL'")
    hyb = (f"cd {D2} && LD_LIBRARY_PATH=. ./hyb_load -m {Q4} -s bridged128_c{N}.state "
           f"-t {{first}} -n {real} -g {G} -ngl 99 -L lg128_h{N}.raw 2>&1 "
           f"| grep -aE 'STATE_LOADED|load_ms|FIRST_TOK_MS|^T |FAIL'")
    rec.update(arms(gold, D2, floor, hyb))
    # hybrid TTFT (hot = ctx-warm exec; cold = + per-seg preload wall delta)
    exec_s = sum(seg["exec"] for seg in rec["chain"].values()) / 1000.0
    hot = (exec_s + rec.get("bridge_s", 0) + rec.get("push_state_s", 0)
           + (rec.get("load_ms") or 0) / 1000 + (rec.get("first_ms") or 0) / 1000)
    cold_wall = sum(seg["wall"] for seg in rec["chain"].values()) / 1000.0
    rec["ttft_hot_s"] = round(hot, 2)
    rec["ttft_cold_s"] = round(hot - exec_s + cold_wall, 2)
    ok = (rec["cosh0"] >= 0.95
          and (rec["prefix_cos_min"] is None or rec["prefix_cos_min"] >= 0.95)
          and rec["dec_h"] is None)
    rec["ok"] = bool(ok)
    print(f"r{N:02d} real={real} exec={exec_s:.2f}s ttft_hot={rec['ttft_hot_s']} "
          f"lcp_h={rec['lcp_h']} dec_h={rec['dec_h']} cosh0={rec['cosh0']} "
          f"pcos={rec['prefix_cos_min']} {'OK' if ok else 'BAD'}", flush=True)


def main():
    global N
    mode = sys.argv[1] if len(sys.argv) > 1 else "sanity"
    if mode in ("verify", "push"):
        verify_ctx()
        push_manifests()
        # seed the two GPU-arm binaries (idempotent, same as 97)
        for d, b, src in ((D2, "hyb_save", "bin/hyb_save"), (D2, "hyb_load", "bin/hyb_load"),
                          (D, "hyb_save_up", "bin/hyb_save_up"),
                          (D, "hyb_load_up", "bin/hyb_load_up")):
            ad.shell(f"rm -f {d}/{b}")
            ad.push(f"{HYB}/{src}", f"{d}/{b}")
            ad.shell(f"chmod 755 {d}/{b}")
        print("SETUP_DONE")
        return
    rounds = [int(x) for x in sys.argv[2:]] if len(sys.argv) > 2 else \
        ([0] if mode == "sanity" else list(range(len(P))))
    res = load()
    for N in rounds:
        if res.get(str(N), {}).get("cosh0") is not None and mode == "batch":
            continue
        doze(f" r{N:02d}-start")
        rec = {}
        try:
            run_round(N, rec)
        except Exception as e:
            rec["err"] = str(e)[-250:]
            print(f"r{N:02d} ERR {rec['err']}", flush=True)
        res[str(N)] = {**res.get(str(N), {}), **rec}
        save(res)
        doze(f" r{N:02d}-end")
    res = load()
    done = [v for v in res.values() if v.get("cosh0") is not None]
    if len(done) == len(P):
        oks = sum(1 for v in done if v.get("ok"))
        c0 = sorted(v["cosh0"] for v in done)
        tt = sorted(v.get("ttft_hot_s") or 0 for v in done)
        ex = sorted(sum(s["exec"] for s in v["chain"].values()) / 1000
                    for v in done if v.get("chain"))
        print(f"NC128-JUDGE prompts={len(done)} ok={oks}/{len(P)} med_cosh0={c0[len(done)//2]} "
              f"med_exec={ex[len(ex)//2]:.2f}s med_ttft_hot={tt[len(tt)//2]}s "
              f"dec_h_total={sum(1 for v in done if v.get('dec_h') is not None)}")
        print("NC128_JUDGE_PASS" if oks >= 45 and c0[len(done) // 2] >= 0.97 else "NC128_JUDGE_FAIL")
    else:
        print(f"NC128-JUDGE incomplete: {len(done)}/{len(P)}")
    print("NC128_DONE")


main()
