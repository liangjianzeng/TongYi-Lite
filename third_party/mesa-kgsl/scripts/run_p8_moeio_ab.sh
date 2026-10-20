#!/system/bin/sh
# [Mesa 线 P8] 专家装载 A/B：今天把 decode 预算拆开后发现 **专家 I/O 占 ~25%**（K40 实测
# pread_wall=399ms/token、412MB/token、hit=0、avg_run=1.00、syscalls=99.7% —— 缓存与合并两条路都没吃到）。
# 而 loader（third_party/llama.cpp/src/llama-moe-slot.cpp）里早就埋了一排没测过的开关：
#   LLAMA_MOE_LOOKAHEAD_PREFETCH(+_DEPTH) / LLAMA_MOE_IO_THREADS / LLAMA_MOE_DECODE_WINDOW /
#   LLAMA_MOE_FATE(+_DEPTH) / LLAMA_MOE_PREFETCH_READ / LLAMA_MOE_PREFETCH_UNIFIED / LLAMA_MOE_ROUTE_KEEP
# ⇒ 这是今天牌桌上唯一"不用重编 Mesa 就可能吃掉 25%"的一项，优先测它。
#
# 口径（不许松）：**安静态**（loadavg>2 直接拒绝跑）+ **交错**（外层轮次，内层腿序固定）+ 每配置 2 轮起 +
# 冷却；只比 decode t/s；**GPU 证据硬闸**（opencl_lines>0 且 drop=0，否则该腿是退回 CPU 的假数）。
# 判据：相对 base 的 decode t/s 提升 ≥5% 且两轮同号才算"该开关有效"；
#       同时必须看 pread 墙钟有没有真的降 —— **t/s 涨了但 pread 没降 = 别处省出来的，不算这项的功劳**。
#
# 用法：RUN=<dir> B=<mesa_dir> M=<gguf> E=<experts> sh run_p8_moeio_ab.sh [npred=64] [rounds=2]
set -u
BIN=${BIN:-minicpm_e2e}
NPRED=${1:-64}; ROUNDS=${2:-2}
RUN=${RUN:?}; B=${B:?}; M=${M:?}; E=${E:?}
LOAD=$(cut -d' ' -f1 /proc/loadavg)
if [ "${LOAD%.*}" -gt 2 ] 2>/dev/null; then echo "!! loadavg=$LOAD > 2，非安静态，拒绝出裁决数"; exit 3; fi
STAMP=$(date +%H%M); OUT=/data/local/tmp/p8_$STAMP; mkdir -p $OUT
cd "$RUN" || exit 1
export LD_LIBRARY_PATH=$RUN:$RUN/lib:$B/lib:$B:/data/local/tmp
export OCL_ICD_VENDORS=$B/lib/libRusticlOpenCL.so RUSTICL_ENABLE=kgsl
export HOME=$B/tmp XDG_CACHE_HOME=$B/tmp CLC_RESOURCE_DIR=$B/lib/clang/21/include
export GGML_OPENCL_ALLOW_NO_SUBGROUP=1 GGML_OPENCL_FAKE_QCOM_REQD=1
export GGML_OPENCL_MESA_SPIRV=1 GGML_OPENCL_ADRENO_XMEM_GEMM=0
export GGML_OPENCL_OPFLUSH=1                      # 今天定下的默认（gen6/gen7 都更快）
export E2E_SEED=42 E2E_TEMP=0 E2E_NOMMAP=1
export GGML_E2E_PROMPT='请详细介绍一下中国的四大发明，分别说明每一项的历史背景、技术要点和对世界文明的影响，分四段展开，每段不少于八十字，不要简短总结。'
[ -f "$RUN/BUILD_INFO" ] && cat "$RUN/BUILD_INFO"
echo "#### p8 moeio npred=$NPRED rounds=$ROUNDS loadavg=$LOAD $(date -Iseconds)"

leg () { # $1=tag  $2..=env
  T=$1; shift
  echo "-- LEG $T [$*] $(date +%H:%M:%S) load=$(cut -d' ' -f1 /proc/loadavg)"
  env "$@" E2E_TOKDUMP=$OUT/$T.tok timeout 900 ./$BIN "$M" "$E" 99 "$NPRED" 512 \
    > $OUT/$T.out 2> $OUT/$T.err
  echo "   rc=$? $(grep -a 'e2e\]\[METRIC' $OUT/$T.out | tail -1 | grep -aoE 'gen=[0-9]+ wall_ms=[0-9]+ tok_s=[0-9.]+ load_ms=[0-9]+')"
  echo "   $(grep -a 'total\[final\]' $OUT/$T.err | tail -1) | $(grep -aoE 'pread_wall=[0-9]+ms' $OUT/$T.err | tail -1) | $(grep -aoE 'hit=[0-9]+ miss=[0-9]+' $OUT/$T.err | tail -1) | gpu[lines=$(grep -ac ggml_opencl $OUT/$T.err) drop=$(grep -ac 'drop unsupported device' $OUT/$T.err)]"
  sleep 60
}
R=1
while [ $R -le "$ROUNDS" ]; do
  echo "===== ROUND $R ====="
  leg base_r$R
  leg la1_r$R   LLAMA_MOE_LOOKAHEAD_PREFETCH=1 LLAMA_MOE_LOOKAHEAD_PREFETCH_DEPTH=1
  leg la2_r$R   LLAMA_MOE_LOOKAHEAD_PREFETCH=1 LLAMA_MOE_LOOKAHEAD_PREFETCH_DEPTH=3
  leg io8_r$R   LLAMA_MOE_IO_THREADS=8
  leg win_r$R   LLAMA_MOE_DECODE_WINDOW=64 LLAMA_MOE_ROUTE_KEEP=1
  R=$((R+1))
done
echo "=== P8_MOEIO_DONE dir=$OUT ==="
echo "读法：按 tag 前缀取各轮 tok_s 求中位，与 base 比；≥5% 且两轮同号才算有效，且 pread_wall 必须同向下降"
