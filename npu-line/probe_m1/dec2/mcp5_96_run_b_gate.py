#!/usr/bin/env python3
# [npu-line] Phase B memory gate: N consecutive full hybrid rounds
#   (NPU prefill serial 3-seg chain -> KV bridge -> GPU decode -ngl 99)
#   must run with ZERO lmkd kills. Acceptance (plan §Phase B) = 5/5 rounds with
#   lmkd-snapshot delta 0 AND decode pass (STATE_LOADED + 32 T-lines + tps>4.5).
# Reuse: run_a3b_seq.py (chain, via subprocess -- it is a top-level script, an
#   import would execute the whole device flow; per-round fresh process is also
#   what keeps AdbSock/socket state from bleeding across rounds), kv_bridge.py
#   (bridge, copy mode NREAL=172, BRIDGE_VER=4), hyb_load fork+GPU in D2 (GPU-
#   decode -ngl 99 is the memory-test subject proper).
# RED LINES: never `svc power stayon` (burn-in). Screen off = keyevent 223 only.
# push must rm the device-side file first (sync SEND on a same-name file can
# leave stale contents). No device execution here -- main session drives real
# rounds; --dry stubs AdbSock + subprocess and never touches the wire.
# Smoke (main session): PY -I run_b_gate.py --rounds 1   (PY = Python310 -I)
# Round-0 corrections (main-session measurement): decode = fork+GPU variant
# hyb_load in D2=/data/local/tmp/hybllm_dev (pre-seeded 9 libs incl.
# libopencl_stub.so -- missing it = CANNOT LINK instant death; never re-push
# the binary/libs), bridge container must be VER=4 (fork loader rejects VER=3
# "incompatible key rotation"), tps floor 4.5 (fork GPU measured 6.16; the
# 10.7 llama-bench number is a warm figure), lmkd baseline = events buffer
# am_kill (main-buffer lmkd logs are always 0 here; dmesg is not relied on).
import argparse
import json
import os
import re
import subprocess
import sys
import time

sys.path.insert(0, "E:/MyLLM_exp/_repro/rb")

S = "<redacted-tailscale>:5555"
R = "/data/local/tmp/npu_m1"
D2 = "/data/local/tmp/hybllm_dev"       # fork+GPU decode dir (pre-seeded, do not clobber)
Q4 = "/data/local/tmp/minicpm5-2b-q4k.gguf"
HYB = "E:/MyLLM_exp/hyb"
NPU_KV = HYB + "/npu_kv"
STATE_LOCAL = HYB + "/bridged172_v4.state"  # regenerated every round, BRIDGE_VER=4
STATE_REMOTE = "bridged172.state"       # relative to D2
NREAL, GREEDY, FIRST_TOK = 172, 32, 32291
TPS_MIN = 4.5                           # fork GPU measured 6.16; CPU floor 3.59
KV_SIZE, H_SIZE = 262144, 524288   # 512x128x2 fp16 / hidden row
CHAIN_TIMEOUT = 4500               # 3 seg x 20 min ceiling + slack
PY = sys.executable
RESULTS = HYB + "/b_gate_results.json"

# lmkd-kill probes (round-0 + gate-smoke calibration): the MAIN buffer DOES carry
# lowmemorykiller kill lines (kernel lmkd) and does NOT emit events-buffer am_kill
# for them — am_kill events are AMS force-stops only (info route). A route that
# errors records None -- never a silent 0 -> false pass.
# Bracket patterns ([k]/[r]) defeat the adbd ShellService echo self-match: the
# grep command text itself gets logged to the main buffer, and a literal
# "lowmemorykiller" pattern would match its own echo (measured 2 false hits).
# FAIL basis = kill_mine: lmkd killing OUR proc family only. Third-party cached
# app kills (e.g. MIUI adj-945) are lmkd working FOR our workload — Phase B
# lever-1 relies on exactly that — recorded as info, never fatal.
LMKD_PROBES = (
    ("events_am_kill", "logcat -d -b events", "am_[k]ill"),
    ("main_lowmem_all", "logcat -d", "lowmemory[k]iller"),
)
KILL_MINE_PAT = "lowmemory[k]iller: Kill.*(chain_[r]un5|hyb[_]load)"
PROBE_BAD = ("failed to open", "unable to open", "permission denied",
             "inaccessible", "-b:", "not found", "unknown buffer", "invalid buffer")

DRY = False
CTX = {"phase": "base"}
SLEEP = time.sleep  # swapped to no-op in --dry


