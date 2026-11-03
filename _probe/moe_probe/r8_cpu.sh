#!/system/bin/sh
# r8: CPU-only floor (OpenCL init forced to fail via bogus platform)
cd /data/local/tmp/moe5 || exit 1
export LD_LIBRARY_PATH=/data/local/tmp/moe5
M=/storage/emulated/0/TongYiLite/models/minicpm-v4.7-35b-a3b-les.gguf
E=/storage/emulated/0/TongYiLite/models/minicpm-v4.7-35b-a3b-les.experts
P=r8_progress.txt
rm -f $P
echo "[`date +%T`] start" >> $P
sleep 30
echo "[`date +%T`] == r8_cpu start" >> $P
LLAMA_MOE_LOG_EVERY_STEP=1 GGML_OPENCL_PLATFORM=NOSUCHDEV \
LLAMA_MOE_DECODE_WINDOW=8 LLAMA_MOE_LOOKAHEAD_PREFETCH=8 LLAMA_MOE_IO_THREADS=4 LLAMA_MOE_PREFETCH_READ=6 \
  ./minicpm_e2e $M $E 0 24 > run_r8_cpu.txt 2>&1
grep -a "e2e" run_r8_cpu.txt | tail -1 >> $P
echo "[`date +%T`] == r8_cpu done" >> $P
echo "[`date +%T`] ALL DONE" >> $P
