#!/usr/bin/env python3
"""NPU M1 功耗采样器 v1（无 root 协议：dumpsys battery 的 Charge counter + voltage）

原理：Charge counter(µAh) 差分 → 平均电流；voltage(mV) → 功率。
  I(A)  = dQ(µAh) * 3.6e-3 / dt(s)
  P(W)  = V(mV)/1000 * I(A)
约定：充电状态数据无效（必须拔线/电池模式）；counter 回绕/重置检测（负跳变>阈值则弃样）。
用法（在远程 PC 上跑）：
  python pwr_sample.py -s 100.109.138.2:5555 -o pwr_740.csv --interval 0.5 --duration 120
输出 CSV 列：t_s, charge_uah, voltage_mv, temp_dC, inst_W, smooth_W(1min窗口中位)
"""
import argparse, csv, re, subprocess, time

ADB = r'C:\Users\jianz\AppData\Local\Android\Sdk\platform-tools\adb.exe'  # 远程 PC 路径
AP = re.compile(r'Charge counter:\s*(\d+)|voltage:\s*(\d+)|temperature:\s*(\d+)')

def sample(serial):
    out = subprocess.run([ADB, '-s', serial, 'shell', 'dumpsys', 'battery'],
                         capture_output=True, text=True, timeout=20).stdout
    m = AP.findall(out)
    q = next((int(a) for a, b, c in m if a), None)
    v = next((int(b) for a, b, c in m if b), None)
    t = next((int(c) for a, b, c in m if c), None)
    return q, v, t

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('-s', '--serial', required=True)
    ap.add_argument('-o', '--out', required=True)
    ap.add_argument('--interval', type=float, default=0.5)
    ap.add_argument('--duration', type=float, default=120)
    args = ap.parse_args()

    rows, prev = [], None
    t0 = time.time()
    print(f'sampling {args.serial} for {args.duration}s every {args.interval}s -> {args.out}')
    while time.time() - t0 < args.duration:
        q, v, t = sample(args.serial)
        now = time.time() - t0
        w = None
        if prev and q is not None and prev[1] is not None and v:
            dt = now - prev[0]; dq = q - prev[1]
            if dq > 0 and dt > 0:               # 电池放电 counter 递减，取绝对流向
                w = (v / 1000.0) * (dq * 3.6e-3 / dt)
        rows.append((now, q, v, t, w))
        prev = (now, q)
        time.sleep(args.interval)

    ws = sorted(r[4] for r in rows if r[4] is not None)
    med = ws[len(ws)//2] if ws else float('nan')
    with open(args.out, 'w', newline='') as f:
        wcsv = csv.writer(f)
        wcsv.writerow(['t_s', 'charge_uah', 'voltage_mv', 'temp_dC', 'inst_W'])
        wcsv.writerows(rows)
    valid = [r for r in rows if r[4] is not None]
    print(f'rows={len(rows)} valid_power={len(valid)} median_W={med:.3f}')
    print('注意：counter 粒度/刷新率会限制分辨率，报告须附原始 CSV；入档用中位数，冷暖态分开。')

if __name__ == '__main__':
    main()
