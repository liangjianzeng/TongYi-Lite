#!/system/bin/sh
# round 3: 方差定标 —— 同配置(a_io4) 5 连跑取中位数 + PREFETCH_READ=6 一次
cd /data/local/tmp/moe5 || exit 1
export LD_LIBRARY_PATH=/data/local/tmp/moe5
M=/storage/emulated/0/TongYiLite/models/minicpm-v4.7-35b-a3b-les.gguf
E=/storage/emulated/0/TongYiLite/models/minicpm-v4.7-35b-a3b-les.experts
P=round3_progress.txt
rm -f $P
echo "[`date +%T`] start" >> $P

run() {
  name=$1
  shift
  echo "[`date +%T`] == $name start" >> $P
  "$@" ./minicpm_e2e $M $E 0 48 > run_$name.txt 2>&1
  grep -a "e2e" run_$name.txt | tail -1 >> $P
  echo "[`date +%T`] == $name done" >> $P
}

ENVBASE="env LLAMA_MOE_DECODE_WINDOW=8 LLAMA_MOE_LOOKAHEAD_PREFETCH=8 LLAMA_MOE_IO_THREADS=4"

run r1 $ENVBASE
run r2 $ENVBASE
run r3 $ENVBASE
run r4 $ENVBASE
run r5 $ENVBASE
# 深位预测弱（rank6/7 miss 0.6）：只读前 6 个预测，省 25% 预读 IO
run g_read6 env LLAMA_MOE_DECODE_WINDOW=8 LLAMA_MOE_LOOKAHEAD_PREFETCH=8 LLAMA_MOE_IO_THREADS=4 LLAMA_MOE_PREFETCH_READ=6

echo "[`date +%T`] ALL DONE" >> $P
