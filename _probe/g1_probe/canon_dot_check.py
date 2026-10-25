#!/usr/bin/env python3
# [G1CMP offline] canonical q4_0 row0 dot verifier.
# usage: python canon_dot_check.py <wq_row0_hex> <x_hex>
import struct, sys

wq = bytes.fromhex(sys.argv[1])
xb = bytes.fromhex(sys.argv[2])
assert len(wq) == 48*18, len(wq)
x = struct.unpack('<%df' % (len(xb)//4), xb)
assert len(x) == 1536, len(x)

# canonical: block = half d (LE), uint8 qs[16]; elem t: qs[t//2], even=low nib; val = d*(nib-8)
def dot_canon(row):
    acc = 0.0
    for b in range(48):
        blk = row[b*18:(b+1)*18]
        d = struct.unpack('<e', blk[:2])[0]
        qs = blk[2:]
        s = 0.0
        for t in range(32):
            qb = qs[t >> 1]
            nib = (qb >> 4) if (t & 1) else (qb & 0xF)
            s += (nib - 8) * x[b*32 + t]
        acc += d * s
    return acc

row0 = wq[:48*18]
print("dot_canon row0 =", dot_canon(row0))
print("expect fused  ~ 1.430500e-01" )
print("expect base   ~ 5.858157e-01")
# flipped-nibble variant (even=high) for comparison
def dot_flip(row):
    acc = 0.0
    for b in range(48):
        blk = row[b*18:(b+1)*18]
        d = struct.unpack('<e', blk[:2])[0]
        qs = blk[2:]
        s = 0.0
        for t in range(32):
            qb = qs[t >> 1]
            nib = (qb & 0xF) if (t & 1) else (qb >> 4)
            s += (nib - 8) * x[b*32 + t]
        acc += d * s
    return acc
print("dot_flipped row0 =", dot_flip(row0))
