#!/system/bin/sh
# [Mesa 线 P2] kgsl 提交层 kernel 丢失 —— 定位实验矩阵（正确性优先，不出性能数）
#
# 病灶（本线唯一真根因）：全图异步提交下 ggml 排队的 op 没有全部变成 GPU 上真正执行的 kernel，
# 正确性只在"每 ≤N op 一次 clFlush"下成立。本脚本用两把尺子夹它：
#   Phase A：扫 OPFLUSH 阈值（0/1/2/4/8/16/64）——看"丢"与积压深度的关系，是否 queue 深度相关；
#   Phase B：OPFLUSH=0（必乱码）下逐个开 Mesa 侧 FD_* 开关 —— 谁能把正确性救回来，谁就是病灶。
# 判定：主尺 = E2E_TOKDUMP 落 token 序列，用 scripts/token_diff.py 与 CPU 参照逐 token 比（"首个分歧位置"）；
#       辅尺 = 关键词命中行数（粗，只在 token 尺不可用时看）。temp=0 + NOMMAP 保证可复现。
# 注意：本矩阵所有腿 stderr 落文件（要数提交次数），性能数一律不用本脚本产物。
#
# 用法：sh run_p2_scan.sh [phase_a|phase_b|all] [n_predict=24]
set -u
PHASE=${1:-all}
NPRED=${2:-24}
RUN=${RUN:-/data/local/tmp/mesa_run}; B=${B:-/data/local/tmp/mesa_bionic}
M=${M:-/storage/emulated/0/TongYiLite/models/minicpm-v4.7-35b-a3b-les.gguf}
E=${E:-/storage/emulated/0/TongYiLite/models/minicpm-v4.7-35b-a3b-les.experts}
OUT=/data/local/tmp/p2_$(date +%H%M); mkdir -p $OUT
cd "$RUN" || exit 1

export LD_LIBRARY_PATH=$RUN:$RUN/lib:$B/lib:$B:/data/local/tmp
export OCL_ICD_VENDORS=$B/lib/libRusticlOpenCL.so RUSTICL_ENABLE=kgsl
export HOME=$B/tmp XDG_CACHE_HOME=$B/tmp CLC_RESOURCE_DIR=$B/lib/clang/21/include
export GGML_OPENCL_ALLOW_NO_SUBGROUP=1 GGML_OPENCL_FAKE_QCOM_REQD=1
export GGML_OPENCL_MESA_SPIRV=1 GGML_OPENCL_ADRENO_XMEM_GEMM=0
export E2E_NBATCH=512 E2E_SEED=42 E2E_NOMMAP=1 E2E_TEMP=0
export GGML_E2E_PROMPT='请详细介绍一下中国的四大发明，分别说明每一项的历史背景、技术要点和对世界文明的影响，分四段展开，每段不少于八十字，不要简短总结'
export LLAMA_MOE_BANK_GPU=0 LLAMA_MOE_UPLOAD=0 LLAMA_MOE_PREFETCH_READ=6
export LLAMA_MOE_LOOKAHEAD_PREFETCH=8 LLAMA_MOE_DECODE_WINDOW=8 LLAMA_MOE_IO_THREADS=1

clear_fds() { unset FD_NODEFER FD_NO_BOCACHE FD_FORCE_REEMIT FD_KGSL_TSSYNC FD_COMPUTE_WFI FD_IBTRACE FD_MESA_DEBUG FD_KGSL_USLEEP_US FD_RD_DUMP FD_RD_DUMP_SUBMITS; }
clear_fds
[ -f "$RUN/BUILD_INFO" ] && { echo "#### BUILD_INFO"; cat "$RUN/BUILD_INFO"; }
echo "#### phase=$PHASE npred=$NPRED date=$(date -Iseconds) loadavg=$(cat /proc/loadavg)"

# $1=tag $2=OPFLUSH $3..=额外 env 赋值
leg () {
  T=$1; OF=$2; shift 2
  L="$OUT/$T"; clear_fds
  echo "-- LEG $T OPFLUSH=$OF extra=$* $(date +%H:%M:%S)"
  env "$@" E2E_TOKDUMP=$L.tok GGML_OPENCL_OPFLUSH=$OF timeout 700 ./minicpm_e2e "$M" "$E" 99 "$NPRED" 512 > "$L.out" 2> "$L.err"
  RC=$?
  echo "   rc=$RC tok=$(grep -aoE 'tok_s=[0-9.]+' $L.out | tail -1) health=$(grep -acE '造纸|印刷|指南针|火药|四大发明' $L.out) SUB=$(grep -ac 'KGSLSUBMIT cmd\[' $L.err) BOREL=$(grep -ac BORERELEASE $L.err) WAIT=$(grep -ac '^KGSLWAIT' $L.err)"
  echo "   head=$(head -c 60 $L.out | tr -d '\n' | tr -d '\r')"
  sleep 45
}

if [ "$PHASE" = all ] || [ "$PHASE" = phase_a ]; then
  echo "===== PHASE A：OPFLUSH 阈值扫描（找 kernel 丢失与积压深度的关系）====="
  for N in 0 1 2 4 8 16 64; do leg "A_ofl$N" "$N"; done
fi

if [ "$PHASE" = all ] || [ "$PHASE" = phase_b ]; then
  echo "===== PHASE B：async(OPFLUSH=0) 下逐个 FD_* 开关，谁能救回正确性 ====="
  leg "B_base"      0
  leg "B_nodefer"   0 FD_NODEFER=1
  leg "B_nobocache" 0 FD_NO_BOCACHE=1
  leg "B_reemit"    0 FD_FORCE_REEMIT=1
  leg "B_tssync"    0 FD_KGSL_TSSYNC=1
  leg "B_wfi"       0 FD_COMPUTE_WFI=1
  leg "B_usleep"    0 FD_KGSL_USLEEP_US=1000
  leg "B_inorder"   0 FD_MESA_DEBUG=inorder
  leg "B_nogrow"    0 FD_MESA_DEBUG=nogrow
  leg "B_us1k_tss"  0 FD_KGSL_USLEEP_US=1000 FD_KGSL_TSSYNC=1
fi
echo "=== P2_SCAN_DONE dir=$OUT $(date -Iseconds) ==="
