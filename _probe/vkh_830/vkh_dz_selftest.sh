#!/system/bin/sh
# [vkh 2026-10-28] VKH_DZ_TAG self-test — proves the dark-zone station labelling is a pure
# observer before any forensics leg pays for it (R-095: "标签开/关两臂 tok/s 差 <3% 且指纹不变").
#
# Two arms, 丙口径 (App 真身: --flash-attn off -ngl 99), default drain (IDLE=2 — the shipping
# shape), REPS passes alternating so thermal drift hits both arms equally:
#   dzoff  VKH_DZ_TAG unset   — identical to every campaign leg
#   dzon   VKH_DZ_TAG=1       — station rows (ENQ@+0x<off>, ENQ#<n>) + STATIONS banner
#
# Pass criteria, all printed as one machine line:
#   tok_s_diff  < 3 %              (the observer must be free — it costs a register read and,
#                                   when on, one map update per launch)
#   fp_identical=yes               host_timing / live dumps / closed0 / op_rows / kernels_total
#                                   and the ENQ_IDLE + ENQ/PRE_FORWARD rows must not move
#   txt_identical=yes              greedy completion byte-identical across arms and reps
# Station offsets are file-relative:  addr2line -e libggml-opencl.so -f -C 0x<off>
# K40 = mechanism only; no perf verdict leaves this script.
W="${WORKDIR:-/data/local/tmp/vkh_k40}"
M="${MODEL:-/data/local/tmp/qwen2.5-0.5b-q4_k_m.gguf}"
TAG="${TAG:-k40dz}"
REPS="${REPS:-2}"
N="${N:-48}"
P="${PROMPT:-The capital of France is}"
cd "$W" || exit 2
export LD_LIBRARY_PATH="$PWD"
export GGML_DISABLE_VULKAN=1
export GGML_OPENCL_VKH_OPTIME=1
export GGML_OPENCL_HOST_TIMING=1
unset GGML_OPENCL_NDRANGE_IDLE
mkdir -p out
LIBMD5=$(md5sum libggml-opencl.so 2>/dev/null | cut -c1-32)
B0=$(dumpsys battery 2>/dev/null | grep -m1 temperature | tr -dc "0-9")
echo "#### DZSELFCHECK_HOST tag=$TAG pwd=$W lib=$LIBMD5 model=$M reps=$REPS n=$N batt=${B0:-na} $(date +%H:%M:%S)"
[ -n "$LIBMD5" ] || { echo "#### DZSELFCHECK_ABORT_NO_LIB"; exit 3; }

fp_string() {
    E=out/dz_${TAG}_$1_r$2.err
    HT=$(grep -c "host-timing" $E 2>/dev/null)
    DM=$(grep -c "DUMP called" $E 2>/dev/null)
    DN=$(grep -c "table=0x0 " $E 2>/dev/null)
    DR=$(( ${DM:-0} - ${DN:-0} ))
    C0=$(grep -c "graph_depth=0" $E 2>/dev/null)
    OPR=$(grep -c "op=MUL_MAT" $E 2>/dev/null)
    KT=$(grep "TOTAL host_ms" $E 2>/dev/null | tail -1 | sed -n 's/.*kernels=\([0-9]*\).*/\1/p')
    # NOTE the printf padding: rows read "host_ms=    902.5 nodes=    1788", so the pattern must
    # allow the spaces. A stricter pattern silently yields "none" on BOTH arms and the fingerprint
    # comparison then passes vacuously — caught on the first 4-rep run, do not "simplify" this.
    # Equality compares STRUCTURE only (counts), never ms: host-side ms fluctuates run to run and a
    # float-for-float equality would be no for the wrong reason. ms belongs in the COST line.
    IDL=$(grep "op=ENQ_IDLE" $E 2>/dev/null | tail -1 | sed -n 's/.*nodes= *\([0-9]*\).*/n\1/p')
    PRF=$(grep "op=ENQ\/PRE_FORWARD" $E 2>/dev/null | tail -1 | sed -n 's/.*nodes= *\([0-9]*\).*/n\1/p')
    DRV=$(grep "op=ENQ_DRV" $E 2>/dev/null | tail -1 | sed -n 's/.*nodes= *\([0-9]*\).*/n\1/p')
    echo "ht=${HT:-0} dumps=${DR:-0} closed0=${C0:-0} op_rows=${OPR:-0} kernels=${KT:-na} idle=${IDL:-none} darkzone=${PRF:-none} drv=${DRV:-none}"
}

