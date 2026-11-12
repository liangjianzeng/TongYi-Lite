#!/usr/bin/env python3
# [npu-line] G6 (M2): GPU (Vulkan via /data/local/tmp/vkl llama.cpp) decode energy for
# the SAME model (MiniCPM5-2B -> GGUF Q4_K_M, converted on WSL host). Companion of
# mcp5_94_pwr_decode.py (NPU side): same battery-mode protocol, same idle-subtraction,
# same red lines (no stayon; Dozing at exit). llama-bench -p 0 -n <tg> = pure decode.
# Usage: python mcp5_94_pwr_gpu.py --serial <redacted-tailscale>:5555 --active 180
import argparse
import time

from mcp5_94_adbsock import AdbSock
from mcp5_94_pwr_decode import Sampler, battery, sh

VKL = "/data/local/tmp/vkl"
GGUF = "/data/local/tmp/minicpm5-2b-q4k.gguf"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--serial", required=True)
    ap.add_argument("--active", type=float, default=180.0)
    ap.add_argument("--idle", type=float, default=40.0)
    ap.add_argument("--ngl", type=int, default=99, help="GPU layers offload (-ngl)")
    ap.add_argument("--csv", default=r"E:\MyLLM_exp\pwr\gpu_decode_pwr.csv")
    args = ap.parse_args()

    usb, q, v = battery(args.serial)
    if usb:
        print("ABORT: device on charger — unplug first")
        return
    print(f"battery ok: q={q}uAh v={v}mV")
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

    # pure-decode bench loop; parse tg t/s + token count from stdout
    cmd = (f"cd {VKL} && LD_LIBRARY_PATH={VKL} ./llama-bench -m {GGUF} "
           f"-ngl {args.ngl} -p 0 -n 128 -r 1 -f csv 2>/dev/null")
    toks, t0, runs = 0, time.time(), []
    s_act = Sampler(args.serial)
    s_act.start()
    while time.time() - t0 < args.active:
        out = AdbSock(args.serial).shell(cmd)
        # table rows (build 62bcdf0e has no -f csv): | model | size | params | backend |
        # ngl | test | t/s ± dev |  — count tokens from the tg test cell
        n = 0
        for line in out.splitlines():
            f = [x.strip() for x in line.split("|")]
            if len(f) >= 8 and f[6].startswith("tg") and f[7][:1].isdigit():
                n += int(f[6][2:])
                runs.append((int(f[6][2:]), float(f[7].split("±")[0])))
        if n == 0:
            print("bench produced no rows:\n", out[-400:])
            break
        toks += n
    s_act.stop = True
    s_act.join()
    t_act = s_act.rows[-1][0] - s_act.rows[0][0]
    e_act = s_act.energy_J() - p_idle * t_act
    open(args.csv, "w").write("t,q_uah,v_mv\n" + "\n".join(
        f"{t:.2f},{q},{v}" for t, q, v in s_idle.rows + s_act.rows))
    tgs = [r[1] for r in runs]
    print(f"bench_runs={len(runs)} tg_t/s median={sorted(tgs)[len(tgs)//2] if tgs else 0:.2f}")
    print(f"tokens={toks} window={t_act:.0f}s E_active={e_act:.1f}J")
    print(f"MJ_PER_TOKEN = {e_act / max(toks,1) * 1000:.1f} mJ/token")
    wake = sh(args.serial, "dumpsys power | grep -m1 mWakefulness")
    print("WAKE:", wake.strip())
    if "Awake" in wake:
        sh(args.serial, "input keyevent 223")
        print("SCREEN turned off (223)")
    print("PWR_GPU_DONE")


if __name__ == "__main__":
    main()
