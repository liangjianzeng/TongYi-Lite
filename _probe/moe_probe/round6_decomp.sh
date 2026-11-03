#!/system/bin/sh
# round6 decomposition: split the ~900ms unaccounted time
# d_base      = full GPU-bank path (prefetch read6 config)
# d_skread    = SKIP_READ=1  -> no real UFS reads (keeps accounting)
# d_skpack    = SKIP_READ=1 + SKIP_PACK=1 -> graph compute + per-layer sync only
cd /data/local/tmp/moe5 || exit 1
export LD_LIBRARY_PATH=/data/local/tmp/moe5
M=/storage/emulated/0/TongYiLite/models/minicpm-v4.7-35b-a3b-les.gguf
E=/storage/emulated/0/TongYiLite/models/minicpm-v4.7-35b-a3b-les.experts
P=round6_decomp.txt
rm -f $P
echo "[`date +%T`] start" >> $P

one() {
  echo "[`date +%T`] cooldown 90s ($1)" >> $P
  sleep 90
  echo "[`date +%T`] == $1 start" >> $P
  env $2 ./minicpm_e2e $M $E 0 64 > run_$1.txt 2>&1
  grep -a "e2e" run_$1.txt | tail -1 >> $P
  grep -a "\[step\]" run_$1.txt | tail -6 >> $P
  grep -a "moe-ssd" run_$1.txt | tail -3 >> $P
  echo "[`date +%T`] == $1 done" >> $P
}

one d_base "LLAMA_MOE_DECODE_WINDOW=8 LLAMA_MOE_LOOKAHEAD_PREFETCH=8 LLAMA_MOE_IO_THREADS=4 LLAMA_MOE_PREFETCH_READ=6"
one d_skread "LLAMA_MOE_DECODE_WINDOW=8 LLAMA_MOE_LOOKAHEAD_PREFETCH=8 LLAMA_MOE_IO_THREADS=4 LLAMA_MOE_PREFETCH_READ=6 LLAMA_MOE_SKIP_READ=1"
one d_skpack "LLAMA_MOE_DECODE_WINDOW=8 LLAMA_MOE_LOOKAHEAD_PREFETCH=8 LLAMA_MOE_IO_THREADS=4 LLAMA_MOE_PREFETCH_READ=6 LLAMA_MOE_SKIP_READ=1 LLAMA_MOE_SKIP_PACK=1"
echo "[`date +%T`] ALL DONE" >> $P
