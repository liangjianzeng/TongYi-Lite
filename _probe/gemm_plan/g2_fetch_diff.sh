#!/usr/bin/env bash
# [gemm_plan ledger-222] G2 取证回拉: err/lg 件收拢 + logits 比对(合同第11条修订版执行)。
# 用法(host): bash _probe/gemm_plan/g2_fetch_diff.sh
set -u
DEV=${DEV:-100.75.247.55:5555}; PORT=${PORT:-15037}
DIR=$(cd "$(dirname "$0")" && pwd)
IN=$DIR/g2_inbox; mkdir -p $IN
adb -P $PORT -s $DEV pull /data/local/tmp/gemm/out $IN/ 2>&1 | tail -1
OUT=$(ls -d $IN/out 2>/dev/null || echo $IN)
echo "#### G2FETCH dir=$OUT"
grep -h "G2_METRIC\|leg=prefill\|leg=decode" $OUT/g2_*.err 2>/dev/null | sed 's/^/#### /' | head -60
NPRED=${NPRED:-32} python3 $DIR/g2_diff_logits.py $OUT
echo "#### G2FETCH_DONE"
