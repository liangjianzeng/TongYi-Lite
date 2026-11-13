#!/usr/bin/env python3
# [npu-line M3-shell] App-embedded-adb hybrid smoke: App generates ids+d2q feeds natively
# (feedsOnly), pushes them over its own ADB client to the LOCAL adbd (127.0.0.1:5555, shell
# domain), runs the 3-seg chain there, pulls 84 KV, bridges + GPU-decodes in-process.
# CONFIRM=1 env REQUIRED (device window). Flow:
#   Phase A  tool reference on the SAME prompt: WSL gen_ids + prep77b (512 gear) -> tool
#            feeds/ids md5 + tool 3-seg chain run -> tool KV md5s (equiv baseline).
#   Phase B  App arms (uiautomator driven, same scaffold as mcp5_97 MC smoke):
#            HYB x2 (hybridPrefillEnabled + hybridViaShell)  -> determinism + TTFT + stages,
#            GPU x1 (both off)                                -> TTFT reference.
#   Phase C  verdict: light path = App feeds byte-equal tool feeds (12/12) AND device KV
#            equal tool KV (84/84) AND rep1==rep2 AND coherent reply; heavy path (feeds
#            differ -> App template/tokenizer diverged) = rev3b 3-arm judge on APP feeds
#            (GOLD hyb_save -ngl 99 / FLOOR hyb_save_up -ngl 0 / HYB bridged hyb_load),
#            gates cosh0>=0.95 / prefix-cos>=0.95 / decisive=0.
# Red lines: Dozing at entry/exit (transient wake only for UI driving, svc power stayon
# BANNED); settings restored off; nothing written outside E:/MyLLM_exp.
import sys, os, re, json, time, shutil, hashlib, subprocess, argparse

if os.environ.get("CONFIRM") != "1":
    sys.exit("REFUSED: set CONFIRM=1 (device window; no other batch running)")

sys.path.insert(0, "E:/MyLLM_exp/_repro/rb")
sys.stdout.reconfigure(encoding="utf-8", errors="replace")
from mcp5_94_adbsock import AdbSock
import numpy as np

S = "<redacted-tailscale>:5555"
PKG = "com.dgxspark.tongyilite"
ACT = f"{PKG}/.MainActivity"
R = "/data/local/tmp/npu_m1"
D = "/data/local/tmp/hybllm"
D2 = "/data/local/tmp/hybllm_dev"
Q4 = "/data/local/tmp/minicpm5-2b-q4k.gguf"
HYB = "E:/MyLLM_exp/hyb"
STAGE = "E:/wsl_stage"
REF = HYB + "/ref_m3s"
SETTINGS = "app_flutter/inference_settings.json"
PY = sys.executable
WSL = ["wsl.exe", "-d", "Ubuntu-22.04", "bash", "-lc"]
G, VOCAB, MARGIN = 64, 130560, 1.0
NCHUNK = 4
MANIFESTS = ["manifest_pre2_A", "manifest_pre2_B", "manifest_pre2_C"]
FEEDS = ["d2q_emb_0", "d2q_emb_1", "d2q_emb_2", "d2q_emb_3",
         "d2q_am_0", "d2q_am_1", "d2q_am_2", "d2q_am_3",
         "d2q_cos_table", "d2q_sin_table", "d2q_kc0", "d2q_vc0"]
KEYWORDS = ["prefill", "decode", "cache", "memory", "bandwidth", "token",
            "weight", "compute", "kv"]

ap = argparse.ArgumentParser()
ap.add_argument("--prompt-file", default=HYB + "/mc_app_prompt.txt")
ap.add_argument("--hyb-reps", type=int, default=2)
ap.add_argument("--skip-a", action="store_true", help="reuse REF/ref.json (Phase A already done)")
ap.add_argument("--no-gpu", action="store_true", help="skip GPU reference arm (forensics loop)")
A = ap.parse_args()

