import struct

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

targets = {67:'topk', 76:'gate'}
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
c_sorted = sorted(c_topk)

ne, gd = got['GPU'][76][1], got['GPU'][76][2]
_,  cd = got['CPU'][76][1], got['CPU'][76][2]

print("GPU gate col -> best matching CPU expert column:")
for j in range(8):
    gv = col(gd, ne, j)
    scores = []
    for e in c_sorted:
        cv = col(cd, ne, c_sorted.index(e))
        worst = max(abs(a-b) for a,b in zip(gv,cv)); refmax = max(abs(b) for b in cv) or 1e-30
        scores.append((worst/refmax, e))
    scores.sort()
    print(f"  GPU col{j}: best=expert {scores[0][1]} rel={scores[0][0]:.4f} | 2nd=expert {scores[1][1]} rel={scores[1][0]:.4f}")
