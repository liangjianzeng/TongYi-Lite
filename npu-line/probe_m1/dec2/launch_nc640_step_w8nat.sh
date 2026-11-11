cd /data/local/tmp/npu_m1 || exit 1
# [npu-line] G3 native-recipe W8 decode: all 42 layers on w8nat_l{K} ctxs (native
# qnn-onnx-converter + enc, cpp/model.so flow — the recipe proven green by w8nat_l0
# device probe 2026-11-11) + w8 head (fp16 norm). Usage: ./launch_nc640_step_w8nat.sh STEP
export LD_LIBRARY_PATH=$PWD/lib ADSP_LIBRARY_PATH=$PWD/lib
STEP=${1:-0}
pkill -f chain_run5 2>/dev/null || true; sleep 1
if [ "$STEP" = "0" ]; then cp -f d2e_hs0.raw d2e_hs.raw; cp -f d2e_hs0.raw d2e_hs_t0.raw; fi
# gate targets are absolute (gn*t+gid, t=CR5_T0) — preseed counter to the step's floor
rm -rf gate; mkdir -p gate; echo $((3 * STEP)) > gate/counter
rm -f d2e_logits_t${STEP}.raw d2e_hn.raw cr5_s_*.log
CHAIN_KEEP=1 CR5_T0=$STEP CR5_ROLL_SAVE=1 CR5_RESEED_DIR=$PWD CR5_RESEED_DST=$PWD/d2e_hs.raw CR5_GATE=$PWD/gate CR5_ID=0 CR5_GATE_N=3 nohup ./chain_run5 manifest_nat_A 1 > cr5_s_0.log 2>&1 &
CHAIN_KEEP=1 CR5_T0=$STEP CR5_ROLL_SAVE=1 CR5_RESEED_DIR=$PWD CR5_RESEED_DST=$PWD/d2e_hs.raw CR5_GATE=$PWD/gate CR5_ID=1 CR5_GATE_N=3 nohup ./chain_run5 manifest_nat_B 1 > cr5_s_1.log 2>&1 &
CHAIN_KEEP=1 CR5_T0=$STEP CR5_ROLL_SAVE=1 CR5_RESEED_DIR=$PWD CR5_RESEED_DST=$PWD/d2e_hs.raw CR5_GATE=$PWD/gate CR5_ID=2 CR5_GATE_N=3 nohup ./chain_run5 manifest_nat_C 1 > cr5_s_2.log 2>&1 &
echo LAUNCHED_STEP_W8NAT_$STEP