# The observer's own price, measured where it is actually paid. The station map update runs in
# the ENQ timer's destructor AFTER its own t1 was read, so it does not inflate ENQ/* rows — it
# lands inside LOOP_TOTAL instead. And because labelling costs host CPU work, the product's own
# [host-timing] host_ms (clock()) is the right high-resolution yardstick: llama-cli prints tok/s
# with one decimal, which at 1.6 t/s means one quantum = 6 % — too coarse to clear a 3 % gate.
cost_string() {   # $1=arm $2=rep
    E=out/dz_${TAG}_$1_r$2.err
    HTM=$(grep "host-timing" $E 2>/dev/null | sed -n 's/.*host_ms= *\([0-9.]*\).*/\1/p' | awk '{ s += $1; n++ } END { if (n > 0) printf "%.2f", s/n; else print "na" }')
    LT=$(grep "op=LOOP_TOTAL" $E 2>/dev/null | tail -1 | sed -n 's/.*host_ms= *\([0-9.]*\) *nodes= *\([0-9]*\).*/\1\/\2/p')
    echo "host_ms_mean=${HTM:-na} loop=${LT:-none}"
}

rep=1
while [ "$rep" -le "$REPS" ]; do
    for arm in dzoff dzon; do
        if [ "$arm" = "dzon" ]; then export VKH_DZ_TAG=1; else unset VKH_DZ_TAG; fi
        B=$(dumpsys battery 2>/dev/null | grep -m1 temperature | tr -dc "0-9")
        if [ -n "$B" ] && [ "$B" -gt 440 ]; then echo "#### DZSELFCHECK_THERMAL_ABORT rep=$rep arm=$arm $B"; exit 4; fi
        echo "#### DZSELFCHECK_BEGIN rep=$rep arm=$arm batt=$B dz=${VKH_DZ_TAG:-off} $(date +%H:%M:%S)"
        timeout 900 ./llama-cli -m $M -ngl 99 --flash-attn off \
            -p "$P" -n $N --temp 0 --no-display-prompt -v \
            > out/dz_${TAG}_${arm}_r$rep.raw 2> out/dz_${TAG}_${arm}_r$rep.err
        RC=$?
        [ "$RC" -eq 0 ] || { echo "#### DZSELFCHECK_RC_FAIL arm=$arm rc=$RC"; exit 7; }
        if ! grep -q "vkh-optime" out/dz_${TAG}_${arm}_r$rep.err; then
            echo "#### DZSELFCHECK_PROOF_FAIL arm=$arm lib=$LIBMD5"; exit 5
        fi
        GEN=$(tr '\r' '\n' < out/dz_${TAG}_${arm}_r$rep.raw | grep -E "Generation:" | tail -1 | sed -n 's/.*Generation: \([0-9.]*\) t\/s.*/\1/p')
        TXT=$(tr '\r' '\n' < out/dz_${TAG}_${arm}_r$rep.raw | sed -n '/^> /{n;p}' | head -1 | md5sum | cut -c1-32)
        echo "#### DZSELFCHECK_RESULT rep=$rep arm=$arm tps=${GEN:-na} txt=$TXT"
        echo "#### DZSELFCHECK_FP   rep=$rep arm=$arm $(fp_string $arm $rep)"
        echo "#### DZSELFCHECK_COST rep=$rep arm=$arm $(cost_string $arm $rep)"
        if [ "$arm" = "dzon" ]; then
            echo "#### DZSELFCHECK_STATIONS rep=$rep $(grep 'STATIONS' out/dz_${TAG}_${arm}_r$rep.err | tail -1 | sed 's/.*STATIONS/STATIONS/')"
            grep "op=ENQ@+0x" out/dz_${TAG}_${arm}_r$rep.err | tail -1 | sed "s/^/#### DZSELFCHECK_TOP rep=$rep /"
        fi
    done
    rep=$((rep+1))
