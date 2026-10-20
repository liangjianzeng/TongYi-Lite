#!/system/bin/sh
# [Mesa 线 · 设备侧测量矩阵] 唯一合法的性能取数入口（P0-3）
#
# 规矩（血泪教训：2026-10-19 那批"Mesa 只有 1.2 t/s"的数全是带 per-op clFlush + 带逐提交
# printf 的调试版 Mesa 测出来的，据此做的整线裁决已作废）：
#   1. 每条腿打印完整 env 指纹 + 构建指纹 + 机身负载/温度，缺指纹的数不入档；
#   2. CPU 对手腿与 Mesa 腿同会话交错、每腿之间冷却 COOLDOWN 秒，重复 N 轮取中位；
#   3. OPFLUSH 必须显式两档（async / flush1），禁止把安全阀写死在环境里当性能；
#   4. 计时腿的 stderr 一律丢 /dev/null（在机 Mesa 是逐提交打 trace 的调试版，落文件会反噬计时），
#      性能数只认 stdout 的 [e2e][METRIC] 行（e2e 源码已把 t/s 从 stderr 搬来 stdout）；
#   5. 专家流式 IO 单独记账（total[decode] pread），否则"慢"算不到头上。
#
# 用法（830，shell）：
#   sh run_mesa_matrix.sh <运行目录:含 minicpm_e2e 与 lib/libopencl_stub.so> [轮数=3] [legs]
#   legs 默认 CPU,MESA_ASYNC,MESA_FLUSH1（可加 VENDOR）
#   可调环境变量：NPRED=128 COOLDOWN=90 NGL=99 TMO=900 B=/data/local/tmp/mesa_bionic
set -u
RUN=${1:-/data/local/tmp/mesa_run}
ROUNDS=${2:-3}
LEGS=${3:-CPU,MESA_ASYNC,MESA_FLUSH1}

B=${B:-/data/local/tmp/mesa_bionic}                # bionic 版 rusticl + freedreno + kgsl
M=${M:-/storage/emulated/0/TongYiLite/models/minicpm-v4.7-35b-a3b-les.gguf}
E=${E:-/storage/emulated/0/TongYiLite/models/minicpm-v4.7-35b-a3b-les.experts}
COOLDOWN=${COOLDOWN:-90}
NPRED=${NPRED:-128}                                # n_predict（历史 256 token 协议：NPRED=256）
NGL=${NGL:-99}
TMO=${TMO:-900}
BIN=${BIN:-minicpm_e2e}          # K40 上是 minicpm_e2e_dspark（本机 HEAD 构），830 上是 minicpm_e2e
LOGDIR=${LOGDIR:-/data/local/tmp/matrix_$(date +%m%d_%H%M)}
mkdir -p "$LOGDIR"

# ---- 统一协议（与 e9_830.sh 同源）----
# CPU 对手腿用今天扫出来的最优配置（IO=1/W=8/LA8 = 7.00 t/s）；IO=4 会把 CPU bank 打到 3.0-4.2，
# 对手数不锁配置等于没有基线。所有腿共用同一份 env，只换后端开关。
export E2E_NBATCH=512 E2E_SEED=42 E2E_NOMMAP=1 E2E_TEMP=0.7   # NOMMAP：外置存储 mmap 读回垃圾页
export GGML_E2E_PROMPT='请详细介绍一下中国的四大发明，分别说明每一项的历史背景、技术要点和对世界文明的影响，分四段展开，每段不少于八十字，不要简短总结'
export LLAMA_MOE_BANK_GPU=0 LLAMA_MOE_UPLOAD=0 LLAMA_MOE_PREFETCH_READ=6
export LLAMA_MOE_LOOKAHEAD_PREFETCH=8 LLAMA_MOE_DECODE_WINDOW=8 LLAMA_MOE_IO_THREADS=1

