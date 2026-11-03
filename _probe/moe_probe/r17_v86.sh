#!/system/bin/sh
# r17: K90(830) CPU dispatch A/B: baseline libggml-cpu vs v86 (armv8.6+dotprod+i8mm+fp16+bf16+KleidiAI)
# usage: r17_v86.sh [baseline|v86]
cd /data/local/tmp/moe830 || exit 1
export LD_LIBRARY_PATH=/data/local/tmp/moe830
M=/storage/emulated/0/TongYiLite/models/minicpm-v4.7-35b-a3b-les.gguf
E=/storage/emulated/0/TongYiLite/models/minicpm-v4.7-35b-a3b-les.experts
VARIANT=$1
P=r17_progress.txt
echo "[`date +%T`] cooldown 90s ($VARIANT)" >> $P
sleep 90
echo "[`date +%T`] == $VARIANT start" >> $P
LLAMA_MOE_LOG_EVERY_STEP=1 \
  LLAMA_MOE_DECODE_WINDOW=8 LLAMA_MOE_LOOKAHEAD_PREFETCH=8 LLAMA_MOE_IO_THREADS=4 LLAMA_MOE_PREFETCH_READ=6 \
  ./minicpm_e2e $M $E 0 64 > run_r17_$VARIANT.txt 2>&1
grep -a "e2e" run_r17_$VARIANT.txt | tail -1 >> $P
echo "[`date +%T`] == $VARIANT done" >> $P
