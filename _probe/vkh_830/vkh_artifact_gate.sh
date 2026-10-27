#!/usr/bin/env bash
# [vkh 2026-10-28] R-098 artifact acceptance gate — host-side, runs before a single byte is pushed.
#
# Why this exists (all three were learned the expensive way, on 740, 2026-10-28):
#  G3  a "法证" build without .debug_line gives function names but NO line info, and worse, feeding
#      addr2line an offset from a DIFFERENT build does not error — it prints a plausible fake
#      symbol (observed: `ggml_cl_ssm_scan @ ggml-opencl.cpp:0`, a function the model never calls).
#      Ruling: 法证 build 必须自带 .debug_line.
#  G5  the CLI stack must be complete AND same-build: `llama-cli` from build/vk-rel also needs
#      libllama-server-impl.so; missing it produced `CANNOT LINK EXECUTABLE` and burned a leg.
#      Ruling: 被测栈与被测件同 build 同栈，探针 build（build-x4 一类）禁入 decode 主案。
#  G4  the instrument must be provably INSIDE the artifact before a device leg, not inferred from
#      a banner after one (strings on the .so is the cheap proof-of-instrument).
#
# Verdict lines are machine-readable:  #### ARTGATE_<arm> …  and  #### ARTGATE_VERDICT … PASS=yes|no
# Exit: 0 pass, 1 any gate failed, 2 bad usage.
LIB="${LIB:?LIB=/path/to/libggml-opencl.so}"
STACK="${STACK:-}"            # dir holding llama-cli + its libs; empty = skip the stack gates
CLI="${CLI:-llama-cli}"
# Colon-separated extra dirs allowed to satisfy a NEEDED entry — e.g. the OpenCL stub, which lives
# outside the cmake bin/ dir: EXTRA_DIRS=_probe/oclstub_build/opencl-stub
EXTRA_DIRS="${EXTRA_DIRS:-}"

command -v readelf >/dev/null 2>&1 || { echo "#### ARTGATE_ABORT no readelf"; exit 2; }
[ -f "$LIB" ] || { echo "#### ARTGATE_ABORT no such LIB=$LIB"; exit 2; }

FAIL=0
MD=$(md5sum "$LIB" | cut -c1-32)
SZ=$(stat -c%s "$LIB")
SONAME=$(readelf -d "$LIB" 2>/dev/null | sed -n 's/.*SONAME.*\[\(.*\)\]/\1/p')
echo "#### ARTGATE_LIB path=$LIB md5=$MD size=$SZ soname=${SONAME:-none}"

# --- G3 debug info ---------------------------------------------------------------
if readelf -S "$LIB" 2>/dev/null | grep -q "\.debug_line"; then LINE_OK=yes; else LINE_OK=no; fi
if [ "$LINE_OK" = yes ]; then
    echo "#### ARTGATE_DEBUGINFO ok=.debug_line present(addr2line 可给行号)"
else
    echo "#### ARTGATE_DEBUGINFO FAIL=无 .debug_line ⇒ addr2line 只能给函数名，且跨 build 偏移会静默吐假符号（R-098 铁律）"
    FAIL=1
fi

# --- G4 instrument actually compiled in ------------------------------------------
# Count PRESENCE PER PATTERN, not matching lines: one printf format string can carry several of
# these tokens on a single strings() line, so `grep -c` under-counts (it reported 2/4 on a good
# lib that contains all four).
INSTR_MISSING=""; INSTR_HITS=0
for pat in "STATIONS rows=" "FUSETAX" "ENQ_DRV@+0x" "drv_sites="; do
    if strings -a "$LIB" 2>/dev/null | grep -qF "$pat"; then
        INSTR_HITS=$((INSTR_HITS + 1))
    else
        INSTR_MISSING="$INSTR_MISSING $pat"
    fi
done
if [ -z "${INSTR_MISSING// /}" ]; then
    echo "#### ARTGATE_INSTR ok=4/4 (STATIONS|FUSETAX|ENQ_DRV@|drv_sites)"
