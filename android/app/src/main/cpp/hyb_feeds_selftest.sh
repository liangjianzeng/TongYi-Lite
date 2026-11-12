#!/usr/bin/env bash
# [npu-line M2 Phase C-3] hyb_feeds 主机自测门（同 hyb_kv_bridge_selftest.sh 模式）。
#
# 编译 hyb_feeds.c + hyb_feeds_selftest.c（纯 C11 + libm，主机可跑），
# 生成全 12 件 d2q_*，恒跑布局/尺寸/全零断言；参考目录存在时逐字节对拍
# （emb/am/kc0/vc0 全等）。cos/sin 恒跑 float64 真值执法（rank-ulp 距 >1
# 即 FAIL；fp32-vs-double 边界计数只作信息，判法源自 hyb_d dtest）。
#
# 参考生成（WSL，一次性；模型 = /home/liang/models/minicpm5-2b，只读）：
#   wsl.exe -d Ubuntu-22.04 -- python3 /mnt/e/MyLLM_exp/hyb_c/gen_feeds_ref.py
# 产出 E:/MyLLM_exp/hyb_c/feeds_ref/{rows_ref.raw,d2q_*.raw,params.txt}。
#
# env 覆盖：CC / ROWS / REF / HID / THETA / HD / P0 / S / NC / CHUNKS / WORK
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${WORK:-E:/MyLLM_exp/hyb_c/feeds_work}"
ROWS="${ROWS:-E:/MyLLM_exp/hyb_c/feeds_ref/rows_ref.raw}"
REF="${REF:-E:/MyLLM_exp/hyb_c/feeds_ref}"
# 参数面优先取参考 params.txt（生成器从模型 config.json 记录真身：
# MiniCPM5 rope_theta=5000000，写死 10000 会让 trig 判卷全假阴性——
# C-3 调试实证）。显式 env 覆盖仍优先。
PT=""
[ -f "$REF/params.txt" ] && PT="$(tr -d ' ' <"$REF/params.txt")"
ptget() { sed -n "s/.*\"$1\":\([0-9.]*\).*/\1/p" <<<"$PT"; }
[ -n "${HID:-}"    ] || HID="$(ptget hid)"
[ -n "${THETA:-}"  ] || THETA="$(ptget theta)"
[ -n "${HD:-}"     ] || HD="$(ptget hd)"
HID="${HID:-2048}"
THETA="${THETA:-10000.0}"
HD="${HD:-128}"
P0="${P0:-88}"
S="${S:-128}"
NC="${NC:-512}"
CHUNKS="${CHUNKS:-4}"

fail() { echo "SELFTEST_FAIL $1" >&2; exit 1; }

# 编译器探测（同 kv bridge selftest）
CCX="${CC:-}"
if [ -z "$CCX" ]; then
    for c in /c/mingw64/bin/gcc.exe gcc clang; do
        if command -v "$c" >/dev/null 2>&1; then CCX="$c"; break; fi
    done
fi
[ -n "$CCX" ] || fail "no C compiler (set CC=)"
echo "[selftest] compiler: $CCX"

mkdir -p "$WORK" || fail "cannot make $WORK"
BIN="$WORK/hyb_feeds_selftest"
[ -f "$HERE/hyb_feeds.c" ] || fail "missing hyb_feeds.c"
[ -f "$HERE/hyb_feeds_selftest.c" ] || fail "missing hyb_feeds_selftest.c"
"$CCX" -O2 -std=c11 -Wall -Wextra -o "$BIN" \
    "$HERE/hyb_feeds.c" "$HERE/hyb_feeds_selftest.c" -lm \
    || fail "build failed"

# 参考缺失 → 造一份合成 rows 表跑 layout-only（值随机但确定性：位型计数器）
if [ ! -s "$ROWS" ]; then
    echo "NOTICE: rows 参考缺失（$ROWS）→ layout-only（合成表）"
    python - "$WORK/rows_synth.raw" "$NC" "$HID" <<'PY' || fail "synth rows failed (need python)"
import sys, struct
out, nc, hid = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
with open(out, "wb") as f:
    for i in range(nc * hid):
        f.write(struct.pack("<H", (i * 2654435761) & 0xFFFF))
PY
    ROWS="$WORK/rows_synth.raw"
    REF=""
fi

rm -rf "$WORK/gen" 2>/dev/null
mkdir -p "$WORK/gen" || fail "cannot make gen dir"
if [ -n "${REF:-}" ] && [ -d "$REF" ]; then
    echo "[selftest] reference: $REF"
    "$BIN" "$WORK/gen" "$ROWS" "$HID" "$THETA" "$HD" "$REF" "$S" "$NC" "$P0" "$CHUNKS" \
        || fail "selftest exited nonzero"
else
    echo "[selftest] no reference dir — layout-only"
    "$BIN" "$WORK/gen" "$ROWS" "$HID" "$THETA" "$HD" "" "$S" "$NC" "$P0" "$CHUNKS" \
        || fail "selftest exited nonzero"
fi
echo "SELFTEST_PASS feeds (work=$WORK)"