ad = AdbSock(S)
os.makedirs(REF, exist_ok=True)
os.makedirs(REF + "/kv", exist_ok=True)
results = {"stages": {}, "gates": {}, "judge": None}


def doze(tag):
    x = ad.shell("dumpsys power | grep -m1 mWakefulness").strip()
    if "Awake" in x:
        ad.shell("input keyevent 223")
        x = ad.shell("dumpsys power | grep -m1 mWakefulness").strip()
    print(f"[wake {tag}] {x.splitlines()[0] if x else '?'}", flush=True)
    assert "Dozing" in x or "Asleep" in x, f"screen stuck Awake at {tag}"


def sh(cmd):
    return ad.shell(cmd)


def runas(cmd):
    return sh(f"run-as {PKG} {cmd}")


def md5_local(p):
    return hashlib.md5(open(p, "rb").read()).hexdigest()


def md5_dev(p):
    x = sh(f"md5sum {p} 2>/dev/null")
    return x.strip().splitlines()[0].split()[0] if x and "md5sum" not in x.split()[0] else ""


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


def pull_logits(remote_abs, local):
    ad.pull(remote_abs, local)
    a = np.fromfile(local, dtype="<f2").reshape(-1, VOCAB).astype(np.float32)
    os.remove(local)
    ad.shell(f"rm -f {remote_abs}")
    return a


# ---------------------------------------------------------------- UI scaffold (97-proven)
def uiauto_dump():
    sh("uiautomator dump /sdcard/ui.xml >/dev/null 2>&1")
    return sh("cat /sdcard/ui.xml")


