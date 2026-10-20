#!/system/bin/sh
# [Mesa 线 P2 头号假设] "kernel 丢失"也许根本不是提交层丢内核，而是**我们自己的融合内核有 race**。
#
# 为什么是这一刀（两条独立线索对上了）：
#   1) 今天的层段二分（§11）：gen7 上 `NGL=1` 输出正确、**`NGL>=4` 从 token 1 全崩**，`NGL=99` 吐 48 个 `!`。
#      ⇒ 病灶需要"多层同时在飞"，不是单内核（moe_probe4 在 async 下 GPU NMSE=0.000000）。
#   2) fork 里 2026-10-18 的旧注释（ggml-opencl.cpp:9377-9380）：
#        "[dspark 2026-10-18] opt-out GGML_OPENCL_FUSE_RMS_MUL=0: **race hunt** — the 2-op rms_norm+mul
#         fuse **runs every layer** (attn_post_norm etc.) ... the **whole-graph race disappears only with
#         GGML_OPENCL_DISABLE_FUSION=1**."
#      ⇒ 前人已经撞见过"整图 race"，且只有**关掉融合**才消失；而融合内核实例数正好随层数线性增长。
#
# 所以本脚本在**病灶态**（gen7, `OPFLUSH=0` async, `NGL=99`）下逐个关融合，看能否让 async 与 CPU 48 token 全等。
# 判据（先写死，不许事后改）：
#   GATE：`repro` 腿必须复现病灶（与 CPU 参照从第 1 个 token 就分歧）；不复现 ⇒ 整组作废。
#   胜者：某腿与 CPU 参照 **48 token 逐 token 全等** ⇒ 那个融合就是根因 ⇒ L1 的验收（无 per-op flush 下 48 token 全等）
#         可以**在不重编 Mesa 的前提下达成**，且 P2 从"Mesa 提交层"改判为"我们 ggml 的融合 race"。
#   部分胜：分歧点从 1 往后挪 ⇒ 记"该融合参与但不唯一"。
#   全败：记"融合无罪"，回到 Mesa 侧（ring 复用/grow）。
#   硬闸：每条 Mesa 腿必须 opencl_lines>0 且 drop=0（退回 CPU 的"全等"是同义反复，今天被骗过三次）。
#
# 用法：RUN=<dir> B=<mesa_dir> M=<gguf> E=<experts> sh run_p2_fusion_ab.sh [npred=48]
set -u
BIN=${BIN:-minicpm_e2e}
NPRED=${1:-48}
RUN=${RUN:?}; B=${B:?}; M=${M:?}; E=${E:?}
STAMP=$(date +%H%M); OUT=/data/local/tmp/p2f_$STAMP; mkdir -p $OUT
cd "$RUN" || exit 1
export LD_LIBRARY_PATH=$RUN:$RUN/lib:$B/lib:$B:/data/local/tmp
export OCL_ICD_VENDORS=$B/lib/libRusticlOpenCL.so RUSTICL_ENABLE=kgsl
export HOME=$B/tmp XDG_CACHE_HOME=$B/tmp CLC_RESOURCE_DIR=$B/lib/clang/21/include
export GGML_OPENCL_ALLOW_NO_SUBGROUP=1 GGML_OPENCL_FAKE_QCOM_REQD=1
export GGML_OPENCL_MESA_SPIRV=1 GGML_OPENCL_ADRENO_XMEM_GEMM=0
export E2E_SEED=42 E2E_TEMP=0 E2E_NOMMAP=1
export GGML_E2E_PROMPT='请详细介绍一下中国的四大发明，分别说明每一项的历史背景、技术要点和对世界文明的影响，分四段展开，每段不少于八十字，不要简短总结。'
echo "#### fusion_ab npred=$NPRED $(date -Iseconds) loadavg=$(cat /proc/loadavg)"

echo "-- LEG cpu_ref (OFF=1) $(date +%H:%M:%S)"
GGML_OPENCL_OFF=1 E2E_TOKDUMP=$OUT/cpu.tok timeout 900 ./$BIN "$M" "$E" 99 "$NPRED" 512 > $OUT/cpu.out 2> $OUT/cpu.err
echo "   rc=$? tok=$(ls -l $OUT/cpu.tok 2>/dev/null | awk '{print $5}')B health=$(grep -acE '造纸|印刷|指南针|火药' $OUT/cpu.out)"
sleep 45

leg () { # $1=tag $2..=env（全部在 OPFLUSH=0 病灶态下）
  T=$1; shift
  echo "-- LEG $T [$*] $(date +%H:%M:%S)"
  env GGML_OPENCL_OPFLUSH=0 "$@" E2E_TOKDUMP=$OUT/$T.tok timeout 900 ./$BIN "$M" "$E" 99 "$NPRED" 512 \
    > $OUT/$T.out 2> $OUT/$T.err
  echo "   rc=$? tok=$(ls -l $OUT/$T.tok 2>/dev/null | awk '{print $5}')B health=$(grep -acE '造纸|印刷|指南针|火药' $OUT/$T.out) gpu[lines=$(grep -ac ggml_opencl $OUT/$T.err) drop=$(grep -ac 'drop unsupported device' $OUT/$T.err)]"
  sleep 45
}
leg repro                              # 门：必须复现病灶
leg nofusion      GGML_OPENCL_DISABLE_FUSION=1
leg normsmul      GGML_OPENCL_FUSE_RMS_MUL=0
leg normsadd      GGML_OPENCL_FUSE_RMS_ADD=0
leg nomeglu       GGML_OPENCL_FUSE_MM_GLU=0
echo "=== P2_FUSION_AB_DONE dir=$OUT ==="
echo "读法：python3 third_party/mesa-kgsl/scripts/token_diff.py $OUT/cpu.tok $OUT/repro.tok $OUT/nofusion.tok $OUT/normsmul.tok $OUT/normsadd.tok $OUT/nomeglu.tok"
echo "     先看 repro 是否复现（不复现整组作废）；再看哪条腿 48 token 全等 —— 那条腿的融合就是根因"
