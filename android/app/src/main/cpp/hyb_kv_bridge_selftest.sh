#!/usr/bin/env bash
# [npu-line M2 Phase C] Byte-exactness selftest for hyb_kv_bridge.c.
#
# Builds hyb_kv_bridge.c + hyb_kv_bridge_selftest.c with a HOST compiler
# (gcc/clang — the same C translation unit the APK ships) and diffs the
# produced state containers against the frozen Phase A goldens written by
# the Python reference npu-line/probe_m1/dec2/mcp5_95_kv_bridge.py:
#   v4 = App lineage (lc fork c1a2cb0 loader) — default, gate case
#   v3 = upstream 5c200e0 toolchain — regression case
#
# Run from anywhere (Git Bash on Windows):
#   bash android/app/src/main/cpp/hyb_kv_bridge_selftest.sh
#
# Overrides (env): CC KV_DIR IDS GOLDEN_V4 GOLDEN_V3 NREAL P0 WORK
# Samples are SELF-CONTAINED under E:/MyLLM_exp/hyb_c/bridge_input/ (derived
# from the v4 golden by E:/MyLLM_exp/hyb_c/derive_bridge_input.py — the batch
# scratch E:/MyLLM_exp/hyb/{npu_kv,ids.raw} gets clobbered per-prompt by the
# 50-prompt judge batch and must NOT be a test dependency). Re-derive after a
# golden re-freeze:
#   wsl.exe -d Ubuntu-22.04 -- python3 /mnt/e/MyLLM_exp/hyb_c/derive_bridge_input.py
# v4 arm is self-consistent by construction (inputs derived from its golden);
# v3 arm is the independent cross-version check (same rows must reproduce the
# driver-frozen v3 golden). Exit 0 = both byte-identical.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SNAP="${SNAP:-E:/MyLLM_exp/hyb_c/bridge_input}"
WORK="${WORK:-E:/MyLLM_exp/hyb_c}"
KV_DIR="${KV_DIR:-$SNAP}"
IDS="${IDS:-$SNAP/ids.raw}"
GOLDEN_V4="${GOLDEN_V4:-$SNAP/goldens/bridged172_v4.state}"
GOLDEN_V3="${GOLDEN_V3:-$SNAP/goldens/bridged172.state}"
# NREAL/P0 from the snapshot manifest when not overridden
if [ -f "$SNAP/params.env" ]; then
    [ -n "${NREAL:-}" ] || NREAL="$(sed -n 's/^NREAL=//p' "$SNAP/params.env" | head -1)"
    [ -n "${P0:-}"    ] || P0="$(sed -n 's/^P0=//p' "$SNAP/params.env" | head -1)"
fi
NREAL="${NREAL:-172}"
P0="${P0:-88}"

# --- locate a host C compiler -------------------------------------------------
COMP=""
for cand in "${CC:-}" /c/mingw64/bin/gcc.exe gcc clang; do
    [ -n "$cand" ] || continue
    if command -v "$cand" >/dev/null 2>&1; then COMP="$cand"; break; fi
done
if [ -z "$COMP" ]; then
    echo "SELFTEST_FAIL no host C compiler found (set CC=...)" >&2
    exit 2
fi
echo "[selftest] compiler: $COMP"

mkdir -p "$WORK" || exit 2
EXE="$WORK/hyb_selftest$( [[ "$COMP" == *mingw* ]] && echo .exe )"

# --- build --------------------------------------------------------------------
"$COMP" -O2 -std=c11 -Wall -Wextra -o "$EXE" \
    "$HERE/hyb_kv_bridge.c" "$HERE/hyb_kv_bridge_selftest.c" || {
    echo "SELFTEST_FAIL compile" >&2; exit 2; }

# --- preflight ----------------------------------------------------------------
for f in "$IDS" "$GOLDEN_V4" "$GOLDEN_V3"; do
    [ -f "$f" ] || { echo "SELFTEST_FAIL missing sample: $f" >&2; exit 2; }
done
ls "$KV_DIR"/d2q_kc_0.raw "$KV_DIR"/d2q_vc_41.raw >/dev/null 2>&1 || {
    echo "SELFTEST_FAIL missing NPU kv raws under $KV_DIR" >&2; exit 2; }

# --- run one version, byte-diff vs its golden ---------------------------------
run_ver() { # $1 = ver (4|0/3), $2 = golden, $3 = tag
    local ver="$1" golden="$2" tag="$3" out="$WORK/bridged_c${NREAL}_v$3.state"
    "$EXE" "$KV_DIR" "$IDS" "$out" "$NREAL" "$P0" 0 42 512 "$ver" || return 1
    if cmp "$out" "$golden"; then
        echo "SELFTEST_PASS v$tag byte-identical to golden ($(stat -c%s "$out") bytes)"
        sha256sum "$out" "$golden"
        return 0
    fi
    echo "SELFTEST_FAIL v$tag differs from golden" >&2
    sha256sum "$out" "$golden"
    ls -la "$out" "$golden"
    return 1
}

# v4 = default (no explicit ver arg => exercises HYB_BRIDGE_DEFAULT_VER)
rc=0
"$EXE" "$KV_DIR" "$IDS" "$WORK/bridged_c${NREAL}.state" "$NREAL" "$P0" || rc=1
if [ $rc -eq 0 ] && cmp "$WORK/bridged_c${NREAL}.state" "$GOLDEN_V4"; then
    echo "SELFTEST_PASS v4(default) byte-identical to golden ($(stat -c%s "$WORK/bridged_c${NREAL}.state") bytes)"
    sha256sum "$WORK/bridged_c${NREAL}.state" "$GOLDEN_V4"
else
    echo "SELFTEST_FAIL v4(default) differs from golden" >&2
    rc=1
fi

# v3 regression (upstream 5c200e0 toolchain lineage)
run_ver 3 "$GOLDEN_V3" 3 || rc=1

exit $rc
