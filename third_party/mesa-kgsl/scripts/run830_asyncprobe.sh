#!/system/bin/sh
# [gen7 病灶局部化探针] async + 部分CBD —— 只在 ffn_moe_slots / result_output 节点同步，能否救 async 乱码？
# 判读：
#   async 无 CBD        = 乱码（10-24 矩阵 3/3 定案）
#   async + CBD 全节点  = 健康（10-18 复盘历史结论）
#   async + SLOTS 同步  = ?  ← 本实验主问题：能救 => 病灶局部化到 40 个槽位边界（BO/ring 候选强证）
#   async + OUT 单点    = ?  能救 => 同步点还可以更粗（修复面更小）
# 温和协议：每腿经 gentle_830.sh；NPRED=64；W=64（读量-82%）；共 3 次加载（配额 6）。
set -u
RUN=/data/local/tmp/mesa_run
B=/data/local/tmp/mesa_bionic
M=/storage/emulated/0/TongYiLite/models/minicpm-v4.7-35b-a3b-les.gguf
E=/storage/emulated/0/TongYiLite/models/minicpm-v4.7-35b-a3b-les.experts
LOGDIR=/data/local/tmp/asyncprobe_$(date +%m%d_%H%M)
NPRED=64; NGL=99; COOLDOWN=120; TMO=900
mkdir -p "$LOGDIR"
cd "$RUN" || exit 1
echo "#### asyncprobe run=$RUN logdir=$LOGDIR date=$(date -Iseconds)"
[ -f "$RUN/BUILD_INFO" ] && { echo "#### BUILD_INFO"; sed 's/^/#  /' "$RUN/BUILD_INFO" | head -4; }
echo "#### avail=$(awk '/MemAvailable/{print $2}' /proc/meminfo)kB swap=$(awk '/SwapTotal/{t=$2}/SwapFree/{f=$2}END{print t-f}' /proc/meminfo)kB"

export E2E_NBATCH=512 E2E_SEED=42 E2E_NOMMAP=1 E2E_TEMP=0.7
export GGML_E2E_PROMPT='请详细介绍一下中国的四大发明，分别说明每一项的历史背景、技术要点和对世界文明的影响，分四段展开，每段不少于八十字，不要简短总结'
export LLAMA_MOE_BANK_GPU=0 LLAMA_MOE_UPLOAD=0 LLAMA_MOE_PREFETCH_READ=6
export LLAMA_MOE_LOOKAHEAD_PREFETCH=8 LLAMA_MOE_DECODE_WINDOW=64 LLAMA_MOE_IO_THREADS=1

# async 腿：OPFLUSH 不设（默认异步提交）
BASE_ENV="LD_LIBRARY_PATH=$RUN:$RUN/lib:$B/lib:/data/local/tmp OCL_ICD_VENDORS=$B/lib/libRusticlOpenCL.so RUSTICL_ENABLE=kgsl HOME=$B/tmp XDG_CACHE_HOME=$B/tmp CLC_RESOURCE_DIR=$B/lib/clang/21/include GGML_OPENCL_ALLOW_NO_SUBGROUP=1 GGML_OPENCL_FAKE_QCOM_REQD=1 GGML_OPENCL_MESA_SPIRV=1 GGML_OPENCL_ADRENO_XMEM_GEMM=0"

for LEG in ASYNC_CBD_SLOTS ASYNC_CBD_OUT ASYNC_NOCBD; do
  case $LEG in
    ASYNC_CBD_SLOTS) EXTRA="E2E_CBD=1 E2E_CBD_ONLY=ffn_moe_slots" ;;
    ASYNC_CBD_OUT)   EXTRA="E2E_CBD=1 E2E_CBD_ONLY=result_output" ;;
    ASYNC_NOCBD)     EXTRA="" ;;
  esac
  L="$LOGDIR/${LEG}.log"; LERR="$LOGDIR/${LEG}.err"
  echo "-- LEG $LEG $(date -Iseconds)"
  env $EXTRA $BASE_ENV E2E_TOKDUMP="$LOGDIR/${LEG}.tok" \
    sh /data/local/tmp/gentle_830.sh "$LEG" \
    timeout "$TMO" ./minicpm_e2e "$M" "$E" "$NGL" "$NPRED" 512 > "$L" 2> "$LERR"
  GRC=$?
  MET=$(grep -a 'e2e\]\[METRIC' "$L" | tail -1)
  HT=$(grep -acE '上海|四大发明|造纸|印刷|指南针|火药' "$L")
  echo "--   rc=$GRC | ${MET:-NO_METRIC-or-SKIPPED} | health_hits=$HT"
  sleep "$COOLDOWN"
done
echo "#### done $(date -Iseconds)"
