#!/system/bin/sh
# r20: dynamic split clean retest on 740 - dyn vs base alternating x2
cd /data/local/tmp/moe5 || exit 1
M=/storage/emulated/0/TongYiLite/models/minicpm-v4.7-35b-a3b-les.gguf
E=/storage/emulated/0/TongYiLite/models/minicpm-v4.7-35b-a3b-les.experts
P=r20_progress.txt
rm -f $P
echo "[`date +%T`] start" >> $P

one() { # $1=name $2=MATMUL_SPLIT $3=SPLIT_DYNAMIC
  echo "[`date +%T`] cooldown 120s" >> $P
  sleep 120
  echo "[`date +%T`] == $1 start" >> $P
  LD_LIBRARY_PATH=/data/local/tmp/moe5 LLAMA_MOE_DECODE_WINDOW=8 \
    LLAMA_MOE_LOOKAHEAD_PREFETCH=8 LLAMA_MOE_IO_THREADS=4 LLAMA_MOE_PREFETCH_READ=6 \
    LLAMA_MOE_LOG_EVERY_STEP=1 LLAMA_MOE_MATMUL_SPLIT=$2 LLAMA_MOE_SPLIT_DYNAMIC=$3 \
    ./minicpm_e2e $M $E 0 48 > run_$1.txt 2>&1
  grep -a "e2e" run_$1.txt | tail -1 >> $P
  echo "[`date +%T`] == $1 done" >> $P
}

one base_a 0 0
one dyn_a 8 1
one base_b 0 0
one dyn_b 8 1
echo "[`date +%T`] ALL DONE" >> $P