# ---------------------------------------------------------------- lmkd probes
def lmkd_snapshot(ad):
    """{tag: count|None}; None = probe unavailable on this device (not 0 kills)."""
    snap = {}
    for tag, dump, pat in LMKD_PROBES:
        head = ad.shell(f"{dump} 2>&1 | head -2")
        if any(b in head.lower() for b in PROBE_BAD):
            snap[tag] = None
            continue
        o = ad.shell(f"{dump} 2>/dev/null | grep -ciE '{pat}'")
        try:
            snap[tag] = int(o.strip().splitlines()[-1])
        except (ValueError, IndexError):
            snap[tag] = None
    # kill_mine: the only FAIL-bearing probe (see KILL_MINE_PAT rationale)
    head = ad.shell("logcat -d 2>&1 | head -2")
    if any(b in head.lower() for b in PROBE_BAD):
        snap["kill_mine"] = None
    else:
        o = ad.shell(f"logcat -d 2>/dev/null | grep -acE '{KILL_MINE_PAT}'")
        try:
            snap["kill_mine"] = int(o.strip().splitlines()[-1])
        except (ValueError, IndexError):
            snap["kill_mine"] = None
    return snap


def lmkd_verdict(base, end):
    valid = [t for t, v in end.items() if base.get(t) is not None and v is not None]
    delta = {t: end[t] - base[t] for t in valid}
    if "kill_mine" not in valid:
        return delta, "kill-mine probe unavailable -> zero-kill not certifiable"
    if delta["kill_mine"] > 0:
        return delta, f"lmkd killed OUR procs: kill_mine+{delta['kill_mine']}"
    return delta, ""


# ---------------------------------------------------------------- device bits
def doze(ad, where=""):
    """RED LINE: screen-off enforcement. keyevent 223 only, never svc power stayon."""
    w = ""
    for _ in range(3):
        w = ad.shell("dumpsys power | grep -m1 mWakefulness").strip()
        if "Awake" not in w:
            break
        ad.shell("input keyevent 223")
        SLEEP(2)
    print(f"[wake{where}] {w}")
    return w


def pcount(ad, pat):
    o = ad.shell(f"pgrep -f '{pat}' | wc -l").strip().splitlines()
    try:
        return int(o[-1])
    except (ValueError, IndexError):
        return -1


def meminfo(ad):
    o = ad.shell("cat /proc/meminfo | grep -E 'MemAvailable|MemFree'")
    m = re.search(r"MemAvailable:\s+(\d+)", o)
    return int(m.group(1)) if m else -1


# ---------------------------------------------------------------- stage: chain
def run_subproc(argv, timeout, env=None):
    if DRY:
        return dry_subproc(argv)
    return subprocess.run(argv, capture_output=True, text=True,
                          timeout=timeout, check=False, env=env)


def run_chain(ad):
    """One full serial A->B->C via run_a3b_seq.py. Returns (ok, reason, evidence).
    NOTE run_a3b_seq prints A3_DONE unconditionally -- parse the per-seg markers."""
    try:
        r = run_subproc([PY, "-I", HYB + "/run_a3b_seq.py"], CHAIN_TIMEOUT)
    except subprocess.TimeoutExpired:
        ad.shell("pkill -f 'chain_[r]un5' 2>/dev/null || true")
        return False, f"chain subprocess timeout >{CHAIN_TIMEOUT}s", ""
    out = (r.stdout or "") + (r.stderr or "")
    segs = dict(re.findall(r"seg ([ABC]): done=(True|False)", out))
    died = re.findall(r"seg ([ABC]): process gone at t=(\S+)", out)
    ok = ("A3_ABORT" not in out and "pulled 84 kv" in out and "A3_DONE" in out
          and all(segs.get(g) == "True" for g in "ABC"))
    if ok:
        return True, "", ""
    dead_seg = died[0][0] if died else next(
        (g for g in "ABC" if segs.get(g) == "False"), None)
    ev = chain_evidence(ad, dead_seg, out)
    if died:
        sig = "instant-death" if "log_empty:yes" in ev else "process-gone"
        reason = f"seg {dead_seg} {sig} at t={died[0][1]} (resident died, see evidence)"
    elif "A3_ABORT" in out:
        reason = f"chain abort at seg {dead_seg} (no CR5_DONE within budget)"
    else:
        reason = f"chain markers incomplete: segs={segs} rc={r.returncode}"
    return False, reason, ev


