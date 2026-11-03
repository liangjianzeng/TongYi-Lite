#!/system/bin/sh
# r18: 740 v86 CPU A/B - base vs v86 alternating x2, warm, 48 tok
cd /data/local/tmp/moe5 || exit 1
M=/storage/emulated/0/TongYiLite/models/minicpm-v4.7-35b-a3b-les.gguf
E=/storage/emulated/0/TongYiLite/models/minicpm-v4.7-35b-a3b-les.experts
P=r18_progress.txt
rm -f $P
echo "[`date +%T`] start" >> $P

one() { # $1=name $2=libpath
  echo "[`date +%T`] cooldown 90s" >> $P
  sleep 90
  echo "[`date +%T`] == $1 start" >> $P
  LD_LIBRARY_PATH=$2 LLAMA_MOE_DECODE_WINDOW=8 LLAMA_MOE_LOOKAHEAD_PREFETCH=8 \
    LLAMA_MOE_IO_THREADS=4 LLAMA_MOE_PREFETCH_READ=6 LLAMA_MOE_LOG_EVERY_STEP=1 \
    ./minicpm_e2e $M $E 0 48 > run_$1.txt 2>&1
  grep -a "e2e" run_$1.txt | tail -1 >> $P
  echo "[`date +%T`] == $1 done" >> $P
}

one base_a /data/local/tmp/moe5
one v86_a /data/local/tmp/moe5/v86:/data/local/tmp/moe5
one base_b /data/local/tmp/moe5
one v86_b /data/local/tmp/moe5/v86:/data/local/tmp/moe5
echo "[`date +%T`] ALL DONE" >> $P
