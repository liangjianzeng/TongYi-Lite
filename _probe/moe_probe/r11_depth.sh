#!/system/bin/sh
# r11: lookahead depth sweep (window 8 -> 12/16), 32 tok each
cd /data/local/tmp/moe5 || exit 1
export LD_LIBRARY_PATH=/data/local/tmp/moe5
M=/storage/emulated/0/TongYiLite/models/minicpm-v4.7-35b-a3b-les.gguf
E=/storage/emulated/0/TongYiLite/models/minicpm-v4.7-35b-a3b-les.experts
P=r11_progress.txt
rm -f $P
echo "[`date +%T`] start" >> $P

one() {
  echo "[`date +%T`] cooldown 45s ($1)" >> $P
  sleep 45
  echo "[`date +%T`] == $1 start" >> $P
  env $2 ./minicpm_e2e $M $E 0 32 > run_$1.txt 2>&1
  grep -a "e2e" run_$1.txt | tail -1 >> $P
  echo "[`date +%T`] == $1 done" >> $P
}

one r11_d12 "LLAMA_MOE_DECODE_WINDOW=12 LLAMA_MOE_LOOKAHEAD_PREFETCH=12 LLAMA_MOE_IO_THREADS=4 LLAMA_MOE_PREFETCH_READ=6"
one r11_d16 "LLAMA_MOE_DECODE_WINDOW=16 LLAMA_MOE_LOOKAHEAD_PREFETCH=16 LLAMA_MOE_IO_THREADS=4 LLAMA_MOE_PREFETCH_READ=6"
echo "[`date +%T`] ALL DONE" >> $P
