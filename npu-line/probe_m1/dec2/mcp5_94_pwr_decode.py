#!/usr/bin/env python3
# [npu-line] G6 (M2): NPU decode steady-state energy — mJ/token for the fp16 resident
# 3-process gated chain (mcp5_85 launch_nc640.sh mode = App hot-loop lower bound).
# Protocol (pwr_sample.py v1 canon): battery mode only (USB powered => ABORT), Charge
# counter diff x voltage; idle baseline sampled first, subtracted over the active window.
# Red line: NEVER svc power stayon; Dozing verified at exit (223 if Awake).
# Usage: python mcp5_94_pwr_decode.py --serial <redacted-tailscale>:5555 --active 180
import argparse
import os
import re
import threading
import time

from mcp5_94_adbsock import AdbSock

# adb.exe vanished from platform-tools (2026-11-11, Android Studio mid-update); the live
# server on :5037 + AdbSock carries the full driver surface until it is restored.
R = "/data/local/tmp/npu_m1"
# ANCHORED (^) — 'Max charging voltage: 5000000' (µV) sits above the real 'voltage: 4307'
# (mV) in dumpsys battery; an unanchored regex grabs the µV one and reports 5000 W.
RATES = re.compile(r"^\s*Charge counter:\s*(\d+)|^\s*voltage:\s*(\d+)", re.M)


def sh(serial, cmd):
    return AdbSock(serial).shell(cmd)


def battery(serial):
    out = sh(serial, "dumpsys battery")
    usb = "USB powered: true" in out or "AC powered: true" in out
    m = RATES.findall(out)
    q = next((int(a) for a, b in m if a), None)
    v = next((int(b) for a, b in m if b), None)
    return usb, q, v


class Sampler(threading.Thread):
    """Lockstep (q,v,t) rows; energy computed offline from the raw CSV."""

    def __init__(self, serial, interval=0.2):
        super().__init__(daemon=True)
        self.serial, self.interval = serial, interval
        self.rows, self.stop = [], False

    def run(self):
        while not self.stop:
            _, q, v = battery(self.serial)
            self.rows.append((time.time(), q, v))
            time.sleep(self.interval)

    def energy_J(self):
        J = 0.0
        for (t0, q0, v0), (t1, q1, v1) in zip(self.rows, self.rows[1:]):
            if q0 is None or q1 is None or not v0:
                continue
            dq = q1 - q0
            if dq > 0:  # discharging: counter decreases; take magnitude
                J += (v0 / 1000.0) * (abs(dq) * 3.6e-3)
        return J


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--serial", required=True)
    ap.add_argument("--active", type=float, default=180.0, help="active decode seconds")
    ap.add_argument("--idle", type=float, default=40.0)
    ap.add_argument("--csv", default=r"E:\MyLLM_exp\pwr\decode_pwr.csv")
    args = ap.parse_args()

    usb, q, v = battery(args.serial)
    if usb:
        print("ABORT: device on charger — battery-mode-only protocol (unplug cable, "
              "wireless adb is ready at <redacted-tailscale>:5555)")
        return
    print(f"battery ok: q={q}uAh v={v}mV")
    # feeds for the 8-step teacher chain (small files only; big ctx/caches assumed staged)
    st = r"E:\wsl_stage"
    import os
    ad = AdbSock(args.serial)
    for f in ([f"d2e_hs_t{t}.raw" for t in range(1, 8)] +
              [f"g_am640_t{t}.raw" for t in range(8)] + ["d2e_hs0.raw", "launch_nc640.sh"]):
        if os.path.exists(f"{st}\\{f}"):
            ad.push(f"{st}\\{f}", f"{R}/{f}")
    sh(args.serial, f"chmod 755 {R}/launch_nc640.sh")
    wake = sh(args.serial, "dumpsys power | grep -m1 mWakefulness")
    if "Awake" in wake:
        sh(args.serial, "input keyevent 223")

    # idle baseline (screen Dozing, WiFi adb alive, no load)
    s_idle = Sampler(args.serial)
    s_idle.start()
    time.sleep(args.idle)
    s_idle.stop = True
    s_idle.join()
    t_idle = s_idle.rows[-1][0] - s_idle.rows[0][0]
    p_idle = s_idle.energy_J() / t_idle if t_idle else 0.0
    print(f"idle: {p_idle:.3f} W over {t_idle:.0f}s ({len(s_idle.rows)} samples)")

    # active: back-to-back resident 8-step launches
    toks, t0 = 0, time.time()
    s_act = Sampler(args.serial)
    s_act.start()
    walls = []
    while time.time() - t0 < args.active:
        out = sh(args.serial, f"cd {R} && ./launch_nc640.sh")
        assert "LAUNCHED_NC640" in out, out
        lc = time.time()
        done = False
        while time.time() - lc < 120:
            c = sh(args.serial, f"grep -al CR5_DONE {R}/cr5_0.log {R}/cr5_1.log "
                                f"{R}/cr5_2.log 2>/dev/null | wc -l").strip().splitlines()[-1]
            if c == "3":
                done = True
                break
            if not sh(args.serial, "pgrep -f chain_run5").strip():
                break
            time.sleep(0.15)
        assert done, "cycle failed (crash?) — see cr5_*.log"
        walls.append(time.time() - lc)
        toks += 8
    s_act.stop = True
    s_act.join()
    t_act = s_act.rows[-1][0] - s_act.rows[0][0]
    e_act = s_act.energy_J() - p_idle * t_act
    csv = "\n".join(f"{t:.2f},{q},{v}" for t, q, v in s_idle.rows + s_act.rows)
    open(args.csv, "w").write("t,q_uah,v_mv\n" + csv)
    print(f"cycles={len(walls)} wall/cycle avg={sum(walls)/max(len(walls),1):.2f}s")
    print(f"tokens={toks} active_window={t_act:.0f}s E_total={s_act.energy_J():.1f}J "
          f"E_active={e_act:.1f}J")
    print(f"MJ_PER_TOKEN = {e_act / max(toks,1) * 1000:.1f} mJ/token  "
          f"({toks / t_act:.2f} tok/s wall incl relaunch)")
    wake = sh(args.serial, "dumpsys power | grep -m1 mWakefulness")
    print("WAKE:", wake.strip())
    if "Awake" in wake:
        sh(args.serial, "input keyevent 223")
        print("SCREEN turned off (223)")
    print("PWR_DECODE_DONE")


if __name__ == "__main__":
    main()
