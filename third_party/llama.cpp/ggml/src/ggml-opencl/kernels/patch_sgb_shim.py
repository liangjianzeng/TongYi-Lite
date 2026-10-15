#!/usr/bin/env python3
# [dspark 2026-10-14] Patch Adreno gemv kernels for drivers that lack FLOAT
# overloads of sub_group_broadcast (Adreno 740 / SM8550, OpenCL 3.0 online
# compiler: only scalar uint/int/long/ulong exist). Adds sgb_f/sgb_f4/sgb_f8
# shim functions (guarded by -DSGB_FLOAT_BROKEN from host-side canary) and
# rewrites every sub_group_broadcast call site to route through them.
# Idempotent: skips files already patched.
import re, sys, pathlib

KDIR = pathlib.Path(__file__).parent

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

# call-site rewrites: (pattern, replacement). Vector args mapped by name:
#   y          -> float8 (gemv kernel params)
#   y_local    -> float4 (q4_k 32b_trans)
# scalar: <name>.sN (y.sN / regB.sN / y_local.sN etc.)
RE_SCALAR = re.compile(r"sub_group_broadcast\(([A-Za-z_][A-Za-z0-9_]*)\.s(\d)\s*,")
RE_VEC8   = re.compile(r"sub_group_broadcast\(y\s*,")
RE_VEC4   = re.compile(r"sub_group_broadcast\(y_local\s*,")

def patch_file(path: pathlib.Path) -> bool:
    text = path.read_text(encoding="utf-8")
    if "sgb_f8(float8 v" in text:
        return False  # already patched

    n_scalar = len(RE_SCALAR.findall(text))
    n_vec8   = len(RE_VEC8.findall(text))
    n_vec4   = len(RE_VEC4.findall(text))
    other    = [m for m in re.finditer(r"sub_group_broadcast\(", text)]
    total    = len(other)
    handled  = n_scalar + n_vec8 + n_vec4
    if handled != total:
        print(f"!! {path.name}: {handled}/{total} call sites matched expected shapes; manual review needed")
        # list unmatched shapes
        for m in other:
            seg = text[m.start():m.start()+60].split("\n")[0]
            if not (RE_SCALAR.match(seg) or seg.startswith("sub_group_broadcast(y,") or seg.startswith("sub_group_broadcast(y_local,")):
                print("   UNMATCHED:", seg)
        sys.exit(1)

    text = RE_SCALAR.sub(r"sgb_f(\1.s\2,", text)
    text = RE_VEC8.sub("sgb_f8(y,", text)
    text = RE_VEC4.sub("sgb_f4(y_local,", text)

    # insert shim after the last top-of-file #pragma line (pragmas stay first)
    lines = text.split("\n")
    last_pragma = -1
    for i, ln in enumerate(lines[:40]):
        if ln.startswith("#pragma"):
            last_pragma = i
    lines.insert(last_pragma + 1, SHIM.rstrip())
    path.write_text("\n".join(lines), encoding="utf-8")
    print(f"patched {path.name}: scalar={n_scalar} vec8={n_vec8} vec4={n_vec4}")
    return True

def main():
    files = sorted(p for p in KDIR.glob("*.cl") if "sub_group_broadcast(" in p.read_text(encoding="utf-8"))
    print(f"{len(files)} files contain sub_group_broadcast")
    for p in files:
        patch_file(p)

if __name__ == "__main__":
    main()
