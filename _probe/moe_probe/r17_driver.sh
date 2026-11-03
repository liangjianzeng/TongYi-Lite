#!/system/bin/sh
# r17 driver: interleaved v86 vs baseline CPU lib, 2 passes x 64 tok, K90(830)
cd /data/local/tmp/moe830 || exit 1
M=/storage/emulated/0/TongYiLite/models/minicpm-v4.7-35b-a3b-les.gguf
E=/storage/emulated/0/TongYiLite/models/minicpm-v4.7-35b-a3b-les.experts
P=r17_progress.txt
rm -f $P
echo "[`date +%T`] start" >> $P

one() { # $1=name $2=LP
  echo "[`date +%T`] cooldown 90s" >> $P
  sleep 90
  echo "[`date +%T`] == $1 start" >> $P
  LD_LIBRARY_PATH=$2 LLAMA_MOE_LOG_EVERY_STEP=1 \
    LLAMA_MOE_DECODE_WINDOW=8 LLAMA_MOE_LOOKAHEAD_PREFETCH=8 LLAMA_MOE_IO_THREADS=4 LLAMA_MOE_PREFETCH_READ=6 \
    ./minicpm_e2e $M $E 0 64 > run_r17_$1.txt 2>&1
  grep -a "e2e" run_r17_$1.txt | tail -1 >> $P
  echo "[`date +%T`] == $1 done" >> $P
}

one v86_1 "/data/local/tmp/moe830/v86:/data/local/tmp/moe830"
one base_1 "/data/local/tmp/moe830"
one v86_2 "/data/local/tmp/moe830/v86:/data/local/tmp/moe830"
one base_2 "/data/local/tmp/moe830"
echo "[`date +%T`] ALL DONE" >> $P
