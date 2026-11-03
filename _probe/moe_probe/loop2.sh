#!/system/bin/sh
# round 2: 收 M1 的 2%（2.90 -> 2.97）
# 矩阵: 基线复测 / io=3 / io=6 / window=12 / window=12+io=6 / 早层加宽
cd /data/local/tmp/moe5 || exit 1
export LD_LIBRARY_PATH=/data/local/tmp/moe5
M=/storage/emulated/0/TongYiLite/models/minicpm-v4.7-35b-a3b-les.gguf
E=/storage/emulated/0/TongYiLite/models/minicpm-v4.7-35b-a3b-les.experts
P=round2_progress.txt
rm -f $P
echo "[`date +%T`] start" >> $P

run() {
  name=$1
  shift
  echo "[`date +%T`] == $name start" >> $P
  "$@" ./minicpm_e2e $M $E 0 48 > run_$name.txt 2>&1
  grep -a "e2e" run_$name.txt | tail -1 >> $P
  echo "[`date +%T`] == $name done" >> $P
}

# A: 基线复测（方差参考）
run a_io4 env LLAMA_MOE_DECODE_WINDOW=8 LLAMA_MOE_LOOKAHEAD_PREFETCH=8 LLAMA_MOE_IO_THREADS=4
# B: io=3
run b_io3 env LLAMA_MOE_DECODE_WINDOW=8 LLAMA_MOE_LOOKAHEAD_PREFETCH=8 LLAMA_MOE_IO_THREADS=3
# C: io=6
run c_io6 env LLAMA_MOE_DECODE_WINDOW=8 LLAMA_MOE_LOOKAHEAD_PREFETCH=8 LLAMA_MOE_IO_THREADS=6
# D: window=12（cache12+pf8=20 slot/层, ~1.0GiB）
run d_w12 env LLAMA_MOE_DECODE_WINDOW=12 LLAMA_MOE_LOOKAHEAD_PREFETCH=8 LLAMA_MOE_IO_THREADS=4
# E: window=12 + io=6
run e_w12io6 env LLAMA_MOE_DECODE_WINDOW=12 LLAMA_MOE_LOOKAHEAD_PREFETCH=8 LLAMA_MOE_IO_THREADS=6
# F: 早层加宽（miss 高的 l0-l5 给 16，其余 8）
run f_early16 env LLAMA_MOE_DECODE_WINDOW=8 LLAMA_MOE_LOOKAHEAD_PREFETCH=8 LLAMA_MOE_IO_THREADS=4 LLAMA_MOE_LAYER_WINDOWS=0:16,1:16,2:16,3:16,4:16,5:16

echo "[`date +%T`] ALL DONE" >> $P
