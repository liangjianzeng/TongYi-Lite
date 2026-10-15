#!/usr/bin/env python3
# Full reset of the SGB shim: strip ALL shim remnants (MARK comment + the three
# sgb_* function blocks, wherever they sit), then re-insert the complete shim
# at a single depth-0 point AFTER all top-of-file pragmas. Call-site rewrites
# (sgb_f/sgb_f4/sgb_f8) are left untouched.
import pathlib, sys, re

KDIR = pathlib.Path(__file__).parent
MARK = "// [dspark 2026-10-14] SGB bitcast shims."

SHIM = """\
// [dspark 2026-10-14] SGB bitcast shims. Host passes -DSGB_FLOAT_BROKEN when
// the driver's online compiler lacks float overloads of sub_group_broadcast
// (Adreno 740: only scalar uint/int/long/ulong exist). Bitcast float<->uint,
// broadcast as integer, cast back — bitwise identical, subgroup-uniform.
inline float sgb_f(float v, uint lid) {
#ifdef SGB_FLOAT_BROKEN
    return as_float(sub_group_broadcast(as_uint(v), lid));
#else
    return sub_group_broadcast(v, lid);
#endif
}
inline float4 sgb_f4(float4 v, uint lid) {
#ifdef SGB_FLOAT_BROKEN
    float4 r;
    r.s0 = sgb_f(v.s0, lid); r.s1 = sgb_f(v.s1, lid);
    r.s2 = sgb_f(v.s2, lid); r.s3 = sgb_f(v.s3, lid);
    return r;
#else
    return sub_group_broadcast(v, lid);
#endif
}
inline float8 sgb_f8(float8 v, uint lid) {
#ifdef SGB_FLOAT_BROKEN
    float8 r;
    r.s0 = sgb_f(v.s0, lid); r.s1 = sgb_f(v.s1, lid);
    r.s2 = sgb_f(v.s2, lid); r.s3 = sgb_f(v.s3, lid);
    r.s4 = sgb_f(v.s4, lid); r.s5 = sgb_f(v.s5, lid);
    r.s6 = sgb_f(v.s6, lid); r.s7 = sgb_f(v.s7, lid);
    return r;
#else
    return sub_group_broadcast(v, lid);
#endif
}
"""

def strip_shim(lines):
    out = []
    i = 0
    while i < len(lines):
        ln = lines[i]
        s = ln.strip()
        if s.startswith(MARK):
            i += 1
            continue  # drop MARK comment line
        m = re.match(r"inline float[48]? sgb_f[48]?\(", s)
        if m:
            # skip to the line that is exactly "}"
            while i < len(lines) and lines[i].strip() != "}":
                i += 1
            i += 1
            # swallow one following blank line
            if i < len(lines) and lines[i].strip() == "":
                i += 1
            continue
        out.append(ln)
        i += 1
    return out

def find_insert(lines):
    """Insert after the LAST depth-0 #pragma within the first 60 lines,
    but never inside an #if block."""
    depth = 0
    last = None
    for i, ln in enumerate(lines[:60]):
        t = ln.strip()
        if t.startswith("#if") and not t.startswith("#pragma"):
            depth += 1
        elif t.startswith("#endif"):
            depth = max(0, depth - 1)
        elif t.startswith("#pragma") and depth == 0:
            last = i
    return last

def main():
    n = 0
    for p in sorted(KDIR.glob("*.cl")):
        text = p.read_text(encoding="utf-8")
        if MARK not in text and "sgb_f(" not in text:
            continue
        lines = strip_shim(text.split("\n"))
        # clean leading run of blank lines left behind
        at = find_insert(lines)
        if at is None:
            print(f"!! {p.name}: no insertion point"); sys.exit(1)
        # insert shim; ensure a blank line separation below if next line non-empty
        new = lines[:at+1] + [""] + SHIM.rstrip("\n").split("\n") + lines[at+1:]
        p.write_text("\n".join(new), encoding="utf-8")
        n += 1
        print(f"reset {p.name}: shim at line {at+2}")
    print(f"{n} files reset")

if __name__ == "__main__":
    main()
