#!/usr/bin/env python3
# [npu-line] MC App-side gate scaffold: hybrid vs pure-GPU TTFT + smoke (device window only).
# CONFIRM=1 env REQUIRED (refuses to run otherwise) — device is shared with judge batch.
# Flow: preflight (installed/debuggable/npu_m1 staging) -> enable hybrid via run-as prefs ->
# am start -> uiautomator-drive input+send (ASCII prompts only, IME-free) -> TTFT from logcat
# 'TongYiLite' stage lines -> restore prefs. Each prompt runs ON then OFF (A/B). TTFT parity
# reference = A6 §6.4 (172 tok: hybrid 4.94s vs GPU 9.05s). Red line: Dozing at entry/exit.
#   usage: CONFIRM=1 python -I run_mc_app_smoke.py [--prompt-file F] [--reps 2]
import sys, os, re, json, time, subprocess, argparse

if os.environ.get("CONFIRM") != "1":
    sys.exit("REFUSED: set CONFIRM=1 (device window; judge batch must be paused)")

sys.path.insert(0, "E:/MyLLM_exp/_repro/rb")
sys.stdout.reconfigure(encoding="utf-8", errors="replace")
from mcp5_94_adbsock import AdbSock

S = "<redacted-tailscale>:5555"
PKG = "com.dgxspark.tongyilite"
ACT = f"{PKG}/.MainActivity"
R_APP = f"/data/data/{PKG}/files/npu_m1"
HYB = "E:/MyLLM_exp/hyb"
LOG = HYB + "/mc_app_smoke.log"
ap = argparse.ArgumentParser()
ap.add_argument("--prompt-file", default=None)   # ASCII ~172-token prompt for A6 parity
ap.add_argument("--reps", type=int, default=2)
A = ap.parse_args()

ad = AdbSock(S)
results = {}


def doze(tag):
    x = ad.shell("dumpsys power | grep -m1 mWakefulness").strip()
    if "Awake" in x:
        ad.shell("input keyevent 223")
        x = ad.shell("dumpsys power | grep -m1 mWakefulness").strip()
    print(f"[wake {tag}] {x}", flush=True)
    assert "Dozing" in x or "Asleep" in x, f"screen stuck Awake at {tag}"


def sh(cmd):
    return ad.shell(cmd)


def runas(cmd):
    return sh(f"run-as {PKG} {cmd}")


