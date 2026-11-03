import struct, itertools

HDR = 116
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

targets = {67:'topk', 76:'gate', 77:'up', 79:'down'}
got = {'GPU': {}, 'CPU': {}}
for path, tag in [('dump_gpu.bin','GPU'), ('dump_cpu.bin','CPU')]:
    for idx, op, tt, ne, name, data in records(path):
        if idx in targets and idx not in got[tag]:
            got[tag][idx] = (tt, ne, data)

def f32(data):
    return struct.unpack('<%df' % (len(data)//4), data[:len(data)//4*4])
def col(data, ne, j):
    m = ne[0]
    return f32(data[j*m:(j+1)*m])

g_topk = list(struct.unpack('<8i', got['GPU'][67][2][:32]))
c_topk = list(struct.unpack('<8i', got['CPU'][67][2][:32]))
g_sorted = sorted(g_topk); c_sorted = sorted(c_topk)

ne_g, gd = got['GPU'][76][1], got['GPU'][76][2]
ne_c, cd = got['CPU'][76][1], got['CPU'][76][2]
ne_gu, gdu = got['GPU'][77][1], got['GPU'][77][2]
ne_cu, cdu = got['CPU'][77][1], got['CPU'][77][2]
ne_gd, gdd = got['GPU'][79][1], got['GPU'][79][2]
ne_cd, cdd = got['CPU'][79][1], got['CPU'][79][2]

rest = g_sorted[4:]
best = None
for perm in itertools.permutations(rest):
    tot = 0.0
    for k, e in enumerate(perm):
        for gdat, gne, cdat, cne in [(gd, ne_g, cd, ne_c), (gdu, ne_gu, cdu, ne_cu), (gdd, ne_gd, cdd, ne_cd)]:
            gv = col(gdat, gne, 4+k); cv = col(cdat, cne, c_sorted.index(e))
            worst = max(abs(a-b) for a,b in zip(gv,cv)); refmax = max(abs(b) for b in cv) or 1e-30
            tot += worst/refmax
    if best is None or tot < best[0]:
        best = (tot, perm)
print("best perm for GPU cols 4-7:", best[1], "avg rel:", best[0]/12)
print("CPU sorted[4:8]:", c_sorted[4:])
print("GPU topk:", g_topk)
print("CPU topk:", c_topk)