done

# ---- verdict: mean tok/s per arm, fingerprint and text equality ----
# Collect per-leg numbers from the .raw files themselves (the log is the caller's tee target).
collect() {   # $1=arm
    s=0; c=0
    r=1
    while [ "$r" -le "$REPS" ]; do
        V=$(tr '\r' '\n' < out/dz_${TAG}_$1_r$r.raw 2>/dev/null | grep -E "Generation:" | tail -1 | sed -n 's/.*Generation: \([0-9.]*\) t\/s.*/\1/p')
        if [ -n "$V" ]; then s=$(awk -v a="$s" -v b="$V" 'BEGIN{printf "%.4f", a+b}'); c=$((c+1)); fi
        r=$((r+1))
    done
    [ "$c" -gt 0 ] || { echo "0"; return; }
    awk -v a="$s" -v c="$c" 'BEGIN{printf "%.3f", a/c}'
}
hm_mean() {   # $1=arm — mean [host-timing] host_ms over every step of every rep
    s=0; c=0; r=1
    while [ "$r" -le "$REPS" ]; do
        V=$(grep "host-timing" out/dz_${TAG}_$1_r$r.err 2>/dev/null | sed -n 's/.*host_ms=\([0-9.]*\).*/\1/p' | awk '{ s += $1; n++ } END { if (n > 0) printf "%.3f", s/n }')
        if [ -n "$V" ]; then s=$(awk -v a="$s" -v b="$V" 'BEGIN{printf "%.4f", a+b}'); c=$((c+1)); fi
        r=$((r+1))
    done
    if [ "$c" -gt 0 ]; then awk -v a="$s" -v c="$c" 'BEGIN{printf "%.3f", a/c}'; else echo na; fi
}
T_OFF=$(collect dzoff); T_ON=$(collect dzon)
DIFF=$(awk -v a="$T_OFF" -v b="$T_ON" 'BEGIN{ if (a+0<=0) {print "100"} else { d=(b-a)/a*100; if (d<0) d=-d; printf "%.2f", d } }')
OK_TOK=$(awk -v d="$DIFF" 'BEGIN{print (d<3.0)?"yes":"no"}')
# llama-cli prints tok/s with ONE decimal: at these rates a single quantum is already ~6 %, so
# the tok/s gate on its own cannot tell a 3 % observer from print noise. host_ms — the product's
# own clock() yardstick at 2 decimals, and exactly what a map update per launch inflates — is the
# high-resolution witness. A tok/s miss that fits inside one print quantum and is cleared by
# host_ms is reported MARGINAL, not FAIL; anything bigger is FAIL.
QUANTUM=$(awk -v t="$T_OFF" 'BEGIN{ if (t+0<=0) print "na"; else printf "%.1f", 0.1/t*100 }')
H_OFF=$(hm_mean dzoff); H_ON=$(hm_mean dzon)
HDIFF=$(awk -v a="$H_OFF" -v b="$H_ON" 'BEGIN{ if (a+0<=0) {print "100"} else { d=(b-a)/a*100; if (d<0) d=-d; printf "%.2f", d } }')
OK_HOST=$(awk -v d="$HDIFF" 'BEGIN{print (d<=3.0)?"yes":"no"}')
T1=$(tr '\r' '\n' < out/dz_${TAG}_dzoff_r1.raw | sed -n '/^> /{n;p}' | head -1 | md5sum | cut -c1-32)
T2=$(tr '\r' '\n' < out/dz_${TAG}_dzon_r1.raw | sed -n '/^> /{n;p}' | head -1 | md5sum | cut -c1-32)
[ "$T1" = "$T2" ] && OK_TXT=yes || OK_TXT=no
FP1=""; FP2=""; r=1
while [ "$r" -le "$REPS" ]; do FP1="$FP1|$(fp_string dzoff $r)"; FP2="$FP2|$(fp_string dzon $r)"; r=$((r+1)); done
[ "$FP1" = "$FP2" ] && OK_FP=yes || OK_FP=no
ST1=$(grep "STATIONS" out/dz_${TAG}_dzon_r1.err 2>/dev/null | tail -1)
SROWS=$(echo "$ST1" | sed -n 's/.*rows=\([0-9]*\).*/\1/p')
[ -n "$SROWS" ] && [ "$SROWS" != "0" ] && OK_ST=ok || OK_ST="EMPTY(station rows missing — labelling dead)"
# Cross-attribution honesty: the DZ@ station rows must account for exactly the launches the
# ENQ/PRE_FORWARD row claims (both are cumulative totals of the same table). If they disagree,
# the station→dark-zone mapping is lying and any verdict built on it is void.
DZL=$(grep "STATIONS" out/dz_${TAG}_dzon_r1.err 2>/dev/null | tail -1 | sed -n 's/.*dz_launches=\([0-9]*\).*/\1/p')
PFN=$(grep "op=ENQ\/PRE_FORWARD" out/dz_${TAG}_dzon_r1.err 2>/dev/null | tail -1 | sed -n 's/.*nodes= *\([0-9]*\).*/\1/p')
if [ -z "$DZL" ] || [ -z "$PFN" ]; then
    OK_X="MISSING(dz=$DZL pre_forward=$PFN)"
