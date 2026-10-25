import re, struct, sys
mm = open(sys.argv[1]).read()
raw = open(sys.argv[2]).read()
mm_calls = re.findall(r'\[G1CMP/mm\] call=(\d+) type0=(\d+) nb01=(\d+) contig=(\d+)', mm)
mm_rows = re.findall(r'\[G1CMP/mm\] row0_hex=([0-9a-f]+)', mm)
mm_x    = re.findall(r'\[G1CMP/mm\] x_hex=([0-9a-f]+)', mm)
f_rows  = re.findall(r'\[G1CMP/raw\] wq_row0_hex=([0-9a-f]+)', raw)
f_x     = re.findall(r'\[G1CMP/raw\] x_hex=([0-9a-f]+)', raw)
print("mm calls:", mm_calls)
print("n mm_rows", len(mm_rows), "n f_rows", len(f_rows), "n mm_x", len(mm_x), "n f_x", len(f_x))
if f_rows and mm_rows:
    print("row0 fused vs mm[0] same?", f_rows[0] == mm_rows[0])
    for i, r in enumerate(mm_rows[:6]):
        print(f"  mm[{i}] same as fused row0? {r == f_rows[0]}")
    print("  fused row0[:60]:", f_rows[0][:60])
    print("  mm[0]   row0[:60]:", mm_rows[0][:60])
if f_x and mm_x:
    for i, xv in enumerate(mm_x[:6]):
        print(f"  mm[{i}] x==fused x? {xv == f_x[0]}")
    def canon(hexc, xhex):
        row = bytes.fromhex(hexc); xb = bytes.fromhex(xhex)
        x = struct.unpack('<1536f', xb)
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
    print("canon(mm0 row0, mm0 x) =", canon(mm_rows[0], mm_x[0]))