# libopencl_stub.so 是二进制的 DT_NEEDED：任何腿（连纯 CPU 腿）都必须能让动态加载器找到它，
# 否则进程连 exec 都失败（rc=1，症状像"模型打不开"）。VENDOR 腿给 $RUN/lib 但不给 $B/lib。
# 坑（K40 实测踩过，整轮矩阵 2 分钟全腿 rc=1）：libggml*.so 与 stub 在 K40 上直接躺在 $RUN
# 根目录而不是 $RUN/lib，所以 $RUN 本身必须在 LD_LIBRARY_PATH 里。
MESA_ENV="LD_LIBRARY_PATH=$RUN:$RUN/lib:$B/lib:/data/local/tmp OCL_ICD_VENDORS=$B/lib/libRusticlOpenCL.so RUSTICL_ENABLE=kgsl HOME=$B/tmp XDG_CACHE_HOME=$B/tmp CLC_RESOURCE_DIR=$B/lib/clang/21/include GGML_OPENCL_ALLOW_NO_SUBGROUP=1 GGML_OPENCL_FAKE_QCOM_REQD=1 GGML_OPENCL_MESA_SPIRV=1 GGML_OPENCL_ADRENO_XMEM_GEMM=0"
VENDOR_ENV="LD_LIBRARY_PATH=$RUN:$RUN/lib:/vendor/lib64:/system/lib64:/data/local/tmp OCL_ICD_VENDORS= RUSTICL_ENABLE= HOME=/data/local/tmp XDG_CACHE_HOME=/data/local/tmp"

cd "$RUN" || exit 1
# 预检：跑完 6 条腿才发现"二进制找不到"是白烧半小时（rc=127 与 rc=1 在日志里长得一样）
[ -x "$RUN/$BIN" ] || { echo "!! 预检失败：$RUN/$BIN 不存在或不可执行（BIN= 可覆盖）" >&2; exit 2; }
[ -f "$M" ] || { echo "!! 预检失败：模型 $M 不存在" >&2; exit 2; }
[ -d "$E" ] || { echo "!! 预检失败：专家目录 $E 不存在" >&2; exit 2; }
echo "#### run=$RUN rounds=$ROUNDS legs=$LEGS npred=$NPRED ngl=$NGL date=$(date -Iseconds)"
[ -f "$RUN/BUILD_INFO" ] && { echo "#### BUILD_INFO"; cat "$RUN/BUILD_INFO"; }
echo "#### loadavg=$(cat /proc/loadavg) temp=$(dumpsys battery 2>/dev/null | grep -m1 temperature | tr -d ' ')"
echo "#### cpu7=$(cat /sys/devices/system/cpu/cpu7/cpufreq/scaling_cur_freq 2>/dev/null) gpuclk=$(cat /sys/class/kgsl/kgsl-3d0/gpuclk 2>/dev/null)"
echo "#### logdir=$LOGDIR"

one () {  # $1=tag  $2..=env 覆盖
  TAG=$1; shift
  R=1
  while [ $R -le "$ROUNDS" ]; do
    L="$LOGDIR/${TAG}_r$R.log"
    echo "-- LEG $TAG round=$R $(date -Iseconds)"
    echo "--   env: $(env "$@" printenv 2>/dev/null | grep -aE 'OPFLUSH|OCL_ICD|RUSTICL|GGML_OPENCL_(ALLOW|FAKE|MESA|ADRENO)|LD_LIBRARY' | tr '\n' ' ')"
    env "$@" E2E_TOKDUMP="$LOGDIR/${TAG}_r$R.tok" timeout "$TMO" "./$BIN" "$M" "$E" "$NGL" "$NPRED" 512 > "$L" 2>/dev/null
    RC=$?
    MET=$(grep -a 'e2e\]\[METRIC' "$L" | tail -1)
    PF=$(grep -a 'prefill' "$L" | tail -1)
    IO=$(grep -a 'total\[decode\]' "$L" | tail -1)
    HT=$(grep -acE '上海|四大发明|造纸|印刷|指南针|火药' "$L")
    echo "--   rc=$RC | ${MET:-NO_METRIC} | ${PF:-no_prefill} | health_hits=$HT"
    echo "--   io: ${IO:-no_decode_io_stats}"
    R=$((R+1))
    [ $R -le "$ROUNDS" ] && sleep "$COOLDOWN"
  done
}

for L in $(echo "$LEGS" | tr ',' ' '); do
  case $L in
    CPU)         one CPU_BANK   LD_LIBRARY_PATH=$RUN:$RUN/lib:/data/local/tmp GGML_OPENCL_OFF=1 GGML_OPENCL_OPFLUSH=0 ;;
    VENDOR)      one VENDOR_ICD $VENDOR_ENV ;;
    MESA_ASYNC)  one MESA_ASYNC $MESA_ENV GGML_OPENCL_OPFLUSH=0 ;;
    MESA_FLUSH1) one MESA_FLUSH1 $MESA_ENV GGML_OPENCL_OPFLUSH=1 ;;
    *) echo "未知腿 $L（可用：CPU,VENDOR,MESA_ASYNC,MESA_FLUSH1）" ;;
  esac
  sleep "$COOLDOWN"
done
echo "=== MATRIX_DONE $(date -Iseconds) ==="