else
    echo "#### ARTGATE_INSTR FAIL=缺 ${INSTR_MISSING# } —— 仪表不全，别上机（白烧腿）"
    FAIL=1
fi

# --- G5 same-build CLI stack completeness (needs $STACK) -------------------------
if [ -n "$STACK" ]; then
    [ -d "$STACK" ] || { echo "#### ARTGATE_STACK FAIL=目录不存在 $STACK"; exit 2; }
    need_list() {   # direct NEEDED entries of a file
        readelf -d "$1" 2>/dev/null | sed -n 's/.*NEEDED.*\[\(.*\)\]/\1/p'
    }
    have() {        # is a NEEDED soname satisfied by $STACK or $EXTRA_DIRS (by name or by SONAME)?
        local f d
        for d in "$STACK" $(printf '%s' "$EXTRA_DIRS" | tr ':' ' '); do
            [ -d "$d" ] || continue
            [ -f "$d/$1" ] && return 0
            for f in "$d"/*.so*; do
                [ -f "$f" ] || continue
                [ "$(readelf -d "$f" 2>/dev/null | sed -n 's/.*SONAME.*\[\(.*\)\]/\1/p')" = "$1" ] && return 0
            done
        done
        return 1
    }
    MISS=""; SEEN=""
    queue="$STACK/$CLI"
    [ -f "$queue" ] || { echo "#### ARTGATE_STACK FAIL=找不到 $queue"; exit 2; }
    while [ -n "$queue" ]; do
        cur=${queue%% *}; queue=${queue#* }; [ "$cur" = "$queue" ] && queue=""
        [ -z "$cur" ] && continue
        base=$(basename "$cur")
        case " $SEEN " in *" $base "*) continue;; esac
        SEEN="$SEEN $base"
        for n in $(need_list "$cur"); do
            case "$n" in libc.so*|libm.so*|libdl.so*|liblog.so*|libandroid.so*|libz.so*|libstdc++.so*) continue;; esac
            have "$n" || MISS="$MISS $n"
            # recurse into stack-provided deps so a missing transitive lib is caught here, not on device
            if have "$n"; then
                for cand in "$STACK/$n" "$STACK"/${n}.*; do
                    [ -f "$cand" ] && queue="$queue $cand"
                done
            fi
        done
    done
    MISS=$(echo "$MISS" | tr ' ' '\n' | sort -u | tr '\n' ' ')
    if [ -z "${MISS// /}" ]; then
        echo "#### ARTGATE_STACK ok=$STACK 依赖闭包完整（含 $CLI 的传递依赖）"
    else
        echo "#### ARTGATE_STACK FAIL=缺依赖:$MISS —— 上机必 CANNOT LINK（今晚 libllama-server-impl.so 即此类）"
        FAIL=1
    fi
    # same-build sanity: is the backend we are about to drop in actually newer/different from the stack's own?
    SSTACK=$(md5sum "$STACK/libggml-opencl.so" 2>/dev/null | cut -c1-32)
    if [ -n "$SSTACK" ]; then
        [ "$SSTACK" = "$MD" ] \
            && echo "#### ARTGATE_LINEAGE note=栈内 libggml-opencl 与待推件同 md5（无需换件）" \
            || echo "#### ARTGATE_LINEAGE note=栈内件 ${SSTACK:0:8} ≠ 待推件 ${MD:0:8}（换件属预期，但必须同 build 同树，见 R-098）"
    fi
else
    echo "#### ARTGATE_STACK skip=未给 STACK=（依赖闭包未检，CANNOT LINK 类坑防不住）"
fi

[ "$FAIL" -eq 0 ] && echo "#### ARTGATE_VERDICT lib=${MD:0:8} PASS=yes 可上机" || echo "#### ARTGATE_VERDICT lib=${MD:0:8} PASS=no 禁上机"
exit $FAIL
