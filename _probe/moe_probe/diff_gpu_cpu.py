#!/usr/bin/env python3
# diff_gpu_cpu.py - compare minicpm_e2e per-op dumps (GPU vs CPU), report first divergent op.
# Format: [idx u32][op u32][type u32][ne 4*i64][name 64B][nbytes u64][raw]
import struct, sys, math

HDR = 4+4+4+32+64+8  # 116

def records(path):
    with open(path, 'rb') as f:
        while True:
            h = f.read(HDR)
            if len(h) < HDR: return
            idx, op, tt = struct.unpack('<iii', h[:12])
            ne = struct.unpack('<4q', h[12:44])
            name = h[44:108].split(b'\0')[0].decode('utf-8','replace')
            nb, = struct.unpack('<Q', h[108:116])
            data = f.read(nb)
            if len(data) < nb: return
            yield idx, op, tt, ne, name, data

TYPE_NAMES = {0:'F32',1:'F16',30:'Q4_K',14:'Q6_K',12:'Q8_0',9:'Q3_K',2:'I32',5:'I64',4:'I64_4'}

def as_floats(tt, data):
    if tt == 0:
        n = len(data)//4
        return struct.unpack('<%df' % n, data[:n*4])
    if tt == 1:
        # f16 -> float via struct trick: use numpy-less conversion
        import array
        # half bits to float
        out = []
        n = len(data)//2
        it = iter(struct.unpack('<%dH' % n, data[:n*2]))
        for h in it:
            s = (h >> 15) & 1; e = (h >> 10) & 0x1F; m = h & 0x3FF
            if e == 0: v = m * 2**-24
            elif e == 31: v = float('inf') if m == 0 else float('nan')
            else: v = (1 + m/1024) * 2**(e-15)
            out.append(-v if s else v)
        return out
    return None

g = records(sys.argv[1] if len(sys.argv) > 1 else 'dump_gpu.bin')
c = records(sys.argv[2] if len(sys.argv) > 2 else 'dump_cpu.bin')

report = []
first_bad = None
n_cmp = 0
while True:
    rg = next(g, None); rc = next(c, None)
    if rg is None or rc is None:
        if rg is not None or rc is not None:
            print("!! record count mismatch, stopped")
        break
    idx, op, tt, ne, name, dg = rg
    idx2, op2, tt2, ne2, name2, dc = rc
    n_cmp += 1
    if (idx, op, tt, ne, name) != (idx2, op2, tt2, ne2, name2):
        print(f"!! MISMATCH meta at idx={idx}: gpu({name},{tt},{ne}) cpu({name2},{tt2},{ne2})")
        break
    if dg == dc:
        continue
    fl_g = as_floats(tt, dg); fl_c = as_floats(tt, dc)
    if fl_g is None:
        # non-float type: compare bytes only
        rel = 0.0 if dg == dc else float('nan')
    else:
        worst = 0.0; refmax = 1e-30; ngbad = 0
        for a, b in zip(fl_g, fl_c):
            d = abs(a-b); r = abs(b)
            if r > refmax: refmax = r
            if d > worst: worst = d
        rel = worst / refmax
    report.append((rel, idx, name, op, tt, ne))
    if rel > 0.01 and first_bad is None:
        first_bad = (rel, idx, name, op, tt, ne)

print(f"\ncompared {n_cmp} nodes, {len(report)} differ byte-wise")
report.sort(reverse=True)
print("\n=== first divergent node (rel_err > 0.01) ===")
if first_bad:
    rel, idx, name, op, tt, ne = first_bad
    print(f"idx={idx} name={name} op={op} type={tt} shape={ne} rel_err={rel:.6f}")
else:
    print("none above 0.01")

print("\n=== top 25 by rel_err ===")
for rel, idx, name, op, tt, ne in report[:25]:
    print(f"rel={rel:10.6f} idx={idx:5d} name={name:28s} op={op:3d} type={tt:2d} ne={ne}")
