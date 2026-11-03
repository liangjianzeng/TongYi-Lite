#!/system/bin/sh
# r13: decode window (cache c) sweep -- hit rate is the real lever
# legs: w12 (c=12) / w16 (c=16) / w16s4 (c=16 + split=4 async)
cd /data/local/tmp/moe5 || exit 1
export LD_LIBRARY_PATH=/data/local/tmp/moe5
M=/storage/emulated/0/TongYiLite/models/minicpm-v4.7-35b-a3b-les.gguf
E=/storage/emulated/0/TongYiLite/models/minicpm-v4.7-35b-a3b-les.experts
P=r13_progress.txt
rm -f $P
echo "[`date +%T`] start" >> $P

one() { # $1=name $2=window $3=split
  echo "[`date +%T`] cooldown 60s" >> $P
  sleep 60
  echo "[`date +%T`] == $1 (win=$2 split=$3) start" >> $P
  LLAMA_MOE_DECODE_WINDOW=$2 LLAMA_MOE_LOOKAHEAD_PREFETCH=8 LLAMA_MOE_IO_THREADS=4 \
    LLAMA_MOE_PREFETCH_READ=6 LLAMA_MOE_LOG_EVERY_STEP=1 \
    LLAMA_MOE_MATMUL_SPLIT=$3 \
    ./minicpm_e2e $M $E 0 32 > run_$1.txt 2>&1
  grep -a "e2e" run_$1.txt | tail -1 >> $P
  echo "[`date +%T`] == $1 done" >> $P
}

one r13_w12   12 0
one r13_w16   16 0
one r13_w16s4 16 4
echo "[`date +%T`] ALL DONE" >> $P