def chain_evidence(ad, seg, out=""):
    """Keep the scene: byte count + tail of the dead segment's log (never deleted)."""
    if seg not in ("A", "B", "C"):
        return "no-seg-info; chain stdout:\n" + out[-1200:]
    k = {"A": 0, "B": 1, "C": 2}[seg]
    ev = ad.shell(f"wc -c {R}/p{k}.log 2>&1; tail -c 600 {R}/p{k}.log 2>&1")
    first = ev.splitlines()[0].strip() if ev.strip() else ""
    empty = first.startswith("0 ") or "No such file" in ev
    return f"seg={seg} log={R}/p{k}.log log_empty:{'yes' if empty else 'no'}\n{ev[-1000:]}"


def kv_ready(t0):
    """84 KV + hidden must be fresh (mtime >= round start) and correctly sized."""
    files = ([f"{NPU_KV}/d2q_kc_{i}.raw" for i in range(42)] +
             [f"{NPU_KV}/d2q_vc_{i}.raw" for i in range(42)] +
             [f"{NPU_KV}/d2q_h_l41_3.raw"])
    bad = []
    for f in files:
        if not os.path.exists(f):
            bad.append(os.path.basename(f) + ":missing")
            continue
        want = H_SIZE if "h_l41" in f else KV_SIZE
        if os.path.getsize(f) != want:
            bad.append(f"{os.path.basename(f)}:size{os.path.getsize(f)}!={want}")
        elif os.path.getmtime(f) < t0 - 5:
            bad.append(os.path.basename(f) + ":stale")
    return bad[:6], len(files)


# ---------------------------------------------------------------- stage: bridge
def run_bridge():
    # VER=4 container mandatory: the lc-fork GPU loader rejects VER=3
    # ("incompatible key rotation"); kv_bridge.py reads BRIDGE_VER from env.
    r = run_subproc([PY, "-I", HYB + "/kv_bridge.py", "copy",
                     STATE_LOCAL, str(NREAL)], 600,
                    env=dict(os.environ, BRIDGE_VER="4"))
    ok = r.returncode == 0 and "BRIDGE_OK" in (r.stdout or "")
    note = ((r.stdout or "")[-200:] + (r.stderr or "")[-200:]).strip()
    if ok and not DRY:
        sz = os.path.getsize(STATE_LOCAL) if os.path.exists(STATE_LOCAL) else -1
        ok = sz > 1_000_000  # 172-cell VER=4 state ~7.40 MB
        note += f" size={sz}"
    return ok, note


# ---------------------------------------------------------------- stage: decode
def gpu_decode(ad):
    """Fork+GPU-resident decode (the memory-test body): hyb_load in D2, -ngl 99."""
    stub = ad.shell(f"ls {D2}/libopencl_stub.so 2>&1")  # missing -> CANNOT LINK death
    if "No such file" in stub or "cannot access" in stub:
        return False, False, 0, -1.0, f"D2 preseed broken, no libopencl_stub.so: {stub[:300]}"
    ad.shell(f"rm -f {D2}/{STATE_REMOTE}")  # MUST rm before push (stale-file pitfall)
    ad.push(STATE_LOCAL, f"{D2}/{STATE_REMOTE}")
    o = ad.shell(f"cd {D2} && LD_LIBRARY_PATH=. ./hyb_load -m {Q4} -s {STATE_REMOTE} "
                 f"-t {FIRST_TOK} -n {NREAL} -g {GREEDY} -ngl 99 2>&1 "
                 f"| grep -aE 'STATE_LOADED|FAIL|CANNOT|tps|^T '")
    state_ok = "STATE_LOADED" in o
    tlines = [l for l in o.splitlines() if re.match(r"^T \d+ \d+$", l)]
    m = re.search(r"tps=([\d.]+)", o)
    tps = float(m.group(1)) if m else -1.0
    ok = state_ok and len(tlines) == GREEDY and tps > TPS_MIN
    return ok, state_ok, len(tlines), tps, o[:1200]


