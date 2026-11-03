#!/system/bin/sh
# r10: attack pmgmt (IO critical path). warm sweep: io threads x prefetch read
# all legs GPU-bank base config unless noted, 32 tokens each
cd /data/local/tmp/moe5 || exit 1
export LD_LIBRARY_PATH=/data/local/tmp/moe5
M=/storage/emulated/0/TongYiLite/models/minicpm-v4.7-35b-a3b-les.gguf
E=/storage/emulated/0/TongYiLite/models/minicpm-v4.7-35b-a3b-les.experts
P=r10_progress.txt
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

BASE="LLAMA_MOE_DECODE_WINDOW=8 LLAMA_MOE_LOOKAHEAD_PREFETCH=8 LLAMA_MOE_IO_THREADS=4 LLAMA_MOE_PREFETCH_READ=6"
one r10_io6   "LLAMA_MOE_DECODE_WINDOW=8 LLAMA_MOE_LOOKAHEAD_PREFETCH=8 LLAMA_MOE_IO_THREADS=6 LLAMA_MOE_PREFETCH_READ=6"
one r10_io8   "LLAMA_MOE_DECODE_WINDOW=8 LLAMA_MOE_LOOKAHEAD_PREFETCH=8 LLAMA_MOE_IO_THREADS=8 LLAMA_MOE_PREFETCH_READ=6"
one r10_rd8   "LLAMA_MOE_DECODE_WINDOW=8 LLAMA_MOE_LOOKAHEAD_PREFETCH=8 LLAMA_MOE_IO_THREADS=4 LLAMA_MOE_PREFETCH_READ=8"
one r10_io8rd8 "LLAMA_MOE_DECODE_WINDOW=8 LLAMA_MOE_LOOKAHEAD_PREFETCH=8 LLAMA_MOE_IO_THREADS=8 LLAMA_MOE_PREFETCH_READ=8"
one r10_rd10  "LLAMA_MOE_DECODE_WINDOW=8 LLAMA_MOE_LOOKAHEAD_PREFETCH=8 LLAMA_MOE_IO_THREADS=6 LLAMA_MOE_PREFETCH_READ=10"
echo "[`date +%T`] ALL DONE" >> $P
