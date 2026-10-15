#!/usr/bin/env python3
# Fix shim placement: it must sit at preprocessor depth 0, not inside the
# `#ifdef cl_qcom_reqd_sub_group_size` header block. Moves the shim block to
# just after the #endif that closes the first header #ifdef (or after pragmas
# when no such block exists). Idempotent.
import pathlib, sys

KDIR = pathlib.Path(__file__).parent
MARK = "// [dspark 2026-10-14] SGB bitcast shims."
MARK_END = "sgb_f8(float8 v, uint lid) {"

def extract_shim(lines):
    start = end = None
    depth = 0
    for i, ln in enumerate(lines):
        s = ln.strip()
        if start is not None and s.startswith(MARK):
            start = i
        # find full block
    # simpler: locate MARK line, then scan until the closing "}" of sgb_f8
    for i, ln in enumerate(lines):
        if ln.startswith(MARK):
            start = i
            break
    else:
        return None, None
    for i in range(start + 1, len(lines)):
        if lines[i].startswith("}"):
            # shim ends at the first "}" alone after sgb_f8's opening; the last
            # function is sgb_f8, its closing brace line is "}"
            end = i
            # ensure this is sgb_f8's closing (search forward for next non-empty)
            return start, end
    return start, None

def main():
    for p in sorted(KDIR.glob("*.cl")):
        text = p.read_text(encoding="utf-8")
        if MARK not in text:
            continue
        lines = text.split("\n")
        s, e = extract_shim(lines)
        if s is None or e is None:
            print(f"!! {p.name}: shim markers not found"); sys.exit(1)
        shim = lines[s:e+1]
        rest = lines[:s] + lines[e+1:]
        # walk rest, track #if* / #endif depth; insert at first depth==0 index
        # that comes after all header pragmas (skip leading pragmas/blank/comments)
        depth = 0
        insert_at = None
        for i, ln in enumerate(rest):
            t = ln.strip()
            if t.startswith("#if") and not t.startswith("#pragma"):
                depth += 1
            elif t.startswith("#endif"):
                if depth > 0:
                    depth -= 1
                    if depth == 0 and insert_at is None:
                        insert_at = i + 1
            elif depth == 0 and insert_at is None:
                if t and not t.startswith("#pragma") and not t.startswith("//"):
                    insert_at = i
        if insert_at is None:
            print(f"!! {p.name}: no depth-0 insertion point"); sys.exit(1)
        new_lines = rest[:insert_at] + [""] + shim + rest[insert_at:]
        p.write_text("\n".join(new_lines), encoding="utf-8")
        print(f"fixed {p.name}: shim moved to line {insert_at} (depth 0)")

if __name__ == "__main__":
    main()