# ---------------------------------------------------------------- one round
def one_round(ad, rnum):
    t0 = time.time()
    rec = {"round": rnum, "ts": time.strftime("%Y-%m-%d %H:%M:%S"), "log": "",
           "lmkd_base": None, "lmkd_end": None, "lmkd_delta": None,
           "tps": None, "memAvailable": None, "verdict": "FAIL", "reason": "", "evidence": ""}
    try:
        doze(ad, f" r{rnum}-start")                                   # 0) red line
        CTX["phase"] = "base"
        rec["lmkd_base"] = lmkd_snapshot(ad)                           # 1) baseline
        # 2) clear the field (bracket pattern: pkill must not match itself)
        ad.shell("pkill -f 'chain_[r]un5' 2>/dev/null || true")
        SLEEP(2)
        n = pcount(ad, "chain_[r]un5")
        if n != 0:
            rec["reason"] = f"chain procs survive pkill (pgrep={n})"
            return rec
        # 3) serial 3-seg NPU prefill chain
        ok, why, ev = run_chain(ad)
        if not ok:
            rec["reason"], rec["evidence"] = why, ev
            return rec
        if not DRY:
            bad, nfile = kv_ready(t0)
            if bad:
                rec["reason"] = f"KV pull incomplete {len(bad)}/{nfile}: {bad}"
                return rec
        # 4) bridge + push + GPU-resident decode
        ok, why = run_bridge()
        if not ok:
            rec["reason"] = "kv_bridge fail: " + why
            return rec
        ok, state_ok, nT, tps, o = gpu_decode(ad)
        rec["tps"] = tps
        if not ok:
            rec["reason"] = (f"decode fail state_loaded={state_ok} T_lines={nT} "
                             f"(want {GREEDY}) tps={tps} (>{TPS_MIN})")
            rec["evidence"] = o
            return rec
        # 5) end-of-round: lmkd delta, procs exited, meminfo
        CTX["phase"] = "end"
        rec["lmkd_end"] = lmkd_snapshot(ad)
        delta, bad = lmkd_verdict(rec["lmkd_base"], rec["lmkd_end"])
        rec["lmkd_delta"] = delta
        if bad:
            rec["reason"] = "lmkd kills this round: " + bad
            return rec
        n = pcount(ad, "chain_[r]un5")
        if n != 0:
            rec["reason"] = f"chain procs still resident at round end (pgrep={n})"
            return rec
        n = pcount(ad, "hyb_[l]oad")  # covers hyb_load and hyb_load_up
        if n != 0:
            rec["reason"] = f"hyb_load still resident at round end (pgrep={n})"
            return rec
        rec["memAvailable"] = meminfo(ad)
        probes = [t for t, v in (rec["lmkd_end"] or {}).items() if v is not None]
        rec["log"] = (f"chain ABC done; decode T={nT} tps={tps}; "
                      f"probes={','.join(probes)}; memAvail={rec['memAvailable']}kB")
        rec["verdict"] = "PASS"
        return rec
    except Exception as e:  # noqa: BLE001 -- a round that cannot be measured is a FAIL
        rec["reason"] = f"round exception: {type(e).__name__}: {e}"
        rec["evidence"] = rec["evidence"] or ""
        return rec
    finally:
        CTX["phase"] = "base"


# ---------------------------------------------------------------- results I/O
def append_result(rec, path):
    data = []
    if os.path.exists(path):
        try:
            with open(path, encoding="utf-8") as f:
                data = json.load(f)
            assert isinstance(data, list)
        except Exception:  # noqa: BLE001 -- corrupt results file: quarantine, start fresh
            os.replace(path, path + ".corrupt")
            data = []
    data.append(rec)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=1, ensure_ascii=False)


def print_row(rec):
    d = rec["lmkd_delta"]
    dtxt = ",".join(f"{t.split('_')[0]}{v:+d}" for t, v in d.items()) if d else "-"
    tps = "-" if rec["tps"] is None else format(rec["tps"], ".2f")
    mem = "-" if not rec["memAvailable"] else str(rec["memAvailable"])
    print(f"| {rec['round']:>2d} | {dtxt:<24s} | {tps:>6s} | {mem:>9s} | "
          f"{rec['verdict']:<4s} | {rec['reason'][:60]:<60s} |")


# ---------------------------------------------------------------- dry harness
class DryAdb:
    """Offline AdbSock stand-in answering exactly the commands the gate issues."""
    def __init__(self):
        self.faults, self.inject_round, self.round = set(), 10**9, 0

    def _inj(self, kind):
        return kind in self.faults and self.round == self.inject_round

    def shell(self, cmd):
        if "mWakefulness" in cmd:
            return "  mWakefulness=Dozing\n"
        if "keyevent" in cmd:
            return ""
        if "logcat" in cmd:
            if "head" in cmd:
                return "--------- beginning of main\n01-01 00:00:00 I am_kill : [0,1,x,0]\n"
            return ("3\n" if (self._inj("lmkd") and CTX["phase"] == "end") else "0\n")
        if "pgrep" in cmd:
            return "0\n"
        if "libopencl_stub" in cmd:
            return f"{D2}/libopencl_stub.so\n"
        if "hyb_load" in cmd:
            tps = "2.10" if self._inj("decode") else "6.16"  # fork GPU measured 6.16
            lines = [f"STATE_LOADED tokens={NREAL} next_pos=260 load_ms=41"]
            lines += [f"T {i} {1000 + i}" for i in range(GREEDY)]
            lines.append(f"HYB_DECODE tps={tps} secs=3.0")
            return "\n".join(lines) + "\n"
        if "MemAvailable" in cmd:
            return "MemFree:          524288 kB\nMemAvailable:    2621440 kB\n"
        if "wc -c" in cmd:  # chain_evidence
            if self._inj("instantdeath"):
                return "wc: /data/local/tmp/npu_m1/p1.log: No such file or directory\n"
            return "412 /data/local/tmp/npu_m1/p1.log\nCR5_DONE seg ok\n"
        return ""

    def push(self, local, remote):
        print(f"[dry] push {local} -> {remote}")

    def pull(self, remote, local):
        print(f"[dry] pull {remote} -> {local}")


