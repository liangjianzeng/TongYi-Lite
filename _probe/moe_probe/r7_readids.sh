#!/system/bin/sh
# r7: per-step readids/writeids split of the 156ms graph floor
# needs the NEW libllama.so (flush_ubatch prints readids= writeids=)
cd /data/local/tmp/moe5 || exit 1
export LD_LIBRARY_PATH=/data/local/tmp/moe5
M=/storage/emulated/0/TongYiLite/models/minicpm-v4.7-35b-a3b-les.gguf
E=/storage/emulated/0/TongYiLite/models/minicpm-v4.7-35b-a3b-les.experts
P=r7_progress.txt
rm -f $P
echo "[`date +%T`] start" >> $P

echo "[`date +%T`] cooldown 60s (r7_base)" >> $P
sleep 60
echo "[`date +%T`] == r7_base start" >> $P
LLAMA_MOE_LOG_EVERY_STEP=1 \
LLAMA_MOE_DECODE_WINDOW=8 LLAMA_MOE_LOOKAHEAD_PREFETCH=8 LLAMA_MOE_IO_THREADS=4 LLAMA_MOE_PREFETCH_READ=6 \
  ./minicpm_e2e $M $E 0 64 > run_r7_base.txt 2>&1
grep -a "e2e" run_r7_base.txt | tail -1 >> $P
echo "[`date +%T`] == r7_base done" >> $P

echo "[`date +%T`] cooldown 60s (r7_skpack)" >> $P
sleep 60
echo "[`date +%T`] == r7_skpack start" >> $P
LLAMA_MOE_LOG_EVERY_STEP=1 \
LLAMA_MOE_DECODE_WINDOW=8 LLAMA_MOE_LOOKAHEAD_PREFETCH=8 LLAMA_MOE_IO_THREADS=4 LLAMA_MOE_PREFETCH_READ=6 \
LLAMA_MOE_SKIP_READ=1 LLAMA_MOE_SKIP_PACK=1 \
  ./minicpm_e2e $M $E 0 64 > run_r7_skpack.txt 2>&1
grep -a "e2e" run_r7_skpack.txt | tail -1 >> $P
echo "[`date +%T`] == r7_skpack done" >> $P
echo "[`date +%T`] ALL DONE" >> $P
