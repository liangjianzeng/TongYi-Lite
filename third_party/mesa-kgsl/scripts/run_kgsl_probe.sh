#!/system/bin/sh
# [Mesa 线 P2] kgsl 提交层 kernel 丢失 · 变体矩阵（排错体，不出性能数）
#
# 病灶：全图异步提交下 271390 enqueued op 只对应 118586 次提交（`ee87dda0`），
# 正确性只在"每 ≤8 op 一次 clFlush"下成立 —— 这是本线当前唯一的真根因：
# 它同时是"必须开 OPFLUSH"的原因与"提交税看起来 5 倍于 vendor"的原因。
# 本脚本只做一件事：同一 e2e 输入下，逐 Mesa 侧 FD_* 开关量出「提交计数 / 文本健康」两列，
# 把 10-19 那次一拥而上的 17 个变体（ib/ib2/nodefer/reemit/tssync/wfi/nocache/fdflush/
# fence/inorder/nogrow/csdsc/ureal/inst/grave/rw…）变成可复现的矩阵，而不是散装日志。
#
# 用法：sh run_kgsl_probe.sh <运行目录> [n_gen=8] [OPFLUSH档=0]
#   跑完看表：SUB=KGSLSUBMIT cmd[] 行数、NC=nr_cmds_total、TXT=是否出现验收文本、RC
set -u
RUN=${1:-/data/local/tmp/mesa_run}
NG=${2:-8}
OFL=${3:-0}
B=/data/local/tmp/mesa_bionic
M=/storage/emulated/0/TongYiLite/models/minicpm-v4.7-35b-a3b-les.gguf
E=/storage/emulated/0/TongYiLite/models/minicpm-v4.7-35b-a3b-les.experts
OUT=/data/local/tmp/kgsl_probe
mkdir -p $OUT
cd "$RUN" || exit 1

export LD_LIBRARY_PATH="$RUN/lib:$B/lib:/data/local/tmp"
export OCL_ICD_VENDORS=$B/lib/libRusticlOpenCL.so RUSTICL_ENABLE=kgsl
export HOME=$B/tmp XDG_CACHE_HOME=$B/tmp CLC_RESOURCE_DIR=$B/lib/clang/21/include
export GGML_OPENCL_ALLOW_NO_SUBGROUP=1 GGML_OPENCL_FAKE_QCOM_REQD=1
export GGML_OPENCL_MESA_SPIRV=1 GGML_OPENCL_ADRENO_XMEM_GEMM=0
export GGML_OPENCL_OPFLUSH=$OFL
export E2E_NBATCH=512 E2E_SEED=42 E2E_NOMMAP=1 E2E_TEMP=0.7
export LLAMA_MOE_BANK_GPU=0 LLAMA_MOE_UPLOAD=0 LLAMA_MOE_PREFETCH_READ=6
export LLAMA_MOE_LOOKAHEAD_PREFETCH=8 LLAMA_MOE_DECODE_WINDOW=8 LLAMA_MOE_IO_THREADS=1
export GGML_E2E_PROMPT='请详细介绍一下中国的四大发明，分别说明每一项的历史背景、技术要点和对世界文明的影响，分四段展开，每段不少于八十字，不要简短总结'

echo "variant | rc | SUB(cmd) | NC(nr_cmds_total) | FLUSH(FDBATCH) | WAIT | health_text | logits_max"
for V in base nodefer no_bocache reemit tssync wfi inorder nogrow ibtrace; do
  : > $OUT/$V.log
  case $V in
    base)       env > /dev/null ;;
    nodefer)    export FD_NODEFER=1 ;;
    no_bocache) export FD_NO_BOCACHE=1 ;;
    reemit)     export FD_FORCE_REEMIT=1 ;;
    tssync)     export FD_KGSL_TSSYNC=1 ;;
    wfi)        export FD_COMPUTE_WFI=1 ;;
    inorder)    export FD_MESA_DEBUG=inorder ;;
    nogrow)     export FD_MESA_DEBUG=nogrow ;;
    ibtrace)    export FD_IBTRACE=1 ;;
  esac
  timeout 600 ./minicpm_e2e "$M" "$E" 99 256 "$NG" > $OUT/$V.log 2>&1
  RC=$?
  SUB=$(grep -ac '^KGSLSUBMIT cmd\[' $OUT/$V.log)
  NC=$(grep -aoE 'nr_cmds_total=[0-9]+' $OUT/$V.log | tail -1)
  FL=$(grep -ac 'FDBATCH flush' $OUT/$V.log)
  WT=$(grep -ac '^KGSLWAIT' $OUT/$V.log)
  HT=$(grep -acE '上海|四大发明|长城' $OUT/$V.log)
  LM=$(grep -aoE 'max=[0-9.]+' $OUT/$V.log | tail -1)
  # 复位本变体的开关，避免污染下一腿
  unset FD_NODEFER FD_NO_BOCACHE FD_FORCE_REEMIT FD_KGSL_TSSYNC FD_COMPUTE_WFI FD_IBTRACE FD_MESA_DEBUG
  echo "$V | $RC | $SUB | $NC | $FL | $WT | $HT | $LM"
  sleep 30
done
echo "=== KGSL_PROBE_DONE (logs: $OUT) ==="
