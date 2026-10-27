#!/system/bin/sh
# [vkh 2026-10-28] NDRANGE_IDLE A/B — the self-inflicted-drain weigh-in (K40 = mechanism only).
# Fact on the table (ggml-opencl.cpp L1456/L1459-1467 at HEAD): idle_n defaults to 2, so every
# 2nd successful NDRange enqueue calls clFinish(queue) — ~450 full-queue drains per token. That
# is a correctness fuse for the H2' race (R-060), never A/B'd for performance.
# Legs (REPS passes, alternating so thermal drift hits both arms equally):
#   idle2  default (drain every 2 launches)      — what every campaign leg has always run
#   idle0  GGML_OPENCL_NDRANGE_IDLE=0            — no drains
#   cpu    -ngl 0                                 — greedy reference for the numeric gate
# Numerical gate: the completion text of idle0 must match idle2 and the CPU reference. If IDLE=0
# produces divergent/garbage text, H2' is live: the fuse may only be made SMART, never removed —
# the perf verdict still stands, the fix is capped.
W="${WORKDIR:-/data/local/tmp/vkh_k40}"
M="${MODEL:-/data/local/tmp/qwen2.5-0.5b-q4_k_m.gguf}"
TAG="${TAG:-k40idle}"
REPS="${REPS:-2}"
N="${N:-48}"
# Shallow prompts (6 tokens to EOS) cannot witness the H2' garbage-text race. Pass a long
# continuation prompt via PROMPT so every arm writes 100+ tokens under greedy sampling.
P="${PROMPT:-The capital of France is}"
cd "$W" || exit 2
export LD_LIBRARY_PATH="$PWD"
export GGML_DISABLE_VULKAN=1
export GGML_OPENCL_VKH_OPTIME=1
export GGML_OPENCL_HOST_TIMING=1
mkdir -p out
LIBMD5=$(md5sum libggml-opencl.so | cut -c1-32)
echo "#### IDLEAB_HOST $TAG pwd=$W lib=$LIBMD5 model=$M reps=$REPS n=$N $(date +%H:%M:%S)"
[ -n "$LIBMD5" ] || { echo "#### IDLEAB_ABORT_NO_LIB"; exit 3; }
rep=1
while [ "$rep" -le "$REPS" ]; do
    for leg in idle2 idle0 cpu; do
        case $leg in
            idle2) FA=off; NG="-ngl 99"; unset GGML_OPENCL_NDRANGE_IDLE ;;
            idle0) FA=off; NG="-ngl 99"; export GGML_OPENCL_NDRANGE_IDLE=0 ;;
            cpu)   FA=off; NG="-ngl 0";  unset GGML_OPENCL_NDRANGE_IDLE ;;
        esac
        B=$(dumpsys battery 2>/dev/null | grep -m1 temperature | tr -dc "0-9")
        if [ -n "$B" ] && [ "$B" -gt 440 ]; then echo "#### IDLEAB_THERMAL_ABORT rep=$rep leg=$leg $B"; exit 4; fi
        echo "#### IDLEAB_BEGIN rep=$rep leg=$leg fa=$FA $NG idle=${GGML_OPENCL_NDRANGE_IDLE:-default2} batt=$B $(date +%H:%M:%S)"
        timeout 900 ./llama-cli -m $M $NG --flash-attn $FA \
            -p "The capital of France is" -n $N --temp 0 --no-display-prompt -v \
            > out/ab_${TAG}_${leg}_r$rep.raw 2> out/ab_${TAG}_${leg}_r$rep.err
        RC=$?
        GEN=$(tr '\r' '\n' < out/ab_${TAG}_${leg}_r$rep.raw | grep -E "Generation:" | tail -1)
        # Completion = the line right after the '> ' prompt echo; the spinner frames and the perf
        # line must stay out of the hash (spinner frame count tracks wall clock, so hashing the
        # whole stdout makes every run look different — that false alarm cost one rerun).
        TXT=$(tr '\r' '\n' < out/ab_${TAG}_${leg}_r$rep.raw | sed -n '/^> /{n;p}' | head -1 | md5sum | cut -c1-32)
        HT=$(grep "host-timing" out/ab_${TAG}_${leg}_r$rep.err | tail -1)
        # The table is re-dumped on every graph; take the LAST dump's rows, not the first.
        IDL=$(grep "op=ENQ_IDLE" out/ab_${TAG}_${leg}_r$rep.err | tail -1)
        DRV=$(grep "op=ENQ_DRV" out/ab_${TAG}_${leg}_r$rep.err | tail -1)
        PRF=$(grep "op=PRE_FORWARD" out/ab_${TAG}_${leg}_r$rep.err | tail -1)
        TOT=$(grep "op=TOTAL\|TOTAL host_ms" out/ab_${TAG}_${leg}_r$rep.err | tail -1)
        echo "#### IDLEAB_RESULT rep=$rep leg=$leg rc=$RC | $GEN | txt=$TXT"
        echo "#### IDLEAB_HT   rep=$rep leg=$leg $HT"
        echo "#### IDLEAB_ROWS rep=$rep leg=$leg $IDL"
        echo "#### IDLEAB_ROWS rep=$rep leg=$leg $DRV"
        echo "#### IDLEAB_ROWS rep=$rep leg=$leg $PRF"
        echo "#### IDLEAB_TOT  rep=$rep leg=$leg $TOT"
        if [ "$leg" != "cpu" ] && ! grep -q "vkh-optime" out/ab_${TAG}_${leg}_r$rep.err; then
            echo "#### IDLEAB_PROOF_FAIL leg=$leg no instrument banner lib=$LIBMD5 — aborting"; exit 5
        fi
    done
    rep=$((rep+1))
done
echo "#### IDLEAB_DONE $(date +%H:%M:%S)"
