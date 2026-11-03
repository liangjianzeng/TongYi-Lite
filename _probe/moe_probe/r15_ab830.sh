#!/system/bin/sh
# r15: K90(830) interleaved GPU vs CPU A/B x3, per-step logging, 48 tok
cd /data/local/tmp/moe830 || exit 1
export LD_LIBRARY_PATH=/data/local/tmp/moe830
M=/storage/emulated/0/TongYiLite/models/minicpm-v4.7-35b-a3b-les.gguf
E=/storage/emulated/0/TongYiLite/models/minicpm-v4.7-35b-a3b-les.experts
P=r15_progress.txt
rm -f $P
echo "[`date +%T`] start" >> $P

one() { # $1=name $2=extra_env
  echo "[`date +%T`] cooldown 90s" >> $P
  sleep 90
  echo "[`date +%T`] == $1 start" >> $P
  env $2 LLAMA_MOE_LOG_EVERY_STEP=1 \
    LLAMA_MOE_DECODE_WINDOW=8 LLAMA_MOE_LOOKAHEAD_PREFETCH=8 LLAMA_MOE_IO_THREADS=4 LLAMA_MOE_PREFETCH_READ=6 \
    ./minicpm_e2e $M $E 0 48 > run_$1.txt 2>&1
  grep -a "e2e" run_$1.txt | tail -1 >> $P
  echo "[`date +%T`] == $1 done" >> $P
}

one gpu1 ""
one cpu1 "GGML_OPENCL_OFF=1"
one gpu2 ""
one cpu2 "GGML_OPENCL_OFF=1"
one gpu3 ""
one cpu3 "GGML_OPENCL_OFF=1"
echo "[`date +%T`] ALL DONE" >> $P
