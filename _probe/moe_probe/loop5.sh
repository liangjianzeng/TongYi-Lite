#!/system/bin/sh
# round 5: 交错冷态 A/B —— read6 vs read8(read全深) 各2次 + read5 一次
# 每跑前冷却 150s，交错次序消热态混杂
cd /data/local/tmp/moe5 || exit 1
export LD_LIBRARY_PATH=/data/local/tmp/moe5
M=/storage/emulated/0/TongYiLite/models/minicpm-v4.7-35b-a3b-les.gguf
E=/storage/emulated/0/TongYiLite/models/minicpm-v4.7-35b-a3b-les.experts
P=round5_progress.txt
rm -f $P
echo "[`date +%T`] start" >> $P

one() { # $1=name $2=PREFETCH_READ
  echo "[`date +%T`] cooldown 150s" >> $P
  sleep 150
  echo "[`date +%T`] == $1 start" >> $P
  LLAMA_MOE_DECODE_WINDOW=8 LLAMA_MOE_LOOKAHEAD_PREFETCH=8 LLAMA_MOE_IO_THREADS=4 \
    LLAMA_MOE_PREFETCH_READ=$2 \
    ./minicpm_e2e $M $E 0 48 > run_$1.txt 2>&1
  grep -a "e2e" run_$1.txt | tail -1 >> $P
  echo "[`date +%T`] == $1 done" >> $P
}

one r5_read6a 6
one r5_read8a 8
one r5_read6b 6
one r5_read8b 8
one r5_read5 5
echo "[`date +%T`] ALL DONE" >> $P
