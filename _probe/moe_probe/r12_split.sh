#!/system/bin/sh
# r12: A2 split wiring + async deferred reads A/B
# legs: base0 (no split) / s2 (split=2 async) / s2sync (split=2 sync defer) / s4 (split=4 async)
# all warm, 32 tokens each, 60s cooldown
cd /data/local/tmp/moe5 || exit 1
export LD_LIBRARY_PATH=/data/local/tmp/moe5
M=/storage/emulated/0/TongYiLite/models/minicpm-v4.7-35b-a3b-les.gguf
E=/storage/emulated/0/TongYiLite/models/minicpm-v4.7-35b-a3b-les.experts
P=r12_progress.txt
rm -f $P
echo "[`date +%T`] start" >> $P

one() { # $1=name $2=split $3=defer_async
  echo "[`date +%T`] cooldown 60s" >> $P
  sleep 60
  echo "[`date +%T`] == $1 (split=$2 async=$3) start" >> $P
  LLAMA_MOE_DECODE_WINDOW=8 LLAMA_MOE_LOOKAHEAD_PREFETCH=8 LLAMA_MOE_IO_THREADS=4 \
    LLAMA_MOE_PREFETCH_READ=6 LLAMA_MOE_LOG_EVERY_STEP=1 \
    LLAMA_MOE_MATMUL_SPLIT=$2 LLAMA_MOE_DEFER_ASYNC=$3 \
    ./minicpm_e2e $M $E 0 32 > run_$1.txt 2>&1
  grep -a "e2e" run_$1.txt | tail -1 >> $P
  grep -a -m1 "matmul-split" run_$1.txt >> $P 2>/dev/null
  echo "[`date +%T`] == $1 done" >> $P
}

one r12_base0  0 1
one r12_s2     2 1
one r12_s2sync 2 0
one r12_s4     4 1
echo "[`date +%T`] ALL DONE" >> $P