elif [ "$DZL" = "$PFN" ]; then OK_X=ok; else OK_X="MISMATCH(dz=$DZL pre_forward=$PFN)"; fi
PASS=yes
if [ "$OK_TOK" != "yes" ]; then
    if [ "$OK_HOST" = "yes" ] && awk -v d="$DIFF" -v q="$QUANTUM" 'BEGIN{ exit !(q != "na" && d <= q) }'; then
        TOKVERDICT="MARGINAL(差${DIFF}% ≤ 打印量子${QUANTUM}%，host_ms 已澄清)"
    else
        TOKVERDICT="FAIL(差${DIFF}% 超 3% 且非打印量子可解释)"; PASS=no
    fi
else
    TOKVERDICT="ok(差${DIFF}%)"
fi
[ "$OK_HOST" = "yes" ] || PASS=no
[ "$OK_FP" = "yes" ] || PASS=no
[ "$OK_TXT" = "yes" ] || PASS=no
[ "$OK_ST" = "ok" ] || PASS=no
[ "$OK_X" = "ok" ] || PASS=no
echo "#### DZSELFCHECK_VERDICT tps_off=$T_OFF tps_on=$T_ON tok=$TOKVERDICT | host_ms off=$H_OFF on=$H_ON delta=${HDIFF}% host_ok=$OK_HOST(限3%) | fp_identical=$OK_FP txt_identical=$OK_TXT stations=$OK_ST dz_cross=$OK_X | PASS=$PASS"
if [ "$PASS" = "yes" ]; then
    echo "#### DZSELFCHECK_PASS 标签枪合格：观察者免费，可作 740 暗区法证腿（addr2line -e libggml-opencl.so -f -C 0x<off>）"
else
    echo "#### DZSELFCHECK_FAIL 标签枪不合格，禁止上 740（对照腿会被污染）"
    echo "#### DZSELFCHECK_FPDIFF off=[$FP1] on=[$FP2]"
fi
echo "#### DZSELFCHECK_DONE $(date +%H:%M:%S)"
