import re, struct, sys, math
mm = open(sys.argv[1]).read()
row = bytes.fromhex(re.findall(r'row0_hex=([0-9a-f]+)', mm)[0])
xb  = struct.unpack('<1536f', bytes.fromhex(re.findall(r'x_hex=([0-9a-f]+)', mm)[0]))

def q8_1_from_float(xb, off):
    # ggml from_float_q8_1_nonvectorized: amax/32... actually: d = max(abs)/32.0f? check ±: uses amax/32.0f? in ggml-common: 
    amax = max(abs(v) for v in xb)
    d = amax / 32.0 if amax > 0 else 1.0
    q = [max(-16, min(15, int(round(v/d)) if v/d != int(v/d) else int(v/d))) for v in xb]
    # lroundf = round half away from zero
    q = []
    for v in xb:
        r = v/d
        qi = math.floor(r+0.5) if r >= 0 else math.ceil(r-0.5)
        qi = max(-16, min(15, qi))
        q.append(qi)
    return d, q

def dot_variant(even_high):
    acc = 0.0
    for b in range(48):
        blk = row[b*18:(b+1)*18]
        d4 = struct.unpack('<e', blk[:2])[0]
        qs = blk[2:]
        d8, q8 = q8_1_from_float(xb[b*32:(b+1)*32], b*32)
        s = 0.0
        for t in range(32):
            qb = qs[t >> 1]
            nib = (qb >> 4) if (t & 1) != even_high else (qb & 0xF)
            s += (nib - 8) * q8[t]
        acc += d4 * d8 * s
    return acc

print("even=low  + q8_1 requant:", dot_variant(False))
print("even=high + q8_1 requant:", dot_variant(True))
print("baseline observed        : 0.5858157")