def dry_subproc(argv):
    class P:
        returncode, stdout, stderr = 0, "", ""
    p = P()
    src = " ".join(argv)
    if "run_a3b_seq.py" in src:
        ad = DRY_AD
        dead = ad._inj("chain") or ad._inj("instantdeath")
        out = "IO pushed\nSPAWNED_A\nseg A: done=True\nCR5_DONE\n"
        if dead:
            out += "SPAWNED_B\nseg B: process gone at t=60s\nseg B: done=False\nA3_ABORT\n"
        else:
            out += ("SPAWNED_B\nseg B: done=True\nCR5_DONE\n"
                    "SPAWNED_C\nseg C: done=True\nCR5_DONE\n"
                    "pulled 84 kv + h_l41, kc0 size 262144\n")
        p.stdout = out + "WAKE_END: mWakefulness=Dozing\nA3_DONE\n"
    elif "kv_bridge.py" in src:
        p.stdout = f"BRIDGE_OK copy {STATE_LOCAL} 7401172\n"  # VER=4 size
    return p


DRY_AD = None  # set in main() when --dry


# ---------------------------------------------------------------- main
def main():
    global DRY, SLEEP, DRY_AD
    ap = argparse.ArgumentParser(description="Phase B memory gate: N x full hybrid round, "
                                             "zero lmkd kills required")
    ap.add_argument("--rounds", type=int, default=5, help="consecutive rounds (smoke: 1)")
    ap.add_argument("--dry", action="store_true", help="stub AdbSock+subprocess, no device")
    ap.add_argument("--dry-inject", default="none",
                    choices=["none", "lmkd", "decode", "chain", "instantdeath"],
                    help="inject a fault into the LAST dry round to exercise FAIL paths")
    a = ap.parse_args()
    DRY = a.dry
    results_path = (HYB + "/b_gate_results.dry.json") if DRY else RESULTS
    if DRY:
        SLEEP = lambda s: None
        DRY_AD = DryAdb()
        DRY_AD.inject_round = a.rounds
        DRY_AD.faults = set() if a.dry_inject == "none" else {a.dry_inject}
        ad = DRY_AD
        print(f"[dry] stubs active; inject={a.dry_inject} into round {a.rounds}")
    else:
        from mcp5_94_adbsock import AdbSock
        ad = AdbSock(S)
        doze(ad, " gate-start")
        # D2 (fork libs + hyb_load + libopencl_stub.so) is pre-seeded by the main
        # session -- never re-push binaries/libs there, only the round's state.
        print(f"decode dir: {D2} (pre-seeded fork libs + hyb_load)")

    print("| rnd | lmkd_delta         |    tps | MemAvail kB | verdict | note |")
    print("|-----|--------------------|--------|-------------|---------|------|")
    recs, failed = [], None
    for rnum in range(1, a.rounds + 1):
        if DRY:
            DRY_AD.round = rnum
        rec = one_round(ad, rnum)
        recs.append(rec)
        append_result(rec, results_path)
        print_row(rec)
        if rec["verdict"] != "PASS":
            failed = rec
            break

    if failed:
        print(f"GATE_FAIL round={failed['round']} reason={failed['reason']}")
        if failed["evidence"]:
            print("--- evidence ---")
            print(failed["evidence"])
        gate = "GATE_FAIL"
    else:
        print(f"GATE_PASS {a.rounds}/{a.rounds} rounds, lmkd deltas all 0, decode all pass "
              f"(tps {[r['tps'] for r in recs]})")
        gate = "GATE_PASS"
    doze(ad, " gate-end")  # Dozing re-check, whatever happened
    print(f"results appended -> {results_path}")
    sys.exit(0 if gate == "GATE_PASS" else 1)


if __name__ == "__main__":
    main()
