#!/system/bin/sh
# [vkh 2026-10-28] Price the dark zone. VKH_DZ_TAG forensics resolved every dark launch
# (ENQ/PRE_FORWARD, 490/token-run, 40 % of the submit loop with drains off) to ONE site:
# graph_compute ggml-opencl.cpp:10119 — the continuation of ggml_opencl_op_rms_norm_fused()
# at L10118. Fused helpers enqueue directly and never set g_vkh_current_op, which is exactly
# why they were dark.
#
# The product already ships an opt-out for that fuse (GGML_OPENCL_FUSE_RMS_MUL=0, L10113-10116),
# so the path can be priced without touching a byte of product code: run the same leg with the
# fuse on / off and read the dark-zone rows. Drains are pinned OFF (IDLE=0) so per-site ms is
# attribution-clean — with IDLE=2 every 2nd enqueue absorbs a full clFinish and the numbers lie.
#
# K40 = mechanism/attribution only. No perf verdict leaves this script; tok/s is printed solely
# as a sanity signal (and the numeric gate txt= must match across arms).
W="${WORKDIR:-/data/local/tmp/vkh_k40}"
M="${MODEL:-/data/local/tmp/qwen2.5-0.5b-q4_k_m.gguf}"
TAG="${TAG:-k40fz1}"
N="${N:-24}"
P="${PROMPT:-The capital of France is}"
cd "$W" || exit 2
export LD_LIBRARY_PATH="$PWD"
export GGML_DISABLE_VULKAN=1
export GGML_OPENCL_VKH_OPTIME=1
export GGML_OPENCL_HOST_TIMING=1
export GGML_OPENCL_NDRANGE_IDLE=0
export VKH_DZ_TAG=1
mkdir -p out
LIBMD5=$(md5sum libggml-opencl.so 2>/dev/null | cut -c1-32)
B0=$(dumpsys battery 2>/dev/null | grep -m1 temperature | tr -dc "0-9")
echo "#### FUSEAB_HOST tag=$TAG lib=$LIBMD5 n=$N batt=${B0:-na} idle=0 dz=on $(date +%H:%M:%S)"
[ -n "$LIBMD5" ] || { echo "#### FUSEAB_ABORT_NO_LIB"; exit 3; }
[ "${B0:-0}" -le 440 ] || { echo "#### FUSEAB_THERMAL_ABORT $B0"; exit 4; }

for arm in fuse_on fuse_off; do
    if [ "$arm" = "fuse_off" ]; then export GGML_OPENCL_FUSE_RMS_MUL=0; else unset GGML_OPENCL_FUSE_RMS_MUL; fi
    B=$(dumpsys battery 2>/dev/null | grep -m1 temperature | tr -dc "0-9")
    [ "${B:-0}" -le 440 ] || { echo "#### FUSEAB_THERMAL_ABORT arm=$arm $B"; exit 4; }
    echo "#### FUSEAB_BEGIN arm=$arm batt=$B fuse_rms_mul=${GGML_OPENCL_FUSE_RMS_MUL:-on} $(date +%H:%M:%S)"
    timeout 900 ./llama-cli -m $M -ngl 99 --flash-attn off \
        -p "$P" -n $N --temp 0 --no-display-prompt -v \
        > out/fz_${TAG}_${arm}.raw 2> out/fz_${TAG}_${arm}.err
    RC=$?
    [ "$RC" -eq 0 ] || { echo "#### FUSEAB_RC_FAIL arm=$arm rc=$RC"; exit 7; }
    grep -q "vkh-optime" out/fz_${TAG}_${arm}.err || { echo "#### FUSEAB_PROOF_FAIL arm=$arm"; exit 5; }
    GEN=$(tr '\r' '\n' < out/fz_${TAG}_${arm}.raw | grep "Generation:" | tail -1 | sed -n 's/.*Generation: \([0-9.]*\) t\/s.*/\1/p')
    TXT=$(tr '\r' '\n' < out/fz_${TAG}_${arm}.raw | sed -n '/^> /{n;p}' | head -1 | md5sum | cut -c1-32)
    AV=$(grep -c "ADDITIVITY_VIOLATION" out/fz_${TAG}_${arm}.err 2>/dev/null)
    MG=$(grep -c "MIDGRAPH_INFO" out/fz_${TAG}_${arm}.err 2>/dev/null)
    echo "#### FUSEAB_RESULT arm=$arm rc=$RC tps=${GEN:-na} txt=$TXT additivity_violations=${AV:-0} midgraph=${MG:-0}"
    E=out/fz_${TAG}_${arm}.err
    for k in LOOP_TOTAL GRAPH_TOTAL MUL_MAT "ENQ/PRE_FORWARD" ENQ_DRV ENQ_IDLE; do
        echo "#### FUSEAB_ROW arm=$arm $(grep "op=$k " $E 2>/dev/null | tail -1 | sed 's/^\[vkh-optime\] //')"
    done
    echo "#### FUSEAB_DZ arm=$arm $(grep 'STATIONS' $E 2>/dev/null | tail -1 | sed 's/.*STATIONS/STATIONS/')"
    grep "op=DZ@+0x" $E 2>/dev/null | tail -3 | sed "s/^\[vkh-optime\] /#### FUSEAB_DZROW arm=$arm /"
done
echo "#### FUSEAB_DONE $(date +%H:%M:%S)"
