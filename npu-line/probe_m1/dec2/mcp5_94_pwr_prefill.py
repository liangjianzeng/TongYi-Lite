#!/usr/bin/env python3
# [npu-line] G6 (M2): NPU prefill energy — mJ/token for the fp16 dec2p chunked-prefill
# (512-token prompt, 4 chunks, 3 gate-locked processes; mcp5_79 launch_pre2_full.sh mode).
# Same battery-mode protocol/red lines as mcp5_94_pwr_decode.py (see its header).
# Usage: python mcp5_94_pwr_prefill.py --serial <redacted-tailscale>:5555 --active 180
import argparse
import os
import time

from mcp5_94_adbsock import AdbSock
from mcp5_94_pwr_decode import Sampler, battery, sh

R = "/data/local/tmp/npu_m1"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--serial", required=True)
    ap.add_argument("--active", type=float, default=180.0)
    ap.add_argument("--idle", type=float, default=40.0)
    ap.add_argument("--csv", default=r"E:\MyLLM_exp\pwr\prefill_pwr.csv")
    args = ap.parse_args()

    usb, q, v = battery(args.serial)
    if usb:
        print("ABORT: device on charger — unplug first (wireless adb <redacted-tailscale>:5555 ready)")
        return
    print(f"battery ok: q={q}uAh v={v}mV")
    st = r"E:\wsl_stage"
    ad = AdbSock(args.serial)
    for f in ([f"d2q_emb_{i}.raw" for i in range(4)] + [f"d2q_am_{i}.raw" for i in range(4)] +
              ["d2q_cos_table.raw", "d2q_sin_table.raw", "d2q_kc0.raw", "d2q_vc0.raw",
               "launch_pre2_full.sh"]):
        if os.path.exists(f"{st}\\{f}"):
            ad.push(f"{st}\\{f}", f"{R}/{f}")
    sh(args.serial, f"chmod 755 {R}/launch_pre2_full.sh")
    if "Awake" in sh(args.serial, "dumpsys power | grep -m1 mWakefulness"):
        sh(args.serial, "input keyevent 223")

    s_idle = Sampler(args.serial)
    s_idle.start()
    time.sleep(args.idle)
    s_idle.stop = True
    s_idle.join()
    t_idle = s_idle.rows[-1][0] - s_idle.rows[0][0]
    p_idle = s_idle.energy_J() / t_idle if t_idle else 0.0
    print(f"idle: {p_idle:.3f} W over {t_idle:.0f}s")

    toks, t0, walls = 0, time.time(), []
    s_act = Sampler(args.serial)
    s_act.start()
    while time.time() - t0 < args.active:
        out = sh(args.serial, f"cd {R} && ./launch_pre2_full.sh")
        assert "LAUNCHED_PRE2" in out, out
        lc = time.time()
        done = False
        while time.time() - lc < 120:
            c = sh(args.serial, f"grep -al CR5_DONE {R}/p0.log {R}/p1.log {R}/p2.log "
                                f"2>/dev/null | wc -l").strip().splitlines()[-1]
            if c == "3":
                done = True
                break
            if not sh(args.serial, "pgrep -f chain_run5").strip():
                break
            time.sleep(0.15)
        assert done, "cycle failed — see p*.log"
        walls.append(time.time() - lc)
        toks += 512
    s_act.stop = True
    s_act.join()
    t_act = s_act.rows[-1][0] - s_act.rows[0][0]
    e_act = s_act.energy_J() - p_idle * t_act
    open(args.csv, "w").write("t,q_uah,v_mv\n" + "\n".join(
        f"{t:.2f},{q},{v}" for t, q, v in s_idle.rows + s_act.rows))
    print(f"cycles={len(walls)} wall/cycle avg={sum(walls)/max(len(walls),1):.2f}s")
    print(f"tokens={toks} window={t_act:.0f}s E_active={e_act:.1f}J")
    print(f"MJ_PER_TOKEN = {e_act / max(toks,1) * 1000:.2f} mJ/token  "
          f"({toks / t_act:.1f} tok/s wall incl relaunch)")
    wake = sh(args.serial, "dumpsys power | grep -m1 mWakefulness")
    print("WAKE:", wake.strip())
    if "Awake" in wake:
        sh(args.serial, "input keyevent 223")
        print("SCREEN turned off (223)")
    print("PWR_PREFILL_DONE")


if __name__ == "__main__":
    main()
