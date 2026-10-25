import re, struct, sys
t = open(sys.argv[1]).read()
wq  = bytes.fromhex(re.search(r'wq_row0_hex=([0-9a-f]+)', t).group(1))
xb  = bytes.fromhex(re.search(r'x_hex=([0-9a-f]+)', t).group(1))
q8b = bytes.fromhex(re.search(r'q8x_blk0=([0-9a-f]+)', t).group(1))
x = struct.unpack('<1536f', xb)

# dequantize quantizer output block0 (straightforward layout: half d + int8[32])
d8 = struct.unpack('<e', q8b[:2])[0]
y = [struct.unpack('b', q8b[2+j:j+3])[0] for j in range(32)]
print("q8 d=%.6e" % d8)
err = max(abs(y[j]*d8 - x[j]) for j in range(32))
print("max|q8(x)-x| blk0 =", err, " (rel to amax %.3f)" % max(abs(v) for v in x[:32]))

# naive dot blk0: wq nib even=low
blk = wq[:18]
d4 = struct.unpack('<e', blk[:2])[0]
qs = blk[2:]
s = 0.0
for tt in range(32):
    qb = qs[tt >> 1]
    nib = (qb >> 4) if (tt & 1) else (qb & 0xF)
    s += (nib - 8) * y[tt]
print("naive dot blk0 =", d4*d8*s)

# swapped nibble
s2 = 0.0
for tt in range(32):
    qb = qs[tt >> 1]
    nib = (qb & 0xF) if (tt & 1) else (qb >> 4)
    s2 += (nib - 8) * y[tt]
print("swapped dot blk0 =", d4*d8*s2)
