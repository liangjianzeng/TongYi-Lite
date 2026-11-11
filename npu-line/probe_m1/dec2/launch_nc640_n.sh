#!/bin/bash
# [npu-line] nc640 chain with configurable step count (diag). Usage: ./launch_nc640_n.sh N
cd /data/local/tmp/npu_m1 || exit 1
export LD_LIBRARY_PATH=$PWD/lib ADSP_LIBRARY_PATH=$PWD/lib
N=${1:-1}
pkill -f chain_run5 2>/dev/null || true; sleep 1
cp -f d2e_hs0.raw d2e_hs.raw
rm -rf gate; mkdir -p gate; echo 0 > gate/counter
rm -f d2e_logits_t*.raw d2e_hn.raw cr5_*.log
CHAIN_KEEP=1 CR5_RESEED_DIR=$PWD CR5_RESEED_DST=$PWD/d2e_hs.raw CR5_GATE=$PWD/gate CR5_ID=0 CR5_GATE_N=3 nohup ./chain_run5 manifest_nc640_A $N > cr5_0.log 2>&1 &
CHAIN_KEEP=1 CR5_RESEED_DIR=$PWD CR5_RESEED_DST=$PWD/d2e_hs.raw CR5_GATE=$PWD/gate CR5_ID=1 CR5_GATE_N=3 nohup ./chain_run5 manifest_nc640_B $N > cr5_1.log 2>&1 &
CHAIN_KEEP=1 CR5_RESEED_DIR=$PWD CR5_RESEED_DST=$PWD/d2e_hs.raw CR5_GATE=$PWD/gate CR5_ID=2 CR5_GATE_N=3 nohup ./chain_run5 manifest_nc640_C $N > cr5_2.log 2>&1 &
wait
echo "N=$N done: $(grep -ac CR5_DONE cr5_0.log)$(grep -ac CR5_DONE cr5_1.log)$(grep -ac CR5_DONE cr5_2.log)"
grep -a CR5_FAIL cr5_0.log cr5_1.log cr5_2.log | head -3
