#!/system/bin/sh
# [Mesa 线 P2] 把部署 lib 里**从没试过**的 FD_* 开关一次性扫掉 —— 它们正好压在剩余假设上，且不用重编 Mesa。
#
# 依据：从部署那颗 libRusticlOpenCL.so（md5 c82f84d89d6962e582796b114a9f4c83，两台机器同一个）里挖出的完整开关表：
#   FD_COMPUTE_WFI FD_DEV_FEATURES FD_FORCE_REEMIT FD_GPU_TRACEPOINT FD_IBTRACE FD_KGSL_TSSYNC
#   FD_KGSL_USLEEP_US FD_MESA_DEBUG FD_MESA_GMEM FD_NO_BOCACHE FD_NODEFER FD_RD_DUMP(+_FRAMES/_PATH/_SUBMITS/_TESTNAME)
# 今天已扫过并结案的：FD_NODEFER（merged 归零但正确性不动）、FD_MESA_DEBUG=inorder/nogrow（观测量逐位不变=没接）、
# FD_RD_DUMP*（串在但不吐东西，判据 C）。**剩下这几个从没碰过**，且各自对应一条活着的假设：
#   FD_NO_BOCACHE   -> BO 缓存复用错（= §5.1 v3 的 ring/BO 复用假设，最便宜的一次判决）
#   FD_FORCE_REEMIT -> 提交/命令被丢（"kernel 丢失"字面假设）
#   FD_COMPUTE_WFI  -> 等待/完成语义（WFI）与深队列打架
#   FD_KGSL_TSSYNC  -> tsync 等待路径
#   FD_KGSL_USLEEP_US -> 在提交路径注入睡眠：**若正确性随睡眠改变，就是 timing race 的直接证明**
#
# 判据（与融合消融同一套，先写死）：
#   GATE：`repro` 腿必须复现病灶（与 CPU 参照第 1 个 token 就分歧），否则整组作废。
#   胜者：与 CPU 参照 48 token 逐 token 全等 ⇒ 该开关对应的假设成立 ⇒ L1 验收可在**不重编 Mesa** 下达成。
#   部分胜：分歧点从 1 往后挪 ⇒ "参与但不唯一"。
#   特殊判读：`usleep` 腿若与 `repro` **不同**（变好或变坏都算），即证明是 timing race，不是确定性 bug。
#   硬闸：Mesa 腿必须 opencl_lines>0 且 drop=0（退回 CPU 的"全等"不算数）。
#
# 用法：RUN=<dir> B=<mesa_dir> M=<gguf> E=<experts> sh run_p2_fdknob_ab.sh [npred=48]
set -u
BIN=${BIN:-minicpm_e2e}
NPRED=${1:-48}
RUN=${RUN:?}; B=${B:?}; M=${M:?}; E=${E:?}
STAMP=$(date +%H%M); OUT=/data/local/tmp/p2k_$STAMP; mkdir -p $OUT
cd "$RUN" || exit 1
export LD_LIBRARY_PATH=$RUN:$RUN/lib:$B/lib:$B:/data/local/tmp
export OCL_ICD_VENDORS=$B/lib/libRusticlOpenCL.so RUSTICL_ENABLE=kgsl
export HOME=$B/tmp XDG_CACHE_HOME=$B/tmp CLC_RESOURCE_DIR=$B/lib/clang/21/include
export GGML_OPENCL_ALLOW_NO_SUBGROUP=1 GGML_OPENCL_FAKE_QCOM_REQD=1
export GGML_OPENCL_MESA_SPIRV=1 GGML_OPENCL_ADRENO_XMEM_GEMM=0
export E2E_SEED=42 E2E_TEMP=0 E2E_NOMMAP=1
export GGML_E2E_PROMPT='请详细介绍一下中国的四大发明，分别说明每一项的历史背景、技术要点和对世界文明的影响，分四段展开，每段不少于八十字，不要简短总结。'
echo "#### fdknob_ab npred=$NPRED $(date -Iseconds) loadavg=$(cat /proc/loadavg)"

echo "-- LEG cpu_ref (OFF=1) $(date +%H:%M:%S)"
GGML_OPENCL_OFF=1 E2E_TOKDUMP=$OUT/cpu.tok timeout 900 ./$BIN "$M" "$E" 99 "$NPRED" 512 > $OUT/cpu.out 2> $OUT/cpu.err
echo "   rc=$? tok=$(ls -l $OUT/cpu.tok 2>/dev/null | awk '{print $5}')B health=$(grep -acE '造纸|印刷|指南针|火药' $OUT/cpu.out)"
sleep 45

leg () {
  T=$1; shift
  echo "-- LEG $T [$*] $(date +%H:%M:%S)"
  env GGML_OPENCL_OPFLUSH=0 "$@" E2E_TOKDUMP=$OUT/$T.tok timeout 900 ./$BIN "$M" "$E" 99 "$NPRED" 512 \
    > $OUT/$T.out 2> $OUT/$T.err
  echo "   rc=$? tok=$(ls -l $OUT/$T.tok 2>/dev/null | awk '{print $5}')B health=$(grep -acE '造纸|印刷|指南针|火药' $OUT/$T.out) gpu[lines=$(grep -ac ggml_opencl $OUT/$T.err) drop=$(grep -ac 'drop unsupported device' $OUT/$T.err)]"
  sleep 45
}
leg repro
leg nobocache  FD_NO_BOCACHE=1
leg reemit     FD_FORCE_REEMIT=1
leg wfi        FD_COMPUTE_WFI=1
leg tssync     FD_KGSL_TSSYNC=1
leg usleep200  FD_KGSL_USLEEP_US=200
echo "=== P2_FDKNOB_AB_DONE dir=$OUT ==="
echo "读法：python3 third_party/mesa-kgsl/scripts/token_diff.py $OUT/cpu.tok $OUT/repro.tok $OUT/nobocache.tok $OUT/reemit.tok $OUT/wfi.tok $OUT/tssync.tok $OUT/usleep200.tok"
echo "     先验 repro 复现病灶；某腿 48 token 全等 = 该假设成立；usleep 腿只要与 repro 不同就证明是 timing race"