def uiauto_find(text_re):
    for node in re.findall(r"<node[^>]*>", uiauto_dump()):
        attrs = dict(re.findall(r'(\w[\w-]*)="([^"]*)"', node))
        blob = " ".join(attrs.get(k, "") for k in
                        ("text", "content-desc", "resource-id", "class"))
        if re.search(text_re, blob, re.I):
            m = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", attrs.get("bounds", ""))
            if m:
                x1, y1, x2, y2 = map(int, m.groups())
                return ((x1 + x2) // 2, (y1 + y2) // 2)
    return None


def wake_for_ui():
    sh("input keyevent 224")
    time.sleep(1)
    sh("input swipe 500 1800 500 600")
    time.sleep(1)


def send_button():
    x = uiauto_dump()
    ed = None
    cands = []
    for node in re.findall(r"<node[^>]*>", x):
        attrs = dict(re.findall(r'(\w[\w-]*)="([^"]*)"', node))
        b = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", attrs.get("bounds", ""))
        if not b:
            continue
        bb = list(map(int, b.groups()))
        if attrs.get("class") == "android.widget.EditText":
            ed = bb
        elif attrs.get("clickable") == "true" and bb[2] >= 900 and bb[0] > 800:
            cands.append(bb)
    if not ed or not cands:
        return None
    cy = (ed[1] + ed[3]) // 2
    row = [bb for bb in cands if abs((bb[1] + bb[3]) // 2 - cy) < 250] or cands
    bb = max(row, key=lambda v: v[2])
    return ((bb[0] + bb[2]) // 2, (bb[1] + bb[3]) // 2)


def tap_and_send(prompt):
    wake_for_ui()
    pt = uiauto_find(r"edittext")
    assert pt, "input field not found via uiautomator"
    sh(f"input tap {pt[0]} {pt[1]}")
    time.sleep(1)
    esc = prompt.replace(" ", "%s").replace("&", "\\&").replace("<", "\\<").replace(">", "\\>")
    sh(f"input text '{esc}'")
    time.sleep(1)
    st = send_button()
    assert st, "send button not found"
    t0 = time.time()
    sh(f"input tap {st[0]} {st[1]}")
    return t0


def set_hybrid(hyb_on, shell_on):
    sh(f"am force-stop {PKG}")
    time.sleep(3)  # R5 lesson: wait for the dying Dart teardown flush before writing
    x = runas(f"cat {SETTINGS}")
    j = json.loads(x)
    j["hybridPrefillEnabled"] = hyb_on
    j["hybridViaShell"] = shell_on
    for attempt in range(3):
        ad.shell(f"run-as {PKG} sh -c 'cat > {SETTINGS}.tmp' <<'EOFJSON'\n{json.dumps(j)}\nEOFJSON")
        runas(f"mv {SETTINGS}.tmp {SETTINGS}")
        j2 = json.loads(runas(f"cat {SETTINGS}"))
        if j2.get("hybridPrefillEnabled") == hyb_on and j2.get("hybridViaShell") == shell_on:
            if attempt:
                print(f"[set_hybrid] stuck after {attempt} rewrites, now OK", flush=True)
            break
        time.sleep(2)
    else:
        raise AssertionError("settings rewrite failed (late flush keeps reverting)")
    # deterministic fresh conversation per arm (reversible .bak), like 97
    runas("mv databases/tongyilite.db databases/tongyilite.db.bak 2>/dev/null; "
          "mv databases/tongyilite.db-journal databases/tongyilite.db-journal.bak 2>/dev/null; true")
    sh("logcat -c")


def parse_stages(log):
    out = {}
    for m in re.finditer(r"\[HybridShell\]\[T\] stage=(\S+) ms=(\d+)", log):
        out[m.group(1)] = int(m.group(2))
    m = re.search(r"hyb prefill\(feedsOnly\): n_real=(\d+)", log)
    if m:
        out["n_real_native"] = int(m.group(1))
    m = re.search(r"shell 域混合完成 nReal=(\d+)", log)
    if m:
        out["n_real"] = int(m.group(1))
    m = re.search(r"hyb decode done: n_gen=(\d+)", log)
    if m:
        out["n_gen"] = int(m.group(1))
    out["shell_done"] = "shell 域混合完成" in log
    out["feeds_only_ok"] = "feeds staged locally for shell-domain" in log
    out["fell_back"] = "回退纯 GPU" in log
    out["chat_hyb_ok"] = "[ChatNotifier][Hybrid] 成功" in log
    return out


def app_arm(tag, hyb_on, shell_on, prompt, need_kv_snapshot=False):
    set_hybrid(hyb_on, shell_on)
    wake_for_ui()
    sh(f"am start -n {ACT}")
    t_load = time.time()
    ready = False
    while time.time() - t_load < 300:
        time.sleep(5)
        lg = sh("logcat -d -s TongYiLite:* llama:* flutter:* 2>/dev/null | tail -400")
        if "Model load result: true" in lg:
            ready = True
            break
    print(f"[{tag}] model-ready={ready} after {time.time()-t_load:.0f}s", flush=True)
    assert ready, f"{tag}: model never loaded"
    sh("logcat -c")
    t0 = tap_and_send(prompt)
    sh("uiautomator dump /sdcard/ui.xml >/dev/null 2>&1")
    base = set(re.findall(r'text="([^"]{40,})"', sh("cat /sdcard/ui.xml")))
    ttft, reply_nodes = None, []
    while time.time() - t0 < 180:
        time.sleep(2)
        dump = uiauto_dump()
        for t in re.findall(r'text="([^"]{40,})"', dump):
            if t in base:
                continue
            t_clean = t.replace("&#10;", " ").replace("&amp;", "&")
            if t_clean[:40] not in prompt and prompt[:40] not in t_clean:
                ttft = time.time() - t0
                reply_nodes = [t_clean]
                break
        if ttft:
            break
    assert ttft is not None, f"{tag}: no NEW reply text in 180s"
    time.sleep(10)  # let decode finish for n_gen + stage lines
    # full reply = all new long texts (flutter renders the hybrid turn in one bubble)
    dump = uiauto_dump()
    reply_nodes = [t.replace("&#10;", " ").replace("&amp;", "&")
                   for t in re.findall(r'text="([^"]{40,})"', dump) if t not in base]
    log = sh("logcat -d -s TongYiLite:* llama:* flutter:*")
    open(HYB + "/m3s_app_smoke.log", "a", encoding="utf-8").write(f"\n===== {tag} =====\n{log}\n")
    st = parse_stages(log)
    snap = None
    if need_kv_snapshot:
        snap = {
            "feeds": {f: md5_dev(f"{R}/{f}.raw") for f in FEEDS},
            "ids": md5_dev(f"{R}/ids.raw"),
            "kv": {},
            "chain_logs": {k: ((sh(f"grep -a CR5_DONE {R}/p{k}.log 2>/dev/null").strip().splitlines() or [""])[-1])
                           for k in range(3)},
        }
        for i in range(42):
            for t in ("kc", "vc"):
                snap["kv"][f"d2q_{t}_{i}.raw"] = md5_dev(f"{R}/d2q_{t}_{i}.raw")
    results["stages"][tag] = st
    results[tag] = {"ttft_s_wall": round(ttft, 2), "reply_join_len": sum(len(x) for x in reply_nodes),
                    "reply_head": (reply_nodes[0][:160] if reply_nodes else ""),
                    "reply_nodes": reply_nodes}
    print(tag, json.dumps(results["stages"][tag], ensure_ascii=False),
          f"ttft={ttft:.2f}s len={sum(len(x) for x in reply_nodes)}", flush=True)
    return snap


# ------------------------------------------------------------------- Phase A: tool reference
prompt = open(A.prompt_file, encoding="utf-8").read().strip()
assert prompt.isascii(), "scaffold is ASCII-only (adb input text)"
doze("entry")

if A.skip_a and os.path.exists(REF + "/ref.json"):
    rj = json.load(open(REF + "/ref.json", encoding="utf-8"))
    real_tool, ref_feed_md5 = rj["real"], rj["feeds"]
    ref_ids_md5, ref_kv_md5, tool_chain = rj["ids"], rj["kv"], rj["chain"]
    print(f"== Phase A skipped (ref real={real_tool})", flush=True)
else:
    print("== Phase A: tool reference (WSL 512-gear prep + device 3-seg chain)", flush=True)
    os.makedirs(STAGE, exist_ok=True)
    pf = f"{STAGE}/prompt_m3s.txt"
    open(pf, "w", encoding="utf-8").write(prompt)
    o1 = wsl("cd /mnt/e/MyLLM_exp/hyb && python3 gen_ids.py", pf)
    m = re.search(r"real_tokens (\d+)", o1.stdout)
    assert m, "gen_ids: " + (o1.stdout + o1.stderr)[-250:]
    real_tool = int(m.group(1))
    o2 = wsl("cd /mnt/e/MyLLM_exp/hyb && python3 mcp5_77b_pre2_prep.py", pf)
    assert "PREP77_DONE" in o2.stdout, "prep: " + (o2.stdout + o2.stderr)[-250:]
    ref_feed_md5 = {f: md5_local(f"{STAGE}/{f}.raw") for f in FEEDS}
    shutil.copyfile(HYB + "/ids.raw", f"{REF}/ids_tool.raw")
    ref_ids_md5 = md5_local(f"{REF}/ids_tool.raw")
    print(f"tool ref: real={real_tool} ids_md5={ref_ids_md5}", flush=True)

    # tool chain run (hardened protocol, mirrors mcp5_98 seg_chain128 for the 512 gear)
    sh("pkill -f 'chain_[r]un5' 2>/dev/null; true")
    for f in FEEDS:
        ad.push(f"{STAGE}/{f}.raw", f"{R}/{f}.raw")
    sh(f"rm -f {R}/d2q_h_l*_* {R}/d2q_knew_* {R}/d2q_vnew_* {R}/d2q_kc_*.raw {R}/d2q_vc_*.raw "
       f"{R}/p0.log {R}/p1.log {R}/p2.log")
    ad.push(f"{REF}/ids_tool.raw", f"{R}/ids_tool.raw")
    sh(f"cd {R} && for i in $(seq 0 41); do cp d2q_kc0.raw d2q_kc_$i.raw; "
       f"cp d2q_vc0.raw d2q_vc_$i.raw; done")
    tool_chain = {}
    for k, man in enumerate(MANIFESTS):
        started = False
        for attempt in range(3):
            sh(f"rm -f {R}/p{k}.log")
            sh(f"cd {R} && export LD_LIBRARY_PATH={R}/lib ADSP_LIBRARY_PATH={R}/lib && "
               f"CHAIN_KEEP=1 CR5_ROLL_SAVE=1 nohup ./chain_run5 {man} {NCHUNK} "
               f"> p{k}.log 2>&1 </dev/null & sleep 1; touch {R}/p{k}.log; echo SPAWNED_{k}")
            for _ in range(5):
                time.sleep(3)
                if "1" in sh(f"grep -ac 'CR5 segs=' {R}/p{k}.log 2>/dev/null || echo 0").strip().splitlines()[-1]:
                    started = True
                    break
            if started:
                break
            sh("pkill -f 'chain_[r]un5' 2>/dev/null || true")
            time.sleep(3)
        assert started, f"tool chain seg {k} never spawned"
        done = False
        death = 0
        for t in range(120):
            c = sh(f"grep -ac CR5_DONE {R}/p{k}.log 2>/dev/null || echo 0").strip().splitlines()[-1]
            h = sh(f"grep -ac 'CR5 segs=' {R}/p{k}.log 2>/dev/null || echo 0").strip().splitlines()[-1]
            if "1" in c and "1" in h:
                done = True
                break
            try:
                alive = int(sh("pgrep -f 'chain_[r]un5' | wc -l").strip().splitlines()[-1])
            except (ValueError, IndexError):
                alive = 1
            death = death + 1 if (alive == 0 and t > 8) else 0
            if death >= 3:
                break
            time.sleep(5)
        assert done, f"tool chain seg {k} not done; tail: {sh(f'tail -3 {R}/p{k}.log')[-200:]}"
        nh = int(sh(f"ls {R}/d2q_h_l*_* 2>/dev/null | wc -l").strip().splitlines()[-1])
        assert nh == 14 * NCHUNK * (k + 1), f"tool seg {k} h dumps {nh} != {14*NCHUNK*(k+1)}"
        dl = sh(f"grep -a CR5_DONE {R}/p{k}.log").strip().splitlines()[-1]
        mm = re.search(r"wall=([\d.]+) ms.*exec=([\d.]+)", dl)
        tool_chain[k] = {"wall_ms": float(mm.group(1)), "exec_ms": float(mm.group(2))}
        print(f"tool seg {k}: wall={tool_chain[k]['wall_ms']:.0f}ms exec={tool_chain[k]['exec_ms']:.0f}ms", flush=True)
    ref_kv_md5 = {}
    for i in range(42):
        for t in ("kc", "vc"):
            name = f"d2q_{t}_{i}.raw"
            ad.pull(f"{R}/{name}", f"{REF}/kv/{name}")
            ref_kv_md5[name] = md5_local(f"{REF}/kv/{name}")
    sh("pkill -f 'chain_[r]un5' 2>/dev/null || true")
    json.dump({"real": real_tool, "feeds": ref_feed_md5, "ids": ref_ids_md5,
               "kv": ref_kv_md5, "chain": tool_chain},
          open(REF + "/ref.json", "w"), indent=1)

# ----------------------------------------------------------------------- Phase B: App arms
print("== Phase B: App arms", flush=True)
snap = None
replies = []
for rep in range(A.hyb_reps):
    s = app_arm(f"HYB{rep}", True, True, prompt, need_kv_snapshot=(rep == 0))
    if rep == 0:
        snap = s
    replies.append(" ".join(results[f"HYB{rep}"]["reply_nodes"]))
if not A.no_gpu:
    app_arm("GPU0", False, False, prompt)
set_hybrid(False, False)
doze("exit")

# ----------------------------------------------------------------------- Phase C: verdict
app_feeds_ok = snap and all(snap["feeds"][f] == ref_feed_md5[f] for f in FEEDS)
app_ids_ok = snap and snap["ids"] == ref_ids_md5
app_kv_ok = snap and all(snap["kv"][k] == ref_kv_md5[k] for k in ref_kv_md5)
n_kv_eq = sum(1 for k in ref_kv_md5 if snap and snap["kv"].get(k) == ref_kv_md5[k])
det = (A.hyb_reps >= 2 and replies[0] == replies[1] and len(replies[0]) > 40)
reply_low = replies[0].lower()
coherent = (len(replies[0]) >= 120
            and sum(kw in reply_low for kw in KEYWORDS) >= 3)
hyb_markers = all(results["stages"].get(f"HYB{r}", {}).get("shell_done")
                  and results["stages"][f"HYB{r}"].get("chat_hyb_ok")
                  and not results["stages"][f"HYB{r}"].get("fell_back")
                  for r in range(A.hyb_reps))
gpu_clean = not any(results["stages"].get("GPU0", {}).get(k)
                    for k in ("shell_done", "feeds_only_ok"))
nreal = results["stages"].get("HYB0", {}).get("n_real")

gates = {"feeds_equiv": bool(app_feeds_ok), "ids_equiv": bool(app_ids_ok),
         "kv_equiv": bool(app_kv_ok), "kv_eq_count": f"{n_kv_eq}/84",
         "determinism": bool(det), "coherent": bool(coherent),
         "hybrid_markers": bool(hyb_markers), "gpu_arm_clean": bool(gpu_clean),
         "nreal_match_tool": (nreal == real_tool)}
# nreal==tool 是信息位（App chat 模板与 gen_ids 有已知差异，2026-11-13 实测
# 191 vs 183）——轻门要求字节等价时它自然蕴含；重门以 rev3b 判卷为正确性权威，
# 不在这里预设相等，否则模板分歧场景下重门永不可达。
verdict = hyb_markers and gpu_clean and det and coherent

if verdict and app_feeds_ok and app_kv_ok:
    gates["path"] = "light"
elif verdict:
    # heavy path: App template/tokenizer diverged -> rev3b 3-arm judge on APP feeds
    print("== Phase C heavy path: rev3b judge on App feeds", flush=True)
    gates["path"] = "heavy"
    kvdir = HYB + "/npu_kv_m3s"
    os.makedirs(kvdir, exist_ok=True)
    for i in range(42):
        for t in ("kc", "vc"):
            name = f"d2q_{t}_{i}.raw"
            ad.pull(f"{R}/{name}", f"{kvdir}/{name}")
    ad.pull(f"{R}/ids.raw", f"{HYB}/ids_m3s.raw")
    real = nreal or real_tool
    be = dict(os.environ)
    be.update({"BRIDGE_VER": "4", "NPU_VER": "4", "NPU_NC": "512", "NPU_PFX": "d2q",
               "NPU_KV_DIR": kvdir, "NPU_IDS": f"{HYB}/ids_m3s.raw"})
    ob = subprocess.run([PY, "-I", HYB + "/kv_bridge.py", "copy",
                         f"{HYB}/bridged_m3s.state", str(real)],
                        capture_output=True, text=True,
                        encoding="utf-8", errors="replace", env=be)
    assert "BRIDGE_OK" in ob.stdout, "bridge: " + (ob.stdout + ob.stderr)[-200:]
    ad.push(f"{HYB}/ids_m3s.raw", f"{D2}/idsm3s.raw")
    ad.push(f"{HYB}/ids_m3s.raw", f"{D}/idsm3s.raw")
    sh(f"rm -f {D2}/bridged_m3s.state")
    ad.push(f"{HYB}/bridged_m3s.state", f"{D2}/bridged_m3s.state")
    gold = (f"cd {D2} && LD_LIBRARY_PATH=. ./hyb_save -m {Q4} -f idsm3s.raw "
            f"-o gdm3.state -n {real} -g {G} -p 88 -ngl 99 -L lgm3_g.raw 2>&1 "
            f"| grep -aE 'PREFILL|^T |first_tok|FAIL'")
    floor = (f"cd {D} && LD_LIBRARY_PATH=. ./hyb_save_up -m {Q4} -f idsm3s.raw "
             f"-o fum3.state -n {real} -g {G} -p 88 -ngl 0 -L lgm3_u.raw 2>&1 "
             f"| grep -aE 'PREFILL|^T |first_tok|FAIL'")
    hyb = (f"cd {D2} && LD_LIBRARY_PATH=. ./hyb_load -m {Q4} -s bridged_m3s.state "
           f"-t {{first}} -n {real} -g {G} -ngl 99 -L lgm3_h.raw 2>&1 "
           f"| grep -aE 'STATE_LOADED|load_ms|FIRST_TOK_MS|^T |FAIL'")
    og = sh(gold)
    first = next((int(l.split("first_tok=")[1]) for l in og.splitlines() if "first_tok=" in l), -1)
    assert first >= 0, "gold: " + og[-250:]
    ou = sh(floor)
    oh = sh(hyb.replace("{first}", str(first)))
    assert "STATE_LOADED" in oh, "load: " + oh[-250:]
    gsr, usr, hsr = series(og), series(ou), series(oh)
    lg = pull_logits(f"{D2}/lgm3_g.raw", f"{HYB}/lgm3_g.tmp")
    lu = pull_logits(f"{D}/lgm3_u.raw", f"{HYB}/lgm3_u.tmp")
    lh = pull_logits(f"{D2}/lgm3_h.raw", f"{HYB}/lgm3_h.tmp")
    nsteps = min(len(lg), len(lu), len(lh), len(gsr), len(usr), len(hsr), G)
    lg, lu, lh = lg[:nsteps], lu[:nsteps], lh[:nsteps]
    gsr, usr, hsr = gsr[:nsteps], usr[:nsteps], hsr[:nsteps]
    cosh = [cs(lg[i], lh[i]) for i in range(nsteps)]
    marg = [float(np.partition(lg[i], -2)[-1] - np.partition(lg[i], -2)[-2]) for i in range(nsteps)]
    lcp_h = next((i for i in range(nsteps) if hsr[i] != gsr[i]), nsteps)
    pre = cosh[:lcp_h]
    dec_h = lcp_h if (lcp_h < nsteps and marg[lcp_h] >= MARGIN) else None
    results["judge"] = {"first": first, "steps": nsteps, "lcp_h": lcp_h,
                        "cosh0": round(cosh[0], 4),
                        "prefix_cos_min": round(min(pre), 4) if pre else None,
                        "dec_h": dec_h}
    gates["judge_ok"] = (cosh[0] >= 0.95 and (not pre or min(pre) >= 0.95) and dec_h is None)
    verdict = bool(gates["judge_ok"])
else:
    gates.setdefault("path", "failed")

ttfts = {t: results[t]["ttft_s_wall"] for t in results if t in ("HYB0", "HYB1", "GPU0")}
gates["ttft"] = ttfts
gates["chain_wall_ms_tool"] = {k: v["wall_ms"] for k, v in tool_chain.items()}
results["gates"] = gates
json.dump(results, open(HYB + "/m3s_results.json", "w"), ensure_ascii=False, indent=1)
print(json.dumps(gates, ensure_ascii=False, indent=1), flush=True)
print("M3SHELL_SMOKE_" + ("PASS" if verdict else "FAIL"), flush=True)
