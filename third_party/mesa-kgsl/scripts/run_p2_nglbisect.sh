#!/system/bin/sh
# [Mesa 线 P2] 深队列病灶的"层段二分"：gen7 上 async 从 token 1 全崩，但内核粒度探针（moe_probe4）
# 在 async 下 GPU NMSE=0.000000 —— 单个内核无罪。剩下两种可能：
#   ① 别的算子族在深队列下出错；② 高 op 数下的系统性效应（探针只有几个 op，测不到）。
# 本脚本用 n_gpu_layers 做**单调二分**：把前 k 层放 GPU、其余留 CPU，看 async 从哪个 k 开始崩。
#   * 若 NGL=1 就崩        ⇒ 病灶在"前几层也有的算子"（norm/rope/attention/MoE 之一），转算子族扫；
#   * 若随 k 增大才崩      ⇒ 支持"高 op 数/深队列系统性效应"（②），要按 op 数阈值找拐点；
#   * 若 NGL=99 崩但小 k 全好 ⇒ 与专家层（后段 MoE）有关，回到 MoE 侧但按"批量深度"查而非单内核。
#
# 判据（先写死，不许事后改）：
#   GATE：NGL=99 的 async 腿必须复现已知病灶（与 CPU 参照第 1 个 token 就分歧）；不复现 ⇒ 整组作废。
#   结论：最小的"与 CPU 参照分歧"的 k；若所有 k 都全等而 NGL=99 崩，记为"k 不足以覆盖"（不算结论）。
#   每条腿都要 opencl_lines>0 且 drop=0，否则该腿是退回 CPU 的假全等，一律不算数（今天被骗过三次）。
#
# 用法：RUN=<dir> B=<mesa_dir> M=<gguf> E=<experts> sh run_p2_nglbisect.sh [npred=48] ["1 4 8 16 24 99"]
set -u
BIN=${BIN:-minicpm_e2e}
NPRED=${1:-48}
KS=${2:-"1 4 8 16 24 99"}
RUN=${RUN:?}; B=${B:?}; M=${M:?}; E=${E:?}
STAMP=$(date +%H%M); OUT=/data/local/tmp/p2n_$STAMP; mkdir -p $OUT
cd "$RUN" || exit 1
export LD_LIBRARY_PATH=$RUN:$RUN/lib:$B/lib:$B:/data/local/tmp
export OCL_ICD_VENDORS=$B/lib/libRusticlOpenCL.so RUSTICL_ENABLE=kgsl
export HOME=$B/tmp XDG_CACHE_HOME=$B/tmp CLC_RESOURCE_DIR=$B/lib/clang/21/include
export GGML_OPENCL_ALLOW_NO_SUBGROUP=1 GGML_OPENCL_FAKE_QCOM_REQD=1
export GGML_OPENCL_MESA_SPIRV=1 GGML_OPENCL_ADRENO_XMEM_GEMM=0
export E2E_SEED=42 E2E_TEMP=0 E2E_NOMMAP=1
export GGML_E2E_PROMPT='请详细介绍一下中国的四大发明，分别说明每一项的历史背景、技术要点和对世界文明的影响，分四段展开，每段不少于八十字，不要简短总结。'
[ -f "$RUN/BUILD_INFO" ] && cat "$RUN/BUILD_INFO"
echo "#### nglbisect npred=$NPRED ks=[$KS] $(date -Iseconds) loadavg=$(cat /proc/loadavg)"

echo "-- LEG cpu_ref (OFF=1, 全图 CPU) $(date +%H:%M:%S)"
GGML_OPENCL_OFF=1 E2E_TOKDUMP=$OUT/cpu.tok timeout 900 ./$BIN "$M" "$E" 99 "$NPRED" 512 \
  > $OUT/cpu.out 2> $OUT/cpu.err
echo "   rc=$? tok=$(ls -l $OUT/cpu.tok 2>/dev/null | awk '{print $5}')B health=$(grep -acE '造纸|印刷|指南针|火药' $OUT/cpu.out)"
sleep 45

for K in $KS; do
  echo "-- LEG ngl$K (OPFLUSH=0 async, NGL=$K) $(date +%H:%M:%S)"
  GGML_OPENCL_OPFLUSH=0 E2E_TOKDUMP=$OUT/ngl$K.tok timeout 900 ./$BIN "$M" "$E" "$K" "$NPRED" 512 \
    > $OUT/ngl$K.out 2> $OUT/ngl$K.err
  RC=$?
  echo "   rc=$RC tok=$(ls -l $OUT/ngl$K.tok 2>/dev/null | awk '{print $5}')B $(grep -a 'e2e\]\[METRIC' $OUT/ngl$K.out | tail -1 | cut -c1-96)"
  echo "   gpu[opencl_lines=$(grep -ac ggml_opencl $OUT/ngl$K.err) drop=$(grep -ac 'drop unsupported device' $OUT/ngl$K.err)] health=$(grep -acE '造纸|印刷|指南针|火药' $OUT/ngl$K.out)"
  sleep 45
done
echo "=== P2_NGLBISECT_DONE dir=$OUT ==="
echo "读法：python3 third_party/mesa-kgsl/scripts/token_diff.py $OUT/cpu.tok $OUT/ngl*.tok"
echo "     先看 ngl99 是否复现病灶（不复现整组作废），再取最小分歧 k"
