#!/system/bin/sh
# [ffn_moe_slots 方案 §4 案 B · 温和版 v2] CBD 往返测量 —— 830 / MESA_FLUSH1
# v2 变更（10-24 死机事故后）：
#   1. 每腿必经 gentle_830.sh 包装（会话/每腿内存门 + 跑中看门狗 + 加载配额 6 次）；
#   2. DECODE_WINDOW=8 -> 64（采纳配置：读量 -82%，页缓存冲刷大幅减少，对日常机友好）；
#   3. NPRED 128 -> 64（诊断用途 t/s 精度足够，腿时长减半）；
#   4. 冷却 90 -> 120s。
# 三腿 x 2 轮 = 6 次加载 = 配额上限，正好一满会话；若看门狗/前置跳过某腿，少的数据下轮补。
# 判读不变：CBD_SLOTS vs CBD_OFF 差 = 40 次往返上界（含审计税）；CBD_OUT = 单点税标定。
set -u
RUN=/data/local/tmp/mesa_run
B=/data/local/tmp/mesa_bionic
M=/storage/emulated/0/TongYiLite/models/minicpm-v4.7-35b-a3b-les.gguf
E=/storage/emulated/0/TongYiLite/models/minicpm-v4.7-35b-a3b-les.experts
LOGDIR=/data/local/tmp/cbdab_$(date +%m%d_%H%M)
NPRED=${NPRED:-64}; NGL=99; COOLDOWN=${COOLDOWN:-120}; TMO=900
mkdir -p "$LOGDIR"
cd "$RUN" || exit 1
echo "#### cbdab-v2 run=$RUN logdir=$LOGDIR date=$(date -Iseconds)"
[ -f "$RUN/BUILD_INFO" ] && { echo "#### BUILD_INFO"; sed 's/^/#  /' "$RUN/BUILD_INFO" | head -4; }
echo "#### loadavg=$(cat /proc/loadavg) avail=$(awk '/MemAvailable/{print $2}' /proc/meminfo)kB swap=$(awk '/SwapTotal/{t=$2}/SwapFree/{f=$2}END{print t-f}' /proc/meminfo)kB"

export E2E_NBATCH=512 E2E_SEED=42 E2E_NOMMAP=1 E2E_TEMP=0.7
export GGML_E2E_PROMPT='请详细介绍一下中国的四大发明，分别说明每一项的历史背景、技术要点和对世界文明的影响，分四段展开，每段不少于八十字，不要简短总结'
export LLAMA_MOE_BANK_GPU=0 LLAMA_MOE_UPLOAD=0 LLAMA_MOE_PREFETCH_READ=6
export LLAMA_MOE_LOOKAHEAD_PREFETCH=8 LLAMA_MOE_DECODE_WINDOW=64 LLAMA_MOE_IO_THREADS=1

BASE_ENV="LD_LIBRARY_PATH=$RUN:$RUN/lib:$B/lib:/data/local/tmp OCL_ICD_VENDORS=$B/lib/libRusticlOpenCL.so RUSTICL_ENABLE=kgsl HOME=$B/tmp XDG_CACHE_HOME=$B/tmp CLC_RESOURCE_DIR=$B/lib/clang/21/include GGML_OPENCL_ALLOW_NO_SUBGROUP=1 GGML_OPENCL_FAKE_QCOM_REQD=1 GGML_OPENCL_MESA_SPIRV=1 GGML_OPENCL_ADRENO_XMEM_GEMM=0 GGML_OPENCL_OPFLUSH=1"

R=1
while [ $R -le 2 ]; do
  for LEG in CBD_OFF CBD_SLOTS CBD_OUT; do
    case $LEG in
      CBD_OFF)   EXTRA="" ;;
      CBD_SLOTS) EXTRA="E2E_CBD=1 E2E_CBD_ONLY=ffn_moe_slots" ;;
      CBD_OUT)   EXTRA="E2E_CBD=1 E2E_CBD_ONLY=result_output" ;;
    esac
    L="$LOGDIR/${LEG}_r$R.log"; LERR="$LOGDIR/${LEG}_r$R.err"
    echo "-- LEG $LEG round=$R $(date -Iseconds)"
    # 每腿经 gentle_830.sh：内存门 + 看门狗 + 配额（任一不过自动跳过并记日志）
    env $EXTRA $BASE_ENV E2E_TOKDUMP="$LOGDIR/${LEG}_r$R.tok" \
      sh /data/local/tmp/gentle_830.sh "$LEG" \
      timeout "$TMO" ./minicpm_e2e "$M" "$E" "$NGL" "$NPRED" 512 > "$L" 2> "$LERR"
    GRC=$?
    MET=$(grep -a 'e2e\]\[METRIC' "$L" | tail -1)
    HT=$(grep -acE '上海|四大发明|造纸|印刷|指南针|火药' "$L")
    GSUB=$(grep -acE "KGSLSUBMIT|clFlush|QueueSubmit|clEnqueue" "$LERR")
    echo "--   rc=$GRC | ${MET:-NO_METRIC-or-SKIPPED} | health_hits=$HT | submits=$GSUB"
    [ "$GRC" -eq 4 ] && echo "--   （该腿被温和协议跳过：等内存回落后重跑本脚本即可补）"
    sleep "$COOLDOWN"
  done
  R=$((R+1))
done
echo "#### done $(date -Iseconds) 会话加载配额请看 /data/local/tmp/gentle_state/loads"