def uiauto_find(text_re):
    """Return (x,y) center of first uiautomator node whose text/desc/content-desc matches."""
    sh("uiautomator dump /sdcard/ui.xml >/dev/null 2>&1")
    x = sh("cat /sdcard/ui.xml")
    for node in re.findall(r"<node[^>]*>", x):
        attrs = dict(re.findall(r'(\w[\w-]*)="([^"]*)"', node))
        blob = " ".join(attrs.get(k, "") for k in
                        ("text", "content-desc", "resource-id", "class"))
        if re.search(text_re, blob, re.I):
            b = attrs.get("bounds", "")
            m = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", b)
            if m:
                x1, y1, x2, y2 = map(int, m.groups())
                return ((x1 + x2) // 2, (y1 + y2) // 2)
    return None


def logcat_mark():
    sh("logcat -c")


def logcat_hyb(seconds):
    time.sleep(seconds)
    return sh(f"logcat -d -s TongYiLite:*")


def wake_for_ui():
    # input tap requires an awake+unlocked screen; permanent stay-on stays BANNED (burn-in
    # red line) — we wake just for driving and doze() at exit puts the panel to sleep.
    sh("input keyevent 224")
    time.sleep(1)
    sh("input swipe 500 1800 500 600")
    time.sleep(1)


def send_button():
    # Flutter IconButton semantics don't bubble (no text/desc on the send node — proven on
    # device). Anchor = rightmost clickable node in the SAME row as the EditText, x2>=900.
    sh("uiautomator dump /sdcard/ui.xml >/dev/null 2>&1")
    x = sh("cat /sdcard/ui.xml")
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
    # same row: vertical center within EditText's expanded band (keyboard may shift layout)
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
    # ASCII only — adb input text cannot drive Chinese IME (documented scaffold limit)
    esc = prompt.replace(" ", "%s").replace("&", "\\&").replace("<", "\\<").replace(">", "\\>")
    sh(f"input text '{esc}'")
    time.sleep(1)
    st = send_button()
    assert st, "send button not found (rightmost clickable in EditText row)"
    t0 = time.time()
    sh(f"input tap {st[0]} {st[1]}")
    return t0


SETTINGS = "app_flutter/inference_settings.json"  # path_provider documents dir on Android = app_flutter


def set_hybrid(on):
    # Settings are a JSON file (settings_service.dart save(): tmp+rename), NOT shared_prefs.
    # Read-modify-write while the app is stopped (App overwrites the whole file on UI save).
    sh(f"am force-stop {PKG}")
    # RACE (R5 lesson): the dying Dart process flushes settings on teardown and can land
    # AFTER our write, silently reverting the toggle (hybrid branch never entered, zero
    # fallback logs = branch short-circuited on a stale false). Wait for full teardown,
    # write, then verify twice with a gap to catch a late flush.
    time.sleep(3)
    import json as _json
    x = runas(f"cat {SETTINGS}")
    j = _json.loads(x)
    j["hybridPrefillEnabled"] = on
    ad.shell(f"run-as {PKG} sh -c 'cat > {SETTINGS}.tmp' <<'EOFJSON'\n{_json.dumps(j)}\nEOFJSON")
    runas(f"mv {SETTINGS}.tmp {SETTINGS}")
    for attempt in range(3):
        j2 = _json.loads(runas(f"cat {SETTINGS}"))
        if j2.get("hybridPrefillEnabled") == on:
            if attempt:
                print(f"[set_hybrid] toggle stuck after {attempt} rewrites, now OK", flush=True)
            break
        time.sleep(2)
        ad.shell(f"run-as {PKG} sh -c 'cat > {SETTINGS}.tmp' <<'EOFJSON'\n{_json.dumps(j)}\nEOFJSON")
        runas(f"mv {SETTINGS}.tmp {SETTINGS}")
    else:
        raise AssertionError(f"settings rewrite failed (late flush keeps reverting to {not on})")
    # Deterministic fresh conversation: move the sqlite conversation store aside (reversible
    # .bak) while stopped — otherwise reps accumulate context and TTFT A/B is skewed by
    # growing prefill (each rep would pay the previous reps' history).
    runas("mv databases/tongyilite.db databases/tongyilite.db.bak 2>/dev/null; "
          "mv databases/tongyilite.db-journal databases/tongyilite.db-journal.bak 2>/dev/null; true")
    sh("logcat -c")  # while stopped: model-ready poll below must not see the PREVIOUS boot's lines


def parse_stages(log):
    # Real hyb_jni LOGI formats (android/app/src/main/cpp/hyb_jni.cpp, on-device verified):
    #   "hyb feeds gguf: ok=1 hid=.. hd=.. vocab=.. theta=5000000.0 .."   (theta audit)
    #   "hyb prefill: feeds generated natively (chunks=.. s=.. .."
    #   "hyb prefill done: n_real=.. segs=3"
    #   "hyb decode: state loaded (N cells, X ms)"
    #   "hyb decode done: n_gen=.. stopped=.. text=.. chars"
    out = {}
    m = re.search(r"hyb feeds gguf: ok=(\d+).*?theta=([\d.]+)", log)
    if m:
        out["theta_ok"], out["theta"] = int(m.group(1)), float(m.group(2))
    for pat, key, cast in (
            (r"hyb prefill done: n_real=(\d+)", "n_real", int),
            (r"hyb decode: state loaded \(\d+ cells, (\d+) ms\)", "state_load_ms", int),
            (r"hyb decode done: n_gen=(\d+)", "n_gen", int)):
        m = re.search(pat, log)
        if m:
            out[key] = cast(m.group(1))
    out["hybrid_path"] = "hyb prefill done" in log
    return out


prompt = "Explain in three short points why prefill and decode have different bottlenecks. "
if A.prompt_file:
    prompt = open(A.prompt_file, encoding="utf-8").read().strip()
assert prompt.isascii(), "scaffold is ASCII-only (no Chinese IME via adb input text)"

doze("entry")
# preflight
assert "package:" in sh(f"pm path {PKG}"), "App not installed"
assert runas("id") and "uid" in runas("id"), "run-as failed (debug APK required)"
# filesDir is 0700 app uid — shell can't ls it; must go through run-as (proven on device)
n_ctx = runas("ls files/npu_m1/ 2>/dev/null | grep -c 'dec2p_l.*_ctx[.]bin' || true")
n_man = runas("ls files/npu_m1/ 2>/dev/null | grep -c manifest_pre2 || true")
n_llm = runas("ls app_flutter/models/ 2>/dev/null | grep -c 'minicpm5.*[.]gguf' || true")
print(f"preflight: ctx.bin={n_ctx.strip()} manifests={n_man.strip()} q4_gguf={n_llm.strip()} (expect 42 / 3 / 1)")
assert "42" in n_ctx and "1" in n_llm, "staging incomplete — run stage_app_assets.py + model copy"

for rep in range(A.reps):
    for on in (True, False):
        tag = f"rep{rep}_{'HYB' if on else 'GPU'}"
        set_hybrid(on)
        # Wake before start: MIUI doze-throttles a screen-off cold start so hard that the
        # load lands past any sane poll window (R3: Model loaded 22s after window close).
        # Screen-on here is transient UI driving, NOT svc power stayon (burn-in red line);
        # doze("exit") at the end puts the panel back to sleep.
        wake_for_ui()
        sh(f"am start -n {ACT}")
        # wait for model load (auto-load on boot since defaultModelId set): ~50s incl warmup.
        # logcat was cleared in set_hybrid while stopped, so we only see THIS boot.
        t_load = time.time()
        ready = False
        # MIUI cold start can take ~2.5 min before Dart even triggers load — window must
        # cover start->load-trigger latency plus the ~60s load+warmup (observed 21:41 round).
        while time.time() - t_load < 300:
            time.sleep(5)
            lg = sh("logcat -d -s TongYiLite:* flutter:* 2>/dev/null | tail -400")
            if "Model load result: true" in lg:
                ready = True
                break
        print(f"[{tag}] model-ready={ready} after {time.time()-t_load:.0f}s", flush=True)
        assert ready, f"{tag}: model never loaded"
        logcat_mark()
        t0 = tap_and_send(prompt)
        # TTFT = wall clock tap -> first reply text rendered in the conversation list.
        # CRITICAL (R4 lesson): a previous rep's reply is still on screen — the heuristic
        # hits at t+0s and every rep reports 4.3s. Baseline the on-screen reply set BEFORE
        # tap, and only texts NOT in the baseline count as the new reply.
        sh("uiautomator dump /sdcard/ui.xml >/dev/null 2>&1")
        base = set(re.findall(r'text="([^"]{40,})"', sh("cat /sdcard/ui.xml")))
        ttft = None
        reply_seen = ""
        t_deadline = t0 + 150
        while time.time() < t_deadline:
            time.sleep(2)
            sh("uiautomator dump /sdcard/ui.xml >/dev/null 2>&1")
            dump = sh("cat /sdcard/ui.xml")
            texts = re.findall(r'text="([^"]{40,})"', dump)
            for t in texts:
                if t in base:
                    continue
                t_clean = t.replace("&#10;", " ").replace("&amp;", "&")
                if t_clean[:40] not in prompt and prompt[:40] not in t_clean:
                    ttft = time.time() - t0
                    reply_seen = t_clean[:120]
                    break
            if ttft:
                break
        assert ttft is not None, f"{tag}: no NEW reply text in 150s (send dead or model stuck)"
        time.sleep(8)  # let generation run a bit further for n_gen/stages
        log = sh("logcat -d -s TongYiLite:* flutter:*")
        open(LOG, "a", encoding="utf-8").write(
            f"\n===== {tag} =====\n{log}\n")
        st = parse_stages(log)
        results[tag] = {"stages": st, "ttft_s_wall": ttft, "reply_head": reply_seen}
        print(tag, json.dumps(results[tag], ensure_ascii=False), flush=True)

set_hybrid(False)  # leave default-off (red line: feature ships disabled)
doze("exit")
json.dump(results, open(HYB + "/mc_app_smoke_results.json", "w"), indent=1)
print("MC_APP_SMOKE_DONE (human check: TTFT parity vs A6 6.4 table + reply text sanity)")
